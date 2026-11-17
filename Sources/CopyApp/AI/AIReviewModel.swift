import Foundation
import CopyCore

@MainActor final class AIReviewModel: ObservableObject, Identifiable {
    let id = UUID()
    let manifest: CopyManifest
    let batches: [MetadataBatch]
    let configuration: AIConfiguration?
    @Published var groups: [AIGroup] = []
    @Published var selected = Set<UUID>()
    @Published var destination: URL?
    @Published var sending = false
    @Published var status = ""
    @Published var error: String?
    @Published var preflightSummary: [String] = []
    @Published var readyJobs: [TransferJob] = []
    var requestTask: Task<Void, Never>?
    init(manifest: CopyManifest, batches: [MetadataBatch], configuration: AIConfiguration? = nil) {
        self.manifest = manifest; self.batches = batches; self.configuration = configuration
    }
    func splitSelection() {
        let entries = groups.flatMap(\.entries).filter { selected.contains($0) }
        guard !entries.isEmpty else { return }
        for i in groups.indices { groups[i].entries.removeAll { selected.contains($0) } }
        groups.removeAll { $0.entries.isEmpty }
        var name = "新分组", suffix = 1
        while groups.contains(where: { $0.folder == name }) { suffix += 1; name = "新分组-\(suffix)" }
        groups.append(AIGroup(folder: name, entries: entries, reason: "用户手动拆分")); invalidatePreview()
    }
    func moveSelection(to id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        let entries = groups.flatMap(\.entries).filter { selected.contains($0) }
        for i in groups.indices { groups[i].entries.removeAll { selected.contains($0) } }
        if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].entries.append(contentsOf: entries) }
        groups.removeAll { $0.entries.isEmpty }; invalidatePreview()
    }
    func mergeAll() {
        guard let first = groups.first else { return }
        groups = [AIGroup(folder: first.folder, entries: groups.flatMap(\.entries), reason: "用户手动合并全部分组")]
        invalidatePreview()
    }
    func invalidatePreview() { readyJobs = []; preflightSummary = [] }
    func send(store: CredentialStore, onFailure: @escaping () -> Void) {
        guard let configuration, !sending else { return }
        sending = true; error = nil; groups = []; invalidatePreview()
        requestTask = Task {
            defer { sending = false }
            do {
                let key = try store.read(account: configuration.endpoint.absoluteString)
                var combined: [AIGroup] = []
                for batch in batches {
                    try Task.checkCancellation(); status = "正在请求第 \(batch.part) / \(batch.parts) 批"
                    let result = try await AIClient().propose(batch: batch, configuration: configuration, credential: key)
                    for group in result.groups {
                        if let i = combined.firstIndex(where: { $0.folder.precomposedStringWithCanonicalMapping.lowercased() == group.folder.precomposedStringWithCanonicalMapping.lowercased() }) {
                            combined[i].entries.append(contentsOf: group.entries)
                        } else { combined.append(group) }
                    }
                }
                try Task.checkCancellation()
                try AIProposal(groups: combined).validate(expected: Set(manifest.entries.map(\.id)))
                groups = combined; status = "建议已生成，尚未创建拷贝任务。请核对归属与目标。"
            } catch is CancellationError { status = "请求已取消，未创建任务" }
            catch { self.error = error.localizedDescription; onFailure() }
        }
    }
    func preview(existingJobs: [TransferJob], algorithm: HashAlgorithm) async {
        guard let destination else { error = "请先选择目标文件夹"; return }
        let proposal = AIProposal(groups: groups), manifest = manifest
        error = nil; invalidatePreview()
        do {
            let result = try await Task.detached { () -> ([TransferJob], [String]) in
                let volume = try VolumeInspector().inspect(destination)
                let jobs = try proposal.jobs(manifest: manifest, destination: destination, volume: volume, algorithm: algorithm)
                var reserved = try Preflight.reservedBytes(jobs: existingJobs, volumeID: volume.id)
                var summary: [String] = []
                for job in jobs {
                    let check = try Preflight().check(manifest: job.manifest, destination: job.destination, reservedBytes: reserved)
                    guard check.canStart else { throw CopyProblem.invalid(check.blockers.joined(separator: "；")) }
                    summary.append("\(job.destination.path)：\(job.manifest.fileCount) 个文件，\(ByteCountFormatter.string(fromByteCount: job.manifest.totalBytes, countStyle: .file))，\(check.conflicts.count) 项同名；预计剩余 \(ByteCountFormatter.string(fromByteCount: check.projectedFree ?? 0, countStyle: .file))")
                    reserved += try Preflight.remainingWriteBytes(manifest: job.manifest, destination: job.destination)
                }
                return (jobs, summary)
            }.value
            guard groups == proposal.groups, self.destination == destination else { return }
            readyJobs = result.0; preflightSummary = result.1
        } catch { self.error = error.localizedDescription }
    }
}
