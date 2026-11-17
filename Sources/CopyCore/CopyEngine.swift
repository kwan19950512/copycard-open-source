import Foundation
import Darwin

public struct CopyEngine {
    private let io: FileIO
    private let availableSpace: (URL) throws -> Int64
    public init(io: FileIO = SystemFileIO(), availableSpace: @escaping (URL) throws -> Int64 = CopyEngine.availableSpace) {
        self.io = io; self.availableSpace = availableSpace
    }
    public static func availableSpace(_ url: URL) throws -> Int64 {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw posixFailure() }
        return Int64(clamping: UInt64(info.f_bavail) * UInt64(info.f_bsize))
    }
    public func copy(entry: ManifestEntry, destination: URL, algorithm: HashAlgorithm,
                     control: TransferControl = TransferControl(),
                     previousTemporaryName: String? = nil,
                     onProgress: (CopyProgress) -> Void = { _ in }) async -> FileCopyResult {
        var temporary: String?
        do {
            try checkControl(control)
            try PathSafety.validateRelative(entry.relativePath)
            guard entry.kind != .unsupported else { throw CopyProblem.invalid("不支持的文件类型") }
            guard !PathSafety.contains(entry.sourceURL, destination.appendingPathComponent(entry.relativePath)) else {
                throw CopyProblem.invalid("目标不能覆盖来源")
            }
            if entry.kind == .directory {
                try validateSourceDirectory(entry)
                let directory = try SecureDirectory(root: destination, subdirectory: entry.relativePath)
                try directory.validate()
                try validateSourceDirectory(entry)
                return FileCopyResult(entryID: entry.id, status: .directoryCreated)
            }
            let components = entry.relativePath.split(separator: "/").map(String.init)
            let name = components.last!
            let directory = try SecureDirectory(root: destination, subdirectory: components.dropLast().joined(separator: "/"))
            try directory.validate()
            let source = open(entry.sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard source >= 0 else { throw posixFailure() }
            defer { close(source) }
            try validateSource(source, entry)
            var existing = stat()
            let exists = fstatat(directory.fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0
            if !exists && errno != ENOENT { throw posixFailure() }
            if exists {
                guard existing.st_mode & S_IFMT == S_IFREG else {
                    return FileCopyResult(entryID: entry.id, status: .conflict, message: "目标同名对象不是普通文件")
                }
                do {
                    let sourceHash = try digest(fd: source, entry: entry, phase: .checkingExisting, control: control, onProgress: onProgress)
                    let dest = try io.openReadback(parentFD: directory.fd, name: name)
                    defer { close(dest) }
                    let before = try fingerprint(dest)
                    let sourceIdentity = try fingerprint(source)
                    guard before.device != sourceIdentity.device || before.inode != sourceIdentity.inode else {
                        throw CopyProblem.invalid("目标与来源是同一个文件（硬链接），不是独立副本；未覆盖。")
                    }
                    let targetHash = try digest(fd: dest, entry: entry, phase: .verifying, control: control, onProgress: onProgress)
                    try validateSource(source, entry)
                    try directory.validate()
                    guard try fingerprint(dest) == before else { throw CopyProblem.invalid("目标文件在校验中改变") }
                    try validateNamedFile(parent: directory.fd, name: name, expected: before)
                    if sourceHash == targetHash && before.size == entry.size {
                        let warning: String?
                        do { try FileTimestamps.verify(source: source, target: dest); warning = nil }
                        catch { warning = "内容一致，但创建或修改时间不同或无法核实；已有文件时间未修改。" }
                        return FileCopyResult(entryID: entry.id, status: .existingVerified, digest: sourceHash, message: warning)
                    }
                    return FileCopyResult(entryID: entry.id, status: .conflict, message: "同名文件内容不同，未覆盖")
                } catch let interruption as Interrupted { throw interruption }
                catch { return FileCopyResult(entryID: entry.id, status: .conflict, message: error.localizedDescription) }
            }
            var tempName = ".copycard-\(entry.id.uuidString)-\(UUID().uuidString).partial"
            var out: Int32 = -1
            var copied: Int64 = 0
            var hasher = StreamingHasher(algorithm: algorithm)
            if let previousTemporaryName,
               previousTemporaryName.hasPrefix(".copycard-\(entry.id.uuidString)-"),
               previousTemporaryName.hasSuffix(".partial"), !previousTemporaryName.contains("/") {
                let candidate = openat(directory.fd, previousTemporaryName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                if candidate >= 0 {
                    var candidateOpen = true
                    var info = stat()
                    let valid = fstat(candidate, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1 && info.st_size >= 0 && info.st_size <= entry.size
                    if valid {
                        temporary = previousTemporaryName
                        do {
                            // Compare the entire saved prefix with today's source before appending.
                            var matches = true
                            while copied < info.st_size {
                                try checkControl(control)
                                let count = Int(min(1_048_576, info.st_size - copied))
                                let sourceBytes = try io.read(source, count: count)
                                let savedBytes = try io.read(candidate, count: count)
                                guard !sourceBytes.isEmpty, sourceBytes == savedBytes else { matches = false; break }
                                hasher.update(sourceBytes); copied += Int64(sourceBytes.count)
                                onProgress(CopyProgress(phase: .copying, relativePath: entry.relativePath, bytes: copied, total: entry.size))
                            }
                            try validateSource(source, entry); try directory.validate()
                            if matches {
                                try validateNamedFile(parent: directory.fd, name: previousTemporaryName, expected: FileFingerprint.from(info))
                                out = candidate; tempName = previousTemporaryName
                            } else {
                                close(candidate); candidateOpen = false; copied = 0; hasher = StreamingHasher(algorithm: algorithm); temporary = nil
                                guard lseek(source, 0, SEEK_SET) == 0 else { throw posixFailure() }
                            }
                        } catch { if candidateOpen { close(candidate) }; throw error }
                    } else { close(candidate) }
                }
            }
            if out < 0 { out = openat(directory.fd, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            guard out >= 0 else { throw posixFailure() }
            temporary = tempName
            var outputOpen = true
            defer { if outputOpen { close(out) } }
            var nextSpaceCheck = Date.distantPast
            while true {
                try checkControl(control); try directory.validate()
                if copied < entry.size && Date() >= nextSpaceCheck {
                    let free = try availableSpace(destination)
                    let reserve = max(Int64(67_108_864), entry.size / 100)
                    guard free >= reserve + 1_048_576 else {
                        throw SpaceInterrupted(message: "目标即时空间不足，已暂停。可用 \(free) 字节，安全余量 \(reserve) 字节；当前文件尚余 \(max(0, entry.size - copied)) 字节。已完成文件和临时文件保留，释放空间后手动继续。")
                    }
                    nextSpaceCheck = Date().addingTimeInterval(0.5)
                }
                let bytes = try io.read(source, count: 1_048_576)
                if bytes.isEmpty { break }
                hasher.update(bytes)
                try io.write(out, data: bytes)
                copied += Int64(bytes.count)
                onProgress(CopyProgress(phase: .copying, relativePath: entry.relativePath, bytes: copied, total: entry.size))
            }
            guard copied == entry.size else { throw CopyProblem.invalid("来源大小在复制中改变") }
            try validateSource(source, entry)
            do { try io.preserveTimestamps(source: source, target: out) }
            catch {
                if (error as? POSIXError)?.code == .ENOSPC { throw error }
                throw CopyProblem.invalid("无法保留文件创建时间/修改时间：\(error.localizedDescription)。未标记完成，临时文件保留。")
            }
            try io.synchronize(out)
            guard close(out) == 0 else { outputOpen = false; throw posixFailure() }
            outputOpen = false
            try checkControl(control)
            let readback = try io.openReadback(parentFD: directory.fd, name: tempName)
            defer { close(readback) }
            let before = try fingerprint(readback)
            let targetHash = try digest(fd: readback, entry: entry, phase: .verifying, control: control, onProgress: onProgress)
            guard hasher.finalize() == targetHash, before.size == entry.size,
                  try fingerprint(readback) == before else { throw CopyProblem.invalid("目标读回校验失败，保留临时文件") }
            try validateNamedFile(parent: directory.fd, name: tempName, expected: before)
            do { try FileTimestamps.verify(source: source, target: readback) }
            catch { throw CopyProblem.invalid("创建时间/修改时间复核失败，未发布最终文件：\(error.localizedDescription)") }
            try validateSource(source, entry); try directory.validate(); try checkControl(control)
            try io.publish(parentFD: directory.fd, temporaryName: tempName, finalName: name)
            temporary = nil
            try directory.validate()
            try validateSource(source, entry)
            let published = try fingerprint(readback)
            guard published.size == before.size, published.device == before.device, published.inode == before.inode,
                  published.modifiedSeconds == before.modifiedSeconds, published.modifiedNanos == before.modifiedNanos else {
                throw CopyProblem.invalid("发布后的文件发生变化，不能标记校验通过")
            }
            try validateNamedFile(parent: directory.fd, name: name, expected: published)
            guard try fingerprint(readback) == published else { throw CopyProblem.invalid("发布后的文件发生变化，不能标记校验通过") }
            do { try FileTimestamps.verify(source: source, target: readback) }
            catch { throw CopyProblem.invalid("发布后的创建时间/修改时间发生变化，不能标记完成：\(error.localizedDescription)") }
            return FileCopyResult(entryID: entry.id, status: .copiedVerified, digest: targetHash)
        } catch let interruption as SpaceInterrupted {
            return FileCopyResult(entryID: entry.id, status: .paused, message: interruption.message, temporaryName: temporary)
        } catch let interruption as Interrupted {
            return FileCopyResult(entryID: entry.id, status: interruption.status, temporaryName: temporary)
        } catch {
            if (error as? POSIXError)?.code == .ENOSPC {
                return FileCopyResult(entryID: entry.id, status: .paused, message: "目标磁盘空间已耗尽，已暂停。已完成文件及未完成临时文件保留；释放空间后手动继续并重新校验。", temporaryName: temporary)
            }
            let status: FileCopyStatus = (error as? POSIXError)?.code == .EEXIST ? .conflict : .failed
            return FileCopyResult(entryID: entry.id, status: status, message: error.localizedDescription, temporaryName: temporary)
        }

        func digest(fd: Int32, entry: ManifestEntry, phase: TransferPhase, control: TransferControl,
                    onProgress: (CopyProgress) -> Void) throws -> String {
            var hasher = StreamingHasher(algorithm: algorithm); var count: Int64 = 0
            while true {
                try checkControl(control)
                let bytes = try io.read(fd, count: 1_048_576)
                if bytes.isEmpty { break }
                hasher.update(bytes); count += Int64(bytes.count)
                onProgress(CopyProgress(phase: phase, relativePath: entry.relativePath, bytes: count, total: entry.size))
            }
            return hasher.finalize()
        }
    }
    private struct Interrupted: Error { var status: FileCopyStatus }
    private struct SpaceInterrupted: Error { var message: String }
    private func checkControl(_ control: TransferControl) throws {
        if let status = control.interruption { throw Interrupted(status: status) }
        if Task.isCancelled { throw Interrupted(status: .paused) }
    }
    private func fingerprint(_ fd: Int32) throws -> FileFingerprint {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw posixFailure() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw CopyProblem.invalid("不是普通文件") }
        return FileFingerprint.from(info)
    }
    private func validateSource(_ fd: Int32, _ entry: ManifestEntry) throws {
        guard try fingerprint(fd) == entry.fingerprint, try FileFingerprint.read(entry.sourceURL).1 == entry.fingerprint else {
            throw CopyProblem.invalid("来源文件在选择后发生变化，请重新选择")
        }
    }
    private func validateSourceDirectory(_ entry: ManifestEntry) throws {
        let (kind, value) = try FileFingerprint.read(entry.sourceURL)
        guard kind == .directory, value.device == entry.fingerprint.device, value.inode == entry.fingerprint.inode else {
            throw CopyProblem.invalid("来源目录已丢失或被替换，请重新选择")
        }
    }
    private func validateNamedFile(parent: Int32, name: String, expected: FileFingerprint) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, FileFingerprint.from(info) == expected else {
            throw CopyProblem.invalid("目标文件被替换，停止发布")
        }
    }
}
