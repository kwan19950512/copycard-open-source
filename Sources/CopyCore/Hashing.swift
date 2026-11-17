import Foundation
import CryptoKit

public enum HashAlgorithm: String, Codable, CaseIterable, Sendable {
    case xxh64, md5
}

public func hashFile(at url: URL, algorithm: HashAlgorithm,
                     onChunk: (Int) throws -> Void = { _ in }) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = StreamingHasher(algorithm: algorithm)
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        hasher.update(data)
        try onChunk(data.count)
    }
    return hasher.finalize()
}

public struct StreamingHasher {
    private let algorithm: HashAlgorithm
    private var xxh = XXHash64()
    private var md5 = Insecure.MD5()
    public init(algorithm: HashAlgorithm) { self.algorithm = algorithm }
    public mutating func update(_ data: Data) {
        switch algorithm {
        case .xxh64: xxh.update(data)
        case .md5: md5.update(data: data)
        }
    }
    public func finalize() -> String {
        switch algorithm {
        case .xxh64: return String(format: "%016llx", xxh.digest())
        case .md5: return md5.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}
