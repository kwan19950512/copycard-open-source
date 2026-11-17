import XCTest
@testable import CopyCore

final class SchedulerTests: XCTestCase {
    func testSamePhysicalDiskSerializes() throws {
        let fs = try TestFiles(); var a = try testJob(fs); var b = try testJob(fs, name: "b", sourceDevice: "other")
        a.state = .queued; b.state = .queued
        XCTAssertEqual(DeviceScheduler.eligibleJobs(jobs: [a,b], active: []), [a.id])
        XCTAssertEqual(DeviceScheduler.eligibleJobs(jobs: [b], active: [a]), [])
    }
    func testIndependentDevicesRunTogether() throws {
        let fs = try TestFiles(); var a = try testJob(fs); var b = try testJob(fs, name: "b", sourceDevice: "other", targetDevice: "other-target")
        a.state = .queued; b.state = .queued
        XCTAssertEqual(DeviceScheduler.eligibleJobs(jobs: [a,b], active: []), [a.id,b.id])
    }
    func testUnknownTopologySerializes() throws {
        let fs = try TestFiles(); var a = try testJob(fs); var b = try testJob(fs, name: "b")
        a.state = .queued; b.state = .queued; a.destinationVolume.physicalDevices = nil
        XCTAssertEqual(DeviceScheduler.eligibleJobs(jobs: [a,b], active: []), [a.id])
    }
    func testFailureOnlyBlocksDependentJobs() throws {
        let fs = try TestFiles(); var failed = try testJob(fs); var b = try testJob(fs, name: "b", sourceDevice: "other", targetDevice: "other-target")
        failed.state = .needsAttention; b.state = .queued
        XCTAssertEqual(DeviceScheduler.eligibleJobs(jobs: [failed,b], active: []), [b.id])
    }
    func testManualReorderAndConcurrencyOverride() throws {
        let fs = try TestFiles(); var a = try testJob(fs); var b = try testJob(fs, name: "b")
        a.state = .queued; b.state = .queued
        XCTAssertEqual(DeviceScheduler.eligibleJobs(jobs: [b,a], active: [], allowSharedDevice: true), [b.id,a.id])
    }
}
