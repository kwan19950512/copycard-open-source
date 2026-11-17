import Foundation
import CopyCore

struct TransferActions {
    func prepareBatch(sources: [URL], destination: URL, algorithm: HashAlgorithm = .xxh64) async throws -> [TransferJob] {
        let combined = try await prepare(sources: sources, destination: destination, algorithm: algorithm)
        return try await Task.detached {
            try Self.partition(combined, cacheDevices: true, inspect: VolumeInspector().inspect)
        }.value
    }
    static func partition(_ combined: TransferJob, cacheDevices: Bool = false, inspect: (URL) throws -> VolumeInfo) throws -> [TransferJob] {
        var groups: [String: [SourceSelection]] = [:]; var order: [String] = []
        var deviceVolumes: [UInt64: VolumeInfo] = [:]
        for source in combined.manifest.selections {
            let (kind, fingerprint) = try FileFingerprint.read(source.root)
            let cached = cacheDevices && kind != .unsupported ? deviceVolumes[fingerprint.device] : nil
            let volume = try cached ?? inspect(source.root)
            if cacheDevices && kind != .unsupported { deviceVolumes[fingerprint.device] = volume }
            if groups[volume.id] == nil { order.append(volume.id) }
            groups[volume.id, default: []].append(source)
        }
        return order.map { id in
            let roots = groups[id]!
            // Membership is lexical: resolving links here would silently omit unsupported shortcuts.
            let entries = combined.manifest.entries.filter { entry in roots.contains {
                let root = $0.root.standardizedFileURL.pathComponents
                return entry.sourceURL.standardizedFileURL.pathComponents.starts(with: root)
            } }
            let volumes = combined.manifest.volumes.filter { $0.id == id }
            let manifest = CopyManifest(selections: roots, entries: entries, volumes: volumes)
            return TransferJob(manifest: manifest, destination: combined.destination, destinationVolume: combined.destinationVolume, algorithm: combined.algorithm)
        }
    }
    func prepare(sources: [URL], destination: URL, algorithm: HashAlgorithm = .xxh64) async throws -> TransferJob {
        try await Task.detached {
            let target = destination.standardizedFileURL.resolvingSymlinksInPath()
            if sources.contains(where: { $0.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == target }) {
                throw CopyProblem.invalid("不能粘贴回原位置，请打开另一个目标文件夹。")
            }
            let manifest = try ManifestBuilder().build(sources.map { SourceSelection(root: $0) })
            return TransferJob(manifest: manifest, destination: destination,
                               destinationVolume: try VolumeInspector().inspect(destination), algorithm: algorithm)
        }.value
    }
    func retarget(job: TransferJob, destination: URL) async throws -> TransferJob {
        try await Task.detached {
            var updated = job
            updated.destination = destination; updated.destinationVolume = try VolumeInspector().inspect(destination)
            updated.destinationAnchor = try DestinationAnchor.capture(destination)
            updated.state = .pending; updated.results = [:]; updated.message = nil
            updated.endedAt = nil; updated.verificationStartedAt = nil; updated.requiresReverification = nil
            updated.reportStatus = .pending; updated.reportPaths = []; updated.reportMessage = nil
            return updated
        }.value
    }
}
