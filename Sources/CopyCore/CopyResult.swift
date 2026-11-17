import Foundation

public enum FileCopyStatus: String, Codable, Sendable {
    case copiedVerified, existingVerified, directoryCreated, conflict, failed, paused, cancelled
    public var verified: Bool { self == .copiedVerified || self == .existingVerified || self == .directoryCreated }
}
public struct FileCopyResult: Codable, Sendable {
    public var entryID: UUID
    public var status: FileCopyStatus
    public var digest: String?
    public var message: String?
    public var temporaryName: String?
    public var completedAt: Date
    public init(entryID: UUID, status: FileCopyStatus, digest: String? = nil, message: String? = nil, temporaryName: String? = nil) {
        self.entryID = entryID; self.status = status; self.digest = digest
        self.message = message; self.temporaryName = temporaryName; self.completedAt = Date()
    }
}
public enum TransferPhase: String, Codable, Sendable { case copying, verifying, checkingExisting }
public struct CopyProgress: Sendable {
    public var phase: TransferPhase
    public var relativePath: String
    public var bytes: Int64
    public var total: Int64
    public var jobWorkCompleted: Double = 0
    public var jobWorkTotal: Double = 0
    public var verifiedFiles: Int = 0
    public var totalFiles: Int = 0
    public var workBytesPerSecond: Double = 0
    public var estimatedSecondsRemaining: Double? = nil
    public func inJob(completedBytes: Int64, totalBytes: Int64, verifiedFiles: Int, totalFiles: Int) -> CopyProgress {
        var result = self
        result.jobWorkTotal = Double(totalBytes) * 2
        result.jobWorkCompleted = min(result.jobWorkTotal, Double(completedBytes) * 2 + Double(bytes) + (phase == .verifying ? Double(total) : 0))
        result.verifiedFiles = verifiedFiles; result.totalFiles = totalFiles
        return result
    }
}
public final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var state: FileCopyStatus?
    public init() {}
    public func pause() { lock.lock(); state = .paused; lock.unlock() }
    public func cancel() { lock.lock(); state = .cancelled; lock.unlock() }
    public var interruption: FileCopyStatus? { lock.lock(); defer { lock.unlock() }; return state }
}
