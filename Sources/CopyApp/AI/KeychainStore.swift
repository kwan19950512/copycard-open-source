import Foundation
import CopyCore
import Security
import LocalAuthentication

protocol CredentialStore {
    func read(account: String) throws -> String
    func save(_ value: String, account: String) throws
    func contains(account: String) -> Bool
}
@MainActor final class AISettingsModel: ObservableObject {
    @Published var endpoint = ""
    @Published var model = ""
    @Published var key = ""
    @Published var message: String?
    let store: CredentialStore
    let defaults: UserDefaults
    init(store: CredentialStore, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
        endpoint = defaults.string(forKey: "aiEndpoint") ?? ""; model = defaults.string(forKey: "aiModel") ?? ""
    }
    func save() throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CopyProblem.invalid("API 地址无效") }
        let config = AIConfiguration(endpoint: url, model: model); try config.validate()
        if !key.isEmpty { try store.save(key, account: url.absoluteString); key = "" }
        defaults.set(url.absoluteString, forKey: "aiEndpoint"); defaults.set(model, forKey: "aiModel")
        endpoint = url.absoluteString
        message = "设置已保存；密钥只存于本机钥匙串。"
        NotificationCenter.default.post(name: .copyCardAIConfigurationChanged, object: nil)
    }
}

extension Notification.Name { static let copyCardAIConfigurationChanged = Notification.Name("CopyCardAIConfigurationChanged") }
struct KeychainStore: CredentialStore {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.copycard.ai", kSecAttrAccount as String: account]
    }
    func contains(account: String) -> Bool {
        var q = query(account); q[kSecReturnAttributes as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    func read(account: String) throws -> String {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw CopyProblem.invalid("无法读取本 App 的 API 密钥，请在设置中重新保存") }
        return value
    }
    func save(_ value: String, account: String) throws {
        guard !value.contains("\n"), !value.contains("\r") else { throw CopyProblem.invalid("密钥不能包含换行") }
        let q = query(account), values = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item.merge(values) { _, new in new }; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CopyProblem.invalid("无法保存到钥匙串") }
        } else if status != errSecSuccess { throw CopyProblem.invalid("无法更新钥匙串") }
    }
}
