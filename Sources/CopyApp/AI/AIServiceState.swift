import Foundation
import Network
import CopyCore

@MainActor final class AIServiceState: ObservableObject {
    @Published var online = false
    @Published var configured = false
    @Published var failed = false
    private let monitor = NWPathMonitor()
    var configuration: AIConfiguration? {
        guard let text = UserDefaults.standard.string(forKey: "aiEndpoint"), let url = URL(string: text),
              let model = UserDefaults.standard.string(forKey: "aiModel") else { return nil }
        let value = AIConfiguration(endpoint: url, model: model)
        return (try? value.validate()) == nil ? nil : value
    }
    var reason: String? {
        if !configured { return "先在设置中填写自己的 API" }
        if !online { return "当前无网络，手动拷贝可正常使用" }
        if failed { return "上次服务不可用，点击重新检查后可重试" }
        return nil
    }
    init() {
        refresh()
        monitor.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.online = path.status == .satisfied } }
        monitor.start(queue: DispatchQueue(label: "CopyCard.NetworkAvailability"))
    }
    deinit { monitor.cancel() }
    func refresh() {
        configured = configuration.map { KeychainStore().contains(account: $0.endpoint.absoluteString) } ?? false
        failed = false
    }
}
