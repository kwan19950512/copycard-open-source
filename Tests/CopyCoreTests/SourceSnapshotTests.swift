import XCTest
@testable import CopyCore

final class SourceSnapshotTests: XCTestCase {
    func testDetectsNewDeletedAndModifiedFiles() throws {
        let fs = try TestFiles(), source = try fs.directory("source")
        let file = try fs.file("source/a", Data("a".utf8))
        let builder = ManifestBuilder(), selection = [SourceSelection(root: source)]
        let original = try builder.build(selection)
        XCTAssertFalse(SourceSnapshot.hasChanges(original: original, current: try builder.build(selection), excluded: []))
        _ = try fs.file("source/b")
        XCTAssertTrue(SourceSnapshot.hasChanges(original: original, current: try builder.build(selection), excluded: []))
        let withExtra = try builder.build(selection)
        try FileManager.default.removeItem(at: source.appendingPathComponent("b"))
        XCTAssertTrue(SourceSnapshot.hasChanges(original: withExtra, current: try builder.build(selection), excluded: []))
        try Data("changed".utf8).write(to: file)
        XCTAssertTrue(SourceSnapshot.hasChanges(original: original, current: try builder.build(selection), excluded: []))
    }
    func testRescanPreservesUnchangedIDsAndReportsChanges() throws {
        let fs = try TestFiles(), source = try fs.directory("source")
        _ = try fs.file("source/keep", Data("keep".utf8))
        let changed = try fs.file("source/change", Data("old".utf8))
        let deleted = try fs.file("source/deleted")
        let selection = [SourceSelection(root: source)], builder = ManifestBuilder()
        let original = try builder.build(selection), target = try fs.directory("target")
        let job = TransferJob(manifest: original, destination: target, destinationVolume: testVolume(fs))
        try Data("new content".utf8).write(to: changed)
        try FileManager.default.removeItem(at: deleted)
        _ = try fs.file("source/new")
        let plan = try RescanPlan(job: job, scanned: builder.build(selection))
        let before = try XCTUnwrap(original.entries.first { $0.sourceURL.lastPathComponent == "keep" })
        let after = try XCTUnwrap(plan.manifest.entries.first { $0.sourceURL.lastPathComponent == "keep" })
        XCTAssertEqual(before.id, after.id)
        XCTAssertTrue(plan.added.contains { $0.hasSuffix("/new") })
        XCTAssertTrue(plan.removed.contains { $0.hasSuffix("/deleted") })
        XCTAssertTrue(plan.changed.contains { $0.hasSuffix("/change") })
    }
    func testRescannedTaskRetainsPartialIdentityAndRejectsStalePlan() async throws {
        let fs = try TestFiles(), source = try fs.directory("source"), file = try fs.file("source/a")
        let target = try fs.directory("target"), builder = ManifestBuilder()
        let original = try builder.build([SourceSelection(root: source)])
        let volume = try VolumeInspector().inspect(target)
        var job = TransferJob(manifest: original, destination: target, destinationVolume: volume)
        let entry = try XCTUnwrap(original.entries.first { $0.sourceURL.lastPathComponent == file.lastPathComponent && $0.kind == .file })
        job.results[entry.id] = FileCopyResult(entryID: entry.id, status: .paused, temporaryName: ".copycard-\(entry.id.uuidString)-saved.partial")
        let q = try TransferQueue(store: JobStore(directory: try fs.directory("state")))
        try await q.enqueue(job); try await q.cancel(id: job.id)
        _ = try fs.file("source/new")
        let plan = try RescanPlan(job: job, scanned: builder.build(original.selections))
        try await q.applyRescan(id: job.id, plan: plan)
        let snapshot = await q.snapshot(), updated = try XCTUnwrap(snapshot.jobs.first)
        XCTAssertEqual(updated.state, .pending)
        XCTAssertEqual(updated.results[entry.id]?.temporaryName, ".copycard-\(entry.id.uuidString)-saved.partial")
        XCTAssertEqual(updated.requiresReverification, true)
        do { try await q.applyRescan(id: job.id, plan: plan); XCTFail("stale plan should be rejected") } catch { }
        try await q.closeSession()
    }
    func testRescanContinuesWithoutOverwritingDifferentExistingFile() async throws {
        let fs = try TestFiles(), source = try fs.directory("source"), file = try fs.file("source/a", Data("old".utf8))
        let target = try fs.directory("target"), builder = ManifestBuilder()
        let original = try builder.build([SourceSelection(root: source)])
        let job = TransferJob(manifest: original, destination: target, destinationVolume: try VolumeInspector().inspect(target))
        let q = try TransferQueue(store: JobStore(directory: try fs.directory("state")))
        try await q.enqueue(job); try await q.cancel(id: job.id)
        try Data("new source".utf8).write(to: file)
        let existing = try fs.file("target/source/a", Data("old target".utf8))
        let plan = try RescanPlan(job: job, scanned: builder.build(original.selections))
        try await q.applyRescan(id: job.id, plan: plan); try await q.start(ids: [job.id])
        var state: JobState = .running
        for _ in 0..<500 {
            let snapshot = await q.snapshot(); state = try XCTUnwrap(snapshot.jobs.first?.state)
            if state != .running && state != .queued { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(state, .needsAttention)
        XCTAssertEqual(try Data(contentsOf: existing), Data("old target".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("new source".utf8))
        try await q.closeSession()
    }
    func testExplicitExcludePreservesFilesAndRecordsUnverifiedExclusion() async throws {
        let fs = try TestFiles(), source = try fs.directory("source")
        let conflictSource = try fs.file("source/a", Data("source".utf8))
        _ = try fs.file("source/b", Data("other".utf8))
        let target = try fs.directory("target"), oldTarget = try fs.file("target/source/a", Data("different".utf8))
        let original = try ManifestBuilder().build([SourceSelection(root: source)])
        var job = TransferJob(manifest: original, destination: target, destinationVolume: try VolumeInspector().inspect(target))
        let entry = try XCTUnwrap(original.entries.first { $0.sourceURL.lastPathComponent == "a" })
        job.results[entry.id] = FileCopyResult(entryID: entry.id, status: .conflict, message: "不同")
        let q = try TransferQueue(store: JobStore(directory: try fs.directory("state")))
        try await q.enqueue(job); try await q.cancel(id: job.id); try await q.excludeProblem(jobID: job.id, entryID: entry.id)
        let pendingSnapshot = await q.snapshot()
        var updated = try XCTUnwrap(pendingSnapshot.jobs.first)
        XCTAssertEqual(updated.state, .pending); XCTAssertEqual(updated.excludedCount, 1)
        XCTAssertNil(updated.manifest.entries.first { $0.id == entry.id })
        try await q.start(ids: [job.id])
        for _ in 0..<500 {
            let snapshot = await q.snapshot()
            updated = try XCTUnwrap(snapshot.jobs.first)
            if updated.state != .running && updated.state != .queued { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(updated.state, .completed)
        XCTAssertTrue(updated.completionLabel.contains("未复制、未校验"))
        XCTAssertEqual(try Data(contentsOf: conflictSource), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: oldTarget), Data("different".utf8))
        try await q.closeSession()
    }
    func testExcludingEveryFileNeverClaimsVerificationPassed() async throws {
        let fs = try TestFiles(), source = try fs.directory("source")
        _ = try fs.file("source/a", Data("source".utf8))
        let target = try fs.directory("target"), original = try ManifestBuilder().build([SourceSelection(root: source)])
        var job = TransferJob(manifest: original, destination: target, destinationVolume: try VolumeInspector().inspect(target))
        let entry = try XCTUnwrap(original.entries.first { $0.kind == .file })
        job.results[entry.id] = FileCopyResult(entryID: entry.id, status: .conflict, message: "不同")
        let q = try TransferQueue(store: JobStore(directory: try fs.directory("state")))
        try await q.enqueue(job); try await q.cancel(id: job.id); try await q.excludeProblem(jobID: job.id, entryID: entry.id)
        try await q.start(ids: [job.id])
        var state: JobState = .running
        for _ in 0..<500 {
            let snapshot = await q.snapshot(); state = try XCTUnwrap(snapshot.jobs.first?.state)
            if state != .running && state != .queued { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let snapshot = await q.snapshot()
        XCTAssertEqual(state, .needsAttention)
        XCTAssertTrue(snapshot.jobs.first?.message?.contains("没有文件通过校验") == true)
        try await q.closeSession()
    }
}
