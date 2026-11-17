import XCTest
@testable import CopyCore

final class MulticardSafetyTests: XCTestCase {
    func testAllConfirmedIncompleteTasksReserveAndPartialsAreNotUndercounted() throws {
        let fs = try TestFiles(); var a = try testJob(fs); var b = a; b.id = UUID()
        XCTAssertEqual(try Preflight.reservedBytes(jobs: [a,b], volumeID: a.destinationVolume.id), 6)
        a.state = .queued; b.state = .running
        XCTAssertEqual(try Preflight.reservedBytes(jobs: [a,b], volumeID: a.destinationVolume.id), 6)
        a.state = .paused; b.state = .pending
        XCTAssertEqual(try Preflight.reservedBytes(jobs: [a,b], volumeID: a.destinationVolume.id), 6)
    }
    func testAdmissionRechecksPendingReservationsWithoutLosingFirstJob() async throws {
        let fs = try TestFiles(); let a = try testJob(fs), b = try testJob(fs, name: "b")
        let queue = try TransferQueue(store: JobStore(directory: try fs.directory("state")), inspect: { _ in
            VolumeInfo(id: a.destinationVolume.id, root: fs.root, immediateFree: 67_108_868)
        })
        try await queue.enqueueValidatedBatch([a])
        do { try await queue.enqueueValidatedBatch([b]); XCTFail("Both tasks do not fit with the safety reserve") } catch { }
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs.map(\.id), [a.id]); XCTAssertEqual(snapshot.jobs.first?.state, .pending)
        try await queue.closeSession()
    }
    func testNeverMoreThanTwoEvenWithLegacyLimitAndOverride() throws {
        let fs = try TestFiles()
        let jobs = try (0..<5).map { index -> TransferJob in var job = try testJob(fs, name: "file\(index)"); job.state = .queued; return job }
        XCTAssertEqual(DeviceScheduler.eligibleJobs(jobs: jobs, active: [], limit: 8, allowSharedDevice: true).count, 2)
    }
    func testHistoryNewestFirstWithoutReorderingActiveQueue() throws {
        let fs = try TestFiles(); var older = try testJob(fs); var newer = try testJob(fs, name: "b"); let active = try testJob(fs, name: "c")
        older.state = .completed; older.endedAt = Date(timeIntervalSince1970: 10)
        newer.state = .completed; newer.endedAt = Date(timeIntervalSince1970: 20)
        XCTAssertEqual(TransferJob.displayOrder([older, active, newer]).map(\.id), [active.id, newer.id, older.id])
        older.endedAt = nil; XCTAssertNil(older.historicalEndDate)
    }
    func testSpaceRecheckUsesFreshValuesAndReportsReservation() throws {
        let fs = try TestFiles(); let job = try testJob(fs)
        var free: Int64 = 10
        let check = Preflight { _ in VolumeInfo(id: "target", root: fs.root, immediateFree: free, importantCapacity: 9_000_000_000) }
        let first = try check.check(manifest: job.manifest, destination: job.destination)
        XCTAssertFalse(first.canStart); XCTAssertEqual(first.remainingBytes, 3)
        free = 1_000_000_000
        let second = try check.check(manifest: job.manifest, destination: job.destination, reservedBytes: 100)
        XCTAssertTrue(second.canStart); XCTAssertEqual(second.reservedBytes, 100); XCTAssertEqual(second.safetyReserve, 67_108_864)
    }
}
