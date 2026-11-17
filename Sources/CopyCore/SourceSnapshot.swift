import Foundation

enum SourceSnapshot {
    static func hasChanges(original: CopyManifest, current: CopyManifest, excluded: [ManifestEntry]) -> Bool {
        let excludedPaths = Set(excluded.map { $0.sourceURL.standardizedFileURL.path })
        func relevant(_ manifest: CopyManifest) -> [String: ManifestEntry]? {
            var entries: [String: ManifestEntry] = [:]
            for entry in manifest.entries where !excludedPaths.contains(entry.sourceURL.standardizedFileURL.path) {
                let key = entry.sourceURL.standardizedFileURL.path + "\0" + entry.relativePath
                guard entries[key] == nil else { return nil }
                entries[key] = entry
            }
            return entries
        }
        guard let before = relevant(original), let after = relevant(current), before.count == after.count else { return true }
        for (key, entry) in before {
            guard let now = after[key], now.kind == entry.kind else { return true }
            if entry.kind == .directory {
                if now.fingerprint.device != entry.fingerprint.device || now.fingerprint.inode != entry.fingerprint.inode { return true }
            } else if now.fingerprint != entry.fingerprint { return true }
        }
        return false
    }
}
