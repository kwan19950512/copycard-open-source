import XCTest
import Darwin
@testable import CopyCore

final class JobStoreTests: XCTestCase {
    func testOperatingSystemReleasesLockWhenProcessExitsAbruptly() throws {
        let fs = try TestFiles(); let directory = try fs.directory("state")
        let path = directory.appendingPathComponent("session.lock").path
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-MFcntl=:DEFAULT", "-e", "sysopen(my $f, $ARGV[0], O_RDWR|O_CREAT, 0600) or exit 2; flock($f, 6) or exit 3; kill 9, $$;", path]
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, 9)
        let queue = try TransferQueue(store: JobStore(directory: directory))
        _ = queue
    }
    func testQueueSessionExcludesOtherInstancesAndReleasesOnClose() async throws {
        let fs = try TestFiles(); let store = JobStore(directory: fs.root.appendingPathComponent("state"))
        let first = try TransferQueue(store: store)
        let job = try testJob(fs); try await first.enqueue(job)
        XCTAssertThrowsError(try TransferQueue(store: store))
        XCTAssertEqual(try store.load().map(\.id), [job.id])
        try await first.closeSession()
        let second = try TransferQueue(store: store)
        let reloaded = await second.snapshot()
        XCTAssertEqual(reloaded.jobs.map(\.id), [job.id])
        do { try await first.enqueue(try testJob(fs)); XCTFail("closed queue wrote after releasing lock") } catch {}
        XCTAssertEqual(try store.load().map(\.id), [job.id])
        try await second.closeSession()
    }
    func testOldFingerprintJSONStillDecodesWithoutNewFields() throws {
        let fs = try TestFiles(); let job = try testJob(fs)
        let encoded = try JSONEncoder().encode(job)
        func strip(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(strip) }
            if let object = value as? [String: Any] { return object.filter { $0.key != "changedSeconds" && $0.key != "changedNanos" }.mapValues(strip) }
            return value
        }
        let old = try JSONSerialization.data(withJSONObject: strip(JSONSerialization.jsonObject(with: encoded)))
        let restored = try JSONDecoder().decode(TransferJob.self, from: old)
        XCTAssertEqual(restored.id, job.id)
        XCTAssertNil(restored.manifest.entries.first?.fingerprint.changedSeconds)
    }
    func testRestoredRunningBecomesPaused() throws {
        let fs = try TestFiles(); let store = JobStore(directory: fs.root.appendingPathComponent("state"))
        var job = try testJob(fs); job.state = .running
        try store.save([job]); let loaded = try store.load()
        XCTAssertEqual(loaded.first?.id, job.id); XCTAssertEqual(loaded.first?.state, .paused)
    }
    func testCorruptSnapshotIsNotSilentlyEmpty() throws {
        let fs = try TestFiles(); try fs.file("state/jobs.json", Data("broken".utf8))
        XCTAssertThrowsError(try JobStore(directory: fs.root.appendingPathComponent("state")).load())
        XCTAssertEqual(try String(contentsOf: fs.root.appendingPathComponent("state/jobs.json")), "broken")
    }
    func testCompletedHistoryPersistsOffline() throws {
        let fs = try TestFiles(); let store = JobStore(directory: fs.root.appendingPathComponent("state"))
        var job = try testJob(fs); job.state = .completed
        try store.save([job]); XCTAssertEqual(try store.load().first?.state, .completed)
    }
}
