import XCTest
@testable import CopyCore

final class RateEstimatorTests: XCTestCase {
    func testRemainingFilesRaiseEstimateForSmallFileOverhead() {
        var estimator = TransferRateEstimator()
        var first = CopyProgress(phase: .copying, relativePath: "a", bytes: 0, total: 1)
        first.jobWorkTotal = 1_000_000; first.totalFiles = 10_000
        _ = estimator.measure(first, at: 0)
        var next = first; next.jobWorkCompleted = 100_000; next.verifiedFiles = 10
        let result = estimator.measure(next, at: 10)
        XCTAssertEqual(result.estimatedSecondsRemaining!, 9990, accuracy: 1)
    }
    private func value(_ work: Double, total: Double = 100_000) -> CopyProgress {
        var value = CopyProgress(phase: .copying, relativePath: "a", bytes: 0, total: 0)
        value.jobWorkCompleted = work; value.jobWorkTotal = total; return value
    }
    func testWarmupAndConstantRateCountdown() {
        var estimator = TransferRateEstimator()
        for second in 0...4 { XCTAssertNil(estimator.measure(value(Double(second) * 100), at: Double(second)).estimatedSecondsRemaining) }
        let start = estimator.measure(value(500), at: 5)
        XCTAssertEqual(start.estimatedSecondsRemaining!, 995, accuracy: 0.001)
        let next = estimator.measure(value(800), at: 8)
        XCTAssertEqual(next.estimatedSecondsRemaining!, 992, accuracy: 0.001)
    }
    func testSingleSpikeDoesNotDriveETAAndUpdatesAreThrottled() {
        var estimator = TransferRateEstimator()
        var previous: CopyProgress!
        for second in 0...60 { previous = estimator.measure(value(Double(second) * 100), at: Double(second)) }
        let spike = estimator.measure(value(9000), at: 60.5)
        XCTAssertEqual(spike.estimatedSecondsRemaining, previous.estimatedSecondsRemaining)
        let after = estimator.measure(value(9250), at: 63)
        XCTAssertGreaterThan(after.estimatedSecondsRemaining!, previous.estimatedSecondsRemaining! * 0.9)
    }
    func testSustainedSlowdownEventuallyRaisesETA() {
        var estimator = TransferRateEstimator(); var before: CopyProgress!
        for second in 0...60 { before = estimator.measure(value(Double(second) * 100), at: Double(second)) }
        var after = before!
        for second in 61...150 { after = estimator.measure(value(6000 + Double(second - 60) * 10), at: Double(second)) }
        XCTAssertGreaterThan(after.estimatedSecondsRemaining!, before.estimatedSecondsRemaining! * 2)
    }
    func testAlternatingFastAndSlowFilesConvergeOnAverage() {
        var estimator = TransferRateEstimator(); var work = 0.0
        _ = estimator.measure(value(work), at: 0)
        for second in 1...120 {
            work += second % 2 == 0 ? 190 : 10
            let result = estimator.measure(value(work), at: Double(second))
            if second >= 30 {
                let expected = (100_000 - work) / 100
                XCTAssertEqual(result.estimatedSecondsRemaining!, expected, accuracy: expected * 0.1)
            }
        }
    }
    func testLateSlowdownCanRaiseAnInitiallyShortCountdown() {
        var estimator = TransferRateEstimator()
        _ = estimator.measure(value(0, total: 1000), at: 0)
        let first = estimator.measure(value(500, total: 1000), at: 5)
        var last = first
        for second in 6...65 { last = estimator.measure(value(500 + Double(second - 5), total: 1000), at: Double(second)) }
        XCTAssertGreaterThan(last.estimatedSecondsRemaining!, first.estimatedSecondsRemaining! * 3)
    }
    func testResumeExcludesPreviouslyCompletedWorkAndIgnoresReorderedSamples() {
        var estimator = TransferRateEstimator()
        _ = estimator.measure(value(50_000), at: 100)
        let next = estimator.measure(value(50_500), at: 105)
        XCTAssertEqual(next.workBytesPerSecond, 100, accuracy: 0.001)
        XCTAssertEqual(next.estimatedSecondsRemaining!, 495, accuracy: 0.001)
        let old = estimator.measure(value(50_100), at: 106)
        XCTAssertEqual(old.estimatedSecondsRemaining, next.estimatedSecondsRemaining)
    }
    func testFileAndPhaseChangesKeepHistoryAndCompletionClearsETA() {
        var estimator = TransferRateEstimator()
        _ = estimator.measure(value(0), at: 0)
        var verifying = value(500); verifying.phase = .verifying; verifying.relativePath = "b"
        XCTAssertNotNil(estimator.measure(verifying, at: 5).estimatedSecondsRemaining)
        XCTAssertEqual(estimator.measure(value(100_000), at: 6).estimatedSecondsRemaining, 0)
    }
}
