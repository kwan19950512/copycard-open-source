import AppKit
import CopyCore

extension AppModel {
    func copySelection(_ browser: BrowserModel, pasteboard: NSPasteboard = .general) {
        guard !browser.selected.isEmpty, !acceptingDraft else { return }
        appendCopiedSources(Array(browser.selected))
        pasteboard.clearContents()
        if pasteboard.writeObjects(browser.selected.map { $0 as NSURL }) { copiedPasteboardChange = pasteboard.changeCount }
    }
    func appendCopiedSources(_ urls: [URL]) {
        guard !acceptingDraft else { return }
        var result: [URL] = []
        var roots = Set<String>()
        for url in urls.map(\.standardizedFileURL).sorted(by: { $0.path < $1.path }) {
            var ancestor = url; var covered = false
            while true {
                if roots.contains(ancestor.path) { covered = true; break }
                if ancestor.path == "/" || ancestor.path.isEmpty { break }
                let parent = ancestor.deletingLastPathComponent()
                if parent.path == ancestor.path { break }; ancestor = parent
            }
            if covered { continue }
            roots.insert(url.path); result.append(url)
        }
        guard !result.isEmpty else { return }
        if let existing = copiedBatches.first(where: { $0.sources == result }) { selectCopyBatch(existing.id); return }
        let batch = CopyShelfBatch(sources: result)
        copiedBatches.append(batch)
        selectCopyBatch(batch.id)
        Task {
            let bytes = try? await Task.detached { try ManifestBuilder().build(result.map { SourceSelection(root: $0) }).totalBytes }.value
            if let index = copiedBatches.firstIndex(where: { $0.id == batch.id }) {
                copiedBatches[index].bytes = bytes; copiedBatches[index].statisticsFailed = bytes == nil
                updateShelfStatistics()
            }
        }
        updateShelfStatistics()
    }
    func selectCopyBatch(_ id: UUID) {
        guard !preparing, !acceptingDraft, copiedBatches.contains(where: { $0.id == id }) else { return }
        if draft != nil && draftCopyBatchID == nil { error = "请先确认或取消当前预览；待拷贝批次已保留。"; return }
        let old = draftCopyBatchID, saved = draftJobs
        cancelDraft()
        if let old, let index = copiedBatches.firstIndex(where: { $0.id == old }) { copiedBatches[index].preview = saved }
        selectedCopyBatchID = id; draftCopyBatchID = id
        if let batch = copiedBatches.first(where: { $0.id == id }), !batch.preview.isEmpty {
            draft = batch.preview.first; additionalDrafts = Array(batch.preview.dropFirst()); recheckDraftSpace()
        }
    }
    func removeCopyBatch(_ id: UUID) {
        guard !preparing, !acceptingDraft else { return }
        if draftCopyBatchID == id { cancelDraft() }
        copiedBatches.removeAll { $0.id == id }
        if selectedCopyBatchID == id { selectedCopyBatchID = nil; if let next = copiedBatches.first { selectCopyBatch(next.id) } }
        updateShelfStatistics()
    }
    func removeCopiedSource(_ url: URL) {
        guard !acceptingDraft else { return }
        for batch in copiedBatches where batch.sources.contains(url) { removeCopyBatch(batch.id) }
    }
    private func updateShelfStatistics() {
        copiedBytes = copiedBatches.allSatisfy { $0.bytes != nil } ? copiedBatches.reduce(0) { $0 + ($1.bytes ?? 0) } : nil
        copiedStatisticsFailed = copiedBatches.contains { $0.statisticsFailed }
    }
    func clearCopiedSelection(pasteboard: NSPasteboard = .general) {
        guard !preparing, !acceptingDraft else { return }
        cancelDraft()
        if pasteboard.changeCount == copiedPasteboardChange { pasteboard.clearContents() }
        copiedBatches = []; selectedCopyBatchID = nil; copiedPasteboardChange = -1; updateShelfStatistics()
    }
    func refreshClipboardSelection() {
        // App-owned multi-card shelf is independent of unrelated system clipboard changes.
    }
    func cancelDraft() {
        guard !acceptingDraft else { return }
        preparationID = UUID(); preparationTask?.cancel(); preparationTask = nil
        draft = nil; additionalDrafts = []; draftChecks = [:]; preflightID = UUID(); draftPreflight = nil; preparing = false
        if let id = draftCopyBatchID, let index = copiedBatches.firstIndex(where: { $0.id == id }) { copiedBatches[index].preview = [] }
        draftCopyBatchID = nil
    }
    func paste(into destination: URL) {
        let batch = copiedBatches.first { $0.id == selectedCopyBatchID }
        if !copiedBatches.isEmpty && batch == nil { error = "请先选择一个待拷贝批次，再粘贴到它的目标文件夹。"; return }
        let urls = batch?.sources ?? ((NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
        guard !urls.isEmpty else { error = "剪贴板里没有文件，请先选择文件并复制"; return }
        guard !hasDraftActivity else { error = "当前批次已有预览，请确认、修改目标或取消预览。"; return }
        draftCopyBatchID = batch?.id
        prepare(sources: urls, destination: destination, enqueueWhenReady: true)
    }
    func prepare(sources: [URL], destination: URL, enqueueWhenReady: Bool = false) {
        guard !hasDraftActivity else { error = "已有一项拷贝预览，请先确认或取消，不会替换它。"; return }
        let normalized = sources.map(\.standardizedFileURL).sorted { $0.path < $1.path }
        draftCopyBatchID = copiedBatches.first(where: { $0.sources == normalized })?.id
        let token = UUID(); preparationID = token; preparationLabel = "正在准备拷贝预览，尚未写入文件…"; preparing = true; draft = nil; additionalDrafts = []; draftChecks = [:]; draftPreflight = nil
        preparationTask = Task {
            do {
                let algorithm = HashAlgorithm(rawValue: UserDefaults.standard.string(forKey: "hashAlgorithm") ?? "") ?? .xxh64
                let candidates = try await TransferActions().prepareBatch(sources: sources, destination: destination, algorithm: algorithm)
                guard token == preparationID, !Task.isCancelled else { return }
                draft = candidates.first; additionalDrafts = Array(candidates.dropFirst()); await refreshDraftPreflight()
            } catch { if token == preparationID { self.error = error.localizedDescription } }
            if token == preparationID {
                preparing = false; preparationTask = nil
                if enqueueWhenReady {
                    if draftPreflight?.canStart == true { acceptDraft(start: false) }
                    else if let check = draftPreflight { error = check.blockers.joined(separator: "\n") }
                }
            }
        }
    }
    func refreshDraftPreflight() async {
        let candidates = draftJobs
        guard !candidates.isEmpty else { return }
        let token = UUID(); preflightID = token
        let jobs = await queue?.snapshot().jobs ?? snapshot.jobs
        do {
            let checks = try await Task.detached { () -> [URL: PreflightResult] in
                var output: [URL: PreflightResult] = [:]
                let groups = Dictionary(grouping: candidates, by: \.destination)
                for (destination, group) in groups {
                    let first = group[0]
                    let manifest = CopyManifest(selections: group.flatMap { $0.manifest.selections }, entries: group.flatMap { $0.manifest.entries }, volumes: group.flatMap { $0.manifest.volumes })
                    let reserved = try Preflight.reservedBytes(jobs: jobs.filter { job in !candidates.contains { $0.id == job.id } }, volumeID: first.destinationVolume.id)
                    var check = try Preflight().check(manifest: manifest, destination: destination, reservedBytes: reserved)
                    // Different target folders on the same volume still share available bytes.
                    let siblingBytes = try groups.filter { $0.key != destination && $0.value[0].destinationVolume.id == first.destinationVolume.id }.values.flatMap { $0 }.reduce(Int64(0)) { total, job in
                        let bytes = try Preflight.remainingWriteBytes(manifest: job.manifest, destination: job.destination)
                        let (sum, overflow) = total.addingReportingOverflow(bytes)
                        guard !overflow else { throw CopyProblem.invalid("批次容量超出可计算范围") }; return sum
                    }
                    let (allReserved, overflow) = reserved.addingReportingOverflow(siblingBytes)
                    guard !overflow else { throw CopyProblem.invalid("批次容量超出可计算范围") }
                    if siblingBytes > 0 { check = try Preflight().check(manifest: manifest, destination: destination, reservedBytes: allReserved) }
                    output[destination] = check
                }
                return output
            }.value
            guard preflightID == token, draftJobs.map(\.id) == candidates.map(\.id) else { return }
            draftChecks = checks
            var combined = checks.values.first!
            combined.blockers = checks.values.flatMap(\.blockers); combined.conflicts = checks.values.flatMap(\.conflicts)
            draftPreflight = combined
        } catch { if preflightID == token { draftPreflight = nil; self.error = error.localizedDescription } }
    }
    func recheckDraftSpace() {
        guard draft != nil, !preparing, !acceptingDraft else { return }
        preparing = true; draftPreflight = nil; draftChecks = [:]
        let token = UUID(); preparationID = token
        preparationTask = Task {
            await refreshDraftPreflight()
            if preparationID == token { preparing = false; preparationTask = nil }
        }
    }
    func excludeUnsupportedFromDraft() {
        guard draft != nil, !preparing, !acceptingDraft else { return }
        do {
            let candidates = try draftJobs.map { job -> TransferJob in var value = job; try value.excludeUnsupportedEntries(); return value }
            draft = candidates.first; additionalDrafts = Array(candidates.dropFirst()); draftChecks = [:]; draftPreflight = nil; preparing = true
            let token = UUID(); preparationID = token
            preparationTask = Task {
                await refreshDraftPreflight()
                if token == preparationID { preparing = false; preparationTask = nil }
            }
        } catch { self.error = error.localizedDescription }
    }
    func changeDraftDestination(jobID: UUID? = nil) {
        guard draft != nil, !preparing, !acceptingDraft else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            retargetDraft(to: url, jobID: jobID)
        }
    }
    func retargetDraft(to url: URL, jobID: UUID? = nil) {
        guard draft != nil, !preparing, !acceptingDraft else { return }
        let candidates = draftJobs
        let token = UUID(); preparationID = token; preparing = true; draftPreflight = nil
        preparationTask = Task {
            do {
                var updated: [TransferJob] = []
                for candidate in candidates {
                    updated.append(jobID == nil || candidate.id == jobID ? try await TransferActions().retarget(job: candidate, destination: url) : candidate)
                }
                guard token == preparationID, !Task.isCancelled else { return }
                draft = updated.first; additionalDrafts = Array(updated.dropFirst()); await refreshDraftPreflight()
            } catch { if token == preparationID { self.error = error.localizedDescription } }
            if token == preparationID { preparing = false; preparationTask = nil }
        }
    }
    func acceptDraft(start: Bool) {
        guard !preparing, !acceptingDraft, let candidate = draft, draftPreflight?.canStart == true, let queue else { return }
        acceptingDraft = true
        let candidates = draftJobs
        Task {
            defer { acceptingDraft = false }
            do {
                if snapshot.jobs.contains(where: { $0.id == candidate.id }) { try await queue.replacePending(candidate) }
                else { try await queue.enqueueValidatedBatch(candidates) }
                if let id = draftCopyBatchID {
                    copiedBatches.removeAll { $0.id == id }; selectedCopyBatchID = nil; draftCopyBatchID = nil; updateShelfStatistics()
                }
                draft = nil; additionalDrafts = []; draftChecks = [:]; draftPreflight = nil; queueExpanded = true
                if start { startJobs(candidates.map(\.id)) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func startJobs(_ ids: [UUID]) {
        guard let queue else { return }; sessionsStarted.formUnion(ids)
        if Bundle.main.bundleIdentifier == "local.copycard.app" { notifications.requestPermission() }
        Task { do { try await queue.start(ids: ids) } catch { self.error = error.localizedDescription } }
    }
    func rescanAndContinue(_ job: TransferJob) {
        guard let queue, !hasDraftActivity else { error = "请先完成当前预览，再重新扫描任务。"; return }
        let token = UUID(); preparationID = token; preparationLabel = "正在重新扫描来源，尚未修改任务…"; preparing = true
        preparationTask = Task {
            defer { if preparationID == token { preparing = false; preparationTask = nil } }
            do {
                let scanned = try await Task.detached { try ManifestBuilder().build(job.manifest.selections) }.value
                guard preparationID == token, !Task.isCancelled else { return }
                let plan = try RescanPlan(job: job, scanned: scanned)
                let alert = NSAlert()
                alert.messageText = "重新扫描完成"
                alert.informativeText = "新增 \(plan.added.count) 项，已删除 \(plan.removed.count) 项，已变化 \(plan.changed.count) 项。\n继续后会重新核验已有文件，不覆盖不同的同名文件；已删除来源不再包含在本次范围。变化文件的旧临时数据会保留，但不会自动续用。"
                let groups: [(String, [String])] = [("新增", plan.added), ("删除", plan.removed), ("变化", plan.changed)]
                let details = groups.map { label, paths in "\(label)（\(paths.count) 项）\n" + (paths.isEmpty ? "无" : paths.joined(separator: "\n")) }.joined(separator: "\n\n")
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
                let textView = NSTextView(frame: scroll.bounds); textView.string = details; textView.isEditable = false
                textView.isVerticallyResizable = true; textView.maxSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
                textView.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
                textView.textContainer?.widthTracksTextView = true; textView.sizeToFit()
                scroll.documentView = textView; scroll.hasVerticalScroller = true; alert.accessoryView = scroll
                alert.addButton(withTitle: "继续拷贝并校验"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn, preparationID == token, !Task.isCancelled else { return }
                acceptingDraft = true
                defer { acceptingDraft = false }
                try await queue.applyRescan(id: job.id, plan: plan)
                guard preparationID == token, !Task.isCancelled else { return }
                startJobs([job.id]); queueExpanded = true
            } catch { if preparationID == token { self.error = "重新扫描未完成：\(error.localizedDescription)" } }
        }
    }
    func excludeProblem(job: TransferJob, entry: ManifestEntry) {
        let alert = NSAlert(); alert.messageText = "排除此文件？"
        alert.informativeText = "\(entry.relativePath)\n\n此文件不会在本次任务中复制或校验；来源和目标文件都不会被删除。报告将明确记录此排除项，任务需重新开始核验其他文件。"
        alert.addButton(withTitle: "排除此文件"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try await $0.excludeProblem(jobID: job.id, entryID: entry.id) }
    }
    func perform(_ operation: @escaping (TransferQueue) async throws -> Void) {
        guard let queue else { return }
        Task { do { try await operation(queue) } catch { self.error = error.localizedDescription } }
    }
    func reviewDestination(_ job: TransferJob) {
        guard beginDestinationReview(job) else { return }
        changeDraftDestination()
    }
    @discardableResult func beginDestinationReview(_ job: TransferJob) -> Bool {
        guard !hasDraftActivity else { error = "请先确认或取消当前拷贝预览。"; return false }
        draftCopyBatchID = nil
        draft = job; additionalDrafts = []; draftChecks = [:]; draftPreflight = nil
        return true
    }
    func eject(_ url: URL) {
        Task { do { try await VolumeActions.eject(url, jobs: snapshot.jobs) } catch { self.error = error.localizedDescription } }
    }
}
