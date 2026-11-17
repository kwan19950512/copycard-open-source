import XCTest
@testable import CopyCore

final class RefinementTests: XCTestCase {
    func testLowSpacePausesAndCanContinueWithoutPublishingUnverifiedFile() async throws {
        let fs = try TestFiles(); let job = try testJob(fs)
        let entry = job.manifest.entries[0]
        let result = await CopyEngine(availableSpace: { _ in 1024 }).copy(entry: entry, destination: job.destination, algorithm: .xxh64)
        XCTAssertEqual(result.status, .paused)
        XCTAssertTrue(result.message?.contains("空间不足") == true)
        XCTAssertNotNil(result.temporaryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.destination.appendingPathComponent(entry.relativePath).path))
        let retry = await CopyEngine().copy(entry: entry, destination: job.destination, algorithm: .xxh64)
        XCTAssertEqual(retry.status, .copiedVerified)
    }
    func testAbnormalSessionRequiresReverificationOfCompletedHistory() async throws {
        let fs = try TestFiles(); let store = JobStore(directory: fs.root.appendingPathComponent("state"))
        var job = try testJob(fs); job.state = .completed
        let entry = job.manifest.entries[0]
        job.results[entry.id] = FileCopyResult(entryID: entry.id, status: .copiedVerified, digest: "44bc2cf5ad770999")
        try store.save([job]); XCTAssertFalse(try store.beginSession())
        let queue = try TransferQueue(store: store, inspect: { _ in testVolume(fs) })
        let restored = await queue.snapshot().jobs[0]
        XCTAssertEqual(restored.state, .needsAttention)
        XCTAssertTrue(restored.message?.contains("未正常退出") == true)
        XCTAssertNil(restored.confirmedResult(for: entry.id))
        XCTAssertEqual(restored.successfulFiles, 0)
        XCTAssertEqual(try XMLDocument(data: MHLWriter.document(job: restored)).nodes(forXPath: "/hashlist/hash").count, 0)
        try await queue.closeSession()
        XCTAssertFalse(try store.beginSession())
    }
    func testCleanShutdownPreservesCompletedHistory() async throws {
        let fs = try TestFiles(); let store = JobStore(directory: fs.root.appendingPathComponent("state"))
        var job = try testJob(fs); job.state = .completed
        try store.save([job]); _ = try store.beginSession(); try store.endSession()
        let queue = try TransferQueue(store: store, inspect: { _ in testVolume(fs) })
        let state = await queue.snapshot().jobs[0].state
        XCTAssertEqual(state, .completed)
        try await queue.closeSession()
    }
    func testCollapsedProgressIsWeightedAndNotCompleteBeforeVerification() throws {
        let fs = try TestFiles(); var job = try testJob(fs); job.state = .running
        let progress = CopyProgress(phase: .verifying, relativePath: "a", bytes: 3, total: 3).inJob(completedBytes: 0, totalBytes: 3, verifiedFiles: 0, totalFiles: 1)
        XCTAssertLessThan(QueueOverview(QueueSnapshot(jobs: [job], progress: [job.id: progress], persistenceError: nil)).fraction, 1)
        job.state = .completed
        XCTAssertEqual(QueueOverview(QueueSnapshot(jobs: [job], progress: [:], persistenceError: nil)).fraction, 1)
    }
    func testCompletedFilesRemainInActiveBatchProgress() throws {
        let fs = try TestFiles(); var first = try testJob(fs, name: "a"); var second = try testJob(fs, name: "b")
        let batch = UUID(); first.batchID = batch; second.batchID = batch
        first.state = .completed; second.state = .running
        second.manifest.entries[0].fingerprint.size = 9
        let value = CopyProgress(phase: .copying, relativePath: "b", bytes: 6, total: 9).inJob(completedBytes: 0, totalBytes: 9, verifiedFiles: 0, totalFiles: 1)
        let overview = QueueOverview(QueueSnapshot(jobs: [first, second], progress: [second.id: value], persistenceError: nil))
        XCTAssertEqual(overview.fraction, 0.5, accuracy: 0.0001)
    }
    func testSingleFolderReportMovesWithProjectAndMHLPathsAreRebased() async throws {
        let fs = try TestFiles(); let folder = try fs.directory("source/project")
        _ = try fs.file("source/project/clip.mp4")
        let manifest = try ManifestBuilder().build([SourceSelection(root: folder)])
        let target = try fs.directory("target")
        var job = TransferJob(manifest: manifest, destination: target, destinationVolume: testVolume(fs))
        for entry in manifest.entries { job.results[entry.id] = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64) }
        job.state = .completed
        let paths = try ReportWriter().write(job: job, directory: target)
        XCTAssertEqual(paths.summary.deletingLastPathComponent().path, target.appendingPathComponent("project/拷贝校验报告").path)
        let xml = try XMLDocument(contentsOf: paths.mhl)
        XCTAssertEqual(try xml.nodes(forXPath: "/hashlist/hash/file").first?.stringValue, "clip.mp4")
        let moved = fs.root.appendingPathComponent("portable")
        try FileManager.default.moveItem(at: target.appendingPathComponent("project"), to: moved)
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("clip.mp4")), "abc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("拷贝校验报告/" + paths.summary.lastPathComponent).path))
    }
}
