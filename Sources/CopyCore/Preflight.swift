import Foundation

public struct PreflightResult: Sendable {
    public var blockers: [String]
    public var conflicts: [String]
    public var requiredBytes: Int64
    public var projectedFree: Int64?
    public var immediateFree: Int64?
    public var importantCapacity: Int64?
    public var remainingBytes: Int64 = 0
    public var reservedBytes: Int64 = 0
    public var safetyReserve: Int64 = 0
    public var checkedAt: Date = Date()
    public var canStart: Bool { blockers.isEmpty }
}
public struct Preflight {
    private let inspect: (URL) throws -> VolumeInfo
    public init(inspect: @escaping (URL) throws -> VolumeInfo = VolumeInspector().inspect) { self.inspect = inspect }
    public static func remainingWriteBytes(manifest: CopyManifest, destination: URL) throws -> Int64 {
        _ = try PathSafety.directoryWithoutLinks(destination)
        var total: Int64 = 0
        for entry in manifest.entries where entry.kind == .file {
            do { _ = try FileFingerprint.read(destination.appendingPathComponent(entry.relativePath)) }
            catch let error as POSIXError where error.code == .ENOENT {
                let (next, overflow) = total.addingReportingOverflow(entry.size)
                guard !overflow, entry.size >= 0 else { throw CopyProblem.invalid("容量超出可计算范围") }; total = next
            }
        }
        return total // Existing objects are verified or conflicted, never overwritten.
    }
    public static func reservedBytes(jobs: [TransferJob], volumeID: String, excluding: UUID? = nil) throws -> Int64 {
        var total: Int64 = 0
        for job in jobs where job.id != excluding && job.destinationVolume.id == volumeID && [.pending,.queued,.running,.paused,.needsAttention].contains(job.state) {
            _ = try PathSafety.directoryWithoutLinks(job.destination)
            for entry in job.manifest.entries where entry.kind == .file {
                let path = job.destination.appendingPathComponent(entry.relativePath).standardizedFileURL
                do { _ = try FileFingerprint.read(path) }
                catch let error as POSIXError where error.code == .ENOENT {
                    // Separate jobs can hold separate partial files, even for the same final path.
                    let (next, overflow) = total.addingReportingOverflow(entry.size)
                    guard !overflow, entry.size >= 0 else { throw CopyProblem.invalid("排队容量超出可计算范围") }; total = next
                }
            }
        }
        return total
    }
    public func check(manifest: CopyManifest, destination: URL, reservedBytes: Int64 = 0) throws -> PreflightResult {
        let volume = try inspect(destination)
        var blockers: [String] = []; var conflicts: [String] = []
        do { _ = try PathSafety.directoryWithoutLinks(destination) }
        catch { blockers.append(error.localizedDescription) }
        if volume.readOnly { blockers.append("目标磁盘只读") }
        if reservedBytes < 0 { blockers.append("队列空间预留无效") }
        for source in manifest.selections where PathSafety.contains(source.root, destination) {
            blockers.append("目标不能位于来源内部：\(source.root.lastPathComponent)")
        }
        let existing = try PathSafety.existingAncestor(destination)
        if !FileManager.default.isWritableFile(atPath: existing.path) { blockers.append("没有目标目录写入权限") }
        var names = Set<String>()
        for entry in manifest.entries {
            do { try PathSafety.validateRelative(entry.relativePath) }
            catch { blockers.append("无效路径：\(entry.relativePath)"); continue }
            var key = entry.relativePath.precomposedStringWithCanonicalMapping
            if !volume.caseSensitive { key = key.lowercased() }
            if !names.insert(key).inserted { blockers.append("所选文件的目标路径重名：\(entry.relativePath)") }
            if entry.kind == .unsupported { blockers.append("无法复制并校验：\(entry.relativePath)。\(entry.unsupportedReason ?? "此对象不是受支持的普通文件或目录")。可在预览中明确排除此项后继续其他文件。") }
            if let maxSize = volume.maximumFileSize, entry.size > maxSize { blockers.append("超出目标文件系统单文件大小限制：\(entry.relativePath)") }
            let target = destination.appendingPathComponent(entry.relativePath)
            if PathSafety.contains(entry.sourceURL, target) { blockers.append("目标会覆盖来源：\(entry.relativePath)") }
            var current = destination
            for part in entry.relativePath.split(separator: "/") {
                current.appendPathComponent(String(part))
                if let info = try? FileFingerprint.read(current), info.0 == .unsupported {
                    blockers.append("目标含链接或特殊文件：\(entry.relativePath)"); break
                }
            }
            if let info = try? FileFingerprint.read(target), !(entry.kind == .directory && info.0 == .directory) {
                conflicts.append(entry.relativePath)
            }
        }
        let remaining: Int64
        do { remaining = try Self.remainingWriteBytes(manifest: manifest, destination: destination) }
        catch { remaining = manifest.totalBytes; blockers.append("无法检查目标现有文件，不能确定剩余写入量：\(error.localizedDescription)") }
        let reserve = max(Int64(67_108_864), remaining / 100)
        let (base, overflow1) = remaining.addingReportingOverflow(max(0, reservedBytes))
        let (required, overflow2) = base.addingReportingOverflow(reserve)
        if overflow1 || overflow2 { blockers.append("所需容量超出可计算范围") }
        if let free = volume.immediateFree {
            if free < required { blockers.append("即时可用空间不足：还差 \(max(0, required - free)) 字节（含其他任务预留和安全余量）。释放目标盘空间后重新检查；系统可清理容量不等于已经释放。") }
        } else { blockers.append("无法确定即时可用容量，请重新连接目标") }
        return PreflightResult(blockers: blockers, conflicts: conflicts, requiredBytes: required,
                               projectedFree: overflow1 || overflow2 ? nil : volume.immediateFree.map { $0 - base },
                               immediateFree: volume.immediateFree, importantCapacity: volume.importantCapacity,
                               remainingBytes: remaining, reservedBytes: max(0, reservedBytes), safetyReserve: reserve)
    }
}
