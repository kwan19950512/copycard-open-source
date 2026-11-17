import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum BrowserInteraction {
    static func selectionByClick(_ url: URL, ordered: [URL], selected: Set<URL>, anchor: URL?, command: Bool, shift: Bool) -> Set<URL> {
        if shift, let anchor, let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: url) {
            let range = Set(ordered[min(a, b)...max(a, b)])
            return command ? selected.union(range) : range
        }
        if command {
            var result = selected
            if result.contains(url) { result.remove(url) } else { result.insert(url) }
            return result
        }
        return [url]
    }
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    static func selection(in rect: CGRect, frames: [URL: CGRect], keeping initial: Set<URL> = [], allowed: Set<URL>? = nil) -> Set<URL> {
        let result = initial.union(frames.filter { $0.value.intersects(rect) }.map(\.key))
        return allowed.map { result.intersection($0) } ?? result
    }
    static func ancestors(of location: URL) -> [URL] {
        var url = location.standardizedFileURL
        var result = [url]
        while url.path != "/" {
            url = url.deletingLastPathComponent(); result.append(url)
        }
        return result.reversed()
    }
}

struct BrowserFrames: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor enum SystemFileIcon {
    private static var cache: [String: NSImage] = [:]
    static func image(for item: BrowserItem) -> NSImage {
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: item.url.pathExtension) ?? .data)
        if let icon = cache[type.identifier] { return icon }
        // Resolve by type, not by file path: never read media or remote-volume attributes for icons.
        let icon = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = icon
        return icon
    }
}

struct BrowserPathBar: View {
    @ObservedObject var browser: BrowserModel
    let app: AppModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(BrowserInteraction.ancestors(of: browser.location), id: \.self) { url in
                        if url.path != "/" { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button { browser.navigate(url) } label: {
                            Label(url.path == "/" ? "系统磁盘" : url.lastPathComponent,
                                  systemImage: url.path == "/" ? "internaldrive" : "folder")
                                .lineLimit(1).fixedSize()
                        }.buttonStyle(.plain).help(url.path).id(url)
                            .contextMenu {
                                Button("在访达打开") { NSWorkspace.shared.open(url) }
                                Button("在新窗口打开") { app.openWindow(location: url) }
                            }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 7)
            }.onChange(of: browser.location) { _, url in proxy.scrollTo(url, anchor: .trailing) }
                .onChange(of: app.copiedBatches.count) { _, _ in proxy.scrollTo(browser.location, anchor: .trailing) }
                .onAppear { proxy.scrollTo(browser.location, anchor: .trailing) }
        }.font(.caption).frame(height: 34)
    }
}
