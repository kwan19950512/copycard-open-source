import Foundation
import Combine

struct DirectoryAccessRecord: Codable, Identifiable {
    var path: String
    var bookmark: Data
    var scoped: Bool
    var id: String { path }
}

@MainActor final class DirectoryAccess: ObservableObject {
    @Published private(set) var records: [DirectoryAccessRecord] = []
    @Published private(set) var restorationMessage: String?
    private let defaults: UserDefaults
    let buildID: String
    private var activeScopes: [URL] = []
    private let recordsKey = "directoryAccessRecords"
    init(defaults: UserDefaults = .standard, buildID: String = Bundle.main.object(forInfoDictionaryKey: "CopyCardBuildID") as? String ?? "development") {
        self.defaults = defaults; self.buildID = buildID
        if let data = defaults.data(forKey: recordsKey) {
            do { records = try JSONDecoder().decode([DirectoryAccessRecord].self, from: data) }
            catch { restorationMessage = "位置记录无法读取，请重新选择；原记录未覆盖。" }
        }
        for record in records {
            do {
                var stale = false
                let options: URL.BookmarkResolutionOptions = record.scoped ? [.withSecurityScope, .withoutUI, .withoutMounting] : [.withoutUI, .withoutMounting]
                let url = try URL(resolvingBookmarkData: record.bookmark, options: options, bookmarkDataIsStale: &stale)
                if record.scoped && url.startAccessingSecurityScopedResource() { activeScopes.append(url) }
                if stale { restorationMessage = "部分位置已移动或授权记录过期，可在这里重新选择。" }
            } catch { restorationMessage = "部分位置暂时不可用，请连接磁盘或重新选择。" }
        }
    }
    var needsPrompt: Bool { defaults.string(forKey: "directoryAccessPromptBuild") != buildID }
    var confirmedForBuild: Bool { defaults.string(forKey: "directoryAccessConfirmedBuild") == buildID }
    func notePromptShown() { defaults.set(buildID, forKey: "directoryAccessPromptBuild") }
    var locations: [URL] { records.map { URL(fileURLWithPath: $0.path, isDirectory: true) } }
    nonisolated static func contains(_ parent: URL, _ child: URL) -> Bool {
        let a = parent.standardizedFileURL.pathComponents, b = child.standardizedFileURL.pathComponents
        return b.count >= a.count && Array(b.prefix(a.count)) == a
    }
    nonisolated static func roots(_ urls: [URL]) -> [URL] {
        let sorted = urls.map(\.standardizedFileURL).sorted { $0.pathComponents.count < $1.pathComponents.count }
        return sorted.reduce(into: []) { result, url in if !result.contains(where: { contains($0, url) }) { result.append(url) } }
    }
    func recordSelection(_ urls: [URL], confirmBuild: Bool = true) throws {
        guard !urls.isEmpty else { return }
        // Only called after the human chooses folders in NSOpenPanel.
        var prepared: [DirectoryAccessRecord] = []
        for url in Self.roots(urls) {
            let data: Data; let scoped: Bool
            do { data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil); scoped = true }
            catch { data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil); scoped = false }
            prepared.append(DirectoryAccessRecord(path: url.path, bookmark: data, scoped: scoped))
        }
        let merged = Self.roots(locations + urls)
        let new = merged.compactMap { url in prepared.first { $0.path == url.path } ?? records.first { $0.path == url.path } }
        let encoded = try JSONEncoder().encode(new)
        defaults.set(encoded, forKey: recordsKey); records = new
        if confirmBuild { defaults.set(buildID, forKey: "directoryAccessConfirmedBuild"); notePromptShown() }
        for url in urls where url.startAccessingSecurityScopedResource() { activeScopes.append(url) }
        restorationMessage = nil
    }
}
