import XCTest
import Darwin
@testable import CopyCore

final class FileTimestampTests: XCTestCase {
    private func dates(_ url: URL) throws -> (timespec, timespec) {
        var info = stat(); guard lstat(url.path, &info) == 0 else { throw posixFailure() }
        return (info.st_birthtimespec, info.st_mtimespec)
    }
    private func assertDates(_ target: URL, match source: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try dates(target), b = try dates(source)
        XCTAssertEqual(a.0.tv_sec, b.0.tv_sec, "creation seconds", file: file, line: line)
        XCTAssertEqual(a.0.tv_nsec, b.0.tv_nsec, "creation nanos", file: file, line: line)
        XCTAssertEqual(a.1.tv_sec, b.1.tv_sec, "modification seconds", file: file, line: line)
        XCTAssertEqual(a.1.tv_nsec, b.1.tv_nsec, "modification nanos", file: file, line: line)
    }
    private func source(_ fs: TestFiles, data: Data = Data("abc".utf8)) throws -> URL {
        let url = try fs.file("source/a.mp4", data)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000.125), .modificationDate: Date(timeIntervalSince1970: 1_650_000_000.375)], ofItemAtPath: url.path)
        return url
    }
    func testNewFilesPreserveBothTimesForBothHashesAndEmptyFiles() async throws {
        for algorithm in HashAlgorithm.allCases {
            for data in [Data(), Data("material".utf8)] {
                let fs = try TestFiles(), original = try source(fs, data: data)
                let originalDates = try dates(original)
                let entry = try ManifestBuilder().build([SourceSelection(root: original)]).entries[0]
                let target = try fs.directory("target")
                let result = await CopyEngine().copy(entry: entry, destination: target, algorithm: algorithm)
                XCTAssertEqual(result.status, .copiedVerified, result.message ?? "")
                try assertDates(target.appendingPathComponent("a.mp4"), match: original)
                XCTAssertEqual(try Data(contentsOf: original), data)
                let after = try dates(original)
                XCTAssertEqual(after.0.tv_sec, originalDates.0.tv_sec); XCTAssertEqual(after.0.tv_nsec, originalDates.0.tv_nsec)
                XCTAssertEqual(after.1.tv_sec, originalDates.1.tv_sec); XCTAssertEqual(after.1.tv_nsec, originalDates.1.tv_nsec)
            }
        }
    }
    func testResumedFilePreservesSourceTimesNotPartialCreationTime() async throws {
        let fs = try TestFiles(), original = try source(fs, data: Data(repeating: 12, count: 2_100_000))
        let entry = try ManifestBuilder().build([SourceSelection(root: original)]).entries[0]
        let target = try fs.directory("target"), control = TransferControl()
        let interrupted = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64, control: control) { _ in control.pause() }
        XCTAssertEqual(interrupted.status, .paused)
        let partial = try XCTUnwrap(interrupted.temporaryName)
        let result = await CopyEngine().copy(entry: entry, destination: target, algorithm: .xxh64, previousTemporaryName: partial)
        XCTAssertEqual(result.status, .copiedVerified, result.message ?? "")
        try assertDates(target.appendingPathComponent("a.mp4"), match: original)
    }
    func testExistingEqualFileIsNotSilentlyRetimestamped() async throws {
        let fs = try TestFiles(), original = try source(fs)
        let existing = try fs.file("target/a.mp4"), before = try dates(existing)
        let entry = try ManifestBuilder().build([SourceSelection(root: original)]).entries[0]
        let result = await CopyEngine().copy(entry: entry, destination: existing.deletingLastPathComponent(), algorithm: .xxh64)
        XCTAssertEqual(result.status, .existingVerified)
        XCTAssertTrue(result.message?.contains("时间") == true)
        let after = try dates(existing)
        XCTAssertEqual(after.0.tv_sec, before.0.tv_sec); XCTAssertEqual(after.0.tv_nsec, before.0.tv_nsec)
        XCTAssertEqual(after.1.tv_sec, before.1.tv_sec); XCTAssertEqual(after.1.tv_nsec, before.1.tv_nsec)
    }
}
