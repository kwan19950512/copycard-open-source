import SwiftUI
import AppKit

struct DirectoryAccessView: View {
    @ObservedObject var access: DirectoryAccess
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("集中设置文件访问", systemImage: "folder.badge.person.crop").font(.title2.bold())
            Text("在这里集中选择常用素材根目录。同一位置下可按住 Command 多选；不同磁盘可以继续添加。选上一级目录后，里面的子文件夹不需要逐个选择。")
            Text("这是试用版。更新后 macOS 可能重新要求授权，可在这个窗口集中重新选择。保存位置记录不能替代系统许可，也不代表已获得完整磁盘访问。")
                .font(.callout).foregroundStyle(.secondary)
            if !access.records.isEmpty {
                if !access.confirmedForBuild { Text("这是更新后的版本，请重新选择这些位置以确认当前版本的访问。系统许可仍由 macOS 判断。").font(.caption).foregroundStyle(.secondary) }
                Text("已记住的位置").font(.headline)
                ScrollView { VStack(alignment: .leading, spacing: 8) {
                    ForEach(access.records) { record in Label(record.path, systemImage: "folder").font(.callout).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 150)
            }
            if let note = message ?? access.restorationMessage { Text(note).foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("稍后处理") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("选择常用目录并授权…") { choose() }.buttonStyle(.borderedProminent)
                Button("完成") { dismiss() }.disabled(!access.confirmedForBuild)
            }
        }.padding(24).frame(width: 610)
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "允许访问所选目录"
        panel.message = "选择常用根目录；按住 Command 可以一次选择多个。"
        guard panel.runModal() == .OK else { return }
        do { try access.recordSelection(panel.urls); message = "所选位置已记住。可以继续添加其他位置，或点击完成。" }
        catch { message = "无法保存所选位置：\(error.localizedDescription)。可以重新选择。" }
    }
}
