import Foundation

public enum DeviceScheduler {
    public static func eligibleJobs(jobs: [TransferJob], active: [TransferJob], limit: Int = 2,
                                    allowSharedDevice: Bool = false) -> [UUID] {
        var occupying = active
        var result: [UUID] = []
        for job in jobs where job.state == .queued && !active.contains(where: { $0.id == job.id }) {
            guard occupying.count < min(2, max(1, limit)) else { break }
            let candidate = devices(job)
            let conflict = !allowSharedDevice && occupying.contains { other in
                guard let a = candidate, let b = devices(other) else { return true }
                return !a.isDisjoint(with: b)
            }
            if !conflict { result.append(job.id); occupying.append(job) }
        }
        return result
    }
    private static func devices(_ job: TransferJob) -> Set<String>? {
        var result = Set<String>()
        for volume in job.manifest.volumes + [job.destinationVolume] {
            guard let devices = volume.physicalDevices, !devices.isEmpty else { return nil }
            result.formUnion(devices)
        }
        return result.isEmpty ? nil : result
    }
}
