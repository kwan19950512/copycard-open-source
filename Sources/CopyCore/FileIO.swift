import Foundation
import Darwin

public protocol FileIO {
    func read(_ fd: Int32, count: Int) throws -> Data
    func write(_ fd: Int32, data: Data) throws
    func synchronize(_ fd: Int32) throws
    func preserveTimestamps(source: Int32, target: Int32) throws
    func openReadback(parentFD: Int32, name: String) throws -> Int32
    func publish(parentFD: Int32, temporaryName: String, finalName: String) throws
}
public extension FileIO {
    func preserveTimestamps(source: Int32, target: Int32) throws {
        try FileTimestamps.preserve(source: source, target: target)
    }
}
public struct SystemFileIO: FileIO {
    public init() {}
    public func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        let readCount = try data.withUnsafeMutableBytes { bytes -> Int in
            var result: Int
            repeat { result = Darwin.read(fd, bytes.baseAddress, count) } while result < 0 && errno == EINTR
            if result < 0 { throw posixFailure() }
            return result
        }
        data.count = readCount
        return data
    }
    public func write(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw posixFailure() }
                offset += n
            }
        }
    }
    public func synchronize(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw posixFailure() }
        // Ask the device to flush its cache when supported. fsync remains mandatory.
        if fcntl(fd, F_FULLFSYNC) != 0 && errno != EINVAL && errno != ENOTSUP && errno != ENOTTY { throw posixFailure() }
    }
    public func openReadback(parentFD: Int32, name: String) throws -> Int32 {
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd); throw CopyProblem.invalid("目标不是普通文件")
        }
        return fd
    }
    public func publish(parentFD: Int32, temporaryName: String, finalName: String) throws {
        guard renameatx_np(parentFD, temporaryName, parentFD, finalName, UInt32(RENAME_EXCL)) == 0 else { throw posixFailure() }
        guard fsync(parentFD) == 0 else { throw posixFailure() }
    }
}

func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

/// Retains directory descriptors; every descendant is opened without following links.
final class SecureDirectory {
    private var handles: [(Int32, URL, FileFingerprint)] = []
    var fd: Int32 { handles.last!.0 }
    init(root: URL, subdirectory: String = "") throws {
        let canonical = try PathSafety.directoryWithoutLinks(root)
        let all = canonical.pathComponents.dropFirst() + subdirectory.split(separator: "/").map(String.init)
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        let rootFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw posixFailure() }
        var info = stat(); _ = fstat(rootFD, &info)
        handles.append((rootFD, path, FileFingerprint.from(info)))
        do {
            for name in all {
                guard name != "..", name != ".", !name.isEmpty else { throw CopyProblem.invalid("目录路径不安全") }
                let parent = fd
                if mkdirat(parent, name, 0o755) != 0 && errno != EEXIST { throw posixFailure() }
                let next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw CopyProblem.invalid("无法打开目录 \(path.appendingPathComponent(name).path)：\(posixFailure().localizedDescription)") }
                path.appendPathComponent(name)
                guard fstat(next, &info) == 0 else { close(next); throw posixFailure() }
                handles.append((next, path, FileFingerprint.from(info)))
            }
        } catch {
            for handle in handles { close(handle.0) }
            handles.removeAll()
            throw error
        }
    }
    func validate() throws {
        for (_, path, original) in handles {
            let (kind, current) = try FileFingerprint.read(path)
            guard kind == .directory, current.inode == original.inode, current.device == original.device else {
                throw CopyProblem.invalid("目标目录在复制过程中发生变化")
            }
        }
    }
    deinit { for handle in handles { close(handle.0) } }
}
