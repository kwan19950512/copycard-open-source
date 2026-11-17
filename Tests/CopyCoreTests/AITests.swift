import XCTest
@testable import CopyCore

final class AITests: XCTestCase {
    func testMetadataContainsNoAbsolutePathsOrMedia() throws {
        let fs = try TestFiles(); let url = try fs.file("CARD/video.mp4", Data("MEDIA-MUST-NOT-LEAVE".utf8))
        let manifest = try ManifestBuilder().build([SourceSelection(root: url.deletingLastPathComponent())])
        let batches = try MetadataBuilder().build(manifest: manifest)
        XCTAssertEqual(batches.flatMap(\.items).count, manifest.entries.count)
        let text = String(decoding: try batches[0].encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains(fs.root.path)); XCTAssertFalse(text.contains("MEDIA-MUST-NOT-LEAVE"))
        XCTAssertTrue(text.contains("video.mp4"))
    }
    func testXMLExternalEntitiesDisabled() throws {
        let data = Data("<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><x><CameraModel>&secret;</CameraModel></x>".utf8)
        XCTAssertTrue(MetadataBuilder.cameraFields(data).isEmpty)
        XCTAssertEqual(MetadataBuilder.cameraFields(Data("<x><CameraModel>FX3</CameraModel><Secret>do not send</Secret></x>".utf8)), ["CameraModel": "FX3"])
    }
    func testUnknownEntryAndTraversalRejected() throws {
        let id = UUID()
        XCTAssertThrowsError(try AIProposal(groups: [AIGroup(folder: "../bad", entries: [id])]).validate(expected: [id]))
        XCTAssertThrowsError(try AIProposal(groups: [AIGroup(folder: "safe", entries: [UUID()])]).validate(expected: [id]))
        XCTAssertNoThrow(try AIProposal(groups: [AIGroup(folder: "摄影机A", entries: [id])]).validate(expected: [id]))
    }
    func testDuplicateOrMissingEntriesSurfaced() throws {
        let a = UUID(), b = UUID()
        XCTAssertThrowsError(try AIProposal(groups: [AIGroup(folder: "a", entries: [a,a])]).validate(expected: [a]))
        XCTAssertThrowsError(try AIProposal(groups: [AIGroup(folder: "a", entries: [a])]).validate(expected: [a,b]))
    }
    func testConfigurationDoesNotSerializeCredential() throws {
        let config = AIConfiguration(endpoint: URL(string: "https://example.invalid/v1/chat/completions")!, model: "test")
        XCTAssertNoThrow(try config.validate())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["endpoint", "model"])
        XCTAssertThrowsError(try AIConfiguration(endpoint: URL(string: "http://example.invalid")!, model: "test").validate())
    }
    func testRedirectCannotForwardCredential() {
        let origin = URL(string: "https://example.invalid/v1/chat/completions")!
        XCTAssertFalse(AIClient.allowsRedirect(from: origin, to: URL(string: "https://attacker.invalid")!))
        XCTAssertFalse(AIClient.allowsRedirect(from: origin, to: URL(string: "http://example.invalid")!))
    }
    func testMetadataBatchesNeverOmitEntries() throws {
        let fs = try TestFiles(); var manifest = try ManifestBuilder().build([SourceSelection(root: fs.file("a"))])
        let seed = manifest.entries[0]
        manifest.entries = (0..<1001).map { i in var e = seed; e.id = UUID(); e.relativePath = "file-\(i)"; return e }
        let batches = try MetadataBuilder().build(manifest: manifest)
        XCTAssertGreaterThan(batches.count, 2)
        XCTAssertEqual(batches.flatMap(\.items).map(\.id), manifest.entries.map(\.id))
        for batch in batches { XCTAssertLessThanOrEqual(batch.items.count, 500); XCTAssertLessThanOrEqual(try batch.encoded().count, 200 * 1024) }
    }
    func testConfirmedGroupsCreatePendingJobsWithOriginalPaths() async throws {
        let fs = try TestFiles()
        let source = try fs.directory("CARD"); try fs.file("CARD/a.mp4"); try fs.file("CARD/a.xml")
        let manifest = try ManifestBuilder().build([SourceSelection(root: source)])
        let target = try fs.directory("target"), volume = try VolumeInspector().inspect(target)
        let proposal = AIProposal(groups: [AIGroup(folder: "A机", entries: manifest.entries.map(\.id))])
        let jobs = try proposal.jobs(manifest: manifest, destination: target, volume: volume, algorithm: .md5)
        XCTAssertEqual(jobs[0].manifest.entries.map(\.relativePath), manifest.entries.map(\.relativePath))
        XCTAssertEqual(jobs[0].destination, target.appendingPathComponent("A机"))
        XCTAssertEqual(jobs[0].algorithm, .md5)
        let queue = try TransferQueue(store: JobStore(directory: fs.root.appendingPathComponent("state")))
        try await queue.enqueueBatch(jobs)
        let snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.jobs.allSatisfy { $0.state == .pending })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        do { try await queue.enqueueBatch(jobs); XCTFail("duplicate batch") } catch {}
        let count = await queue.snapshot().jobs.count; XCTAssertEqual(count, 1)
    }
}
