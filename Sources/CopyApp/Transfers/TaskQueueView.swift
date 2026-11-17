import SwiftUI
import CopyCore

struct TaskQueueView: View {
    @ObservedObject var app: AppModel
    private var idleStatus: String {
        let jobs = app.snapshot.jobs
        if jobs.contains(where: { $0.state == .needsAttention }) { return "需要处理" }
        if jobs.contains(where: { $0.state == .paused }) { return "已暂停" }
        if jobs.contains(where: { $0.state == .pending || $0.state == .queued }) { return "待开始" }
        if jobs.contains(where: { $0.state == .cancelled }) { return "有已取消任务" }
        return jobs.isEmpty ? "暂无任务" : "校验通过"
    }
    var body: some View {
        let overview = QueueOverview(app.snapshot)
        let expanded = app.queueExpanded && !app.snapshot.jobs.isEmpty
        VStack(spacing: 0) {
            HStack {
                Button { app.queueExpanded.toggle() } label: {
                    Label(app.snapshot.jobs.isEmpty ? "暂无任务" : "\(app.snapshot.jobs.filter { $0.state == .running }.count) 项进行中 · \(app.snapshot.jobs.filter { $0.state == .pending || $0.state == .queued }.count) 项待开始", systemImage: expanded ? "chevron.down" : "chevron.up")
                }.buttonStyle(.plain).disabled(app.snapshot.jobs.isEmpty)
                Spacer()
                if expanded && app.snapshot.jobs.contains(where: { $0.state == .needsAttention || $0.state == .paused }) {
                    Text(idleStatus).font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
                if !expanded && !app.snapshot.jobs.isEmpty {
                    ProgressView(value: overview.fraction).frame(minWidth: 70, idealWidth: 120, maxWidth: 150)
                    Text("\(Int(overview.fraction * 100))% · \(overview.phase?.label ?? (overview.activeCount > 0 ? "准备中" : idleStatus))")
                        .font(.caption).lineLimit(1)
                    if overview.bytesPerSecond > 0 { Text("\(bytesLabel(Int64(overview.bytesPerSecond)))/秒").font(.caption.monospacedDigit()) }
                }
                if overview.waitingCount > 0 {
                    Button("开始所有待开始任务") { app.startJobs(app.snapshot.jobs.filter { $0.state == .pending }.map(\.id)) }
                        .disabled(!app.snapshot.jobs.contains { $0.state == .pending })
                }
                if expanded { Text("每次复制都完整校验").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 16).padding(.vertical, 10).background(Color(red: 0.055, green: 0.085, blue: 0.14))
            if let error = app.snapshot.persistenceError { Text(error).foregroundStyle(.red).padding(8) }
            if expanded {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(TransferJob.displayOrder(app.snapshot.jobs)) { job in
                            TaskRow(job: job, progress: app.snapshot.progress[job.id], app: app)
                        }
                    }.padding(10)
                }.frame(minHeight: 150, maxHeight: 310)
            }
        }.background(Color(red: 0.045, green: 0.075, blue: 0.12))
            .onChange(of: app.snapshot.jobs.isEmpty) { _, empty in if empty { app.queueExpanded = false } }
    }
}

