import XCTest
import Darwin
@testable import CopyCore

private final class ObservedIO: FileIO {
    let real = SystemFileIO()
    var readbackFD: Int32 = -1
    var readbackBytes = 0
    var writtenBytes = 0
    var onWrite: (() throws -> Void)?
    var onReadback: ((Int32, String) throws -> Void)?
    var onPublish: ((Int32, String) throws -> Void)?
    var onTimestamps: (() throws -> Void)?
    func preserveTimestamps(source: Int32, target: Int32) throws {
        try onTimestamps?(); try real.preserveTimestamps(source: source, target: target)
    }
    func read(_ fd: Int32, count: Int) throws -> Data {
        let data = try real.read(fd, count: count)
        if fd == readbackFD { readbackBytes += data.count }
        return data
    }
    func write(_ fd: Int32, data: Data) throws {
        try onWrite?(); try real.write(fd, data: data); writtenBytes += data.count
    }
    func synchronize(_ fd: Int32) throws { try real.synchronize(fd) }
    func openReadback(parentFD: Int32, name: String) throws -> Int32 {
        try onReadback?(parentFD, name)
        let fd = try real.openReadback(parentFD: parentFD, name: name); readbackFD = fd; return fd
    }
    func publish(parentFD: Int32, temporaryName: String, finalName: String) throws {
        try onPublish?(parentFD, finalName)
        try real.publish(parentFD: parentFD, temporaryName: temporaryName, finalName: finalName)
    }
}

