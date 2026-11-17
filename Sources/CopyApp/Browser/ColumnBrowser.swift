import SwiftUI
import AppKit

struct ColumnBrowser: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var app: AppModel
    var onNewFolder: () -> Void = {}
    var body: some View {
        GeometryReader { viewport in
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(browser.columnPaths.enumerated()), id: \.element) { index, url in
                    DirectoryColumn(url: url, index: index, browser: browser, app: app).frame(width: 230)
                    Divider()
                }
            }.frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                .background(Color(red: 0.035, green: 0.055, blue: 0.09).contentShape(Rectangle())
                    .onTapGesture { browser.select([]) }
                    .contextMenu {
                        Button("新建文件夹") { onNewFolder() }
                        Button("粘贴到这里") { app.paste(into: browser.location) }.disabled(app.hasDraftActivity)
                        Button("在访达打开当前文件夹") { NSWorkspace.shared.open(browser.location) }
                        Button("在新窗口打开当前文件夹") { app.openWindow(location: browser.location) }
                    })
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
private struct DirectoryColumn: View {
    let url: URL
    let index: Int
    @ObservedObject var browser: BrowserModel
    @ObservedObject var app: AppModel
    @State private var items: [BrowserItem] = []
    @State private var selection: Set<URL> = []
    @State private var frames: [URL: CGRect] = [:]
    @State private var space = UUID()
    private var sortedItems: [BrowserItem] {
        BrowserModel.sorted(url == browser.location ? browser.items : items, by: browser.sortKey, ascending: browser.ascending)
    }
    var body: some View {
        let pendingPaths = app.pendingCopyPaths
        ScrollViewReader { proxy in
        List(sortedItems, selection: $selection) { item in
            HStack {
                Image(nsImage: SystemFileIcon.image(for: item)).resizable().scaledToFit().frame(width: 20, height: 20)
                Text(item.name).lineLimit(1)
                if pendingPaths.contains(item.url.standardizedFileURL.path) { PendingCopyBadge() }
                Spacer(minLength: 0)
                if item.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }.tag(item.url)
                .onTapGesture(count: 2) { if item.isDirectory { browser.openColumnFolder(item.url, index: index) } else { NSWorkspace.shared.open(item.url) } }
                .background(GeometryReader { geometry in Color.clear.preference(key: BrowserFrames.self, value: [item.url: geometry.frame(in: .named(space))]) })
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
        }.listStyle(.plain).scrollContentBackground(.hidden)
        .background(Color(red: 0.045, green: 0.065, blue: 0.105))
        .coordinateSpace(name: space)
        .onPreferenceChange(BrowserFrames.self) { frames = $0 }
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            if !frames.values.contains(where: { $0.contains(value.location) }) { selection = []; browser.select([]) }
        })
        .contextMenu {
            Button("粘贴到这里") { app.paste(into: url) }.disabled(app.hasDraftActivity)
            Button("在访达打开当前文件夹") { NSWorkspace.shared.open(url) }
            Button("在新窗口打开当前文件夹") { app.openWindow(location: url) }
        }
        .onAppear { selection = Set(browser.selected.filter { BrowserModel.isDirectChild($0, of: url) }) }
        .onChange(of: browser.selected) { _, selected in
            let visible = Set(selected.filter { BrowserModel.isDirectChild($0, of: url) })
            if selection != visible { selection = visible }
        }
        .onChange(of: browser.revealedURL) { _, revealed in
            if let revealed, url == browser.location { proxy.scrollTo(revealed, anchor: .center) }
        }
        .task(id: url) { items = (try? await Task.detached { try BrowserModel.readDirectory(url) }.value) ?? [] }
        .onChange(of: selection) { _, urls in
            browser.columnSelectionChanged(urls, column: url, index: index, items: sortedItems)
        }
        }
    }
}
