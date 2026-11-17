import SwiftUI
import AppKit
import CopyCore

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    let registry = WindowRegistry()
    let directoryAccess = DirectoryAccess()
    @Published var showDirectoryAccess = false
    @Published var directoryAccessWorkspaceID: UUID?
    let aiService = AIServiceState()
    let queue: TransferQueue?
    @Published var snapshot = QueueSnapshot(jobs: [], progress: [:], persistenceError: nil)
    @Published var error: String?
    @Published var recent: [URL] = []
    @Published var draft: TransferJob?
    @Published var additionalDrafts: [TransferJob] = []
    var draftJobs: [TransferJob] { draft.map { [$0] + additionalDrafts } ?? [] }
    @Published var draftChecks: [URL: PreflightResult] = [:]
    @Published var draftPreflight: PreflightResult?
    @Published var preparing = false
    @Published var preparationLabel = "正在准备拷贝预览，尚未写入文件…"
    @Published var acceptingDraft = false
    @Published var copiedBatches: [CopyShelfBatch] = []
    @Published var selectedCopyBatchID: UUID?
    var draftCopyBatchID: UUID?
    var copiedSources: [URL] { copiedBatches.flatMap(\.sources) }
    var pendingCopyPaths: Set<String> { Set(copiedSources.map { $0.standardizedFileURL.path }) }
    @Published var copiedBytes: Int64? = 0
    @Published var copiedStatisticsFailed = false
    @Published var shelfExpanded = false
    var shelfStatisticsID = UUID()
    var preflightID = UUID()
    var copiedPasteboardChange = -1
    var preparationTask: Task<Void, Never>?
    var hasDraftActivity: Bool { preparing || draft != nil || acceptingDraft }
    @Published var queueExpanded = false
    var preparationID = UUID()
    let power = PowerGuard()
    let notifications = NotificationService()
    var eventMonitor: Any?
    var sessionsStarted = Set<UUID>()
    private var controllers: [UUID: BrowserWindowController] = [:]
    private let dockProgress = CopyDockView()
    init(storage: URL? = nil) {
        var directory = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CopyCard")
        #if DEBUG
        if storage == nil, let fixture = ProcessInfo.processInfo.environment["COPYCARD_UI_STORAGE"] { directory = URL(fileURLWithPath: fixture) }
        #endif
        do { queue = try TransferQueue(store: JobStore(directory: directory)) }
        catch { queue = nil; self.error = "无法加载任务记录，原记录已保留：\(error.localizedDescription)" }
        recent = (UserDefaults.standard.stringArray(forKey: "recentLocations") ?? []).map { URL(fileURLWithPath: $0) }
        if let queue {
            Task {
                await queue.configureConcurrency(limit: max(1, UserDefaults.standard.integer(forKey: "concurrencyLimit") == 0 ? 2 : UserDefaults.standard.integer(forKey: "concurrencyLimit")), allowSharedDevice: UserDefaults.standard.bool(forKey: "allowSharedDevice"))
                for await value in await queue.updates() {
                    let stopped = snapshot.jobs.contains { old in
                        old.state == .running && value.jobs.first(where: { $0.id == old.id })?.state != .running
                    }
                    snapshot = value; power.update(activeCount: value.jobs.filter { $0.state == .running }.count)
                    if Bundle.main.bundleIdentifier?.hasPrefix("local.copycard.app") == true {
                        let overview = QueueOverview(value)
                        NSApp.dockTile.badgeLabel = overview.activeCount > 0 ? String(overview.activeCount) : nil
                        dockProgress.fraction = overview.fraction
                        dockProgress.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
                        dockProgress.needsDisplay = true
                        NSApp.dockTile.contentView = overview.activeCount > 0 ? dockProgress : nil
                        NSApp.dockTile.display()
                    }
                    if stopped {
                        for workspace in registry.workspaces { workspace.left.refresh(); workspace.right?.refresh() }
                    }
                    if Bundle.main.bundleIdentifier == "local.copycard.app" { notifications.update(value.jobs.filter { sessionsStarted.contains($0.id) }) }
                }
            }
        }
    }
    func installKeyboardCommands() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard let self, modifiers == [.command],
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  let pair = self.controllers.first(where: { $0.value.window == NSApp.keyWindow }),
                  let workspace = self.registry.workspaces.first(where: { $0.id == pair.key }) else { return event }
            let browser = workspace.activeBrowser
            if event.keyCode == 126 { browser.navigate(browser.location.deletingLastPathComponent()); return nil }
            if event.keyCode == 125, browser.selected.count == 1, let url = browser.selected.first,
               let item = browser.items.first(where: { $0.url == url }) {
                if item.isDirectory { browser.navigate(url) } else { NSWorkspace.shared.open(url) }
                return nil
            }
            switch event.charactersIgnoringModifiers {
            case "c": self.copySelection(browser); return nil
            case "v": self.paste(into: browser.location); return nil
            case "a": browser.select(Set(browser.items.map(\.url))); return nil
            case "1": browser.mode = .icons; return nil
            case "2": browser.mode = .list; return nil
            case "3": browser.mode = .columns; return nil
            case "[": browser.back(); return nil
            case "]": browser.forward(); return nil
            default: return event
            }
        }
    }
    func openWindow(location: URL? = nil) {
        show(registry.create(location: location ?? FileManager.default.homeDirectoryForCurrentUser))
    }
    func presentDirectoryAccess(in workspaceID: UUID? = nil) {
        directoryAccessWorkspaceID = workspaceID ?? controllers.first(where: { $0.value.window == NSApp.keyWindow })?.key ?? registry.workspaces.first?.id
        showDirectoryAccess = directoryAccessWorkspaceID != nil
    }
    private func show(_ workspace: WorkspaceModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "拷卡"; window.minSize = NSSize(width: 680, height: 450)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(workspace: workspace, app: self))
        let controller = BrowserWindowController(window: window)
        controller.onClose = { [weak self] in
            self?.registry.workspaces.removeAll { $0.id == workspace.id }; self?.controllers[workspace.id] = nil
        }
        window.delegate = controller; controllers[workspace.id] = controller
        window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
        workspace.left.refresh(); workspace.right?.refresh()
    }
    func merge(_ workspace: WorkspaceModel, other: WorkspaceModel) {
        guard workspace.right == nil, other.right == nil else { return }
        registry.merge(workspace, other); controllers[other.id]?.window?.close()
    }
    func split(_ workspace: WorkspaceModel) {
        if let other = registry.split(workspace) { show(other) }
    }
    func remember(_ url: URL) {
        recent.removeAll { $0 == url }; recent.insert(url, at: 0); recent = Array(recent.prefix(10))
        UserDefaults.standard.set(recent.map(\.path), forKey: "recentLocations")
    }
}

@MainActor private final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}

func bytesLabel(_ value: Int64?) -> String {
    guard let value else { return "正在统计…" }
    if value == 0 { return "0 字节" }
    return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
