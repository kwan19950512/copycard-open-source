import XCTest
@testable import CopyCore
@testable import CopyApp

final class AIReviewTests: XCTestCase {
    @MainActor func testSplitMoveMergePreservesExactCoverage() throws {
        let model = AIReviewModel(manifest: CopyManifest(selections: [], entries: [], volumes: []), batches: [])
        let a = UUID(), b = UUID(), c = UUID()
        model.groups = [AIGroup(folder: "A", entries: [a,b,c])]
        model.selected = [b]; model.splitSelection()
        XCTAssertEqual(model.groups.count, 2)
        XCTAssertNoThrow(try AIProposal(groups: model.groups).validate(expected: [a,b,c]))
        model.selected = [c]; model.moveSelection(to: model.groups.last!.id)
        XCTAssertEqual(model.groups.last?.entries.count, 2)
        model.mergeAll(); XCTAssertEqual(model.groups.count, 1)
        XCTAssertNoThrow(try AIProposal(groups: model.groups).validate(expected: [a,b,c]))
    }
}
