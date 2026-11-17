import XCTest
@testable import CopyCore

private final class MockAIProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class AIClientTests: XCTestCase {
    private let config = AIConfiguration(endpoint: URL(string: "https://example.invalid/v1/chat/completions")!, model: "fixture")
    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockAIProtocol.self]; return URLSession(configuration: c)
    }
    private func batch() -> MetadataBatch { MetadataBatch(items: [MetadataItem(id: UUID(), path: "CARD/a.mp4", kind: .file, size: 20, camera: [:])], part: 1, parts: 1) }
    func testMockSuccessSendsOnlyMetadata() async throws {
        let batch = batch(); let proposal = AIProposal(groups: [AIGroup(folder: "当天素材", entries: batch.items.map(\.id), reason: "设备时间需人工确认")])
        MockAIProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-fixture-key")
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream); stream.open(); defer { stream.close() }
                var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }
                data = result
            }
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("fake-fixture-key")); XCTAssertFalse(text.contains("/Users/")); XCTAssertTrue(text.contains("CARD"))
            return (200, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": String(decoding: JSONEncoder().encode(proposal), as: UTF8.self)]]]]))
        }
        let s = session(); defer { s.invalidateAndCancel() }
        let result = try await AIClient().propose(batch: batch, configuration: config, credential: "fake-fixture-key", session: s)
        XCTAssertEqual(result.groups.first?.entries, batch.items.map(\.id))
    }
    func testErrorsAreSanitizedAndNoFallbackTransfer() async throws {
        for status in [429,401,500] {
            MockAIProtocol.handler = { _ in (status, Data("SECRET_SERVER_BODY".utf8)) }
            let s = session(); defer { s.invalidateAndCancel() }
            do { _ = try await AIClient().propose(batch: batch(), configuration: config, credential: "fake", session: s); XCTFail() }
            catch { XCTAssertFalse(error.localizedDescription.contains("SECRET_SERVER_BODY")) }
        }
        MockAIProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let s = session(); defer { s.invalidateAndCancel() }
        do { _ = try await AIClient().propose(batch: batch(), configuration: config, credential: "fake", session: s); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("手动")) }
    }
    func testMalformedAndOversizedResponsesRejected() async throws {
        for data in [Data("not-json".utf8), Data(repeating: 65, count: 1024 * 1024 + 1)] {
            MockAIProtocol.handler = { _ in (200, data) }
            let s = session(); defer { s.invalidateAndCancel() }
            do { _ = try await AIClient().propose(batch: batch(), configuration: config, credential: "fake", session: s); XCTFail() } catch {}
        }
    }
    func testCancelledRequestDoesNotSend() async throws {
        MockAIProtocol.handler = { _ in XCTFail("cancelled request must not send"); return (200, Data()) }
        let s = session(); defer { s.invalidateAndCancel() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AIClient().propose(batch: batch(), configuration: config, credential: "fake", session: s)
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail("unexpected error") }
    }
}
