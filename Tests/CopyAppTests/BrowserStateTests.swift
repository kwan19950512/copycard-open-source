import XCTest
@testable import CopyApp

final class BrowserStateTests: XCTestCase {
    @MainActor func testTreeChildrenHaveIndependentRowIdentitiesAndDepth() {
        let model = DirectoryTreeModel()
        let root = URL(fileURLWithPath: "/tmp/tree"), child = URL(fileURLWithPath: "/tmp/tree/child"), target = URL(fileURLWithPath: "/tmp/tree/child/target")
        model.children = [root: [child], child: [target]]; model.expanded = [root, child]
        XCTAssertEqual(model.visibleNodes(root: root).map(\.url), [root, child, target])
        XCTAssertEqual(model.visibleNodes(root: root).map(\.depth), [0, 1, 2])
        model.expanded = [root]
        XCTAssertEqual(model.visibleNodes(root: root).map(\.url), [root, child])
    }
    func testDirectoryTreeReadsOnlyDirectFoldersAndDoesNotFollowLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copycard-tree-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("parent/nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("shortcut"), withDestinationURL: root.appendingPathComponent("parent"))
        XCTAssertEqual(try DirectoryTreeModel.readChildren(root).map(\.lastPathComponent), ["parent"])
        XCTAssertThrowsError(try DirectoryTreeModel.readChildren(root.appendingPathComponent("shortcut")))
    }
    func testMarqueeSupportsBothDirectionsAndAdditiveSelection() {
        let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b")
        let frames = [a: CGRect(x: 10, y: 10, width: 30, height: 30), b: CGRect(x: 100, y: 10, width: 30, height: 30)]
        let rect = BrowserInteraction.rectangle(from: CGPoint(x: 50, y: 50), to: .zero)
        XCTAssertEqual(BrowserInteraction.selection(in: rect, frames: frames), [a])
        XCTAssertEqual(BrowserInteraction.selection(in: rect, frames: frames, keeping: [b]), [a,b])
        XCTAssertEqual(BrowserInteraction.selection(in: rect, frames: frames, keeping: [b], allowed: [a]), [a], "Old layout/selection must not include another directory")
        XCTAssertTrue(BrowserInteraction.selection(in: CGRect(x: 200, y: 200, width: 10, height: 10), frames: frames).isEmpty)
    }
    func testPathBarAncestorsHaveExactNavigationTargets() {
        XCTAssertEqual(BrowserInteraction.ancestors(of: URL(fileURLWithPath: "/tmp/素材/当天")).map(\.path), ["/", "/tmp", "/tmp/素材", "/tmp/素材/当天"])
        XCTAssertEqual(BrowserInteraction.ancestors(of: URL(fileURLWithPath: "/")).map(\.path), ["/"])
    }
    @MainActor func testMarqueeInvalidatesOldStatisticsAndBlankClearsSelection() {
        let browser = BrowserModel(location: URL(fileURLWithPath: "/tmp"))
        let token = browser.select([URL(fileURLWithPath: "/tmp/a")])
        browser.previewSelection([URL(fileURLWithPath: "/tmp/b")])
        browser.applyStatistics(token: token, count: 1, bytes: 99)
        XCTAssertNil(browser.selectionBytes)
        browser.select([])
        XCTAssertTrue(browser.selected.isEmpty); XCTAssertEqual(browser.selectionBytes, 0)
    }
    @MainActor func testSystemIconDoesNotRequireAnExistingFile() {
        let item = BrowserItem(url: URL(fileURLWithPath: "/unmounted/card/folder"), isDirectory: true, size: 0)
        XCTAssertGreaterThan(SystemFileIcon.image(for: item).size.width, 0)
    }
    func testFileIconsResolveWithoutAccessingFile() {
        XCTAssertEqual(BrowserItem(url: URL(fileURLWithPath: "/unmounted/camera/clip.MP4"), isDirectory: false, size: 0).symbolName, "film")
        XCTAssertEqual(BrowserItem(url: URL(fileURLWithPath: "/unmounted/card"), isDirectory: true, size: 0).symbolName, "folder.fill")
    }
    @MainActor func testNavigationClearsStaleSelection() {
        let browser = BrowserModel(location: URL(fileURLWithPath: "/tmp"))
        browser.selected = [URL(fileURLWithPath: "/tmp/a")]
        browser.navigate(URL(fileURLWithPath: "/Applications"))
        XCTAssertEqual(browser.location.path, "/Applications"); XCTAssertTrue(browser.selected.isEmpty)
    }
    @MainActor func testLateStatisticsIgnored() {
        let browser = BrowserModel(location: URL(fileURLWithPath: "/tmp"))
        let old = browser.select([URL(fileURLWithPath: "/tmp/a")])
        let current = browser.select([URL(fileURLWithPath: "/tmp/b")])
        browser.applyStatistics(token: current, count: 1, bytes: 33)
        browser.applyStatistics(token: old, count: 1, bytes: 999)
        XCTAssertEqual(browser.selectionBytes, 33)
    }
    @MainActor func testMergeSplitPreservesBothLocations() {
        let registry = WindowRegistry()
        let a = registry.create(location: URL(fileURLWithPath: "/tmp"))
        let b = registry.create(location: URL(fileURLWithPath: "/Applications"))
        b.left.selected = [URL(fileURLWithPath: "/Applications/example.app")]
        registry.merge(a, b)
        XCTAssertEqual(registry.workspaces.count, 1)
        XCTAssertEqual(a.right?.location.path, "/Applications")
        let split = registry.split(a)
        XCTAssertEqual(split?.left.selected.count, 1); XCTAssertNil(a.right)
        XCTAssertEqual(registry.workspaces.count, 2)
    }
    @MainActor func testWindowsShareQueueNotSelection() {
        let registry = WindowRegistry()
        let a = registry.create(location: URL(fileURLWithPath: "/tmp"))
        let b = registry.create(location: URL(fileURLWithPath: "/tmp"))
        a.left.select([URL(fileURLWithPath: "/tmp/a")])
        XCTAssertTrue(b.left.selected.isEmpty)
        XCTAssertEqual(a.left.selected.count, 1)
    }
}
