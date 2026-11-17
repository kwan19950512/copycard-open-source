import XCTest
@testable import CopyApp

final class DirectoryAccessTests: XCTestCase {
    @MainActor func testAccessPanelTargetsOnlyOneOfMultipleWorkspaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCardAccessTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root)
        let first = app.registry.create(location: root)
        let second = app.registry.create(location: root)
        app.presentDirectoryAccess(in: second.id)
        XCTAssertTrue(app.showDirectoryAccess)
        XCTAssertEqual(app.directoryAccessWorkspaceID, second.id)
        XCTAssertNotEqual(app.directoryAccessWorkspaceID, first.id)
    }
    func testRootSelectionIncludesDescendantsButNotSimilarNames() {
        let parent = URL(fileURLWithPath: "/Volumes/Card")
        XCTAssertTrue(DirectoryAccess.contains(parent, URL(fileURLWithPath: "/Volumes/Card/DCIM/clip.mp4")))
        XCTAssertFalse(DirectoryAccess.contains(parent, URL(fileURLWithPath: "/Volumes/Card-old/clip.mp4")))
        XCTAssertEqual(DirectoryAccess.roots([parent, parent.appendingPathComponent("DCIM"), parent]).map(\.path), ["/Volumes/Card"])
    }
    @MainActor func testPromptOncePerBuildAndAgainAfterUpdate() throws {
        let name = "CopyCardAccessTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let access = DirectoryAccess(defaults: defaults, buildID: "build1")
        XCTAssertTrue(access.needsPrompt)
        access.notePromptShown()
        XCTAssertFalse(DirectoryAccess(defaults: defaults, buildID: "build1").needsPrompt)
        XCTAssertTrue(DirectoryAccess(defaults: defaults, buildID: "build2").needsPrompt)
        XCTAssertFalse(access.confirmedForBuild)
    }
    @MainActor func testChosenRootsPersistWithoutDuplicatingChildFolders() throws {
        let name = "CopyCardAccessTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCardAccessTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let access = DirectoryAccess(defaults: defaults, buildID: "build1")
        try access.recordSelection([root, root.appendingPathComponent("child")])
        XCTAssertEqual(access.records.count, 1)
        XCTAssertTrue(access.confirmedForBuild)
        let restored = DirectoryAccess(defaults: defaults, buildID: "build1")
        XCTAssertEqual(restored.locations.map(\.path), [root.path])
        XCTAssertFalse(restored.needsPrompt)
        XCTAssertFalse(DirectoryAccess(defaults: defaults, buildID: "build2").confirmedForBuild)
    }
    @MainActor func testCorruptLocationRecordsArePreservedAndExplained() throws {
        let name = "CopyCardAccessTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let data = Data("bad generated fixture".utf8)
        defaults.set(data, forKey: "directoryAccessRecords")
        let access = DirectoryAccess(defaults: defaults, buildID: "build1")
        XCTAssertNotNil(access.restorationMessage)
        XCTAssertEqual(defaults.data(forKey: "directoryAccessRecords"), data)
    }
}
