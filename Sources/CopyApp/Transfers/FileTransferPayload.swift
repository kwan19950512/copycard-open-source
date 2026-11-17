import AppKit
import UniformTypeIdentifiers
import CopyCore

enum FileTransferPayload {
    static let identifier = "local.copycard.selection"
    static func provider(urls: [URL]) -> NSItemProvider {
        let provider = NSItemProvider(object: urls[0] as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
            completion(try? JSONEncoder().encode(urls), nil); return nil
        }
        return provider
    }
    static func read(_ providers: [NSItemProvider]) async throws -> [URL] {
        guard !providers.isEmpty else { throw CopyProblem.invalid("没有可识别的拖入项目；未创建拷贝任务。") }
        var all: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(identifier) {
                let data = await load(provider, type: identifier)
                guard let urls = try? JSONDecoder().decode([URL].self, from: data ?? Data()),
                      !urls.isEmpty, urls.allSatisfy(\.isFileURL) else {
                    throw CopyProblem.invalid("无法完整识别拖入的项目；未定位任何项目，也未创建拷贝任务。")
                }
                all.append(contentsOf: urls)
            } else {
                guard let data = await load(provider, type: UTType.fileURL.identifier),
                      let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                    throw CopyProblem.invalid("无法完整读取拖入的项目；未定位任何项目，也未创建拷贝任务。")
                }
                all.append(url)
            }
        }
        return all
    }
    private static func load(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
        }
    }
}

@MainActor final class DropRequestCoordinator: ObservableObject {
    private var latest = UUID()
    func submit(_ providers: [NSItemProvider], isValid: @escaping () -> Bool = { true }, apply: @escaping ([URL]) throws -> Void, fail: @escaping (Error) -> Void) {
        let request = UUID(); latest = request
        Task {
            do {
                let urls = try await FileTransferPayload.read(providers)
                guard latest == request, isValid() else { return }
                try apply(urls)
            } catch {
                guard latest == request, isValid() else { return }
                fail(error)
            }
        }
    }
}
