import Foundation
import Darwin

public struct VolumeInfo: Codable, Sendable {
    public var id: String
    public var name: String
    public var root: URL
    public var physicalDevices: Set<String>?
    public var immediateFree: Int64?
    public var importantCapacity: Int64?
    public var readOnly: Bool
    public var caseSensitive: Bool
    public var maximumFileSize: Int64?
    public init(id: String, name: String = "", root: URL, physicalDevices: Set<String>? = nil,
                immediateFree: Int64?, importantCapacity: Int64? = nil, readOnly: Bool = false,
                caseSensitive: Bool = true, maximumFileSize: Int64? = nil) {
        self.id = id; self.name = name; self.root = root; self.physicalDevices = physicalDevices
        self.immediateFree = immediateFree; self.importantCapacity = importantCapacity
        self.readOnly = readOnly; self.caseSensitive = caseSensitive; self.maximumFileSize = maximumFileSize
    }
}
public struct VolumeInspector {
    public init() {}
    public func inspect(_ url: URL) throws -> VolumeInfo {
        var existing = URL(fileURLWithPath: try PathSafety.existingAncestor(url).path)
        existing.removeAllCachedResourceValues()
        let values = try existing.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsReadOnlyKey, .volumeSupportsCaseSensitiveNamesKey])
        var status = statfs()
        let hasStat = statfs(existing.path, &status) == 0
        let available = hasStat ? Int64(clamping: UInt64(status.f_bavail) * UInt64(status.f_bsize)) : values.volumeAvailableCapacity.map(Int64.init)
        let root = values.volume ?? existing
        let disk = diskInfo(existing)
        var physical: Set<String>?
        if let stores = disk?["APFSPhysicalStores"] as? [[String: Any]] {
            let devices = stores.compactMap { $0["APFSPhysicalStore"] as? String }.compactMap { diskInfo(URL(fileURLWithPath: "/dev/" + $0))?["ParentWholeDisk"] as? String }
            if devices.count == stores.count && !devices.isEmpty { physical = Set(devices) }
        } else if disk?["VirtualOrPhysical"] as? String == "Physical", let parent = disk?["ParentWholeDisk"] as? String {
            physical = [parent]
        }
        let fingerprint = try FileFingerprint.read(existing).1
        let identity = values.volumeUUIDString ?? (disk?["VolumeUUID"] as? String)
        let type = (disk?["FilesystemType"] as? String)?.lowercased()
        return VolumeInfo(id: identity ?? "unverified-device-\(fingerprint.device)", name: values.volumeName ?? root.lastPathComponent,
                          root: root, physicalDevices: physical, immediateFree: available,
                          importantCapacity: values.volumeAvailableCapacityForImportantUsage,
                          readOnly: values.volumeIsReadOnly ?? false,
                          caseSensitive: values.volumeSupportsCaseSensitiveNames ?? false,
                          maximumFileSize: type == "msdos" ? 4_294_967_295 : nil)
    }
    private func diskInfo(_ url: URL) -> [String: Any]? {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", url.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
