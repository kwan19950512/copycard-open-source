import XCTest
import AppKit
import CopyCore
import UniformTypeIdentifiers
@testable import CopyApp

final class TransferInteractionTests: XCTestCase {
    private func delayedDrop(_ path: String?, delay: TimeInterval, done: XCTestExpectation) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                if let path { completion(URL(fileURLWithPath: path).absoluteString.data(using: .utf8), nil) }
                else { completion(nil, NSError(domain: "DropTest", code: 1)) }
                done.fulfill()
            }
            return nil
        }
        return provider
    }
    @MainActor func testWithoutManualRevisionGuardOldDropOverridesSelection() async throws {
        let done = expectation(description: "old provider finished")
        let applied = expectation(description: "old result applied")
        let browser = BrowserModel(location: URL(fileURLWithPath: "/tmp"))
        let coordinator = DropRequestCoordinator()
        browser.beginNewDrop()
        coordinator.submit([delayedDrop("/tmp/old", delay: 0.1, done: done)], apply: { browser.select(Set($0)); applied.fulfill() }, fail: { _ in XCTFail("unexpected failure") })
        browser.select([URL(fileURLWithPath: "/tmp/manual")])
        await fulfillment(of: [done, applied], timeout: 3)
        XCTAssertEqual(browser.selected, [URL(fileURLWithPath: "/tmp/old")])
    }
    @MainActor func testManualNavigationAndSelectionInvalidatePendingDrop() async throws {
        for navigate in [true, false] {
            let done = expectation(description: "old drop read finishes")
            let browser = BrowserModel(location: URL(fileURLWithPath: "/tmp"))
            let coordinator = DropRequestCoordinator()
            browser.beginNewDrop(); let revision = browser.interactionRevision
            var applied = false, failed = false
            coordinator.submit([delayedDrop("/tmp/old", delay: 0.15, done: done)], isValid: { browser.interactionRevision == revision }, apply: { _ in applied = true }, fail: { _ in failed = true })
            let choice = URL(fileURLWithPath: "/tmp/manual-choice")
            if navigate { browser.navigate(choice) } else { browser.select([choice]) }
            await fulfillment(of: [done], timeout: 3)
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertFalse(applied); XCTAssertFalse(failed)
            if navigate { XCTAssertEqual(browser.location, choice) } else { XCTAssertEqual(browser.selected, [choice]) }
        }
    }
    @MainActor func testOldFailureAfterNewSuccessIsNotReported() async throws {
        let oldDone = expectation(description: "old failure returned")
        let newDone = expectation(description: "new provider returned")
        let applied = expectation(description: "new drop applied")
        let coordinator = DropRequestCoordinator()
        var failures = 0, selected = ""
        coordinator.submit([delayedDrop(nil, delay: 0.2, done: oldDone)], apply: { _ in XCTFail("old drop applied") }, fail: { _ in failures += 1 })
        coordinator.submit([delayedDrop("/tmp/new", delay: 0.01, done: newDone)], apply: { selected = $0[0].lastPathComponent; applied.fulfill() }, fail: { _ in XCTFail("new drop failed") })
        await fulfillment(of: [oldDone, newDone, applied], timeout: 3)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(selected, "new"); XCTAssertEqual(failures, 0)
    }
    @MainActor func testOldFailureAfterManualSelectionIsNotReported() async throws {
        let done = expectation(description: "old failure returned")
        let browser = BrowserModel(location: URL(fileURLWithPath: "/tmp"))
        let coordinator = DropRequestCoordinator()
        browser.beginNewDrop(); let revision = browser.interactionRevision
        var errors = 0
        coordinator.submit([delayedDrop(nil, delay: 0.1, done: done)], isValid: { browser.interactionRevision == revision }, apply: { _ in XCTFail("old drop applied") }, fail: { _ in errors += 1 })
        let manual = URL(fileURLWithPath: "/tmp/manual-choice")
        browser.select([manual]); await fulfillment(of: [done], timeout: 3)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(browser.selected, [manual]); XCTAssertEqual(errors, 0)
    }
    @MainActor func testUncoordinatedDropReproducesEarlierRequestWinning() async throws {
        let firstDone = expectation(description: "earlier provider applied")
        let secondDone = expectation(description: "later provider applied")
        func provider(_ name: String, delay: TimeInterval) -> NSItemProvider {
            let item = NSItemProvider()
            item.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    completion(URL(fileURLWithPath: "/tmp/" + name).absoluteString.data(using: .utf8), nil)
                }
                return nil
            }
            return item
        }
        var applied: [String] = []
        let first = provider("earlier", delay: 0.3), second = provider("latest", delay: 0.01)
        Task { if let urls = try? await FileTransferPayload.read([first]) { applied.append(urls[0].lastPathComponent) }; firstDone.fulfill() }
        Task { if let urls = try? await FileTransferPayload.read([second]) { applied.append(urls[0].lastPathComponent) }; secondDone.fulfill() }
        await fulfillment(of: [firstDone, secondDone], timeout: 3)
        XCTAssertEqual(applied, ["latest", "earlier"])
    }
    @MainActor func testSlowEarlierDropCannotOverrideLatestDrop() async throws {
        let earlierDone = expectation(description: "earlier provider finishes")
        let latestApplied = expectation(description: "latest drop applied")
        func provider(_ name: String, delay: TimeInterval, done: XCTestExpectation? = nil) -> NSItemProvider {
            let result = NSItemProvider()
            result.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    completion(URL(fileURLWithPath: "/tmp/" + name).absoluteString.data(using: .utf8), nil)
                    done?.fulfill()
                }
                return nil
            }
            return result
        }
        let coordinator = DropRequestCoordinator()
        var applied: [String] = []
        coordinator.submit([provider("earlier", delay: 0.3, done: earlierDone)], apply: { applied.append($0[0].lastPathComponent) }, fail: { _ in XCTFail("unexpected error") })
        coordinator.submit([provider("latest", delay: 0.01)], apply: { applied.append($0[0].lastPathComponent); latestApplied.fulfill() }, fail: { _ in XCTFail("unexpected error") })
        await fulfillment(of: [latestApplied, earlierDone], timeout: 3)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(applied, ["latest"])
    }
    func testDropReadsOneFileURL() async throws {
        let url = URL(fileURLWithPath: "/tmp/drop-test.txt")
        let provider = NSItemProvider(object: url as NSURL)
        let urls = try await FileTransferPayload.read([provider])
        XCTAssertEqual(urls.map(\.standardizedFileURL), [url.standardizedFileURL])
    }
    func testDropReadsAllSeparateProviders() async throws {
        let urls = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]
        let result = try await FileTransferPayload.read(urls.map { NSItemProvider(object: $0 as NSURL) })
        XCTAssertEqual(result.map(\.standardizedFileURL), urls.map(\.standardizedFileURL))
    }
    func testDropReadsMultipleURLsInsideCustomProvider() async throws {
        let urls = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]
        let read = try await FileTransferPayload.read([FileTransferPayload.provider(urls: urls)])
        XCTAssertEqual(read, urls)
    }
    func testDropRejectsMultipleProvidersEvenIfOneCannotBeRead() async throws {
        let good = NSItemProvider(object: URL(fileURLWithPath: "/tmp/a") as NSURL)
        let unreadable = NSItemProvider()
        do {
            _ = try await FileTransferPayload.read([good, unreadable])
            XCTFail("Multiple dragged items must not silently become a single item")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("无法完整读取"))
        }
    }
    func testDropRejectsUnreadableProvider() async throws {
        do {
            _ = try await FileTransferPayload.read([NSItemProvider()])
            XCTFail("Unreadable drag must report an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("无法完整读取"))
        }
    }
    func testIconSelectionUsesRangeAndCommandToggle() {
        let urls = ["a", "b", "c", "d"].map { URL(fileURLWithPath: "/tmp/" + $0) }
        XCTAssertEqual(BrowserInteraction.selectionByClick(urls[3], ordered: urls, selected: [urls[1]], anchor: urls[1], command: false, shift: true), Set(urls[1...3]))
        XCTAssertEqual(BrowserInteraction.selectionByClick(urls[1], ordered: urls, selected: [urls[1], urls[2]], anchor: urls[2], command: true, shift: false), [urls[2]])
        XCTAssertEqual(BrowserInteraction.selectionByClick(urls[0], ordered: urls, selected: [urls[2]], anchor: nil, command: false, shift: false), [urls[0]])
    }
    @MainActor func testExplicitExclusionRefreshesPreviewWithoutCopyingAnything() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.command")
        try Data("generated".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.deletingLastPathComponent().appendingPathComponent("link.command"), withDestinationURL: outside)
        let app = AppModel(storage: root.appendingPathComponent("state"))
        app.prepare(sources: [source.deletingLastPathComponent()], destination: target)
        await app.preparationTask?.value
        XCTAssertEqual(app.draftPreflight?.canStart, false)
        app.excludeUnsupportedFromDraft(); await app.preparationTask?.value
        XCTAssertEqual(app.draftPreflight?.canStart, true)
        XCTAssertEqual(app.draft?.excludedCount, 1)
        XCTAssertEqual(app.draft?.manifest.fileCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        app.cancelDraft(); XCTAssertNil(app.draft)
    }
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopyAppTests-" + UUID().uuidString)
        let source = root.appendingPathComponent("card/clip.mp4")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: source)
        return (root, source, target)
    }
    func testPasteCreatesPendingJob() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try await TransferActions().prepare(sources: [source], destination: target)
        XCTAssertEqual(job.state, .pending); XCTAssertEqual(job.manifest.totalBytes, 3)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    @MainActor func testPasteAutomaticallyEnqueuesWithoutStarting() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        app.appendCopiedSources([source]); app.paste(into: target)
        await app.preparationTask?.value
        for _ in 0..<200 where app.acceptingDraft { try await Task.sleep(nanoseconds: 10_000_000) }
        let snapshot = await app.queue!.snapshot()
        XCTAssertEqual(snapshot.jobs.count, 1); XCTAssertEqual(snapshot.jobs.first?.state, .pending)
        XCTAssertNil(app.draft); XCTAssertTrue(app.copiedSources.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        try await app.queue?.closeSession()
    }
    @MainActor func testInvalidPasteKeepsSourcesAndDoesNotEnqueue() async throws {
        let (root, source, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        app.appendCopiedSources([source]); app.paste(into: source.deletingLastPathComponent())
        await app.preparationTask?.value
        let snapshot = await app.queue!.snapshot()
        XCTAssertTrue(snapshot.jobs.isEmpty); XCTAssertFalse(app.copiedSources.isEmpty); XCTAssertNotNil(app.error)
        try await app.queue?.closeSession()
    }
    func testPreparingNeverMovesSource() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await TransferActions().prepare(sources: [source], destination: target)
        XCTAssertEqual(try String(contentsOf: source), "abc")
    }
    @MainActor func testCancelPreparationCannotRestorePreview() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        app.prepare(sources: [source], destination: target)
        let task = app.preparationTask
        app.cancelDraft()
        await task?.value
        XCTAssertNil(app.draft); XCTAssertNil(app.draftPreflight); XCTAssertFalse(app.preparing)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let snapshot = await app.queue!.snapshot()
        XCTAssertTrue(snapshot.jobs.isEmpty)
    }
    @MainActor func testCancelledRescanDoesNotChangeOrStartTask() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        let job = try await TransferActions().prepare(sources: [source], destination: target)
        try await app.queue!.enqueue(job); try await app.queue!.cancel(id: job.id)
        let beforeSnapshot = await app.queue!.snapshot()
        let before = try XCTUnwrap(beforeSnapshot.jobs.first)
        app.rescanAndContinue(before)
        let task = app.preparationTask; app.cancelDraft(); await task?.value
        let after = await app.queue!.snapshot()
        XCTAssertEqual(after.jobs.first?.state, .cancelled)
        XCTAssertEqual(after.jobs.first?.manifest.entries.map(\.id), before.manifest.entries.map(\.id))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        try await app.queue?.closeSession()
    }
    @MainActor func testNewPreparationDoesNotReplaceCurrentPreview() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        app.queueExpanded = true
        app.prepare(sources: [source], destination: target)
        XCTAssertTrue(app.queueExpanded, "Preparing another batch must not hide confirmed tasks")
        await app.preparationTask?.value
        let id = try XCTUnwrap(app.draft?.id)
        app.prepare(sources: [source], destination: root)
        await app.preparationTask?.value
        XCTAssertEqual(app.draft?.id, id); XCTAssertEqual(app.draft?.destination, target)
        XCTAssertNotNil(app.error)
        app.cancelDraft()
        XCTAssertNil(app.draft)
    }
    @MainActor func testCancelRetargetCannotRestorePreviewOrChangeQueuedJob() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        let job = try await TransferActions().prepare(sources: [source], destination: target)
        try await app.queue!.enqueue(job)
        app.draft = job
        app.retargetDraft(to: root.appendingPathComponent("other"))
        let task = app.preparationTask
        app.cancelDraft(); await task?.value
        XCTAssertNil(app.draft)
        let saved = await app.queue!.snapshot()
        XCTAssertEqual(saved.jobs.first?.destination, target)
    }
    @MainActor func testCopiedSelectionSurvivesNavigation() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        let browser = BrowserModel(location: source.deletingLastPathComponent())
        browser.selected = [source]
        let pasteboard = NSPasteboard.withUniqueName()
        app.copySelection(browser, pasteboard: pasteboard)
        browser.navigate(target)
        XCTAssertEqual(app.copiedSources, [source]); XCTAssertTrue(browser.selected.isEmpty)
        app.clearCopiedSelection(pasteboard: pasteboard)
        XCTAssertTrue(app.copiedSources.isEmpty)
    }
    func testSameLocationPasteRejectedBeforePreview() async throws {
        let (root, source, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await TransferActions().prepare(sources: [source], destination: source.deletingLastPathComponent())
            XCTFail("Pasting onto itself must not create a draft")
        } catch { XCTAssertTrue(error.localizedDescription.contains("原位置")) }
    }
    func testBatchConflictRetargetPreservesRelativePaths() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try await TransferActions().prepare(sources: [source.deletingLastPathComponent()], destination: target)
        let new = try await TransferActions().retarget(job: job, destination: root.appendingPathComponent("new-target"))
        XCTAssertEqual(new.manifest.entries.map(\.relativePath), ["card", "card/clip.mp4"])
        XCTAssertEqual(new.destination.lastPathComponent, "new-target"); XCTAssertEqual(new.state, .pending)
    }
    @MainActor func testNewWindowObservesSameProgress() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        let queue = try XCTUnwrap(app.queue)
        let job = try await TransferActions().prepare(sources: [source], destination: target)
        try await queue.enqueue(job)
        let a = app.registry.create(location: target); let b = app.registry.create(location: target)
        for _ in 0..<100 where app.snapshot.jobs.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(app.snapshot.jobs.map(\.id), [job.id])
        XCTAssertFalse(a.left === b.left)
    }
    @MainActor func testCloseWindowKeepsTransfer() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
    func testQuitWaitsForCheckpoint() async throws {
        let (root, source, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(directory: root.appendingPathComponent("state"))
        let queue = try TransferQueue(store: store)
        let job = try await TransferActions().prepare(sources: [source], destination: target)
        try await queue.enqueue(job); try await queue.start(ids: [job.id]); try await queue.pauseAllAndWait()
        let restored = try store.load()
        XCTAssertNotEqual(restored.first?.state, .running)
        XCTAssertNotEqual(restored.first?.state, .queued)
    }
}
