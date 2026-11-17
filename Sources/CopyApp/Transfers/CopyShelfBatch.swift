import Foundation
import CopyCore

struct CopyShelfBatch: Identifiable {
    let id = UUID()
    var sources: [URL]
    var bytes: Int64?
    var statisticsFailed = false
    var preview: [TransferJob] = []
    var origin: URL { sources[0].deletingLastPathComponent() }
    var title: String {
        if sources.count == 1 { return sources[0].lastPathComponent }
        let parts = origin.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return parts[2] + (parts.count > 3 ? " · " + origin.lastPathComponent : "") }
        return origin.lastPathComponent
    }
}
