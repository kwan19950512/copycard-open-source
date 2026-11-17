import SwiftUI
import AppKit
import CopyCore

struct ConflictView: View {
    let job: TransferJob
    @ObservedObject var app: AppModel
    var body: some View {
        let problems = job.manifest.entries.filter { entry in job.confirmedResult(for: entry.id).map { !$0.status.verified } ?? false }
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("待处理文件 \(problems.count) 项").font(.caption.bold())
                Text("内容不同的同名文件不会覆盖。右键文件可在访达查看来源或目标；处理后重新扫描并继续。") .font(.caption)
                ForEach(problems) { entry in
                    Text("\(entry.relativePath)：\(job.results[entry.id]?.message ?? "未完成")")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .contextMenu {
                            Button("在访达查看来源") { NSWorkspace.shared.activateFileViewerSelecting([entry.sourceURL]) }
                            Button("在访达查看目标") { NSWorkspace.shared.activateFileViewerSelecting([job.destination.appendingPathComponent(entry.relativePath)]) }
                            if entry.kind == .file && [.needsAttention, .paused, .cancelled].contains(job.state) {
                                Button("排除此文件…") { app.excludeProblem(job: job, entry: entry) }
                            }
                        }
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.07))
        }
    }
}
