import Foundation

public struct QueueOverview: Sendable {
    public let fraction: Double
    public let activeCount: Int
    public let waitingCount: Int
    public let bytesPerSecond: Double
    public let phase: TransferPhase?
    public init(_ snapshot: QueueSnapshot) {
        let active = snapshot.jobs.filter { [.running, .queued, .pending, .paused, .needsAttention].contains($0.state) }
        let batches = Set(active.compactMap(\.batchID))
        let finishedInBatch = snapshot.jobs.filter { $0.state == .completed && $0.batchID.map { batches.contains($0) } == true }
        let visible = active.isEmpty ? snapshot.jobs.filter { $0.state == .completed } : active + finishedInBatch
        let total = visible.reduce(0.0) { $0 + max(1, Double($1.manifest.totalBytes) * 2) }
        let done = visible.reduce(0.0) { value, job in
            let work = max(1, Double(job.manifest.totalBytes) * 2)
            if job.state == .completed { return value + work }
            let verified = job.manifest.entries.filter { job.confirmedResult(for: $0.id)?.status.verified == true }.reduce(0.0) { $0 + Double($1.size) * 2 }
            let current = snapshot.progress[job.id]?.jobWorkCompleted ?? verified
            return value + min(work * 0.99, max(0, current))
        }
        fraction = total > 0 ? min(1, done / total) : 0
        activeCount = snapshot.jobs.filter { $0.state == .running }.count
        waitingCount = snapshot.jobs.filter { $0.state == .pending || $0.state == .queued }.count
        bytesPerSecond = snapshot.progress.values.reduce(0) { $0 + $1.workBytesPerSecond }
        phase = snapshot.jobs.first(where: { $0.state == .running }).flatMap { snapshot.progress[$0.id]?.phase }
    }
}
