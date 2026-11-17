import XCTest
@testable import CopyApp

private final class FakeCredentialStore: CredentialStore {
    var saved: [String: String] = [:]
    var reads = 0
    func read(account: String) throws -> String { reads += 1; return saved[account] ?? "" }
    func save(_ value: String, account: String) throws { saved[account] = value }
    func contains(account: String) -> Bool { saved[account] != nil }
}
final class AISettingsTests: XCTestCase {
    @MainActor func testKeySavedOnlyOnExplicitSaveAndNeverInDefaults() throws {
        let name = "CopyCardTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let store = FakeCredentialStore(); let model = AISettingsModel(store: store, defaults: defaults)
        XCTAssertEqual(store.reads, 0); XCTAssertTrue(store.saved.isEmpty)
        model.endpoint = "https://example.invalid/v1/chat/completions"; model.model = "fixture"; model.key = "fake-secret"
        XCTAssertTrue(store.saved.isEmpty)
        try model.save()
        XCTAssertEqual(store.saved[model.endpoint], "fake-secret"); XCTAssertEqual(model.key, "")
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: name)).contains("fake-secret"))
    }
    @MainActor func testInvalidConfigurationDoesNotTouchKeychain() throws {
        let store = FakeCredentialStore(); let model = AISettingsModel(store: store)
        model.endpoint = "http://bad.invalid"; model.model = "test"; model.key = "fake"
        XCTAssertThrowsError(try model.save()); XCTAssertTrue(store.saved.isEmpty)
    }
}
