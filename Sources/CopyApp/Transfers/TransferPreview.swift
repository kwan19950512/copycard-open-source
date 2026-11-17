import SwiftUI
import CopyCore

struct TransferPreview: View {
    let job: TransferJob
    @ObservedObject var app: AppModel
    @State private var showPaths = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(app.snapshot.jobs.contains(where: { $0.id == job.id }) ? "更换目标预览 · 尚未应用" : "拷贝预览 · \(app.draftJobs.count) 项独立任务 · 尚未加入队列", systemImage: "doc.on.doc").font(.headline)
                Spacer()
                Button("取消预览", role: .cancel) { app.cancelDraft() }
                    .keyboardShortcut(.cancelAction).disabled(app.acceptingDraft)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(app.draftJobs) { candidate in
                        HStack {
                            TransferRouteView(job: candidate, showPaths: app.draftJobs.count == 1)
                            if app.draftJobs.count > 1 { Button("更换目标…") { app.changeDraftDestination(jobID: candidate.id) }.disabled(app.preparing || app.acceptingDraft) }
                        }
                    }
                }
            }.frame(height: app.draftJobs.count == 1 ? 100 : min(170, CGFloat(app.draftJobs.count) * 75))
            HStack {
                Text("\(app.draftJobs.reduce(0) { $0 + $1.manifest.fileCount }) 个文件 · \(bytesLabel(app.draftJobs.reduce(Int64(0)) { $0 + $1.manifest.totalBytes }))").bold()
                Text(job.algorithm == .xxh64 ? "XXH64BE · 完整校验" : "MD5 · 完整校验").foregroundStyle(.secondary)
                Spacer()
                Button("更换目标…") { app.changeDraftDestination() }.disabled(app.preparing || app.acceptingDraft)
            }.font(.callout)
            if let check = app.draftPreflight {
                ForEach(app.draftChecks.keys.sorted(by: { $0.path < $1.path }), id: \.self) { destination in
                    if let value = app.draftChecks[destination] {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(destination.path).lineLimit(1).truncationMode(.middle)
                            Text("即时可用 \(bytesLabel(value.immediateFree)) · 含可清理容量 \(bytesLabel(value.importantCapacity))（不按已释放计算）")
                            Text("本次需写入 \(bytesLabel(value.remainingBytes)) · 其他任务/同盘目标预留 \(bytesLabel(value.reservedBytes)) · 安全余量 \(bytesLabel(value.safetyReserve))")
                            Text("检查于 \(AppTime.minute(value.checkedAt)) · 加入后预计剩余 \(bytesLabel(value.projectedFree))")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("重新检查空间") { app.recheckDraftSpace() }.disabled(app.preparing || app.acceptingDraft)
                if !check.blockers.isEmpty {
                    ScrollView { Text(check.blockers.joined(separator: "\n")).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 80)
                }
                if !check.conflicts.isEmpty { Text("\(check.conflicts.count) 项同名文件会先完整校验；内容不同则留待处理。").font(.caption).foregroundStyle(.orange) }
            } else { ProgressView("正在检查空间和路径…").controlSize(.small) }
            let unsupported = app.draftJobs.flatMap { $0.manifest.entries }.filter { $0.kind == .unsupported }
            if !unsupported.isEmpty {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("有 \(unsupported.count) 个快捷方式或特殊对象暂时不能复制并校验。其余普通文件可以继续。").font(.callout)
                        Text("排除不会删除来源；这些项目不会复制，也不会记为校验通过。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("排除上述 \(unsupported.count) 项，继续其他文件") { app.excludeUnsupportedFromDraft() }
                        .disabled(app.preparing || app.acceptingDraft)
                }.padding(8).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            let excluded = app.draftJobs.flatMap { $0.excludedEntries ?? [] }
            if !excluded.isEmpty {
                DisclosureGroup("已由你排除 \(excluded.count) 项：未复制、未校验") {
                    ScrollView { ForEach(excluded) { entry in Text(entry.relativePath).font(.caption).frame(maxWidth: .infinity, alignment: .leading) } }.frame(maxHeight: 70)
                }.foregroundStyle(.orange)
            }
            DisclosureGroup("查看最终目录（保留所选文件夹的外层名称）", isExpanded: $showPaths) {
                ScrollView { LazyVStack(alignment: .leading) { ForEach(app.draftJobs.flatMap { $0.manifest.entries }) { Text($0.relativePath).font(.caption).textSelection(.enabled) } } }.frame(maxHeight: 110)
            }
            HStack {
                if app.snapshot.jobs.contains(where: { $0.id == job.id }) { Text("更换整个任务的目标；原目标中已拷贝的文件保留。新目标会重新复制整批内容。").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("加入队列，稍后开始") { app.acceptDraft(start: false) }.disabled(app.draftPreflight?.canStart != true || app.preparing || app.acceptingDraft)
                Button("开始拷贝并校验") { app.acceptDraft(start: true) }.buttonStyle(.borderedProminent).disabled(app.draftPreflight?.canStart != true || app.preparing || app.acceptingDraft)
            }
        }.padding(14).background(Color.accentColor.opacity(0.055))
    }
}
