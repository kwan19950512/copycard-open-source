import Foundation
@testable import CopyCore

func testVolume(_ fs: TestFiles, id: String = "test-volume", devices: Set<String>? = ["disk-test"]) -> VolumeInfo {
    VolumeInfo(id: id, root: fs.root, physicalDevices: devices, immediateFree: 1_000_000_000)
}
func testJob(_ fs: TestFiles, name: String = "a", sourceDevice: String = "reader", targetDevice: String = "disk-test") throws -> TransferJob {
    let file = try fs.file("source/" + name)
    var manifest = try ManifestBuilder().build([SourceSelection(root: file)])
    manifest.volumes = [testVolume(fs, devices: [sourceDevice])]
    return TransferJob(manifest: manifest, destination: try fs.directory("target/" + name),
                       destinationVolume: testVolume(fs, devices: [targetDevice]))
}