final class CopyEngineTests: XCTestCase {
    func testHardlinkedDestinationIsNotIndependentCopy() async throws {
        let fs = try TestFiles(); let source = try fs.file("source/a.mp4")
        let target = try fs.directory("target")
        try FileManager.default.linkItem(at: source, to: target.appendingPathComponent("a.mp4"))
        let entry = try ManifestBuilder().build([SourceSelection(root: source)]).entries[0]
        let result = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(result.status, .conflict)
        XCTAssertTrue(result.message?.contains("硬链接") == true)
        XCTAssertEqual(try Data(contentsOf: source), Data("abc".utf8))
    }
    func testSourceRewrittenWithRestoredModificationTimeCannotSucceed() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs, data: Data("AAAA".utf8)); let io = ObservedIO()
        io.onTimestamps = {
            let fd = open(entry.sourceURL.path, O_RDWR); guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
            let bytes = Array("ZZZZ".utf8)
            guard bytes.withUnsafeBytes({ pwrite(fd, $0.baseAddress, bytes.count, 0) }) == 4 else { throw POSIXError(.EIO) }
            var attrs = attrlist(); attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); attrs.commonattr = UInt32(ATTR_CMN_MODTIME)
            var time = info.st_mtimespec
            guard fsetattrlist(fd, &attrs, &time, MemoryLayout<timespec>.size, 0) == 0 else { throw POSIXError(.EIO) }
        }
        let result = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertFalse(result.status.verified)
        XCTAssertTrue(result.message?.contains("来源") == true)
    }
    private func prepare(_ fs: TestFiles, data: Data = Data("abc".utf8)) throws -> (ManifestEntry, URL) {
        let source = try fs.file("source/a.mp4", data)
        return (try ManifestBuilder().build([SourceSelection(root: source)]).entries[0], try fs.directory("target"))
    }
    func testCopyThenReadback() async throws {
        let fs = try TestFiles(); let data = Data(repeating: 37, count: 2_100_033)
        let (entry, target) = try prepare(fs, data: data); let io = ObservedIO()
        let r = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(r.status, .copiedVerified, r.message ?? "")
        XCTAssertEqual(io.readbackBytes, data.count)
        XCTAssertEqual(try? Data(contentsOf: target.appendingPathComponent("a.mp4")), data)
        XCTAssertEqual(try Data(contentsOf: entry.sourceURL), data)
    }
    func testCorruptReadbackNeverPublishes() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        io.onReadback = { parent, name in
            let fd = openat(parent, name, O_WRONLY | O_NOFOLLOW); defer { close(fd) }
            _ = "bad".withCString { Darwin.write(fd, $0, 3) }
        }
        let r = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(r.status, .failed)
        XCTAssertNotNil(r.temporaryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.mp4").path))
    }
    func testTimestampFailureIsExplicitAndNeverPublishes() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        io.onTimestamps = { throw POSIXError(.ENOTSUP) }
        let result = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("创建时间/修改时间") == true)
        XCTAssertNotNil(result.temporaryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(result.temporaryName!).path))
    }
    func testCreationTimeChangedDuringReadbackNeverPublishesDespiteEqualHash() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        io.onReadback = { _, name in
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: target.appendingPathComponent(name).path)
        }
        let result = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("时间") == true)
        XCTAssertNotNil(result.temporaryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.mp4").path))
    }
    func testDiskFullWhenSavingTimestampsStillPausesAndRetainsPartial() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        io.onTimestamps = { throw POSIXError(.ENOSPC) }
        let result = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(result.status, .paused)
        XCTAssertNotNil(result.temporaryName)
        XCTAssertTrue(result.message?.contains("空间") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.mp4").path))
    }
    func testExistingEqualIsReadAndNotWritten() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        try fs.file("target/a.mp4")
        let r = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .md5)
        XCTAssertEqual(r.status, .existingVerified); XCTAssertEqual(io.writtenBytes, 0)
        XCTAssertEqual(io.readbackBytes, 3); XCTAssertEqual(r.digest, "900150983cd24fb0d6963f7d28e17f72")
    }
    func testDifferentExistingNeverOverwritten() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs)
        let original = Data("old".utf8); try fs.file("target/a.mp4", original)
        let r = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(r.status, .conflict)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("a.mp4")), original)
    }
    func testConflictDoesNotStopFollowingFile() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs)
        try fs.file("target/a.mp4", Data("old".utf8))
        let next = try fs.file("source/b.xml")
        let nextEntry = try ManifestBuilder().build([SourceSelection(root: next)]).entries[0]
        let engine = CopyEngine()
        let first = await engine.copy(entry: entry, destination: target, algorithm: .xxh64)
        let second = await engine.copy(entry: nextEntry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(first.status, .conflict); XCTAssertEqual(second.status, .copiedVerified)
    }
    func testSourceChangesDuringCopy() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        io.onWrite = { try Data("new source".utf8).write(to: entry.sourceURL) }
        let r = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(r.status, .failed); XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.mp4").path))
        XCTAssertEqual(try String(contentsOf: entry.sourceURL), "new source")
        XCTAssertTrue(r.message?.contains("来源") == true)
    }
    func testDestinationAppearsBeforePublish() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        io.onPublish = { _, _ in try Data("other app".utf8).write(to: target.appendingPathComponent("a.mp4")) }
        let r = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(r.status, .conflict)
        XCTAssertEqual(try? String(contentsOf: target.appendingPathComponent("a.mp4")), "other app")
    }
    func testParentReplacedBySymlink() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        let outside = try fs.directory("outside")
        io.onReadback = { _, _ in
            try FileManager.default.moveItem(at: target, to: fs.root.appendingPathComponent("moved"))
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        }
        let r = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(r.status, .failed)
        XCTAssertGreaterThan(io.readbackBytes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testRootSymlinkBeforeCopyCannotRedirectWrite() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs)
        let outside = try fs.directory("outside")
        try FileManager.default.moveItem(at: target, to: fs.root.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        let result = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testMissingSourceDirectoryCannotBeVerified() async throws {
        let fs = try TestFiles(); let source = try fs.directory("empty")
        let entry = try ManifestBuilder().build([SourceSelection(root: source)]).entries[0]
        try FileManager.default.moveItem(at: source, to: fs.root.appendingPathComponent("moved"))
        let target = try fs.directory("target")
        let result = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
    func testReplacementDuringPublishCannotBeVerified() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        io.onPublish = { parent, _ in
            let temp = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: target.path).first { $0.hasSuffix(".partial") })
            XCTAssertEqual(renameat(parent, temp, parent, "saved-original.partial"), 0)
            XCTAssertEqual(symlinkat(entry.sourceURL.path, parent, temp), 0)
        }
        let result = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(result.digest)
        XCTAssertEqual(try String(contentsOf: entry.sourceURL), "abc")
    }
    func testENOSPCPreservesPartial() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs); let io = ObservedIO()
        io.onWrite = { throw POSIXError(.ENOSPC) }
        let r = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(r.status, .paused); XCTAssertNotNil(r.temporaryName)
        XCTAssertTrue(r.message?.contains("空间") == true)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    func testPauseAndCancelPreservePartial() async throws {
        for cancel in [false, true] {
            let fs = try TestFiles(); let (entry, target) = try prepare(fs, data: Data(repeating: 7, count: 2_000_000))
            let control = TransferControl(); let io = ObservedIO()
            io.onWrite = { if cancel { control.cancel() } else { control.pause() } }
            let r = await CopyEngine(io: io).copy(entry: entry, destination: target, algorithm: .xxh64, control: control)
            XCTAssertEqual(r.status, cancel ? .cancelled : .paused); XCTAssertNotNil(r.temporaryName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.mp4").path))
        }
    }
    func testResumeValidPartialChecksPrefixThenOnlyWritesRemainder() async throws {
        let fs = try TestFiles(); let data = Data(repeating: 17, count: 3_000_000)
        let (entry, target) = try prepare(fs, data: data)
        let control = TransferControl(); let firstIO = ObservedIO()
        firstIO.onWrite = { control.pause() }
        let paused = await CopyEngine(io: firstIO).copy(entry: entry, destination: target, algorithm: .xxh64, control: control)
        let name = try XCTUnwrap(paused.temporaryName)
        let beforeSize = try FileFingerprint.read(target.appendingPathComponent(name)).1.size
        let secondIO = ObservedIO()
        let resumed = await CopyEngine(io: secondIO).copy(entry: entry, destination: target, algorithm: .xxh64, previousTemporaryName: name)
        XCTAssertEqual(resumed.status, .copiedVerified, resumed.message ?? "")
        XCTAssertEqual(secondIO.writtenBytes, data.count - Int(beforeSize))
        XCTAssertEqual(secondIO.readbackBytes, data.count)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("a.mp4")), data)
    }
    func testCorruptPartialIsPreservedAndNeverBlindlyAppended() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs)
        let name = ".copycard-\(entry.id.uuidString)-fixture.partial"
        let previous = target.appendingPathComponent(name)
        try Data("bad".utf8).write(to: previous)
        let result = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64, previousTemporaryName: name)
        XCTAssertEqual(result.status, .copiedVerified)
        XCTAssertEqual(try String(contentsOf: previous), "bad")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.mp4")), "abc")
    }
    func testSpaceCanDisappearAfterCopyHasStarted() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs, data: Data(repeating: 8, count: 2_100_000))
        let io = ObservedIO(); var checks = 0
        io.onWrite = { Thread.sleep(forTimeInterval: 0.55) }
        let result = await CopyEngine(io: io, availableSpace: { _ in checks += 1; return checks == 1 ? 1_000_000_000 : 1024 }).copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(result.status, .paused)
        XCTAssertGreaterThan(io.writtenBytes, 0)
        XCTAssertLessThan(io.writtenBytes, Int(entry.size))
        XCTAssertNotNil(result.temporaryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.mp4").path))
    }
    func testFileExistsAfterPublishBeforeCheckpoint() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs)
        _ = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64)
        let r = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(r.status, .existingVerified)
    }
    func testEmptyFileAndDirectory() async throws {
        let fs = try TestFiles(); let (entry, target) = try prepare(fs, data: Data())
        let r = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64)
        XCTAssertEqual(r.status, .copiedVerified); XCTAssertEqual(r.digest, "ef46db3751d8e999")
        let dir = try fs.directory("empty")
        let d = try ManifestBuilder().build([SourceSelection(root: dir)]).entries[0]
        let dr = await CopyEngine().copy(entry: d, destination: target, algorithm: .xxh64)
        XCTAssertEqual(dr.status, .directoryCreated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("empty").path))
    }
}
