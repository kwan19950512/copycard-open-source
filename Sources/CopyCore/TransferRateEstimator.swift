import Foundation

/// Per-run estimator. Call with a monotonic clock; file and phase boundaries
/// intentionally share the same history, including time spent between files.
struct TransferRateEstimator {
    private var samples: [(time: Double, work: Double, files: Int)] = []
    private var baseline: (time: Double, work: Double)?
    private var lastEstimateTime: Double?
    private var estimate: Double?

    mutating func measure(_ value: CopyProgress, at time: Double) -> CopyProgress {
        var result = value
        guard time.isFinite, value.jobWorkCompleted.isFinite, value.jobWorkTotal.isFinite else { return result }
        if baseline == nil { baseline = (time, value.jobWorkCompleted) }
        guard let baseline else { return result }
        if let last = samples.last, time < last.time || value.jobWorkCompleted < last.work {
            result.workBytesPerSecond = rate(at: last.time)
            result.estimatedSecondsRemaining = estimate; return result
        }
        if let last = samples.last, time - last.time < 0.25 {
            result.workBytesPerSecond = rate(at: last.time)
            result.estimatedSecondsRemaining = estimate; return result
        }
        samples.append((time, value.jobWorkCompleted, value.verifiedFiles))
        while samples.count > 2, samples[1].time <= time - 30 { samples.removeFirst() }
        let speed = rate(at: time)
        result.workBytesPerSecond = speed
        let elapsed = time - baseline.time
        if elapsed >= 5, speed > 0, time - (lastEstimateTime ?? -.infinity) >= 3 {
            var raw = max(0, value.jobWorkTotal - value.jobWorkCompleted) / speed
            if let first = samples.first, let last = samples.last, last.files > first.files, time > first.time, value.totalFiles > value.verifiedFiles {
                let filesPerSecond = Double(last.files - first.files) / (time - first.time)
                raw = max(raw, Double(value.totalFiles - value.verifiedFiles) / filesPerSecond)
            }
            if let previous = estimate, let previousTime = lastEstimateTime {
                let weight = 1 - exp(-(time - previousTime) / 15)
                let countdown = max(0, previous - (time - previousTime))
                let adjustment = (raw - countdown) * weight
                // Allow the estimate to grow even when it was only a few seconds:
                // the minimum correction must exceed the natural countdown.
                let limit = max(6, countdown * 0.05) * (time - previousTime) / 3
                estimate = countdown + min(limit, max(-limit, adjustment))
            } else { estimate = raw }
            lastEstimateTime = time
        }
        if value.jobWorkCompleted >= value.jobWorkTotal { estimate = 0 }
        result.estimatedSecondsRemaining = estimate
        return result
    }
    private func rate(at time: Double) -> Double {
        guard let first = samples.first, let last = samples.last, let baseline,
              time - first.time >= 1, time > baseline.time else { return 0 }
        let recent = max(0, last.work - first.work) / (time - first.time)
        let average = max(0, last.work - baseline.work) / (time - baseline.time)
        return recent * 0.7 + average * 0.3
    }
}
