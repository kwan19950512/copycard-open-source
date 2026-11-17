import XCTest
@testable import CopyCore

final class ProgressTests: XCTestCase {
    func testJobProgressIncludesSecondReadbackPass() {
        let copying = CopyProgress(phase: .copying, relativePath: "a", bytes: 25, total: 100).inJob(completedBytes: 0, totalBytes: 100, verifiedFiles: 0, totalFiles: 1)
        XCTAssertEqual(copying.jobWorkCompleted, 25); XCTAssertEqual(copying.jobWorkTotal, 200)
        let verifying = CopyProgress(phase: .verifying, relativePath: "a", bytes: 25, total: 100).inJob(completedBytes: 100, totalBytes: 200, verifiedFiles: 1, totalFiles: 2)
        XCTAssertEqual(verifying.jobWorkCompleted, 325); XCTAssertEqual(verifying.jobWorkTotal, 400)
        XCTAssertEqual(verifying.verifiedFiles, 1); XCTAssertEqual(verifying.totalFiles, 2)
    }
}
