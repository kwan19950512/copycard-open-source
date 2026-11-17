import SwiftUI
import CopyCore

/// The two ends stay visible without expanding task details.
struct TransferRouteView: View {
    let job: TransferJob
    var showPaths = true
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            endpoint("来源", icon: "folder.fill", title: sourceTitle,
                     path: job.manifest.selections.map { $0.root.path }.joined(separator: "\n"), color: .blue)
            Image(systemName: "arrow.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityLabel("拷贝到")
            endpoint("目标", icon: "folder.badge.plus", title: job.destination.lastPathComponent,
                     path: job.destination.path, color: .teal)
        }
    }
    private var sourceTitle: String {
        let names = job.manifest.selections.map { $0.root.lastPathComponent }
        return names.count > 1 ? "\(names[0]) 等 \(names.count) 项" : (names.first ?? "未选择来源")
    }
    private func endpoint(_ label: String, icon: String, title: String, path: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(title.isEmpty ? "/" : title).font(.callout.weight(.semibold)).lineLimit(1)
                if showPaths {
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).help(path)
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
