import AppKit
import CopyCore

enum VolumeActions {
    static func eject(_ url: URL, jobs: [TransferJob]) async throws {
        let volume = try await Task.detached { try VolumeInspector().inspect(url) }.value
        guard !jobs.contains(where: { $0.state == .running && ($0.destinationVolume.id == volume.id || $0.manifest.volumes.contains { $0.id == volume.id }) }) else {
            throw CopyProblem.invalid("这个设备仍有任务正在运行，请先暂停相关任务再推出")
        }
        try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }.value
    }
}
