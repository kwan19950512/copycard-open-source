import Foundation
import Darwin

final class JobStoreLock {
    private var fd: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fd = open(directory.appendingPathComponent("session.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); fd = -1
            throw CopyProblem.invalid("任务记录正在被另一个拷卡实例使用，请先关闭另一个实例。")
        }
    }
    func release() { if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd); fd = -1 } }
    deinit { release() }
}

public struct JobStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    func acquireLock() throws -> JobStoreLock { try JobStoreLock(directory: directory) }
    /// Separate session marker: old jobs.json schemas and records remain compatible.
    public func beginSession() throws -> Bool {
        let marker = directory.appendingPathComponent("session-state")
        let abnormal = try FileManager.default.fileExists(atPath: marker.path) && String(contentsOf: marker) != "clean"
        try writeDurably(Data("active".utf8), to: marker)
        return abnormal
    }
    public func endSession() throws { try writeDurably(Data("clean".utf8), to: directory.appendingPathComponent("session-state")) }
    private func writeDurably(_ bytes: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        try SystemFileIO().synchronize(fd)
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw posixFailure() }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw posixFailure() }
    }
    private struct Envelope: Codable { var version = 1; var jobs: [TransferJob] }
    public func load() throws -> [TransferJob] {
        let url = directory.appendingPathComponent("jobs.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 1 else { throw CopyProblem.invalid("任务记录版本不受支持，原记录已保留") }
        guard Set(envelope.jobs.map(\.id)).count == envelope.jobs.count else { throw CopyProblem.invalid("任务记录损坏：重复标识") }
        return envelope.jobs.map { job in
            var restored = job
            if [.running, .queued].contains(job.state) { restored.state = .paused; restored.message = "等待手动继续" }
            return restored
        }
    }
    public func save(_ jobs: [TransferJob]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(Envelope(jobs: jobs))
        try writeDurably(bytes, to: directory.appendingPathComponent("jobs.json"))
    }
}
