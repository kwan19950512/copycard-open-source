import XCTest
@testable import CopyCore

final class PreflightTests: XCTestCase {
    private func checker(_ root: URL, free: Int64? = 1_000_000_000, readOnly: Bool = false,
                         caseSensitive: Bool = false, maxSize: Int64? = nil) -> Preflight {
        Preflight { _ in VolumeInfo(id: "test", root: root, immediateFree: free, importantCapacity: 9_000_000_000,
                                   readOnly: readOnly, caseSensitive: caseSensitive, maximumFileSize: maxSize) }
    }
    func testDestinationInsideSourceRejected() throws {
        let fs = try TestFiles(); let f = try fs.file("card/a")
        let m = try ManifestBuilder().build([SourceSelection(root: f.deletingLastPathComponent())])
        XCTAssertFalse(try checker(fs.root).check(manifest: m, destination: f.deletingLastPathComponent().appendingPathComponent("backup")).canStart)
    }
    func testSymlinkEscapeRejected() throws {
        let fs = try TestFiles(); let f = try fs.file("card/a")
        let dest = try fs.directory("dest")
        try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("a"), withDestinationURL: f)
        let m = try ManifestBuilder().build([SourceSelection(root: f)])
        XCTAssertFalse(try checker(fs.root).check(manifest: m, destination: dest).canStart)
    }
    func testRootAndAncestorSymlinkRejected() throws {
        let fs = try TestFiles(); let file = try fs.file("source/a")
        let outside = try fs.directory("outside")
        let target = fs.root.appendingPathComponent("target")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        let manifest = try ManifestBuilder().build([SourceSelection(root: file)])
        XCTAssertFalse(try checker(fs.root).check(manifest: manifest, destination: target).canStart)
        XCTAssertFalse(try checker(fs.root).check(manifest: manifest, destination: target.appendingPathComponent("nested")).canStart)
    }
    func testExistingTargetsDoNotReserveRecopySpace() throws {
        let fs = try TestFiles(); let file = try fs.file("source/a")
        var manifest = try ManifestBuilder().build([SourceSelection(root: file)])
        manifest.entries[0].fingerprint.size = 1_000_000_000
        let target = try fs.directory("target"); try fs.file("target/a")
        let result = try checker(fs.root, free: 100_000_000).check(manifest: manifest, destination: target)
        XCTAssertTrue(result.canStart, result.blockers.joined())
        XCTAssertEqual(result.requiredBytes, 67_108_864)
    }
    func testCaseAndUnicodeCollision() throws {
        let fs = try TestFiles(); let a = try fs.file("first/Clip.MP4"); let b = try fs.file("second/clip.mp4")
        var m = try ManifestBuilder().build([SourceSelection(root: a), SourceSelection(root: b)])
        XCTAssertFalse(try checker(fs.root).check(manifest: m, destination: fs.root.appendingPathComponent("dest")).canStart)
        if m.entries.count == 2 {
            m.entries[0].relativePath = "é.mp4"; m.entries[1].relativePath = "e\u{301}.mp4"
            XCTAssertFalse(try checker(fs.root).check(manifest: m, destination: fs.root.appendingPathComponent("dest")).canStart)
        }
    }
    func testReservationsUseImmediateFreeSpace() throws {
        let fs = try TestFiles(); let f = try fs.file("card/a")
        let m = try ManifestBuilder().build([SourceSelection(root: f)])
        let dest = fs.root.appendingPathComponent("dest")
        XCTAssertFalse(try checker(fs.root, free: 100_000_000).check(manifest: m, destination: dest, reservedBytes: 50_000_000).canStart)
        XCTAssertFalse(try checker(fs.root, free: nil).check(manifest: m, destination: dest).canStart)
        XCTAssertTrue(try checker(fs.root).check(manifest: m, destination: dest).canStart)
    }
    func testReadOnlyAndFileSizeLimits() throws {
        let fs = try TestFiles(); let f = try fs.file("card/a")
        let m = try ManifestBuilder().build([SourceSelection(root: f)])
        let dest = fs.root.appendingPathComponent("dest")
        XCTAssertFalse(try checker(fs.root, readOnly: true).check(manifest: m, destination: dest).canStart)
        XCTAssertFalse(try checker(fs.root, maxSize: 2).check(manifest: m, destination: dest).canStart)
    }
}
