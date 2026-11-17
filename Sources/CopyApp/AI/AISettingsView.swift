import SwiftUI
import CopyCore

struct AISettingsView: View {
    @StateObject private var model = AISettingsModel(store: KeychainStore())
    @AppStorage("hashAlgorithm") private var algorithm = HashAlgorithm.xxh64.rawValue
    @AppStorage("notificationSound") private var sound = false
    @AppStorage("concurrencyLimit") private var limit = 2
    @AppStorage("allowSharedDevice") private var sharedDevice = false
    var body: some View {
        Form {
            Section("拷贝与校验") {
                Picker("新任务的校验算法", selection: $algorithm) {
                    Text("XXH64BE（默认）").tag(HashAlgorithm.xxh64.rawValue)
                    Text("MD5").tag(HashAlgorithm.md5.rawValue)
                }
                Text("两者都用于发现复制错误；均不能替代防篡改签名。切换仅影响新建任务，完整读回校验始终开启。").font(.caption).foregroundStyle(.secondary)
                Stepper("最多同时执行 \(min(2, max(1, limit))) 项", value: $limit, in: 1...2)
                Toggle("允许同一物理设备同时执行多项任务（高级）", isOn: $sharedDevice)
                Text("默认让共用设备的任务排队；强制并行可能降低速度。").font(.caption).foregroundStyle(.secondary)
                Toggle("完成和异常通知播放声音", isOn: $sound)
            }
            Section("智能整理 · 每位用户使用自己的 API") {
                TextField("HTTPS 完整地址（含 /chat/completions）", text: $model.endpoint)
                TextField("模型名称", text: $model.model)
                SecureField("API 密钥（留空保留该地址已保存的密钥）", text: $model.key)
                Text("兼容 OpenAI Chat Completions 协议。更换 API 地址不会自动把旧地址的密钥带过去。只发送你确认的目录元数据，不上传媒体内容；服务费用由你的 API 账户承担。").font(.caption).foregroundStyle(.secondary)
                Button("保存 AI 设置") { do { try model.save() } catch { model.message = error.localizedDescription } }
                if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
            }
        }.formStyle(.grouped).frame(width: 630, height: 580)
            .onChange(of: limit) { _, _ in applyConcurrency() }
            .onChange(of: sharedDevice) { _, _ in applyConcurrency() }
    }
    private func applyConcurrency() { AppModel.shared.perform { await $0.configureConcurrency(limit: limit, allowSharedDevice: sharedDevice) } }
}
