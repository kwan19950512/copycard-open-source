import SwiftUI
import CopyCore

struct AIReviewView: View {
    @ObservedObject var model: AIReviewModel
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var metadataExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("智能整理 · 由你确认").font(.title2); Spacer(); Button("关闭") { model.requestTask?.cancel(); dismiss() } }
            Text("\(model.manifest.fileCount) 个文件，\(model.manifest.entries.count) 项目录条目；分 \(model.batches.count) 批，每批最多 500 项 / 200 KiB。不会上传视频、图片或音频内容。").font(.callout)
            if let config = model.configuration { Text("发送至：\(config.endpoint.absoluteString) · 模型：\(config.model)").font(.caption).textSelection(.enabled) }
            DisclosureGroup("查看实际发送的目录元数据（含文件名，请确认可发送给该服务）", isExpanded: $metadataExpanded) {
                ScrollView { Text(model.batches.map { String(decoding: (try? $0.encoded()) ?? Data(), as: UTF8.self) }.joined(separator: "\n\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 150)
            }
            HStack {
                if model.sending { ProgressView().controlSize(.small); Button("取消请求") { model.requestTask?.cancel() } }
                else { Button(model.groups.isEmpty ? "确认发送并生成建议" : "重新生成建议") { model.send(store: KeychainStore()) { app.aiService.failed = true } }.disabled(model.configuration == nil) }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if !model.groups.isEmpty {
                HStack {
                    Button("选中项拆成新组") { model.splitSelection() }.disabled(model.selected.isEmpty)
                    Menu("选中项移动到…") { ForEach(model.groups) { group in Button(group.folder) { model.moveSelection(to: group.id) } } }.fixedSize().disabled(model.selected.isEmpty)
                    Button("合并全部分组") { model.mergeAll() }.disabled(model.groups.count < 2)
                    Spacer(); Text("⌘ 点击多选").font(.caption).foregroundStyle(.secondary)
                }
                List(selection: $model.selected) {
                    ForEach($model.groups) { $group in
                        Section {
                            ForEach(group.entries, id: \.self) { id in
                                if let entry = model.manifest.entries.first(where: { $0.id == id }) {
                                    Label(entry.relativePath, systemImage: entry.kind == .directory ? "folder" : "doc").tag(id)
                                }
                            }
                        } header: {
                            VStack(alignment: .leading) {
                                TextField("分组文件夹名称", text: $group.folder)
                                Text(group.reason.isEmpty ? "请人工确认设备与拍摄归属" : group.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(minHeight: 180)
                HStack {
                    Button("选择目标文件夹…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        if panel.runModal() == .OK { model.destination = panel.url; model.invalidatePreview() }
                    }
                    Text(model.destination?.path ?? "未选择目标").font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Text("各组写入目标下的同名子文件夹，保留原相对目录。下面的预览通过后才可加入队列。").font(.caption).foregroundStyle(.secondary)
                ScrollView { VStack(alignment: .leading) { ForEach(model.preflightSummary, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } } }.frame(maxHeight: 85)
                HStack {
                    Button("检查最终路径与容量") {
                        let algorithm = HashAlgorithm(rawValue: UserDefaults.standard.string(forKey: "hashAlgorithm") ?? "") ?? .xxh64
                        Task { await model.preview(existingJobs: app.snapshot.jobs, algorithm: algorithm) }
                    }.disabled(model.destination == nil || model.sending)
                    Spacer()
                    Button("确认分组，加入待开始队列") {
                        let jobs = model.readyJobs
                        app.perform { queue in
                            try await queue.enqueueValidatedBatch(jobs)
                            await MainActor.run { app.queueExpanded = true; dismiss() }
                        }
                    }.disabled(model.readyJobs.isEmpty || model.sending)
                }
            } else { Spacer() }
        }.padding(20).frame(width: 880, height: 760)
            .onChange(of: model.groups) { _, _ in model.invalidatePreview() }
            .onDisappear { model.requestTask?.cancel() }
    }
}
