import Foundation

public actor TransferQueue {
    private var jobs: [TransferJob]
    private let store: JobStore
    private let storeLock: JobStoreLock
    private var closed = false
    private let inspect: (URL) throws -> VolumeInfo
    private var progress: [UUID: CopyProgress] = [:]
    private var controls: [UUID: TransferControl] = [:]
    private var runners: [UUID: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<QueueSnapshot>.Continuation] = [:]
    private var persistenceError: String?
    private var maximumConcurrent = 2
    private var allowSharedDevice = false
    public init(store: JobStore, inspect: @escaping (URL) throws -> VolumeInfo = VolumeInspector().inspect) throws {
        self.store = store; self.inspect = inspect; self.storeLock = try store.acquireLock(); jobs = try store.load()
        if try store.beginSession() {
            for i in jobs.indices where jobs[i].state == .completed || ([.paused, .needsAttention].contains(jobs[i].state) && !jobs[i].results.isEmpty) {
                if jobs[i].state == .completed { jobs[i].state = .needsAttention }
                jobs[i].requiresReverification = true; jobs[i].verificationStartedAt = nil
                jobs[i].message = "上次程序未正常退出：此前校验记录仅为历史结果，请手动继续重新核验目标文件。旧报告不是中断后的重新确认。"
            }
            try store.save(jobs)
        }
    }
    public func snapshot() -> QueueSnapshot { QueueSnapshot(jobs: jobs, progress: progress, persistenceError: persistenceError) }
    public func updates() -> AsyncStream<QueueSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        }
    }
    private func unsubscribe(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func emit() { let value = snapshot(); for s in subscribers.values { s.yield(value) } }
    private func persist() throws {
        guard !closed else { throw CopyProblem.invalid("任务库会话已关闭，请重新打开 App。") }
        do { try store.save(jobs); persistenceError = nil }
        catch {
            persistenceError = "无法保存任务进度：\(error.localizedDescription)"
            for control in controls.values { control.pause() }
            emit(); throw error
        }
        emit()
    }
    public func enqueue(_ job: TransferJob) throws {
        guard persistenceError == nil else { throw CopyProblem.invalid(persistenceError!) }
        guard !jobs.contains(where: { $0.id == job.id }) else { throw CopyProblem.invalid("任务已存在") }
        var pending = job; pending.state = .pending
        if pending.destinationAnchor == nil { pending.destinationAnchor = try DestinationAnchor.capture(pending.destination) }
        jobs.append(pending)
        do { try persist() } catch { jobs.removeAll { $0.id == job.id }; throw error }
    }
    public func enqueueBatch(_ batch: [TransferJob]) throws {
        guard persistenceError == nil else { throw CopyProblem.invalid(persistenceError!) }
        let ids = batch.map(\.id)
        guard Set(ids).count == ids.count, !jobs.contains(where: { ids.contains($0.id) }) else { throw CopyProblem.invalid("分组任务重复") }
        let previous = jobs
        let pending = try batch.map { job -> TransferJob in
            var pending = job; pending.state = .pending
            if pending.destinationAnchor == nil { pending.destinationAnchor = try DestinationAnchor.capture(pending.destination) }
            return pending
        }
        jobs.append(contentsOf: pending)
        do { try persist() } catch { jobs = previous; emit(); throw error }
    }
    public func enqueueValidatedBatch(_ batch: [TransferJob]) throws {
        try validateAdmission(batch, excluding: [])
        try enqueueBatch(batch)
    }
    private func validateAdmission(_ batch: [TransferJob], excluding: Set<UUID>) throws {
        let existing = jobs.filter { !excluding.contains($0.id) }
        for (destination, group) in Dictionary(grouping: batch, by: \.destination) {
            let job = group[0]
            let volume = try inspect(job.destination)
            guard group.allSatisfy({ $0.destinationVolume.id == volume.id }) else { throw CopyProblem.invalid("目标设备已变化，请重新检查目标") }
            let peers = batch.filter { $0.destination != destination && $0.destinationVolume.id == volume.id }
            var reserved = try Preflight.reservedBytes(jobs: existing, volumeID: volume.id)
            for peer in peers {
                let (sum, overflow) = reserved.addingReportingOverflow(try Preflight.remainingWriteBytes(manifest: peer.manifest, destination: peer.destination))
                guard !overflow else { throw CopyProblem.invalid("批次容量超出可计算范围") }; reserved = sum
            }
            let manifest = CopyManifest(selections: group.flatMap { $0.manifest.selections }, entries: group.flatMap { $0.manifest.entries }, volumes: group.flatMap { $0.manifest.volumes })
            let check = try Preflight(inspect: inspect).check(manifest: manifest, destination: destination, reservedBytes: reserved)
            guard check.canStart else { throw CopyProblem.invalid(check.blockers.joined(separator: "；")) }
        }
    }
    public func start(ids: [UUID]) throws {
        guard persistenceError == nil else { throw CopyProblem.invalid(persistenceError!) }
        let batch = UUID()
        for i in jobs.indices where ids.contains(jobs[i].id) && runners[jobs[i].id] == nil && jobs[i].state != .completed {
            jobs[i].state = .queued; jobs[i].batchID = batch; jobs[i].message = nil; jobs[i].endedAt = nil
        }
        try persist(); pump()
    }
    public func pause(id: UUID) throws {
        if let control = controls[id] { control.pause() }
        else if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .completed { jobs[i].state = .paused }
        try persist()
    }
    public func cancel(id: UUID) throws {
        if let control = controls[id] { control.cancel() }
        else if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .completed { jobs[i].state = .cancelled; jobs[i].endedAt = Date() }
        try persist()
    }
    public func retry(id: UUID) throws { try start(ids: [id]) }
    public func applyRescan(id: UUID, plan: RescanPlan) throws {
        guard persistenceError == nil else { throw CopyProblem.invalid(persistenceError!) }
        guard let i = jobs.firstIndex(where: { $0.id == id }), runners[id] == nil,
              [.needsAttention, .paused, .cancelled].contains(jobs[i].state), jobs[i].manifest.entries.map(\.id) == plan.originalIDs,
              jobs[i].destination.standardizedFileURL == plan.originalDestination else {
            throw CopyProblem.invalid("任务已变化，请重新扫描")
        }
        let previous = jobs[i]
        guard Set(previous.manifest.volumes.map(\.id)) == Set(plan.manifest.volumes.map(\.id)),
              !plan.manifest.volumes.contains(where: { $0.id.hasPrefix("unverified-") }) else { throw CopyProblem.invalid("来源磁盘身份变化，请重新选择") }
        try previous.destinationAnchor?.validate()
        guard previous.destinationAnchor != nil else { throw CopyProblem.invalid("任务缺少目标目录身份，请重新选择目标") }
        var updated = previous
        updated.manifest = plan.manifest
        let retained = Set(plan.manifest.entries.map(\.id))
        updated.results = previous.results.filter { retained.contains($0.key) }
        updated.requiresReverification = true; updated.verificationStartedAt = nil
        updated.state = .pending; updated.message = nil; updated.endedAt = nil
        updated.reportStatus = .pending; updated.reportPaths = []; updated.reportMessage = nil
        try validateAdmission([updated], excluding: [id])
        jobs[i] = updated
        do { try persist() } catch { jobs[i] = previous; emit(); throw error }
    }
    public func clearTask(id: UUID) throws {
        guard persistenceError == nil else { throw CopyProblem.invalid(persistenceError!) }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard runners[id] == nil, jobs[index].state != .running, jobs[index].state != .queued else {
            throw CopyProblem.invalid("请先暂停或取消任务，再清除记录；文件不会被删除")
        }
        let previous = jobs
        jobs.remove(at: index)
        do { try persist() } catch { jobs = previous; emit(); throw error }
    }
    public func excludeProblem(jobID: UUID, entryID: UUID) throws {
        guard persistenceError == nil else { throw CopyProblem.invalid(persistenceError!) }
        guard let i = jobs.firstIndex(where: { $0.id == jobID }), runners[jobID] == nil,
              [.needsAttention, .paused, .cancelled].contains(jobs[i].state),
              let entry = jobs[i].manifest.entries.first(where: { $0.id == entryID && $0.kind == .file }),
              let result = jobs[i].results[entryID], !result.status.verified else {
            throw CopyProblem.invalid("只能排除已停止任务中的待处理文件")
        }
        let previous = jobs[i]
        var excluded = entry; excluded.unsupportedReason = "用户明确排除，未复制、未校验"
        jobs[i].excludedEntries = (jobs[i].excludedEntries ?? []) + [excluded]
        jobs[i].manifest.entries.removeAll { $0.id == entryID }
        jobs[i].results.removeValue(forKey: entryID)
        jobs[i].requiresReverification = true; jobs[i].verificationStartedAt = nil
        jobs[i].state = .pending; jobs[i].message = nil; jobs[i].endedAt = nil
        jobs[i].reportStatus = .pending; jobs[i].reportPaths = []; jobs[i].reportMessage = nil
        do { try persist() } catch { jobs[i] = previous; emit(); throw error }
    }
    public func replacePending(_ job: TransferJob) throws {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }), runners[job.id] == nil else { throw CopyProblem.invalid("请先暂停任务再修改目标") }
        try validateAdmission([job], excluding: [job.id])
        let previous = jobs[i]
        jobs[i] = job; jobs[i].state = .pending
        do { try persist() } catch { jobs[i] = previous; emit(); throw error }
    }
    public func regenerateReport(id: UUID) throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .running else { return }
        do {
            guard let anchor = jobs[i].destinationAnchor else { throw CopyProblem.invalid("旧任务缺少目录身份，不能直接向目标补存报告") }
            try anchor.validate()
            let currentTarget = try inspect(jobs[i].destination)
            guard currentTarget.id == jobs[i].destinationVolume.id, !currentTarget.id.hasPrefix("unverified-") else {
                throw CopyProblem.invalid("目标设备身份已变化，报告仅保留在本机任务记录中")
            }
            let paths = try ReportWriter().write(job: jobs[i], directory: jobs[i].destination)
            jobs[i].reportPaths = paths.all; jobs[i].reportStatus = .saved; jobs[i].reportMessage = nil
            try persist()
        } catch {
            jobs[i].reportStatus = .failed; jobs[i].reportMessage = error.localizedDescription
            try? persist(); throw error
        }
    }
    public func reorder(ids: [UUID]) throws {
        guard ids.count == jobs.count, Set(ids) == Set(jobs.map(\.id)) else { throw CopyProblem.invalid("队列顺序无效") }
        let byID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        jobs = ids.compactMap { byID[$0] }; try persist(); pump()
    }
    public func configureConcurrency(limit: Int, allowSharedDevice: Bool) {
        maximumConcurrent = min(2, max(1, limit)); self.allowSharedDevice = allowSharedDevice; pump()
    }
    public func pauseAllAndWait() async throws {
        for i in jobs.indices where jobs[i].state == .queued { jobs[i].state = .paused }
        for control in controls.values { control.pause() }
        let running = Array(runners.values)
        for task in running { await task.value }
        try persist()
    }
    public func closeSession() async throws {
        guard !closed else { return }
        try await pauseAllAndWait()
        try store.endSession()
        closed = true
        storeLock.release()
    }
    private func pump() {
        guard persistenceError == nil else { return }
        let active = jobs.filter { runners[$0.id] != nil }
        for id in DeviceScheduler.eligibleJobs(jobs: jobs, active: active, limit: maximumConcurrent, allowSharedDevice: allowSharedDevice) {
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { continue }
            let control = TransferControl(); controls[id] = control
            jobs[i].state = .running
            do { try persist() } catch { jobs[i].state = .paused; controls[id] = nil; return }
            runners[id] = Task { await self.run(id: id, control: control) }
        }
    }
    private func run(id: UUID, control: TransferControl) async {
        defer { runners[id] = nil; controls[id] = nil; progress[id] = nil; rateSamples[id] = nil; lastProgressEmission[id] = nil; emit(); pump() }
        guard let initial = jobs.first(where: { $0.id == id }) else { return }
        do {
            // Older pre-release snapshots have no anchor; require explicit retarget instead of trusting them.
            guard let anchor = initial.destinationAnchor else { throw CopyProblem.invalid("旧任务缺少目录身份记录，请更换目标并重新确认") }
            try anchor.validate()
            let currentTarget = try inspect(initial.destination)
            guard currentTarget.id == initial.destinationVolume.id else { throw CopyProblem.invalid("目标设备与原任务不一致，请重新定位") }
            for selection in initial.manifest.selections {
                let current = try inspect(selection.root)
                guard initial.manifest.volumes.contains(where: { $0.id == current.id }), !current.id.hasPrefix("unverified-") else {
                    throw CopyProblem.invalid("来源设备身份无法确认，请重新选择")
                }
            }
            let reserved = try Preflight.reservedBytes(jobs: jobs.filter { $0.state == .running }, volumeID: initial.destinationVolume.id, excluding: id)
            let preflight = try Preflight(inspect: inspect).check(manifest: initial.manifest, destination: initial.destination, reservedBytes: reserved)
            guard preflight.canStart else { throw CopyProblem.invalid(preflight.blockers.joined(separator: "；")) }
            if let i = jobs.firstIndex(where: { $0.id == id }) {
                jobs[i].requiresReverification = true; jobs[i].verificationStartedAt = Date(); try persist()
            }
            let engine = CopyEngine()
            var processedBytes: Int64 = 0, verifiedFiles = 0
            var checkpoint = ProgressCheckpoint()
            for entry in initial.manifest.entries {
                if let interruption = control.interruption {
                    try finish(id: id, state: interruption == .cancelled ? .cancelled : .paused); return
                }
                try jobs.first(where: { $0.id == id })?.destinationAnchor?.validate()
                let processedBefore = processedBytes, verifiedBefore = verifiedFiles
                let result = await engine.copy(entry: entry, destination: initial.destination, algorithm: initial.algorithm, control: control, previousTemporaryName: initial.results[entry.id]?.temporaryName) { value in
                    let combined = value.inJob(completedBytes: processedBefore, totalBytes: initial.manifest.totalBytes, verifiedFiles: verifiedBefore, totalFiles: initial.manifest.fileCount)
                    Task { self.reportProgress(id: id, value: combined) }
                }
                processedBytes += entry.size
                if entry.kind == .file && result.status.verified { verifiedFiles += 1 }
                guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
                jobs[i].results[entry.id] = result
                if result.status.verified, let anchor = jobs[i].destinationAnchor {
                    try anchor.validate()
                    let current = try DestinationAnchor.capture(initial.destination)
                    if current.path != anchor.path { jobs[i].destinationAnchor = current }
                }
                if checkpoint.shouldSave(now: ProcessInfo.processInfo.systemUptime, urgent: [.paused, .cancelled, .failed].contains(result.status)) {
                    try persist()
                }
                if result.status == .paused || result.status == .cancelled {
                    try finish(id: id, state: result.status == .paused ? .paused : .cancelled, message: result.message); return
                }
                // Device loss/space failure ends this job; other independent jobs continue.
                if result.status == .failed {
                    try finish(id: id, state: .needsAttention, message: result.message); return
                }
            }
            guard let job = jobs.first(where: { $0.id == id }) else { return }
            let success = job.manifest.entries.allSatisfy { job.confirmedResult(for: $0.id)?.status.verified == true }
            if success && job.excludedCount > 0 && job.manifest.fileCount == 0 {
                try finish(id: id, state: .needsAttention, message: "没有文件通过校验；\(job.excludedCount) 项已明确排除，未复制、未校验。")
                return
            }
            if success {
                if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].message = "正在复查来源是否新增、删除或变化…"; emit() }
                let current = try await Task.detached { try ManifestBuilder().build(job.manifest.selections) }.value
                if let interruption = control.interruption {
                    try finish(id: id, state: interruption == .cancelled ? .cancelled : .paused); return
                }
                if SourceSnapshot.hasChanges(original: job.manifest, current: current, excluded: job.excludedEntries ?? []) {
                    try finish(id: id, state: .needsAttention, message: "来源在拷贝期间新增、删除或更改了项目；本次不能标记全部完成，请重新扫描处理。")
                    return
                }
            }
            try finish(id: id, state: success ? .completed : .needsAttention)
        } catch {
            try? finish(id: id, state: .needsAttention, message: error.localizedDescription)
        }
    }
    private func finish(id: UUID, state: JobState, message: String? = nil) throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = state; jobs[i].message = message
        if [.completed, .needsAttention, .cancelled].contains(state) { jobs[i].endedAt = Date() }
        try persist()
        if state == .completed { jobs[i].requiresReverification = false; try persist() }
        if state == .completed || state == .needsAttention { try? regenerateReport(id: id) }
    }
    private var lastProgressEmission: [UUID: Date] = [:]
    private var rateSamples: [UUID: TransferRateEstimator] = [:]
    private func reportProgress(id: UUID, value: CopyProgress) {
        guard runners[id] != nil else { return }
        let measured = rateSamples[id, default: TransferRateEstimator()].measure(value, at: ProcessInfo.processInfo.systemUptime)
        progress[id] = measured
        if Date().timeIntervalSince(lastProgressEmission[id] ?? .distantPast) >= 0.1 {
            lastProgressEmission[id] = Date(); emit()
        }
    }
}

struct ProgressCheckpoint {
    private var items = 0
    private var lastSave = ProcessInfo.processInfo.systemUptime
    mutating func shouldSave(now: TimeInterval, urgent: Bool = false) -> Bool {
        items += 1
        guard urgent || items >= 32 || now - lastSave >= 2 else { return false }
        items = 0; lastSave = now; return true
    }
}
