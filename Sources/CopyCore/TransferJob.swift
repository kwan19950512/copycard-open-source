import Foundation

public enum JobState: String, Codable, Sendable { case pending, queued, running, paused, cancelled, needsAttention, completed }
public enum ReportState: String, Codable, Sendable { case pending, saved, failed }
public struct TransferJob: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var batchID: UUID?
    public var manifest: CopyManifest
    public var destination: URL
    public var destinationVolume: VolumeInfo
    public var destinationAnchor: DestinationAnchor?
    public var algorithm: HashAlgorithm
    public var state: JobState = .pending
    public var results: [UUID: FileCopyResult] = [:]
    public var message: String?
    public var createdAt: Date = Date()
    public var endedAt: Date? = nil
    public var historicalEndDate: Date? {
        endedAt ?? (state == .completed ? results.values.map(\.completedAt).max() : nil)
    }
    public var displayName: String {
        let names = manifest.selections.map { $0.root.lastPathComponent }
        return names.count > 1 ? "\(names.first ?? "素材") 等 \(names.count) 项" : (names.first ?? "素材拷贝")
    }
    public static func displayOrder(_ jobs: [TransferJob]) -> [TransferJob] {
        let activeStates: Set<JobState> = [.pending, .queued, .running, .paused]
        return jobs.filter { activeStates.contains($0.state) } + jobs.filter { !activeStates.contains($0.state) }.sorted {
            let a = $0.historicalEndDate ?? $0.createdAt, b = $1.historicalEndDate ?? $1.createdAt
            return a != b ? a > b : $0.id.uuidString < $1.id.uuidString
        }
    }
    public var reportStatus: ReportState = .pending
    public var reportPaths: [URL] = []
    public var reportMessage: String?
    public var excludedEntries: [ManifestEntry]? = nil
    public var requiresReverification: Bool? = nil
    public var verificationStartedAt: Date? = nil
    public func confirmedResult(for id: UUID) -> FileCopyResult? {
        guard let result = results[id] else { return nil }
        if requiresReverification == true {
            guard let started = verificationStartedAt, result.completedAt >= started else { return nil }
        }
        return result
    }
    public var excludedCount: Int { excludedEntries?.count ?? 0 }
    public var completionLabel: String {
        excludedCount == 0 ? "本次所选文件已复制并校验通过" : "本次复制范围已校验通过；另有 \(excludedCount) 项由你排除，未复制、未校验"
    }
    public mutating func excludeUnsupportedEntries() throws {
        let unsupported = manifest.entries.filter { $0.kind == .unsupported }
        guard !unsupported.isEmpty else { return }
        let supported = manifest.entries.filter { $0.kind != .unsupported }
        guard supported.contains(where: { $0.kind == .file || $0.kind == .directory }) else {
            throw CopyProblem.invalid("排除后没有可复制的文件或文件夹，请重新选择来源。")
        }
        excludedEntries = (excludedEntries ?? []) + unsupported
        manifest.entries = supported
    }
    public var successfulFiles: Int { manifest.entries.filter { $0.kind == .file && confirmedResult(for: $0.id)?.status.verified == true }.count }
    public var problemCount: Int { results.values.filter { !$0.status.verified }.count }
    public init(manifest: CopyManifest, destination: URL, destinationVolume: VolumeInfo, algorithm: HashAlgorithm = .xxh64) {
        self.manifest = manifest; self.destination = destination; self.destinationVolume = destinationVolume; self.algorithm = algorithm
        destinationAnchor = try? DestinationAnchor.capture(destination)
    }
}
public struct QueueSnapshot: Sendable {
    public var jobs: [TransferJob]
    public var progress: [UUID: CopyProgress]
    public var persistenceError: String?
    public init(jobs: [TransferJob], progress: [UUID: CopyProgress], persistenceError: String?) {
        self.jobs = jobs; self.progress = progress; self.persistenceError = persistenceError
    }
}
