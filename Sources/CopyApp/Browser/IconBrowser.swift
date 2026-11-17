import SwiftUI
import AppKit

@MainActor private final class MouseModifiers: ObservableObject {
    private var monitor: Any?
    private(set) var flags: NSEvent.ModifierFlags = []
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.flags = event.modifierFlags
            return event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct IconBrowser: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var app: AppModel
    var onNewFolder: () -> Void = {}
    @State private var frames: [URL: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var initialSelection: Set<URL> = []
    @State private var choosing = false
    @State private var selectionAnchor: URL?
    @State private var space = UUID()
    @StateObject private var mouseModifiers = MouseModifiers()
    private var currentFrames: [URL: CGRect] {
        let urls = Set(browser.items.map(\.url))
        return frames.filter { urls.contains($0.key) }
    }
    var body: some View {
        let pendingPaths = app.pendingCopyPaths
        GeometryReader { viewport in
        ScrollViewReader { proxy in
        ScrollView {
            ZStack(alignment: .topLeading) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: browser.iconSize + 42), spacing: 10)], spacing: 10) {
                ForEach(browser.items) { item in
                    let pending = pendingPaths.contains(item.url.standardizedFileURL.path)
                    VStack(spacing: 6) {
                        Image(nsImage: SystemFileIcon.image(for: item)).resizable().scaledToFit()
                            .frame(width: browser.iconSize, height: browser.iconSize)
                            .overlay(alignment: .topTrailing) { if pending { PendingCopyBadge().offset(x: 5, y: -3) } }
                        Text(item.name).font(.callout).lineLimit(2).multilineTextAlignment(.center).frame(height: 34)
                        if pending { Text("已加入待拷贝").font(.caption2.weight(.medium)).foregroundStyle(Color(nsColor: .systemOrange)).lineLimit(1) }
                    }.padding(7).frame(maxWidth: .infinity).id(item.url)
                        .background(browser.selected.contains(item.url) ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(pending ? Color(nsColor: .systemOrange).opacity(0.8) : .clear, lineWidth: 2).allowsHitTesting(false) }
                        .contentShape(Rectangle())
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: BrowserFrames.self, value: [item.url: geometry.frame(in: .named(space))])
                        })
                        .contextMenu {
                            if item.isDirectory {
                                Button("在新窗口打开") { app.openWindow(location: item.url) }
                                Button("粘贴到此文件夹") { app.paste(into: item.url) }.disabled(app.hasDraftActivity)
                            }
                            Button("在访达显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Button("复制") {
                                if !browser.selected.contains(item.url) { browser.select([item.url]) }
                                app.copySelection(browser)
                            }
                        }
                        .accessibilityElement(children: .combine).accessibilityLabel(item.name + (pending ? "，已加入待拷贝栏" : ""))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selectItem(item.url, flags: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags) }
                        .onTapGesture(count: 2) { if item.isDirectory { browser.navigate(item.url) } else { NSWorkspace.shared.open(item.url) } }
                        .onTapGesture {
                            selectItem(item.url, flags: mouseModifiers.flags)
                        }
                }
            }.padding(16).frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
            if browser.items.isEmpty { Text("此文件夹为空").foregroundStyle(.secondary).padding(40).allowsHitTesting(false) }
            if let rect = marquee {
                Rectangle().fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY).allowsHitTesting(false)
            }
            }.coordinateSpace(name: space).contentShape(Rectangle())
                .onPreferenceChange(BrowserFrames.self) { frames = $0 }
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    if !currentFrames.values.contains(where: { $0.contains(value.location) }) { browser.select([]) }
                })
                .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                    .onChanged { value in
                        if !choosing {
                            guard !currentFrames.values.contains(where: { $0.contains(value.startLocation) }) else { return }
                            choosing = true
                            initialSelection = NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty ? [] : browser.selected
                        }
                        let rect = BrowserInteraction.rectangle(from: value.startLocation, to: value.location)
                        marquee = rect
                        browser.previewSelection(BrowserInteraction.selection(in: rect, frames: currentFrames, keeping: initialSelection, allowed: Set(browser.items.map(\.url))))
                    }.onEnded { _ in
                        if choosing { browser.select(browser.selected) }
                        choosing = false; marquee = nil
                    })
                .contextMenu {
                    Button("新建文件夹") { onNewFolder() }
                    Button("粘贴到这里") { app.paste(into: browser.location) }.disabled(app.hasDraftActivity)
                    Button("在访达打开当前文件夹") { NSWorkspace.shared.open(browser.location) }
                    Button("在新窗口打开当前文件夹") { app.openWindow(location: browser.location) }
                }
                .onChange(of: browser.location) { _, _ in frames = [:]; marquee = nil; choosing = false; selectionAnchor = nil }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 0.035, green: 0.055, blue: 0.09))
            .onChange(of: browser.revealedURL) { _, url in if let url { proxy.scrollTo(url, anchor: .center) } }
            .onAppear { if let url = browser.revealedURL { proxy.scrollTo(url, anchor: .center) } }
        }
        }
        .onAppear { mouseModifiers.start() }
        .onDisappear { mouseModifiers.stop() }
    }
    private func selectItem(_ url: URL, flags: NSEvent.ModifierFlags) {
        browser.select(BrowserInteraction.selectionByClick(url, ordered: browser.items.map(\.url), selected: browser.selected, anchor: selectionAnchor, command: flags.contains(.command), shift: flags.contains(.shift)))
        if !flags.contains(.shift) { selectionAnchor = url }
    }
}
