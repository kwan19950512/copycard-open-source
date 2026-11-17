import XCTest
@testable import CopyCore

final class ManifestTests: XCTestCase {
    func testSelectedLinkIsReportedAlongsideItsTargetFolder() throws {
        let fs = try TestFiles(); let file = try fs.file("card/video.txt")
        let link = fs.root.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let manifest = try ManifestBuilder().build([SourceSelection(root: file.deletingLastPathComponent()), SourceSelection(root: link)])
        XCTAssertEqual(manifest.fileCount, 1)
        XCTAssertEqual(manifest.entries.first(where: { $0.sourceURL == link })?.kind, .unsupported)
    }
    func testNestedSelectionPreservesStructure() throws {
        let fs = try TestFiles()
        let file = try fs.file("卡 1/目录/片段.mp4")
        let card = fs.root.appendingPathComponent("卡 1")
        let m = try ManifestBuilder().build([SourceSelection(root: card)])
        XCTAssertEqual(Set(m.entries.map(\.relativePath)), ["卡 1", "卡 1/目录", "卡 1/目录/片段.mp4"])
        XCTAssertEqual(m.totalBytes, 3)
        XCTAssertEqual(m.entries.first { $0.kind == .file }?.sourceURL.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
    }
    func testEmptyDirectoryAndZeroByteFile() throws {
        let fs = try TestFiles()
        let dir = try fs.directory("card/empty")
        try fs.file("card/zero.xml", Data())
        let m = try ManifestBuilder().build([SourceSelection(root: dir.deletingLastPathComponent(), includeRoot: false)])
        XCTAssertEqual(m.entries.count, 2)
        XCTAssertEqual(m.fileCount, 1)
        XCTAssertEqual(m.totalBytes, 0)
    }
    func testOverlappingSelectionsDeduplicate() throws {
        let fs = try TestFiles(); let f = try fs.file("card/a.mp4")
        let m = try ManifestBuilder().build([SourceSelection(root: f), SourceSelection(root: f.deletingLastPathComponent())])
        XCTAssertEqual(m.fileCount, 1)
        XCTAssertEqual(m.entries.filter { $0.kind == .file }.map(\.relativePath), ["card/a.mp4"])
    }
    func testSymlinkIsNotFollowed() throws {
        let fs = try TestFiles(); let external = try fs.file("outside/secret")
        let dir = try fs.directory("card")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: external)
        let m = try ManifestBuilder().build([SourceSelection(root: dir)])
        XCTAssertEqual(m.fileCount, 0)
        XCTAssertEqual(m.entries.filter { $0.kind == .unsupported }.count, 1)
    }
    func testVolumeHasStableIdentityAndCapacity() throws {
        let fs = try TestFiles()
        let v = try VolumeInspector().inspect(fs.root)
        XCTAssertFalse(v.id.isEmpty)
        XCTAssertNotNil(v.immediateFree)
        XCTAssertEqual(v.id, try VolumeInspector().inspect(fs.root.appendingPathComponent("missing")).id)
    }
}
