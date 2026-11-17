import XCTest
@testable import CopyCore

final class ProgressCheckpointTests: XCTestCase {
    func testBatchAndUrgentCheckpoints() {
        var checkpoint = ProgressCheckpoint()
        let now = ProcessInfo.processInfo.systemUptime
        for _ in 0..<31 { XCTAssertFalse(checkpoint.shouldSave(now: now)) }
        XCTAssertTrue(checkpoint.shouldSave(now: now))
        XCTAssertFalse(checkpoint.shouldSave(now: now + 0.1))
        XCTAssertTrue(checkpoint.shouldSave(now: now + 0.2, urgent: true))
        XCTAssertTrue(checkpoint.shouldSave(now: now + 2.3))
    }
}
