import Foundation

public struct RescanPlan: Sendable {
    public let originalIDs: [UUID]
    public let originalDestination: URL
    public let manifest: CopyManifest
    public let added: [String]
    public let removed: [String]
    public let changed: [String]
    public init(job: TransferJob, scanned: CopyManifest) throws {
        let excluded = Set((job.excludedEntries ?? []).map { $0.sourceURL.standardizedFileURL.path })
        func key(_ entry: ManifestEntry) -> String { entry.sourceURL.standardizedFileURL.path + "\0" + entry.relativePath }
        let oldEntries = job.manifest.entries
        let newEntries = scanned.entries.filter { !excluded.contains($0.sourceURL.standardizedFileURL.path) }
        guard job.manifest.fileCount == 0 || newEntries.contains(where: { $0.kind == .file }) else {
            throw CopyProblem.invalid("重新扫描后没有原任务中的普通文件，请检查来源是否可用")
        }
        let old = Dictionary(grouping: oldEntries, by: key), fresh = Dictionary(grouping: newEntries, by: key)
        guard old.values.allSatisfy({ $0.count == 1 }), fresh.values.allSatisfy({ $0.count == 1 }) else { throw CopyProblem.invalid("来源路径重复，无法安全重新扫描") }
        var revised: [ManifestEntry] = [], add: [String] = [], change: [String] = []
        for var entry in newEntries {
            if let previous = old[key(entry)]?.first {
                if previous.kind == entry.kind && previous.fingerprint == entry.fingerprint { entry.id = previous.id }
                else { change.append(entry.relativePath) }
            } else { add.append(entry.relativePath) }
            revised.append(entry)
        }
        originalIDs = oldEntries.map(\.id)
        originalDestination = job.destination.standardizedFileURL
        manifest = CopyManifest(selections: scanned.selections, entries: revised, volumes: scanned.volumes)
        added = add.sorted(); changed = change.sorted()
        removed = oldEntries.filter { fresh[key($0)] == nil }.map(\.relativePath).sorted()
    }
}
