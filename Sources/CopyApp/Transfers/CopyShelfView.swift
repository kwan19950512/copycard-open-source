import SwiftUI
import AppKit

struct CopyShelfView: View {
    @ObservedObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("待拷贝 · \(app.copiedBatches.count) 批", systemImage: "square.stack.3d.up").font(.callout.weight(.semibold))
                Spacer()
                Button("清空") { app.clearCopiedSelection() }.disabled(app.preparing || app.acceptingDraft)
            }
            Text("选择批次后，在目标位置粘贴加入队列").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(app.copiedBatches) { batch in
                        HStack(alignment: .top) {
                            Button { app.selectCopyBatch(batch.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(batch.title, systemImage: app.selectedCopyBatchID == batch.id ? "checkmark.circle.fill" : "folder").font(.callout.weight(.medium)).lineLimit(1)
                                    Text("\(batch.sources.count) 项所选内容 · \(batch.statisticsFailed ? "容量需检查" : bytesLabel(batch.bytes))").font(.caption)
                                    Text(batch.origin.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    let preview = app.draftCopyBatchID == batch.id ? app.draftJobs : batch.preview
                                    Text(preview.first.map { "目标：\($0.destination.path) · 待确认" } ?? "尚未指定目标 · 选择后粘贴").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { app.removeCopyBatch(batch.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("移除此批，不删除文件")
                        }.padding(12).background(app.selectedCopyBatchID == batch.id ? Color.blue.opacity(0.18) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(app.selectedCopyBatchID == batch.id ? Color.accentColor.opacity(0.5) : .clear) }
                            .contextMenu {
                                Button("选择此批") { app.selectCopyBatch(batch.id) }
                                Button("在访达显示来源") { NSWorkspace.shared.activateFileViewerSelecting(batch.sources) }
                                Button("移除此批（保留文件）") { app.removeCopyBatch(batch.id) }
                            }
                            .disabled(app.preparing || app.acceptingDraft)
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.055, green: 0.085, blue: 0.14).opacity(0.9))
    }
}
