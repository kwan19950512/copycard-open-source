import XCTest
@testable import CopyCore

final class UnsupportedSelectionTests: XCTestCase {
    func testRegularCommandCopiesAndVerifiesLikeAnyFile() async throws {
        let fs = try TestFiles()
        let file = try fs.file("card/open.command", Data("#!/bin/sh\necho test\n".utf8))
        let target = try fs.directory("target")
        let manifest = try ManifestBuilder().build([SourceSelection(root: file)])
        XCTAssertEqual(manifest.entries.first?.kind, .file)
        let result = await CopyEngine().copy(entry: manifest.entries[0], destination: target, algorithm: .xxh64)
        XCTAssertEqual(result.status, .copiedVerified)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("open.command")), try Data(contentsOf: file))
    }
    func testLinkHasSpecificReasonAndRequiresExplicitExclusion() throws {
        let fs = try TestFiles()
        let file = try fs.file("project/clip.mp4")
        let outside = try fs.file("outside/open.command")
        try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent().appendingPathComponent("open.command"), withDestinationURL: outside)
        let target = try fs.directory("target")
        let manifest = try ManifestBuilder().build([SourceSelection(root: file.deletingLastPathComponent())])
        let link = try XCTUnwrap(manifest.entries.first { $0.kind == .unsupported })
        XCTAssertTrue(link.unsupportedReason?.contains("符号链接") == true)
        let checker = Preflight()
        let blocked = try checker.check(manifest: manifest, destination: target)
        XCTAssertFalse(blocked.canStart)
        XCTAssertTrue(blocked.blockers.joined().contains("无法复制并校验"))
        var job = TransferJob(manifest: manifest, destination: target, destinationVolume: try VolumeInspector().inspect(target))
        try job.excludeUnsupportedEntries()
        XCTAssertEqual(job.excludedCount, 1)
        XCTAssertEqual(job.manifest.fileCount, 1)
        XCTAssertTrue(try checker.check(manifest: job.manifest, destination: target).canStart)
        XCTAssertEqual(manifest.entries.filter { $0.kind == .unsupported }.count, 1)
        try job.excludeUnsupportedEntries()
        XCTAssertEqual(job.excludedCount, 1)
    }
    func testOnlyUnsupportedSelectionCannotProduceEmptySuccess() throws {
        let fs = try TestFiles(); let outside = try fs.file("outside")
        let link = fs.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let target = try fs.directory("target")
        var job = TransferJob(manifest: try ManifestBuilder().build([SourceSelection(root: link)]), destination: target, destinationVolume: try VolumeInspector().inspect(target))
        XCTAssertThrowsError(try job.excludeUnsupportedEntries())
        XCTAssertEqual(job.excludedCount, 0)
        XCTAssertEqual(job.manifest.entries.count, 1)
    }
    func testExclusionsPersistAndLegacyJobsStillDecode() throws {
        let fs = try TestFiles(); let file = try fs.file("project/a")
        let target = try fs.directory("target")
        let manifest = try ManifestBuilder().build([SourceSelection(root: file)])
        var job = TransferJob(manifest: manifest, destination: target, destinationVolume: try VolumeInspector().inspect(target))
        var item = manifest.entries[0]; item.kind = .unsupported; item.id = UUID(); item.relativePath = "link"
        job.manifest.entries.append(item); try job.excludeUnsupportedEntries()
        let store = JobStore(directory: fs.root.appendingPathComponent("state"))
        try store.save([job]); XCTAssertEqual(try store.load()[0].excludedCount, 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        json.removeValue(forKey: "excludedEntries")
        XCTAssertEqual(try JSONDecoder().decode(TransferJob.self, from: JSONSerialization.data(withJSONObject: json)).excludedCount, 0)
    }
    func testQueueCopiesOthersAndReportsExcludedLinkWithoutDigest() async throws {
        let fs = try TestFiles(); let file = try fs.file("project/clip.mp4")
        let outside = try fs.file("outside/secret")
        try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent().appendingPathComponent("shortcut.command"), withDestinationURL: outside)
        let target = try fs.directory("target")
        var job = TransferJob(manifest: try ManifestBuilder().build([SourceSelection(root: file.deletingLastPathComponent())]), destination: target, destinationVolume: try VolumeInspector().inspect(target))
        try job.excludeUnsupportedEntries()
        let queue = try TransferQueue(store: JobStore(directory: fs.root.appendingPathComponent("state")))
        try await queue.enqueue(job); try await queue.start(ids: [job.id])
        var finished: TransferJob?
        for _ in 0..<1000 {
            finished = await queue.snapshot().jobs.first
            if finished?.state == .completed || finished?.state == .needsAttention { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let result = try XCTUnwrap(finished)
        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.completionLabel.contains("未复制、未校验"))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("project/clip.mp4")), try Data(contentsOf: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("project/shortcut.command").path))
        XCTAssertEqual(result.excludedCount, 1)
        XCTAssertEqual(result.reportStatus, .saved)
        let report = try ReportWriter().write(job: result, directory: target)
        let text = try String(contentsOf: report.summary)
        XCTAssertTrue(text.contains("明确排除：1")); XCTAssertTrue(text.contains("shortcut.command"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report.details)) as? [String: Any])
        let rows = try XCTUnwrap(json["files"] as? [[String: Any]])
        let excluded = try XCTUnwrap(rows.first { ($0["status"] as? String) == "excludedUnverified" })
        XCTAssertNil(excluded["digest"])
        let xml = try XMLDocument(data: Data(contentsOf: report.mhl))
        XCTAssertEqual(try xml.nodes(forXPath: "/hashlist/hash").count, 1)
    }
}
