import XCTest
@testable import CopyCore

final class ResumeTests: XCTestCase {
    private func queue(_ fs: TestFiles, id: String = "test-volume") throws -> TransferQueue {
        try TransferQueue(store: JobStore(directory: fs.root.appendingPathComponent("state")), inspect: { _ in testVolume(fs, id: id) })
    }
    private func finished(_ queue: TransferQueue, id: UUID) async throws -> TransferJob {
        for _ in 0..<300 {
            let jobs = await queue.snapshot().jobs
            if let job = jobs.first(where: { $0.id == id }), job.state != .running && job.state != .queued { return job }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CopyProblem.invalid("测试任务未在时限内完成")
    }
    func testNewJobsStayPending() async throws {
        let fs = try TestFiles(); let q = try queue(fs); let job = try testJob(fs)
        try await q.enqueue(job)
        let s = await q.snapshot(); XCTAssertEqual(s.jobs.first?.state, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.destination.appendingPathComponent("a").path))
    }
    func testClearTaskOnlyRemovesRecordAndPersists() async throws {
        let fs = try TestFiles(), job = try testJob(fs), q = try queue(fs)
        let copied = try fs.file("target/a/keep.mp4")
        try await q.enqueue(job); try await q.clearTask(id: job.id)
        let snapshot = await q.snapshot(); XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.manifest.selections[0].root.path))
        try await q.closeSession()
        let reloaded = try queue(fs); let stored = await reloaded.snapshot(); XCTAssertTrue(stored.jobs.isEmpty)
        try await reloaded.closeSession()
    }
    func testInterruptedPublishRecoversByVerification() async throws {
        let fs = try TestFiles(); let job = try testJob(fs); let q = try queue(fs)
        try fs.file("target/a/a") // File published before the old process saved its checkpoint.
        try await q.enqueue(job); try await q.start(ids: [job.id])
        let done = try await finished(q, id: job.id)
        XCTAssertEqual(done.state, .completed)
        XCTAssertEqual(done.results.values.first?.status, .existingVerified)
    }
    func testDifferentCardWithSameNameRejected() async throws {
        let fs = try TestFiles(); let job = try testJob(fs); let q = try queue(fs, id: "different-card")
        try await q.enqueue(job); try await q.start(ids: [job.id])
        let done = try await finished(q, id: job.id)
        XCTAssertEqual(done.state, .needsAttention)
        XCTAssertTrue(done.message?.contains("设备") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.destination.appendingPathComponent("a").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: job.destination.path), [], "Wrong device must not receive reports either")
    }
    func testReplacedTargetDirectoryRejectedBeforeAnyWrite() async throws {
        let fs = try TestFiles(); let job = try testJob(fs); let q = try queue(fs)
        try await q.enqueue(job)
        try FileManager.default.moveItem(at: job.destination, to: fs.root.appendingPathComponent("original-target"))
        try FileManager.default.createDirectory(at: job.destination, withIntermediateDirectories: true)
        try await q.start(ids: [job.id])
        let done = try await finished(q, id: job.id)
        XCTAssertEqual(done.state, .needsAttention)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: job.destination.path), [])
    }
    func testChangedDestinationReverified() async throws {
        let fs = try TestFiles(); var job = try testJob(fs); let q = try queue(fs)
        let entry = job.manifest.entries[0]
        job.results[entry.id] = FileCopyResult(entryID: entry.id, status: .copiedVerified, digest: "44bc2cf5ad770999")
        try fs.file("target/a/a", Data("changed".utf8))
        try await q.enqueue(job); try await q.start(ids: [job.id])
        let done = try await finished(q, id: job.id)
        XCTAssertEqual(done.state, .needsAttention); XCTAssertEqual(done.results[entry.id]?.status, .conflict)
    }
    func testCancelledQueueDoesNotAutostart() async throws {
        let fs = try TestFiles(); let q = try queue(fs); let job = try testJob(fs)
        try await q.enqueue(job); try await q.cancel(id: job.id)
        try await q.closeSession()
        let restored = try queue(fs); let s = await restored.snapshot()
        XCTAssertEqual(s.jobs.first?.state, .cancelled)
        try await restored.closeSession()
    }
    func testUnavailableDeviceDoesNotWrite() async throws {
        let fs = try TestFiles(); let job = try testJob(fs)
        let q = try TransferQueue(store: JobStore(directory: fs.root.appendingPathComponent("state")), inspect: { _ in throw POSIXError(.ENODEV) })
        try await q.enqueue(job); try await q.start(ids: [job.id])
        let done = try await finished(q, id: job.id)
        XCTAssertEqual(done.state, .needsAttention)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.destination.appendingPathComponent("a").path))
    }
    func testSnapshotFailurePreventsNewWrites() async throws {
        let fs = try TestFiles(); let job = try testJob(fs); let q = try queue(fs)
        try await q.enqueue(job)
        try FileManager.default.moveItem(at: fs.root.appendingPathComponent("state"), to: fs.root.appendingPathComponent("state-backup"))
        try fs.file("state")
        do { try await q.start(ids: [job.id]); XCTFail("must reject unsaved state") } catch {}
        let snapshot = await q.snapshot()
        XCTAssertNotNil(snapshot.persistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.destination.appendingPathComponent("a").path))
    }
}
