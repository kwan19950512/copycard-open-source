import Foundation
import Combine
import CopyCore

enum BrowserMode: String, CaseIterable { case icons, list, columns }
enum BrowserSortKey: String, CaseIterable {
    case name, added, modified, size, kind
    var label: String { switch self { case .name: return "名称"; case .added: return "添加日期"; case .modified: return "修改日期"; case .size: return "大小"; case .kind: return "类型" } }
}
struct BrowserItem: Identifiable, Hashable {
    var url: URL
    var isDirectory: Bool
    var size: Int64
    var modified: Date? = nil
    var added: Date? = nil
    var kind: String = ""
    var folderBytes: Int64? = nil
    var sizeFailed = false
    var measuredBytes: Int64? { isDirectory ? folderBytes : size }
    var sortSize: Int64 { measuredBytes ?? .max }
    var sortModified: Date { modified ?? .distantPast }
    var sortAdded: Date { added ?? .distantPast }
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var symbolName: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "mxf", "braw", "r3d", "avi": return "film"
        case "jpg", "jpeg", "png", "heic", "arw", "cr3", "dng": return "photo"
        case "wav", "mp3", "aac": return "waveform"
        default: return "doc"
        }
    }
}
@MainActor final class BrowserModel: ObservableObject {
    @Published var location: URL
    @Published var selected: Set<URL> = []
    @Published var items: [BrowserItem] = []
    @Published var mode: BrowserMode = .icons { didSet { measureFolderSizesIfNeeded() } }
    @Published var sortKey: BrowserSortKey = .name { didSet { resort(); measureFolderSizesIfNeeded() } }
    @Published var ascending = true { didSet { resort() } }
    @Published var iconSize: Double = 64
    @Published var selectionBytes: Int64?
    @Published var selectionStatisticsFailed = false
    @Published var selectionCount: Int = 0
    @Published var freeBytes: Int64?
    @Published var error: String?
    @Published var revealError: String?
    @Published var columnPaths: [URL]
    private var statisticsToken = UUID()
    private var navigationToken = UUID()
    private(set) var interactionRevision = UUID()
    private var folderSizeTask: Task<Void, Never>?
    private var revealAfterRefresh: [URL]?
    @Published var revealedURL: URL?
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private let directoryReader: @Sendable (URL) throws -> [BrowserItem]
    init(location: URL, directoryReader: @escaping @Sendable (URL) throws -> [BrowserItem] = { try BrowserModel.readDirectory($0) }) {
        self.location = location; columnPaths = [location]; self.directoryReader = directoryReader
    }
    func navigate(_ url: URL) {
        backStack.append(location); forwardStack.removeAll()
        setLocation(url, resetColumns: true)
    }
    private func setLocation(_ url: URL, resetColumns: Bool) {
        interactionRevision = UUID()
        folderSizeTask?.cancel(); revealAfterRefresh = nil; revealedURL = nil
        location = url; items = []; selected = []; selectionBytes = 0; selectionCount = 0; selectionStatisticsFailed = false
        statisticsToken = UUID()
        if resetColumns { columnPaths = [url] }
        refresh()
    }
    func back() {
        guard let url = backStack.popLast() else { return }
        forwardStack.append(location); setLocation(url, resetColumns: true)
    }
    func forward() {
        guard let url = forwardStack.popLast() else { return }
        backStack.append(location); setLocation(url, resetColumns: true)
    }
    func openColumnFolder(_ url: URL, index: Int) {
        if url.standardizedFileURL != location.standardizedFileURL { backStack.append(location); forwardStack.removeAll() }
        columnPaths = Array(columnPaths.prefix(index + 1)) + [url]
        setLocation(url, resetColumns: false)
    }
    func columnSelectionChanged(_ urls: Set<URL>, column: URL, index: Int, items: [BrowserItem]) {
        // A view reflecting the model's selection is not a new user action.
        guard urls != selected else { return }
        if urls.isEmpty && !selected.isEmpty && !selected.contains(where: { Self.isDirectChild($0, of: column) }) { return }
        select(urls)
        if urls.count == 1, let item = urls.first, items.first(where: { $0.url == item })?.isDirectory == true {
            openColumnFolder(item, index: index)
            select(urls)
        }
    }
    nonisolated static func isDirectChild(_ item: URL, of directory: URL) -> Bool {
        let parent = item.deletingLastPathComponent().standardizedFileURL
        let directory = directory.standardizedFileURL
        return parent == directory || parent.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath()
    }
    func refresh() {
        let url = location; let token = UUID(); navigationToken = token; error = nil
        Task {
            do {
                let reader = directoryReader
                let result = try await Task.detached { try reader(url) }.value
                guard navigationToken == token else { return }
                items = result
                resort(); measureFolderSizesIfNeeded()
                if let reveals = revealAfterRefresh {
                    revealAfterRefresh = nil
                    var visibleByPath: [URL: URL] = [:]
                    for item in items {
                        let key = item.url.resolvingSymlinksInPath().standardizedFileURL
                        if visibleByPath[key] == nil { visibleByPath[key] = item.url }
                    }
                    let matches = reveals.compactMap { visibleByPath[$0.resolvingSymlinksInPath().standardizedFileURL] }
                    if matches.count == reveals.count {
                        select(Set(matches), userInitiated: false); revealedURL = matches.first
                    } else {
                        revealError = "已打开所在文件夹，但未能选中全部拖入项目；部分项目可能隐藏或已不存在。未选中任何项目，请在访达检查。"
                    }
                }
                let volume = try await Task.detached { try VolumeInspector().inspect(url) }.value
                guard navigationToken == token else { return }; freeBytes = volume.immediateFree
            } catch {
                guard navigationToken == token else { return }
                self.error = error.localizedDescription; items = []; freeBytes = nil
            }
        }
    }
    nonisolated static func readDirectory(_ url: URL) throws -> [BrowserItem] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey, .localizedTypeDescriptionKey], options: .skipsHiddenFiles).map {
            let value = try $0.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey, .localizedTypeDescriptionKey])
            return BrowserItem(url: $0, isDirectory: value.isDirectory ?? false, size: Int64(value.fileSize ?? 0), modified: value.contentModificationDate, added: value.addedToDirectoryDate, kind: value.localizedTypeDescription ?? $0.pathExtension)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    func revealDroppedFolders(_ urls: [URL], isVolumeRoot: (URL) -> Bool = { url in
        guard let root = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return root.standardizedFileURL.path == url.standardizedFileURL.path
    }) throws {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else {
            throw CopyProblem.invalid("无法识别拖入项目；未创建拷贝任务。")
        }
        let originals = urls.map(\.standardizedFileURL)
        guard try originals.allSatisfy({ url in
            guard url.path != "/" else { return false }
            return [.file, .directory].contains(try FileFingerprint.read(url).0)
        }) else {
            throw CopyProblem.invalid("存在无法定位的项目；未定位任何项目，也未创建拷贝任务。")
        }
        let unique = Array(Set(originals.map { $0.resolvingSymlinksInPath().standardizedFileURL }))
        if unique.count == 1, let folder = originals.first, isVolumeRoot(folder) {
            navigate(folder)
            return
        }
        guard !originals.contains(where: isVolumeRoot), let parent = unique.first?.deletingLastPathComponent(), unique.allSatisfy({ $0.deletingLastPathComponent() == parent }) else {
            throw CopyProblem.invalid("拖入项目不在同一个文件夹，或包含磁盘根目录；请分别拖入，未创建拷贝任务。")
        }
        navigate(parent)
        revealAfterRefresh = unique.sorted { $0.path < $1.path }
    }
    func cancelPendingReveal() { revealAfterRefresh = nil }
    func beginNewDrop() {
        cancelPendingReveal()
        revealedURL = nil
        select([])
    }
    func resort() { items = Self.sorted(items, by: sortKey, ascending: ascending) }
    nonisolated static func sorted(_ values: [BrowserItem], by key: BrowserSortKey, ascending: Bool) -> [BrowserItem] {
        values.sorted { a, b in
            var order: ComparisonResult
            switch key {
            case .name: order = a.name.localizedStandardCompare(b.name)
            case .kind: order = a.kind.localizedStandardCompare(b.kind)
            case .size:
                if (a.measuredBytes == nil) != (b.measuredBytes == nil) { return a.measuredBytes != nil }
                order = compare(a.measuredBytes, b.measuredBytes)
            case .added:
                if (a.added == nil) != (b.added == nil) { return a.added != nil }
                order = compare(a.added, b.added)
            case .modified:
                if (a.modified == nil) != (b.modified == nil) { return a.modified != nil }
                order = compare(a.modified, b.modified)
            }
            if order == .orderedSame { order = a.name.localizedStandardCompare(b.name) }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
    nonisolated private static func compare<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        guard let a, let b else { return .orderedSame }
        return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
    private func measureFolderSizesIfNeeded() {
        guard mode == .list || sortKey == .size else { return }
        folderSizeTask?.cancel()
        let token = navigationToken
        let folders = items.filter { $0.isDirectory && $0.folderBytes == nil && !$0.sizeFailed }.map(\.url)
        folderSizeTask = Task {
            for url in folders {
                guard !Task.isCancelled, navigationToken == token else { return }
                let worker = Task.detached { try Self.directoryBytes(url) }
                let bytes = await withTaskCancellationHandler(operation: { try? await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, navigationToken == token else { return }
                if let index = items.firstIndex(where: { $0.url == url }) { items[index].folderBytes = bytes; items[index].sizeFailed = bytes == nil }
                resort()
            }
        }
    }
    nonisolated static func directoryBytes(_ root: URL) throws -> Int64 {
        guard try FileFingerprint.read(root).0 == .directory else { throw CopyProblem.invalid("无法统计链接目录") }
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in failure = error; return false }) else { throw CopyProblem.invalid("无法统计目录") }
        var total: Int64 = 0
        for case let url as URL in iterator {
            try Task.checkCancellation()
            let (kind, info) = try FileFingerprint.read(url)
            if kind == .unsupported { iterator.skipDescendants(); continue }
            if kind == .file {
                let (sum, overflow) = total.addingReportingOverflow(info.size)
                guard !overflow else { throw CopyProblem.invalid("目录大小超出可计算范围") }; total = sum
            }
        }
        if let failure { throw failure }; return total
    }
    @discardableResult func select(_ urls: Set<URL>, userInitiated: Bool = true) -> UUID {
        if userInitiated { interactionRevision = UUID(); cancelPendingReveal(); revealedURL = nil }
        selected = urls; selectionBytes = urls.isEmpty ? 0 : nil; selectionCount = urls.count; selectionStatisticsFailed = false
        let token = UUID(); statisticsToken = token
        if !urls.isEmpty {
            Task {
                do {
                    let result = try await Task.detached {
                        try ManifestBuilder().build(urls.map { SourceSelection(root: $0) })
                    }.value
                    applyStatistics(token: token, count: urls.count, bytes: result.totalBytes)
                } catch { if statisticsToken == token { self.selectionBytes = nil; self.selectionStatisticsFailed = true } }
            }
        }
        return token
    }
    func previewSelection(_ urls: Set<URL>) {
        interactionRevision = UUID(); cancelPendingReveal(); revealedURL = nil
        guard urls != selected else { return }
        statisticsToken = UUID()
        selected = urls; selectionCount = urls.count; selectionBytes = urls.isEmpty ? 0 : nil; selectionStatisticsFailed = false
    }
    func applyStatistics(token: UUID, count: Int, bytes: Int64) {
        guard token == statisticsToken else { return }; selectionCount = count; selectionBytes = bytes
    }
}
