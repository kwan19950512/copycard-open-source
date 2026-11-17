import Foundation

/// Binds a confirmed target (or its nearest existing ancestor) across pauses and launches.
public struct DestinationAnchor: Codable, Sendable {
    public var path: URL
    public var device: UInt64
    public var inode: UInt64
    public static func capture(_ destination: URL) throws -> DestinationAnchor {
        let safe = try PathSafety.directoryWithoutLinks(destination)
        let path = try PathSafety.existingAncestor(safe)
        let (kind, fingerprint) = try FileFingerprint.read(path)
        guard kind == .directory else { throw CopyProblem.invalid("目标祖先不是目录") }
        return DestinationAnchor(path: path, device: fingerprint.device, inode: fingerprint.inode)
    }
    public func validate() throws {
        _ = try PathSafety.directoryWithoutLinks(path)
        let (kind, current) = try FileFingerprint.read(path)
        guard kind == .directory, current.device == device, current.inode == inode else {
            throw CopyProblem.invalid("目标目录已被替换或设备已变化，请重新选择目标")
        }
    }
}
