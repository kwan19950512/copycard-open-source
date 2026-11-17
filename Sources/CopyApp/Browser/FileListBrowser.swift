import SwiftUI
import AppKit

struct BrowserSortMenu: View {
    @ObservedObject var browser: BrowserModel
    var body: some View {
        Menu {
            Picker("排序方式", selection: $browser.sortKey) { ForEach(BrowserSortKey.allCases, id: \.self) { Text($0.label).tag($0) } }
            Divider()
            Picker("顺序", selection: $browser.ascending) { Text("升序").tag(true); Text("降序").tag(false) }
        } label: { Label("排序", systemImage: "arrow.up.arrow.down") }.fixedSize()
    }
}

struct FileListBrowser: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var app: AppModel
    var onNewFolder: () -> Void = {}
    @State private var sortOrder = [KeyPathComparator(\BrowserItem.name)]
    var body: some View {
        let pendingPaths = app.pendingCopyPaths
        ScrollViewReader { proxy in
            Table(browser.items, selection: Binding(get: { browser.selected }, set: { browser.select($0) }), sortOrder: $sortOrder) {
                TableColumn("名称", value: \.name) { item in
                    HStack(spacing: 8) {
                        Image(nsImage: SystemFileIcon.image(for: item)).resizable().scaledToFit().frame(width: 22, height: 22)
                        Text(item.name).lineLimit(1)
                        if pendingPaths.contains(item.url.standardizedFileURL.path) { PendingCopyBadge() }
                    }
                }.width(min: 140, ideal: 200)
                TableColumn("大小", value: \.sortSize) { item in Text(item.sizeFailed ? "无法统计" : bytesLabel(item.measuredBytes)).foregroundStyle(.secondary) }.width(min: 70, ideal: 80)
                TableColumn("类型", value: \.kind) { item in Text(item.kind).lineLimit(1).foregroundStyle(.secondary) }.width(min: 60, ideal: 80)
                TableColumn("修改日期", value: \.sortModified) { item in Text(item.modified.map(AppTime.minute) ?? "—").foregroundStyle(.secondary) }.width(min: 110, ideal: 125)
                TableColumn("添加日期", value: \.sortAdded) { item in Text(item.added.map(AppTime.minute) ?? "—").foregroundStyle(.secondary) }.width(min: 110, ideal: 125)
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.035, green: 0.055, blue: 0.09))
            .contextMenu(forSelectionType: URL.self) { urls in
                if urls.isEmpty {
                    Button("新建文件夹") { onNewFolder() }
                    Button("粘贴到这里") { app.paste(into: browser.location) }.disabled(app.hasDraftActivity)
                    Button("在访达打开当前文件夹") { NSWorkspace.shared.open(browser.location) }
                }
                else {
                    if urls.count == 1, let url = urls.first, browser.items.first(where: { $0.url == url })?.isDirectory == true {
                        Button("在新窗口打开") { app.openWindow(location: url) }
                        Button("粘贴到此文件夹") { app.paste(into: url) }.disabled(app.hasDraftActivity)
                    }
                    if urls.count == 1, let url = urls.first { Button("在访达显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                    Button("复制所选") { browser.select(urls); app.copySelection(browser) }
                }
            } primaryAction: { urls in
                guard urls.count == 1, let url = urls.first else { return }
                if browser.items.first(where: { $0.url == url })?.isDirectory == true { browser.navigate(url) }
                else { NSWorkspace.shared.open(url) }
            }
            .onChange(of: sortOrder) { _, value in
                guard let first = value.first else { return }
                let key: BrowserSortKey = first.keyPath == \BrowserItem.sortSize ? .size : (first.keyPath == \BrowserItem.sortModified ? .modified : (first.keyPath == \BrowserItem.sortAdded ? .added : (first.keyPath == \BrowserItem.kind ? .kind : .name)))
                if browser.sortKey != key { browser.sortKey = key }
                if browser.ascending != (first.order == .forward) { browser.ascending = first.order == .forward }
            }
            .onChange(of: browser.sortKey) { _, _ in syncSort() }
            .onChange(of: browser.ascending) { _, _ in syncSort() }
            .onChange(of: browser.revealedURL) { _, url in if let url { proxy.scrollTo(url, anchor: .center) } }
            .onAppear { syncSort(); if let url = browser.revealedURL { proxy.scrollTo(url, anchor: .center) } }
        }
    }
    private func syncSort() {
        let order: SortOrder = browser.ascending ? .forward : .reverse
        switch browser.sortKey {
        case .name: sortOrder = [KeyPathComparator(\BrowserItem.name, order: order)]
        case .size: sortOrder = [KeyPathComparator(\BrowserItem.sortSize, order: order)]
        case .kind: sortOrder = [KeyPathComparator(\BrowserItem.kind, order: order)]
        case .added: sortOrder = [KeyPathComparator(\BrowserItem.sortAdded, order: order)]
        case .modified: sortOrder = [KeyPathComparator(\BrowserItem.sortModified, order: order)]
        }
    }
}
