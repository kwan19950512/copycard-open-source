import XCTest
import Foundation
@testable import CopyCore

final class ReportTests: XCTestCase {
    func testPomfortReferenceVerifier() throws {
        guard let tool = ProcessInfo.processInfo.environment["MHL_REFERENCE_TOOL"] else {
            throw XCTSkip("Set MHL_REFERENCE_TOOL to Pomfort mhl-tool for independent interoperability verification")
        }
        let fs = try TestFiles(); let job = try completed(fs, name: "片段 & sample.mp4")
        let output = try ReportWriter().write(job: job, directory: job.destination)
        func verify() throws -> Int32 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["verify", "-f", output.mhl.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        XCTAssertEqual(try verify(), 0)
        try Data("corrupt".utf8).write(to: job.destination.appendingPathComponent("片段 & sample.mp4"))
        XCTAssertNotEqual(try verify(), 0)
    }
    private func completed(_ fs: TestFiles, name: String = "a") throws -> TransferJob {
        var job = try testJob(fs, name: name)
        job.state = .completed
        let entry = job.manifest.entries[0]
        job.results[entry.id] = FileCopyResult(entryID: entry.id, status: .copiedVerified, digest: "44bc2cf5ad770999")
        try Data("abc".utf8).write(to: job.destination.appendingPathComponent(name))
        return job
    }
    func testReportIncludesAllOutcomes() throws {
        let fs = try TestFiles(); var job = try completed(fs)
        var bad = job.manifest.entries[0]; bad.id = UUID(); bad.relativePath = "bad.xml"
        job.manifest.entries.append(bad); job.state = .needsAttention
        job.results[bad.id] = FileCopyResult(entryID: bad.id, status: .failed, message: "read error")
        let output = try ReportWriter().write(job: job, directory: job.destination)
        let text = try String(contentsOf: output.summary)
        XCTAssertTrue(text.contains("bad.xml")); XCTAssertTrue(text.contains("read error"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.details)) as? [String: Any])
        XCTAssertEqual((json["files"] as? [[String: Any]])?.count, 2)
        let xml = try XMLDocument(data: Data(contentsOf: output.mhl))
        XCTAssertEqual(try xml.nodes(forXPath: "/hashlist/hash").count, 1)
    }
    func testXMLSpecialCharacters() throws {
        let fs = try TestFiles(); let job = try completed(fs, name: "a&<片段>.mp4")
        let xml = try XMLDocument(data: MHLWriter.document(job: job))
        XCTAssertEqual(try xml.nodes(forXPath: "/hashlist/hash/file").first?.stringValue, "a&<片段>.mp4")
        XCTAssertEqual(try xml.nodes(forXPath: "/hashlist/hash/xxhash64be").first?.stringValue, "44bc2cf5ad770999")
    }
    func testReportIsPortable() throws {
        let fs = try TestFiles(); let job = try completed(fs)
        let output = try ReportWriter().write(job: job, directory: job.destination)
        let moved = fs.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: job.destination, to: moved)
        let xml = try XMLDocument(contentsOf: moved.appendingPathComponent(output.mhl.lastPathComponent))
        let path = try XCTUnwrap(xml.nodes(forXPath: "/hashlist/hash/file").first?.stringValue)
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent(path)), "abc")
    }
    func testReportFailureDoesNotChangeVerifiedData() async throws {
        let fs = try TestFiles(); let job = try completed(fs)
        try Data("reserved".utf8).write(to: job.destination.appendingPathComponent("拷贝校验报告"))
        let store = JobStore(directory: fs.root.appendingPathComponent("state")); try store.save([job])
        let q = try TransferQueue(store: store, inspect: { _ in job.destinationVolume })
        do { try await q.regenerateReport(id: job.id); XCTFail("report must fail") } catch {}
        let current = await q.snapshot().jobs.first
        XCTAssertEqual(current?.state, .completed); XCTAssertEqual(current?.reportStatus, .failed)
        XCTAssertEqual(try String(contentsOf: job.destination.appendingPathComponent("a")), "abc")
    }
    func testRetryReportWithoutRecopy() async throws {
        let fs = try TestFiles(); var job = try completed(fs)
        job.reportStatus = .failed
        let store = JobStore(directory: fs.root.appendingPathComponent("state")); try store.save([job])
        let before = try FileFingerprint.read(job.destination.appendingPathComponent("a")).1
        let target = job.destinationVolume
        let q = try TransferQueue(store: store, inspect: { _ in target }); try await q.regenerateReport(id: job.id)
        let current = await q.snapshot().jobs.first
        XCTAssertEqual(current?.reportStatus, .saved)
        XCTAssertEqual(try FileFingerprint.read(job.destination.appendingPathComponent("a")).1, before)
    }
    func testSeparateReportsNeverOverwrite() throws {
        let fs = try TestFiles(); let job = try completed(fs)
        let first = try ReportWriter().write(job: job, directory: job.destination)
        let old = try Data(contentsOf: first.mhl)
        let second = try ReportWriter().write(job: job, directory: job.destination)
        XCTAssertNotEqual(first.mhl, second.mhl)
        XCTAssertEqual(try Data(contentsOf: first.mhl), old)
    }
}
