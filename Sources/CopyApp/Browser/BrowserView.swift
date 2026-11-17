import SwiftUI
import AppKit
import CopyCore

struct NavyActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.4))
            .background(primary && enabled ? Color(red: 0.06, green: 0.42, blue: 0.82) : Color.white.opacity(enabled ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(primary ? 0.08 : 0.10)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var app: AppModel
    @ObservedObject private var registry: WindowRegistry
    init(workspace: WorkspaceModel, app: AppModel) { self.workspace = workspace; self.app = app; registry = app.registry }
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                BrowserView(browser: workspace.left, app: app)
                if !app.copiedSources.isEmpty {
                    CopyShelfView(app: app).frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                }
            }
            Divider()
            if app.preparing && app.draft == nil {
                HStack {
                    ProgressView(app.preparationLabel).controlSize(.small)
                    Spacer()
                    Button("取消准备") { app.cancelDraft() }.keyboardShortcut(.cancelAction)
                }.padding(12)
            }
            if let job = app.draft { TransferPreview(job: job, app: app) }
            TaskQueueView(app: app)
        }
        .preferredColorScheme(.dark)
        .background(LinearGradient(colors: [Color(red: 0.035, green: 0.09, blue: 0.18), Color(red: 0.025, green: 0.035, blue: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .alert("操作未完成", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("知道了") { app.error = nil }
        } message: { Text(app.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in app.refreshClipboardSelection() }
    }
}

struct BrowserView: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var app: AppModel
    @State private var volumes: [URL] = []
    @State private var newFolder = false
    @State private var folderName = "新建文件夹"
    @State private var dropTargeted = false
    @StateObject private var dropRequests = DropRequestCoordinator()
    @State private var aiReview: AIReviewModel?
    @State private var preparingAI = false
    @StateObject private var tree = DirectoryTreeModel()
    var body: some View {
        HSplitView {
            List {
                Section("常用位置") {
                    sidebar("个人文件夹", "house", FileManager.default.homeDirectoryForCurrentUser)
                    sidebar("桌面", "desktopcomputer", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
                    sidebar("文稿", "doc", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
                    sidebar("下载", "arrow.down.circle", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                    Button { chooseLocation() } label: {
                        Label("选择其他位置…", systemImage: "folder")
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Section("设备") {
                    ForEach(volumes, id: \.self) { volume in
                        HStack {
                            sidebar(volume.path == "/" ? "系统磁盘" : volume.lastPathComponent, "externaldrive", volume)
                            if (try? volume.resourceValues(forKeys: [.volumeIsEjectableKey]).volumeIsEjectable) == true {
                                Button { app.eject(volume) } label: { Image(systemName: "eject") }.buttonStyle(.borderless).help("手动推出")
                            }
                        }
                    }
                }
                if !app.recent.isEmpty {
                    Section("最近位置") { ForEach(app.recent, id: \.self) { sidebar($0.lastPathComponent, "clock", $0) } }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).frame(minWidth: 175, idealWidth: 205, maxWidth: 235)
                .background(Color(red: 0.055, green: 0.085, blue: 0.14))
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { browser.back() } label: { Image(systemName: "chevron.left") }.help("返回")
                    Button { browser.forward() } label: { Image(systemName: "chevron.right") }.help("前进")
                    Button { browser.navigate(browser.location.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }.help("上一级")
                    BrowserPathBar(browser: browser, app: app).frame(minWidth: 100, maxWidth: .infinity)
                    if !app.copiedSources.isEmpty {
                        Text(browser.location.lastPathComponent.isEmpty ? "/" : browser.location.lastPathComponent)
                            .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 110).help(browser.location.path)
                    }
                    Picker("视图", selection: $browser.mode) {
                        Image(systemName: "square.grid.2x2").tag(BrowserMode.icons)
                        Image(systemName: "list.bullet").tag(BrowserMode.list)
                        Image(systemName: "rectangle.split.3x1").tag(BrowserMode.columns)
                    }.pickerStyle(.segmented).frame(width: 115).labelsHidden()
                    BrowserSortMenu(browser: browser)
                    Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    AIEntryButton(browser: browser, app: app, review: $aiReview, preparing: $preparingAI)
                }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 7).background(Color(red: 0.055, green: 0.085, blue: 0.14))
                HStack {
                        Button { app.copySelection(browser) } label: { Label("复制所选", systemImage: "doc.on.doc") }
                            .buttonStyle(NavyActionStyle()).disabled(browser.selected.isEmpty || app.acceptingDraft)
                            .help("追加到多卡待拷贝清单（⌘C），不替换已有来源")
                        Button { app.paste(into: browser.location) } label: { Label("粘贴到这里", systemImage: "doc.on.clipboard") }
                            .buttonStyle(NavyActionStyle(primary: true)).disabled(app.hasDraftActivity)
                            .help("检查后加入待开始队列，不立即写入（⌘V）")
                        if let batch = app.copiedBatches.first(where: { $0.id == app.selectedCopyBatchID }) {
                            Text("当前批次：\(batch.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Button { folderName = "新建文件夹"; newFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                            .buttonStyle(NavyActionStyle())
                            .keyboardShortcut("n", modifiers: [.command, .shift])
                        Spacer(minLength: 0)
                        Menu("更多") {
                            Button("选择目标拷贝…") { chooseDestination() }.disabled(browser.selected.isEmpty || app.hasDraftActivity)
                            Button("拷贝当前文件夹…") { chooseDestination(currentFolder: true) }.disabled(app.hasDraftActivity)
                            Button("全选") { browser.select(Set(browser.items.map(\.url))) }
                        }.fixedSize()
                }.controlSize(.regular).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(red: 0.045, green: 0.07, blue: 0.115))
                Divider()
                if let error = browser.error {
                    VStack(spacing: 12) {
                        ContentUnavailableView("无法读取这个位置", systemImage: "folder.badge.questionmark", description: Text(error))
                        HStack {
                            Button("重新尝试") { browser.refresh() }
                            Button("选择其他位置…") { chooseLocation() }
                        }
                    }
                } else if browser.mode == .icons {
                    IconBrowser(browser: browser, app: app, onNewFolder: { folderName = "新建文件夹"; newFolder = true }).id(browser.location)
                } else if browser.mode == .list {
                    FileListBrowser(browser: browser, app: app, onNewFolder: { folderName = "新建文件夹"; newFolder = true })
                } else { ColumnBrowser(browser: browser, app: app, onNewFolder: { folderName = "新建文件夹"; newFolder = true }) }
                Divider()
                HStack {
                    Text(browser.selected.isEmpty ? "\(browser.items.count) 项" : "已选 \(browser.selectionCount) 项 · \(browser.selectionStatisticsFailed ? "无法统计大小" : bytesLabel(browser.selectionBytes))")
                        .fontWeight(browser.selected.isEmpty ? .regular : .semibold)
                    Spacer()
                    Text("可用 \(bytesLabel(browser.freeBytes))").foregroundStyle(.secondary)
                    if browser.mode == .icons { Slider(value: $browser.iconSize, in: 32...112).frame(width: 75).help("图标大小") }
                }.font(.caption).padding(10)
            }.frame(minWidth: 300).background(Color(red: 0.035, green: 0.055, blue: 0.09))
        }
        .onAppear { reloadVolumes(); forwardRevealError(browser.revealError) }
        .onChange(of: browser.revealError) { _, error in
            forwardRevealError(error)
        }
        .sheet(item: $aiReview) { AIReviewView(model: $0, app: app) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in reloadVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in reloadVolumes(); browser.refresh() }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: 3).padding(8)
                    .overlay(alignment: .top) {
                        Text("松开后定位文件或文件夹，不会开始拷贝")
                            .font(.callout.weight(.semibold)).padding(10).background(.regularMaterial, in: Capsule()).padding(18)
                    }.allowsHitTesting(false)
            }
        }
        .onDrop(of: ["public.file-url"], isTargeted: $dropTargeted) { providers in
            browser.beginNewDrop()
            let revision = browser.interactionRevision
            dropRequests.submit(providers, isValid: { browser.interactionRevision == revision }, apply: { try browser.revealDroppedFolders($0) }, fail: { app.error = $0.localizedDescription + "\n之前的文件选择已清除，请重新选择。" })
            return true
        }
        .alert("新建文件夹", isPresented: $newFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("创建") {
                do {
                    guard !folderName.isEmpty, !folderName.contains("/"), !folderName.contains("\0"), folderName != ".", folderName != ".." else { throw CopyProblem.invalid("文件夹名称不能为空，也不能含斜杠或使用 .、..") }
                    try FileManager.default.createDirectory(at: browser.location.appendingPathComponent(folderName), withIntermediateDirectories: false)
                    browser.refresh()
                } catch { app.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
    }
    private func sidebar(_ name: String, _ icon: String, _ url: URL) -> some View {
        ForEach(tree.visibleNodes(root: url)) { node in
            DirectoryTreeRow(name: node.depth == 0 ? name : node.url.lastPathComponent,
                             icon: node.depth == 0 ? icon : "folder", url: node.url,
                             depth: node.depth, tree: tree, browser: browser, app: app)
        }
    }
    private func forwardRevealError(_ error: String?) {
        if let error { app.error = error; browser.revealError = nil }
    }
    private func chooseLocation() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try app.directoryAccess.recordSelection([url], confirmBuild: false) }
            catch { app.error = "位置已选中，但未能保存访问记录：\(error.localizedDescription)" }
            browser.navigate(url); app.remember(url)
        }
    }
    private func chooseDestination(currentFolder: Bool = false) {
        let sources = currentFolder ? [browser.location] : Array(browser.selected)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "选择目标文件夹。随后会显示路径与容量预览。"
        if panel.runModal() == .OK, let destination = panel.url { app.prepare(sources: sources, destination: destination) }
    }
    private func reloadVolumes() { volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? [] }
}

private struct AIEntryButton: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var app: AppModel
    @ObservedObject private var service: AIServiceState
    @Binding var review: AIReviewModel?
    @Binding var preparing: Bool
    init(browser: BrowserModel, app: AppModel, review: Binding<AIReviewModel?>, preparing: Binding<Bool>) {
        self.browser = browser; self.app = app; service = app.aiService; _review = review; _preparing = preparing
    }
    var body: some View {
        Menu {
            Button {
                guard let configuration = service.configuration else { return }
                let urls = Array(browser.selected); preparing = true
                Task {
                    defer { preparing = false }
                    do {
                        let result = try await Task.detached { () -> (CopyManifest, [MetadataBatch]) in
                            let manifest = try ManifestBuilder().build(urls.map { SourceSelection(root: $0) })
                            return (manifest, try MetadataBuilder().build(manifest: manifest))
                        }.value
                        review = AIReviewModel(manifest: result.0, batches: result.1, configuration: configuration)
                    } catch { app.error = error.localizedDescription }
                }
            } label: {
                Label(preparing ? "准备目录信息…" : "智能整理", systemImage: "sparkles")
            }
                .disabled(service.reason != nil || browser.selected.isEmpty || preparing)
                .help(service.reason ?? "预览目录信息后，由你决定是否发送")
            if service.failed { Button("重新检查") { service.refresh() }.help("重新开放智能入口，实际连接将在确认发送后重试") }
            SettingsLink { Label(service.configured ? "设置" : "配置 AI", systemImage: "gearshape") }.help(service.reason ?? "设置")
        } label: { Image(systemName: "sparkles") }
            .help("智能整理与 AI 设置").accessibilityLabel("智能整理与 AI 设置")
            .onReceive(NotificationCenter.default.publisher(for: .copyCardAIConfigurationChanged)) { _ in service.refresh() }
    }
}
