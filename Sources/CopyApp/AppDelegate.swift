import AppKit
import SwiftUI
import CopyCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var fixtureWindow: NSWindow?
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // An independently named QA bundle must never fall back to the real task store.
        if Bundle.main.bundleIdentifier != "local.copycard.app" {
            let environment = ProcessInfo.processInfo.environment
            guard let storage = environment["COPYCARD_UI_STORAGE"], !storage.isEmpty,
                  let location = environment["COPYCARD_UI_LOCATION"], !location.isEmpty else {
                NSLog("验收版缺少隔离任务目录或浏览目录，已拒绝启动。")
                exit(EXIT_FAILURE)
            }
        }
        #endif
        NSApp.setActivationPolicy(.regular)
        if Bundle.main.bundleIdentifier == "local.copycard.app" { AppModel.shared.notifications.install() }
        var startLocation: URL?
        #if DEBUG
        startLocation = ProcessInfo.processInfo.environment["COPYCARD_UI_LOCATION"].map { URL(fileURLWithPath: $0) }
        #endif
        AppModel.shared.openWindow(location: startLocation); AppModel.shared.installKeyboardCommands(); NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        // Explicit isolated UI fixture; this invokes the same reveal path without simulating a Finder drop.
        if Bundle.main.bundleIdentifier != "local.copycard.app",
           let path = ProcessInfo.processInfo.environment["COPYCARD_UI_REVEAL_FIXTURE"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let browser = AppModel.shared.registry.workspaces.first?.left else { return }
                do { try browser.revealDroppedFolders([URL(fileURLWithPath: path)]) }
                catch { AppModel.shared.error = error.localizedDescription }
            }
        }
        // Developer-only, opt-in visual fixture. No API request or credential access.
        if let path = ProcessInfo.processInfo.environment["COPYCARD_AI_UI_FIXTURE"],
           let manifest = try? ManifestBuilder().build([SourceSelection(root: URL(fileURLWithPath: path))]),
           let batches = try? MetadataBuilder().build(manifest: manifest) {
            let review = AIReviewModel(manifest: manifest, batches: batches)
            review.groups = [AIGroup(folder: "待人工确认", entries: manifest.entries.map(\.id), reason: "模拟分类建议：设备时间可能不准确")]
            review.status = "界面验收用模拟结果 · 不联网、不使用密钥"
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 800), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "AI 分组界面验收（模拟）"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AIReviewView(model: review, app: AppModel.shared))
            window.center(); window.makeKeyAndOrderFront(nil); fixtureWindow = window
        }
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.openWindow() }; return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let app = AppModel.shared
        guard let queue = app.queue else { return .terminateNow }
        if app.snapshot.jobs.contains(where: { $0.state == .running || $0.state == .queued }) {
            let alert = NSAlert(); alert.messageText = "还有任务正在执行"
            alert.informativeText = "暂停并保存进度后退出，下次打开可以继续。"
            alert.addButton(withTitle: "暂停任务并退出"); alert.addButton(withTitle: "继续拷贝")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task {
            do { try await queue.closeSession(); sender.reply(toApplicationShouldTerminate: true) }
            catch { app.error = error.localizedDescription; sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}
