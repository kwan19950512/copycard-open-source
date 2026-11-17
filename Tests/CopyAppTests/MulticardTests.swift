import XCTest
import AppKit
import CopyCore
@testable import CopyApp

final class MulticardTests: XCTestCase {
    @MainActor func testQueuedDestinationReviewKeepsUnrelatedShelfBatch() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        let a = root.appendingPathComponent("cardA"), b = root.appendingPathComponent("cardB")
        let job = try await TransferActions().prepare(sources: [b], destination: root.appendingPathComponent("target"))
        try await app.queue!.enqueue(job)
        app.snapshot = await app.queue!.snapshot()
        app.appendCopiedSources([a]); XCTAssertNotNil(app.draftCopyBatchID)
        XCTAssertTrue(app.beginDestinationReview(job)); XCTAssertNil(app.draftCopyBatchID)
        await app.refreshDraftPreflight()
        app.acceptDraft(start: false)
        for _ in 0..<200 where app.acceptingDraft { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(app.copiedSources, [a])
        XCTAssertTrue(app.beginDestinationReview(job)); app.cancelDraft()
        XCTAssertEqual(app.copiedSources, [a])
        try await app.queue?.closeSession()
    }
    @MainActor func testColumnNavigationHistoryAndClearedLoadingItems() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("cardA")
        let browser = BrowserModel(location: root, directoryReader: { url in
            if url.lastPathComponent == "cardA" { Thread.sleep(forTimeInterval: 0.15) }
            return try BrowserModel.readDirectory(url)
        })
        browser.refresh()
        for _ in 0..<150 where browser.items.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(browser.items.isEmpty)
        browser.openColumnFolder(child, index: 0)
        XCTAssertTrue(browser.items.isEmpty)
        browser.select(Set(browser.items.map(\.url))); XCTAssertTrue(browser.selected.isEmpty)
        browser.back(); XCTAssertEqual(browser.location.standardizedFileURL, root.standardizedFileURL)
        browser.forward(); XCTAssertEqual(browser.location.standardizedFileURL, child.standardizedFileURL)
        browser.back(); browser.openColumnFolder(root.appendingPathComponent("cardB"), index: 0)
        browser.forward(); XCTAssertEqual(browser.location.lastPathComponent, "cardB")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(browser.items.contains { $0.url.path.contains("cardA") })
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copycard-next-" + UUID().uuidString)
        for path in ["cardA/DCIM", "cardB/DCIM", "target"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        try Data("aaa".utf8).write(to: root.appendingPathComponent("cardA/DCIM/a.mp4"))
        try Data("bbbb".utf8).write(to: root.appendingPathComponent("cardB/DCIM/b.mp4"))
        return root
    }
    @MainActor func testShelfAccumulatesDeduplicatesAndSurvivesSystemClipboard() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        let a = root.appendingPathComponent("cardA"), b = root.appendingPathComponent("cardB")
        app.appendCopiedSources([a]); app.appendCopiedSources([b]); app.appendCopiedSources([a]); XCTAssertEqual(Set(app.copiedSources), [a,b])
        XCTAssertEqual(app.copiedBatches.count, 2)
        app.refreshClipboardSelection(); XCTAssertEqual(app.copiedSources.count, 2)
        app.removeCopiedSource(a); XCTAssertEqual(app.copiedSources, [b])
        let board = NSPasteboard.withUniqueName(); app.clearCopiedSelection(pasteboard: board); XCTAssertTrue(app.copiedSources.isEmpty)
        try await app.queue?.closeSession()
    }
    @MainActor func testNewSourcePreservesUnconfirmedPreviewAndConfirmedQueue() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state")), a = root.appendingPathComponent("cardA"), b = root.appendingPathComponent("cardB"), target = root.appendingPathComponent("target")
        app.appendCopiedSources([a]); app.prepare(sources: app.copiedBatches.first(where: { $0.id == app.selectedCopyBatchID })!.sources, destination: target); await app.preparationTask?.value
        let job = try XCTUnwrap(app.draft)
        try await app.queue!.enqueue(job)
        let firstBatch = try XCTUnwrap(app.selectedCopyBatchID)
        app.appendCopiedSources([b]); XCTAssertNil(app.draft); XCTAssertEqual(app.copiedSources.count, 2)
        XCTAssertEqual(app.copiedBatches.first?.preview.first?.id, job.id)
        app.selectCopyBatch(firstBatch); await app.preparationTask?.value
        XCTAssertEqual(app.draft?.id, job.id); XCTAssertEqual(app.draft?.destination, target)
        let saved = await app.queue!.snapshot(); XCTAssertEqual(saved.jobs.count, 1)
        XCTAssertEqual(saved.jobs.first?.manifest.selections.first?.root, a)
        try await app.queue?.closeSession()
    }
    @MainActor func testDirectPreparationDoesNotConsumeUnrelatedShelfBatch() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        let a = root.appendingPathComponent("cardA"), b = root.appendingPathComponent("cardB")
        app.appendCopiedSources([a])
        app.prepare(sources: [b], destination: root.appendingPathComponent("target")); await app.preparationTask?.value
        XCTAssertNil(app.draftCopyBatchID)
        let id = app.draft?.id
        app.appendCopiedSources([b]); XCTAssertEqual(app.draft?.id, id)
        app.acceptDraft(start: false)
        for _ in 0..<200 where app.acceptingDraft { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(app.copiedBatches.count, 2)
        try await app.queue?.closeSession()
    }
    func testSeparateCardsBecomeIndependentJobsWithoutDroppingLinks() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("cardA"), b = root.appendingPathComponent("cardB")
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("outside-link"), withDestinationURL: b)
        let combined = try await TransferActions().prepare(sources: [a,b], destination: root.appendingPathComponent("target"))
        let ids = ["cardA": "A", "cardB": "B"]
        let jobs = try TransferActions.partition(combined) { url in
            VolumeInfo(id: ids[url.lastPathComponent]!, root: url, immediateFree: 1_000_000_000)
        }
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs.flatMap { $0.manifest.entries }.count, combined.manifest.entries.count)
        XCTAssertEqual(jobs.flatMap { $0.manifest.entries }.filter { $0.kind == .unsupported }.count, 1)
        XCTAssertEqual(Set(jobs.map(\.id)).count, 2)
    }
    @MainActor func testBatchPreviewDetectsCrossCardNameCollisionsAndRetargetsIndividually() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state")), target = root.appendingPathComponent("target")
        let a = try await TransferActions().prepare(sources: [root.appendingPathComponent("cardA/DCIM")], destination: target)
        let b = try await TransferActions().prepare(sources: [root.appendingPathComponent("cardB/DCIM")], destination: target)
        app.draft = a; app.additionalDrafts = [b]; await app.refreshDraftPreflight()
        XCTAssertEqual(app.draftPreflight?.canStart, false)
        let other = root.appendingPathComponent("other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        app.retargetDraft(to: other, jobID: b.id); await app.preparationTask?.value
        XCTAssertEqual(app.draft?.destination, target); XCTAssertEqual(app.additionalDrafts.first?.destination, other)
        XCTAssertEqual(app.draftPreflight?.canStart, true)
        app.cancelDraft(); try await app.queue?.closeSession()
    }
    @MainActor func testDropNavigatesParentAndSelectsWithoutCopying() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("cardA")
        let browser = BrowserModel(location: root.appendingPathComponent("target"))
        try browser.revealDroppedFolders([folder])
        for _ in 0..<150 where browser.revealedURL == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(browser.location.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(browser.selected.map { $0.resolvingSymlinksInPath().path }, [folder.resolvingSymlinksInPath().path])
        XCTAssertEqual(browser.revealedURL?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        try browser.revealDroppedFolders([folder, root.appendingPathComponent("cardB")])
        for _ in 0..<150 where browser.selected.count != 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(Set(browser.selected.map(\.lastPathComponent)), ["cardA", "cardB"])
        XCTAssertThrowsError(try browser.revealDroppedFolders([folder, folder.appendingPathComponent("DCIM/a.mp4")]))
        let file = folder.appendingPathComponent("DCIM/a.mp4")
        try browser.revealDroppedFolders([file])
        for _ in 0..<150 where browser.revealedURL?.lastPathComponent != "a.mp4" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(browser.selected.map(\.lastPathComponent), ["a.mp4"])
        XCTAssertEqual(browser.location.lastPathComponent, "DCIM")
    }
    @MainActor func testDroppedVolumeRootOpensWithoutScanningWholeDisk() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let volume = root.appendingPathComponent("cardA")
        let browser = BrowserModel(location: root.appendingPathComponent("target"))
        try browser.revealDroppedFolders([volume], isVolumeRoot: { $0 == volume })
        XCTAssertEqual(browser.location.standardizedFileURL.path, volume.standardizedFileURL.path)
        XCTAssertTrue(browser.selected.isEmpty); XCTAssertEqual(browser.selectionBytes, 0)
    }
    @MainActor func testMultiDropMixedFilesAndFoldersIsAllOrNothing() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.txt"), folder = root.appendingPathComponent("cardA")
        try Data("test".utf8).write(to: file)
        let hidden = root.appendingPathComponent(".hidden")
        try Data("test".utf8).write(to: hidden)
        let browser = BrowserModel(location: root.appendingPathComponent("target"))
        try browser.revealDroppedFolders([file, folder])
        for _ in 0..<150 where browser.selected.count != 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(Set(browser.selected.map(\.lastPathComponent)), ["test.txt", "cardA"])
        browser.beginNewDrop(); try browser.revealDroppedFolders([file, hidden])
        for _ in 0..<150 where browser.revealError == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(browser.selected.isEmpty); XCTAssertNotNil(browser.revealError)
        XCTAssertThrowsError(try browser.revealDroppedFolders([file, root.appendingPathComponent("missing")]))
    }
    @MainActor func testColumnSynchronizationDoesNotOpenProgrammaticallyRevealedFolder() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("cardA")
        let browser = BrowserModel(location: root.appendingPathComponent("target"))
        browser.mode = .columns
        try browser.revealDroppedFolders([folder])
        for _ in 0..<150 where browser.revealedURL == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let revealed = try XCTUnwrap(browser.selected.first)
        XCTAssertEqual(revealed.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        let revision = browser.interactionRevision
        browser.columnSelectionChanged([revealed], column: root, index: 0, items: browser.items)
        XCTAssertEqual(browser.location.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(browser.revealedURL, revealed)
        XCTAssertEqual(browser.interactionRevision, revision)
        let other = try XCTUnwrap(browser.items.first(where: { $0.name == "cardB" })?.url)
        browser.columnSelectionChanged([other], column: root, index: 0, items: browser.items)
        XCTAssertEqual(browser.location.standardizedFileURL, other.standardizedFileURL)
    }
    @MainActor func testColumnSynchronizationPreservesMultipleDroppedFoldersAndDeduplicates() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("cardA"), second = root.appendingPathComponent("cardB")
        let browser = BrowserModel(location: root.appendingPathComponent("target"))
        browser.mode = .columns
        try browser.revealDroppedFolders([first, second, first])
        for _ in 0..<150 where browser.selected.count != 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(Set(browser.selected.map(\.lastPathComponent)), ["cardA", "cardB"])
        let selected = browser.selected, revision = browser.interactionRevision
        browser.columnSelectionChanged(selected, column: root, index: 0, items: browser.items)
        XCTAssertEqual(browser.selected, selected)
        XCTAssertEqual(browser.location.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(browser.interactionRevision, revision)
    }
    @MainActor func testColumnReflectingDropSelectionClearDoesNotInvalidateDrop() {
        let root = URL(fileURLWithPath: "/tmp")
        let browser = BrowserModel(location: root)
        browser.select([root.appendingPathComponent("selected")])
        browser.beginNewDrop()
        let revision = browser.interactionRevision
        browser.columnSelectionChanged([], column: root, index: 0, items: [])
        XCTAssertTrue(browser.selected.isEmpty)
        XCTAssertEqual(browser.interactionRevision, revision)
    }
    @MainActor func testClearingOtherColumnDoesNotCancelCurrentColumnSelection() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("cardA")
        let other = root.appendingPathComponent("cardB")
        let item = current.appendingPathComponent("DCIM/a.mp4")
        let browser = BrowserModel(location: current)
        browser.select([item]); let revision = browser.interactionRevision
        browser.columnSelectionChanged([], column: other, index: 0, items: [])
        XCTAssertEqual(browser.selected, [item])
        XCTAssertEqual(browser.interactionRevision, revision)
        browser.columnSelectionChanged([], column: item.deletingLastPathComponent(), index: 0, items: [])
        XCTAssertTrue(browser.selected.isEmpty)
        XCTAssertNotEqual(browser.interactionRevision, revision)
    }
    @MainActor func testDroppedHiddenFileReportsThatItWasNotSelected() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".hidden-test")
        try Data("test".utf8).write(to: hidden)
        let browser = BrowserModel(location: root.appendingPathComponent("target"))
        try browser.revealDroppedFolders([hidden])
        for _ in 0..<150 where browser.revealError == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(browser.selected.isEmpty)
        XCTAssertTrue(browser.revealError?.contains("未能选中") == true)
        XCTAssertThrowsError(try browser.revealDroppedFolders([root.appendingPathComponent("missing-test")]))
    }
    @MainActor func testDroppedFileDisappearingBeforeDirectoryReadReportsNotSelected() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let item = root.appendingPathComponent("disappears.txt")
        try Data("test".utf8).write(to: item)
        let started = expectation(description: "directory reading paused")
        let gate = DispatchSemaphore(value: 0)
        let browser = BrowserModel(location: root.appendingPathComponent("target"), directoryReader: { url in
            started.fulfill(); _ = gate.wait(timeout: .now() + 5)
            return try BrowserModel.readDirectory(url)
        })
        try browser.revealDroppedFolders([item])
        await fulfillment(of: [started], timeout: 3)
        try FileManager.default.removeItem(at: item)
        gate.signal()
        for _ in 0..<150 where browser.revealError == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(browser.selected.isEmpty)
        XCTAssertTrue(browser.revealError?.contains("未能选中") == true)
    }
    @MainActor func testNewDropCancelsEarlierPendingSelection() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let item = root.appendingPathComponent("earlier.txt")
        try Data("test".utf8).write(to: item)
        let started = expectation(description: "earlier directory read paused")
        let gate = DispatchSemaphore(value: 0)
        let browser = BrowserModel(location: root.appendingPathComponent("target"), directoryReader: { url in
            started.fulfill(); _ = gate.wait(timeout: .now() + 5)
            return try BrowserModel.readDirectory(url)
        })
        try browser.revealDroppedFolders([item])
        await fulfillment(of: [started], timeout: 3)
        browser.cancelPendingReveal()
        gate.signal()
        for _ in 0..<150 where browser.items.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(browser.selected.isEmpty)
        XCTAssertNil(browser.revealedURL)
        XCTAssertNil(browser.revealError)
    }
    @MainActor func testManualSelectionSurvivesPendingDroppedDirectoryRead() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let earlier = root.appendingPathComponent("earlier.txt"), manual = root.appendingPathComponent("manual.txt")
        try Data("a".utf8).write(to: earlier); try Data("b".utf8).write(to: manual)
        let started = expectation(description: "directory read paused")
        let gate = DispatchSemaphore(value: 0)
        let browser = BrowserModel(location: root.appendingPathComponent("target"), directoryReader: { url in
            started.fulfill(); _ = gate.wait(timeout: .now() + 5); return try BrowserModel.readDirectory(url)
        })
        try browser.revealDroppedFolders([earlier]); await fulfillment(of: [started], timeout: 3)
        browser.select([manual]); gate.signal()
        for _ in 0..<150 where browser.items.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(browser.selected, [manual]); XCTAssertNil(browser.revealedURL); XCTAssertNil(browser.revealError)
    }
    @MainActor func testFailedNewDropClearsPreviousSelection() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent("cardA")
        let browser = BrowserModel(location: root)
        browser.select([previous])
        browser.beginNewDrop()
        let failed = expectation(description: "invalid new drop reports failure")
        let coordinator = DropRequestCoordinator()
        coordinator.submit([NSItemProvider(), NSItemProvider()], apply: { _ in XCTFail("invalid drop must not apply") }, fail: { _ in failed.fulfill() })
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(browser.selected.isEmpty)
        XCTAssertNil(browser.revealedURL)
    }
    @MainActor func testSelectionStatisticsFailureDoesNotReplaceBrowser() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = BrowserModel(location: root)
        browser.select([root.appendingPathComponent("missing")])
        for _ in 0..<200 where !browser.selectionStatisticsFailed { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(browser.selectionStatisticsFailed); XCTAssertNil(browser.error)
        XCTAssertEqual(browser.selected.count, 1)
        browser.select([]); XCTAssertFalse(browser.selectionStatisticsFailed)
    }
    @MainActor func test160And920FilesStayInSeparateBatchesAndDestinations() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        let a = try (0..<160).map { index -> URL in let url = root.appendingPathComponent("cardA/DCIM/A\(index).mp4"); try Data([1]).write(to: url); return url }
        let b = try (0..<920).map { index -> URL in let url = root.appendingPathComponent("cardB/DCIM/B\(index).mp4"); try Data([2]).write(to: url); return url }
        let targetA = root.appendingPathComponent("target"), targetB = root.appendingPathComponent("targetB")
        try FileManager.default.createDirectory(at: targetB, withIntermediateDirectories: true)
        app.queueExpanded = true
        app.appendCopiedSources(a); app.prepare(sources: app.copiedBatches.first(where: { $0.id == app.selectedCopyBatchID })!.sources, destination: targetA); await app.preparationTask?.value
        let batchA = try XCTUnwrap(app.selectedCopyBatchID), jobA = try XCTUnwrap(app.draft)
        app.appendCopiedSources(b)
        XCTAssertEqual(app.copiedBatches.map { $0.sources.count }, [160,920])
        let batchB = try XCTUnwrap(app.selectedCopyBatchID)
        app.prepare(sources: app.copiedBatches.first(where: { $0.id == app.selectedCopyBatchID })!.sources, destination: targetB); await app.preparationTask?.value
        XCTAssertEqual(app.draft?.manifest.selections.count, 920); XCTAssertEqual(app.draft?.destination, targetB)
        app.selectCopyBatch(batchA); await app.preparationTask?.value
        XCTAssertEqual(app.draft?.id, jobA.id); XCTAssertEqual(app.draft?.manifest.selections.count, 160)
        app.acceptDraft(start: false)
        for _ in 0..<200 where app.acceptingDraft { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(app.copiedBatches.count, 1); XCTAssertTrue(app.queueExpanded)
        app.selectCopyBatch(batchB); await app.preparationTask?.value
        XCTAssertEqual(app.draft?.destination, targetB); XCTAssertEqual(app.draft?.manifest.selections.count, 920)
        app.acceptDraft(start: false)
        for _ in 0..<200 where app.acceptingDraft { try await Task.sleep(nanoseconds: 10_000_000) }
        let snapshot = await app.queue!.snapshot()
        XCTAssertEqual(snapshot.jobs.count, 2); XCTAssertEqual(snapshot.jobs.map { $0.manifest.selections.count }, [160,920])
        XCTAssertEqual(snapshot.jobs.map(\.destination), [targetA,targetB]); XCTAssertTrue(app.copiedBatches.isEmpty)
        try await app.queue?.closeSession()
    }
    func testSortUnknownValuesLastInBothDirections() {
        let a = BrowserItem(url: URL(fileURLWithPath: "/a"), isDirectory: false, size: 3, modified: Date(timeIntervalSince1970: 10), kind: "视频")
        let b = BrowserItem(url: URL(fileURLWithPath: "/b"), isDirectory: false, size: 8, modified: Date(timeIntervalSince1970: 20), kind: "音频")
        let unknown = BrowserItem(url: URL(fileURLWithPath: "/folder"), isDirectory: true, size: 0)
        XCTAssertEqual(BrowserModel.sorted([unknown,b,a], by: .size, ascending: true).map(\.name), ["a","b","folder"])
        XCTAssertEqual(BrowserModel.sorted([a,unknown,b], by: .size, ascending: false).map(\.name), ["b","a","folder"])
        XCTAssertEqual(BrowserModel.sorted([unknown,b,a], by: .modified, ascending: false).map(\.name), ["b","a","folder"])
        XCTAssertEqual(BrowserModel.sorted([b,a], by: .name, ascending: true).map(\.name), ["a","b"])
    }
    @MainActor func testPendingCopyMarkersReflectShelfNotTransientSelection() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(storage: root.appendingPathComponent("state"))
        let a = root.appendingPathComponent("cardA"), b = root.appendingPathComponent("cardB")
        let browser = BrowserModel(location: root)
        browser.select([a]); XCTAssertTrue(app.pendingCopyPaths.isEmpty)
        app.copySelection(browser, pasteboard: NSPasteboard.withUniqueName())
        XCTAssertEqual(app.pendingCopyPaths, [a.standardizedFileURL.path])
        browser.select([]); browser.navigate(b)
        XCTAssertEqual(app.pendingCopyPaths, [a.standardizedFileURL.path])
        XCTAssertFalse(app.pendingCopyPaths.contains(root.path))
        XCTAssertFalse(app.pendingCopyPaths.contains(a.appendingPathComponent("DCIM/a.mp4").path))
        app.appendCopiedSources([b])
        let bID = try XCTUnwrap(app.copiedBatches.last?.id)
        app.removeCopyBatch(bID); XCTAssertEqual(app.pendingCopyPaths, [a.standardizedFileURL.path])
        app.clearCopiedSelection(pasteboard: NSPasteboard.withUniqueName()); XCTAssertTrue(app.pendingCopyPaths.isEmpty)
        app.appendCopiedSources([a]); app.prepare(sources: app.copiedBatches.first(where: { $0.id == app.selectedCopyBatchID })!.sources, destination: root.appendingPathComponent("target")); await app.preparationTask?.value
        app.acceptDraft(start: false)
        for _ in 0..<200 where app.acceptingDraft { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(app.pendingCopyPaths.isEmpty)
        let saved = await app.queue!.snapshot(); XCTAssertEqual(saved.jobs.count, 1)
        try await app.queue?.closeSession()
    }
    func testRemainingTimeUsesApproximateReadableUnits() {
        XCTAssertEqual(AppTime.remaining(nil), "剩余时间估算中…")
        XCTAssertEqual(AppTime.remaining(121), "预计剩余约 3 分钟")
        XCTAssertEqual(AppTime.remaining(13), "预计剩余约 15 秒")
        XCTAssertEqual(AppTime.remaining(7199), "预计剩余约 2 小时 0 分钟")
        XCTAssertEqual(AppTime.remaining(.infinity), "剩余时间估算中…")
    }
    func testDirectorySizeCountsContentsNotDirectoryEntryAndSkipsLinks() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cardA/link"), withDestinationURL: root.appendingPathComponent("cardB"))
        XCTAssertEqual(try BrowserModel.directoryBytes(root.appendingPathComponent("cardA")), 3)
    }
    @MainActor func testNotificationContainsTaskTargetTimeAndExclusion() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var job = try await TransferActions().prepare(sources: [root.appendingPathComponent("cardA")], destination: root.appendingPathComponent("target"))
        job.state = .completed; job.endedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var message = NotificationService.message(for: job)
        XCTAssertTrue(message.title.contains("完成")); XCTAssertTrue(message.body.contains("cardA")); XCTAssertTrue(message.body.contains(job.destination.path))
        XCTAssertTrue(message.body.contains(AppTime.minute(job.endedAt!)))
        job.excludedEntries = [job.manifest.entries[0]]
        message = NotificationService.message(for: job)
        XCTAssertTrue(message.title.contains("排除")); XCTAssertTrue(message.body.contains("未复制、未校验"))
    }
}
