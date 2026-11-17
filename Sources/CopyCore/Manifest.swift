import Foundation
import Darwin

public struct SourceSelection: Codable, Sendable {
    public let root: URL
    public let includeRoot: Bool
    public init(root: URL, includeRoot: Bool = true) { self.root = root; self.includeRoot = includeRoot }
}
public enum EntryKind: String, Codable, Sendable { case file, directory, unsupported }
public struct FileFingerprint: Codable, Equatable, Sendable {
    public var size: Int64
    public var device: UInt64
    public var inode: UInt64
    public var modifiedSeconds: Int64
    public var modifiedNanos: Int64
    public var changedSeconds: Int64? = nil
    public var changedNanos: Int64? = nil
}
public struct ManifestEntry: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sourceURL: URL
    public var relativePath: String
    public var kind: EntryKind
    public var fingerprint: FileFingerprint
    public var unsupportedReason: String? = nil
    public var size: Int64 { kind == .file ? fingerprint.size : 0 }
}
public struct CopyManifest: Codable, Sendable {
    public var selections: [SourceSelection]
    public var entries: [ManifestEntry]
    public var volumes: [VolumeInfo]
    public init(selections: [SourceSelection], entries: [ManifestEntry], volumes: [VolumeInfo]) {
        self.selections = selections; self.entries = entries; self.volumes = volumes
    }
    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    public var fileCount: Int { entries.filter { $0.kind == .file }.count }
}
public enum CopyProblem: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
public struct ManifestBuilder {
    public init() {}
    public func build(_ selections: [SourceSelection]) throws -> CopyManifest {
        guard !selections.isEmpty else { throw CopyProblem.invalid("请选择来源文件") }
        let sorted = selections.sorted { $0.root.standardizedFileURL.pathComponents.count < $1.root.standardizedFileURL.pathComponents.count }
        var roots: [SourceSelection] = []
        var rootPaths = Set<String>()
        for item in sorted {
            var ancestor = item.root.standardizedFileURL
            let canonical = ancestor.path
            var covered = false
            while true {
                if rootPaths.contains(ancestor.path) { covered = true; break }
                if ancestor.path == "/" || ancestor.path.isEmpty { break }
                let parent = ancestor.deletingLastPathComponent()
                if parent.path == ancestor.path { break }; ancestor = parent
            }
            if covered { continue }
            rootPaths.insert(canonical)
            roots.append(item)
        }
        var entries: [ManifestEntry] = []
        var volumeMap: [String: VolumeInfo] = [:]
        var deviceVolumes: [UInt64: VolumeInfo] = [:]
        func walk(_ url: URL, _ relative: String) throws {
            let (kind, fingerprint) = try FileFingerprint.read(url)
            let alias = (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
            let effectiveKind: EntryKind = alias ? .unsupported : kind
            if !relative.isEmpty {
                try PathSafety.validateRelative(relative)
                entries.append(ManifestEntry(id: UUID(), sourceURL: url, relativePath: relative,
                                             kind: effectiveKind, fingerprint: fingerprint,
                                             unsupportedReason: effectiveKind == .unsupported ? (kind == .unsupported ? FileFingerprint.unsupportedReason(url) : "Finder 替身（快捷方式），当前版本无法复制并验证其指向关系") : nil))
            }
            if effectiveKind == .directory {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try walk(child, relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            }
        }
        for selection in roots {
            let (kind, fingerprint) = try FileFingerprint.read(selection.root)
            let volume = try (kind != .unsupported ? deviceVolumes[fingerprint.device] : nil) ?? VolumeInspector().inspect(selection.root)
            if kind != .unsupported { deviceVolumes[fingerprint.device] = volume }
            volumeMap[volume.id] = volume
            let name = selection.includeRoot || kind != .directory ? selection.root.lastPathComponent : ""
            try walk(selection.root, name)
        }
        return CopyManifest(selections: roots, entries: entries, volumes: Array(volumeMap.values))
    }
}

extension FileFingerprint {
    static func unsupportedReason(_ url: URL) -> String {
        var value = stat()
        if lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFLNK {
            return "符号链接（快捷方式），当前版本不会跟随它复制指向的内容，也不支持复制并验证链接本身"
        }
        return "特殊文件对象，当前版本无法按普通文件复制并校验"
    }
    static func from(_ value: stat) -> FileFingerprint {
        FileFingerprint(size: value.st_size, device: UInt64(UInt32(bitPattern: value.st_dev)),
                        inode: value.st_ino, modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
                        modifiedNanos: Int64(value.st_mtimespec.tv_nsec), changedSeconds: Int64(value.st_ctimespec.tv_sec),
                        changedNanos: Int64(value.st_ctimespec.tv_nsec))
    }
    public static func read(_ url: URL) throws -> (EntryKind, FileFingerprint) {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let type = value.st_mode & S_IFMT
        let kind: EntryKind = type == S_IFREG ? .file : (type == S_IFDIR ? .directory : .unsupported)
        return (kind, from(value))
    }
}
