import SwiftUI
import CopyCore

@MainActor final class DirectoryTreeModel: ObservableObject {
    struct Node: Identifiable {
        let url: URL
        let depth: Int
        var id: URL { url }
    }
    @Published var expanded: Set<URL> = []
    @Published var children: [URL: [URL]] = [:]
    @Published var errors: [URL: String] = [:]
    @Published var loading: Set<URL> = []
    func visibleNodes(root: URL) -> [Node] {
        var result: [Node] = []
        func append(_ url: URL, depth: Int) {
            result.append(Node(url: url, depth: depth))
            if expanded.contains(url) {
                for child in children[url] ?? [] { append(child, depth: depth + 1) }
            }
        }
        append(root, depth: 0)
        return result
    }
    func toggle(_ url: URL) {
        if expanded.contains(url) { expanded.remove(url); return }
        expanded.insert(url)
        guard !loading.contains(url) else { return }
        loading.insert(url); errors[url] = nil
        Task {
            do {
                let result = try await Task.detached { try Self.readChildren(url) }.value
                children[url] = result
            } catch { children[url] = []; errors[url] = error.localizedDescription }
            loading.remove(url)
        }
    }
    nonisolated static func readChildren(_ url: URL) throws -> [URL] {
        // Never follow shortcut links or traverse descendants until explicitly expanded.
        guard try FileFingerprint.read(url).0 == .directory else { throw CopyProblem.invalid("不是可展开的普通目录") }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { (try? FileFingerprint.read($0).0) == .directory }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

struct DirectoryTreeRow: View {
    let name: String
    let icon: String
    let url: URL
    var depth = 0
    @ObservedObject var tree: DirectoryTreeModel
    @ObservedObject var browser: BrowserModel
    let app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Button { tree.toggle(url) } label: {
                    Image(systemName: tree.expanded.contains(url) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).help("展开 / 收起目录，不切换当前文件夹")
                Button { browser.navigate(url); app.remember(url) } label: {
                    Label(name, systemImage: icon).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(.leading, CGFloat(depth) * 13)
                .background(browser.location.standardizedFileURL == url.standardizedFileURL ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contextMenu {
                    Button("粘贴到此文件夹") { app.paste(into: url) }.disabled(app.hasDraftActivity)
                    Button("在访达打开") { NSWorkspace.shared.open(url) }
                    Button("在新窗口打开") { app.openWindow(location: url) }
                }
            if tree.expanded.contains(url) {
                if tree.loading.contains(url) { ProgressView().controlSize(.mini).padding(.leading, CGFloat(depth + 1) * 13 + 20) }
                if let error = tree.errors[url] { Text(error).font(.caption2).foregroundStyle(.secondary).padding(.leading, 20).help(error) }
            }
        }
    }
}