private struct TaskRow: View {
    let job: TransferJob
    let progress: CopyProgress?
    @ObservedObject var app: AppModel
    @State private var expanded = false
    private var tint: Color {
        switch job.state { case .completed: return .green; case .needsAttention: return .red; case .paused: return .orange; case .running, .queued: return .blue; default: return .gray }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: job.state == .completed ? "checkmark.circle.fill" : (job.state == .needsAttention ? "exclamationmark.triangle" : "doc.on.doc"))
                    .foregroundStyle(job.state == .completed ? Color.green : .accentColor)
                Text(job.state.label).fontWeight(.semibold)
                Text("\(job.manifest.fileCount) 个文件 · \(bytesLabel(job.manifest.totalBytes))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if job.state == .pending {
                    Button("开始拷贝") { app.startJobs([job.id]) }.buttonStyle(NavyActionStyle(primary: true))
                } else if job.state == .running || job.state == .queued {
                    Button("暂停") { app.perform { try await $0.pause(id: job.id) } }.buttonStyle(NavyActionStyle())
                } else if job.state == .needsAttention && !expanded {
                    Button("查看问题") { expanded = true }.buttonStyle(NavyActionStyle())
                }
                Button(expanded ? "收起" : "详情") { expanded.toggle() }.buttonStyle(NavyActionStyle())
            }
            TransferRouteView(job: job, showPaths: false)
            if let date = job.historicalEndDate {
                Text("\(job.state == .completed ? "完成于" : "结束于") \(AppTime.minute(date))\(job.endedAt == nil ? "（历史记录）" : "")")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: min(progress.jobWorkCompleted, max(1, progress.jobWorkTotal) * 0.99), total: max(1, progress.jobWorkTotal))
                Text("本次已校验 \(progress.verifiedFiles) / \(progress.totalFiles) 个文件 · \(job.problemCount) 项待处理").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("\(progress.phase.label)：\(progress.relativePath)").lineLimit(1)
                    Spacer()
                    Text("\(bytesLabel(progress.bytes)) / \(bytesLabel(progress.total))")
                    Text(progress.workBytesPerSecond > 0 ? "\(bytesLabel(Int64(progress.workBytesPerSecond)))/秒 · \(AppTime.remaining(progress.estimatedSecondsRemaining))" : "正在采样速度…")
                        .font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.primary)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if job.state == .completed {
                Label(job.completionLabel, systemImage: "checkmark.shield.fill").font(.headline).foregroundStyle(.green)
            }
            if job.excludedCount > 0 {
                Text("另有 \(job.excludedCount) 项明确排除，未复制、未校验；详见报告。").font(.callout).foregroundStyle(.orange)
                if expanded { ForEach(job.excludedEntries ?? []) { entry in Text(entry.relativePath).font(.caption).textSelection(.enabled) } }
            }
            if let message = job.message { Text(message).font(.caption).foregroundStyle(.orange) }
            let timeWarnings = job.results.values.filter { job.confirmedResult(for: $0.entryID)?.status == .existingVerified && job.confirmedResult(for: $0.entryID)?.message != nil }.count
            if timeWarnings > 0 {
                Text("\(timeWarnings) 个已有文件内容一致，但创建/修改时间不同或无法核实；未修改已有时间。详情和报告列出文件。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if job.state == .needsAttention || job.state == .paused || job.state == .cancelled {
                Button("重新扫描并继续…") { app.rescanAndContinue(job) }.disabled(app.preparing || app.acceptingDraft)
            }
            if job.state == .pending {
                Text("同名文件会先校验：内容一致则保留，内容不同不会覆盖；已有文件的创建和修改时间不会自动更改。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if job.reportStatus == .failed { Text("素材结果已保留，但报告未保存：\(job.reportMessage ?? "")").font(.caption).foregroundStyle(.orange) }
            if expanded {
                Text("来源：" + job.manifest.selections.map { $0.root.path }.joined(separator: "、")).font(.caption).textSelection(.enabled)
                Text("目标：" + job.destination.path).font(.caption).textSelection(.enabled)
                let files = job.manifest.entries.filter { $0.kind == .file }
                let added = files.filter { job.confirmedResult(for: $0.id)?.status == .copiedVerified }.count
                let existing = files.filter { job.confirmedResult(for: $0.id)?.status == .existingVerified }.count
                let problem = files.filter { entry in job.confirmedResult(for: entry.id).map { !$0.status.verified } ?? false }.count
                let notProcessed = files.filter { job.confirmedResult(for: $0.id) == nil }.count
                Text("新增并校验 \(added) · 已有文件校验 \(existing) · 待处理 \(problem) · 尚未处理 \(notProcessed) · 明确排除 \(job.excludedCount)").font(.caption)
                ConflictView(job: job, app: app)
                ForEach(job.manifest.entries.filter { job.confirmedResult(for: $0.id)?.status == .existingVerified && job.confirmedResult(for: $0.id)?.message != nil }) { entry in
                    Text("\(entry.relativePath)：\(job.results[entry.id]?.message ?? "")")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .contextMenu {
                            Button("在访达查看来源") { NSWorkspace.shared.activateFileViewerSelecting([entry.sourceURL]) }
                            Button("在访达查看目标") { NSWorkspace.shared.activateFileViewerSelecting([job.destination.appendingPathComponent(entry.relativePath)]) }
                        }
                }
            }
        }.padding(14).background(Color(red: 0.065, green: 0.10, blue: 0.16), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.08)).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.35)))
            .contextMenu {
                if job.state == .running || job.state == .queued { Button("暂停") { app.perform { try await $0.pause(id: job.id) } } }
                else if job.state != .completed && job.state != .cancelled { Button(job.state == .pending ? "开始" : "继续 / 重新核验") { app.startJobs([job.id]) } }
                if job.state != .completed && job.state != .cancelled { Button("取消任务（保留文件）") { app.perform { try await $0.cancel(id: job.id) } } }
                Divider()
                ForEach(job.manifest.selections, id: \.root) { source in
                    Button("打开来源：" + source.root.lastPathComponent) {
                        let directory = job.manifest.entries.contains { $0.sourceURL == source.root && $0.kind == .directory }
                        if directory || !source.includeRoot { NSWorkspace.shared.open(source.root) }
                        else { NSWorkspace.shared.activateFileViewerSelecting([source.root]) }
                    }
                }
                Button("在访达打开目标文件夹") { NSWorkspace.shared.open(job.destination) }
                Button("清除任务（仅记录）") { app.perform { try await $0.clearTask(id: job.id) } }
                    .disabled(job.state == .running || job.state == .queued)
                if let report = job.reportPaths.first { Button("查看报告") { NSWorkspace.shared.open(report) } }
                Button("补存报告") { app.perform { try await $0.regenerateReport(id: job.id) } }.disabled(job.state == .running)
                if job.state != .running && job.state != .completed { Button("更换整批目标…") { app.reviewDestination(job) } }
                Button("优先排队") {
                    let ids = [job.id] + app.snapshot.jobs.filter { $0.id != job.id }.map(\.id)
                    app.perform { try await $0.reorder(ids: ids) }
                }.disabled(job.state == .running)
            }
    }
}

extension JobState {
    var label: String {
        switch self { case .pending: return "待开始"; case .queued: return "排队中"; case .running: return "进行中"; case .paused: return "已暂停"; case .cancelled: return "已取消（文件保留）"; case .needsAttention: return "部分完成 / 待处理"; case .completed: return "校验通过" }
    }
}
extension TransferPhase {
    var label: String { switch self { case .copying: return "正在复制"; case .verifying: return "正在读回校验"; case .checkingExisting: return "正在核对已有文件" } }
}
