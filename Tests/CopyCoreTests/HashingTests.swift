import XCTest
@testable import CopyCore

final class HashingTests: XCTestCase {
    func testHashFileReadsAllBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = 0
        XCTAssertEqual(try hashFile(at: url, algorithm: .xxh64) { bytes += $0 }, "44bc2cf5ad770999")
        XCTAssertEqual(bytes, 3)
    }
    func testEmptyXXH64() {
        XCTAssertEqual(StreamingHasher(algorithm: .xxh64).finalize(), "ef46db3751d8e999")
    }
    func testEmptyMD5() {
        XCTAssertEqual(StreamingHasher(algorithm: .md5).finalize(), "d41d8cd98f00b204e9800998ecf8427e")
    }
    func testReferenceVectors() {
        let vectors = [("a", "d24ec4f1a98c6e5b", "0cc175b9c0f1b6a831c399e269772661"),
                       ("abc", "44bc2cf5ad770999", "900150983cd24fb0d6963f7d28e17f72"),
                       ("hello", "26c7827d889f6da3", "5d41402abc4b2a76b9719d911017c592")]
        for (input, xxh, md5) in vectors {
            for (algorithm, expected) in [(HashAlgorithm.xxh64, xxh), (.md5, md5)] {
                var hasher = StreamingHasher(algorithm: algorithm)
                hasher.update(Data(input.utf8))
                XCTAssertEqual(hasher.finalize(), expected)
            }
        }
    }
    func testChunkBoundaries() {
        let input = Data((0..<100_003).map { UInt8($0 % 251) })
        for algorithm in HashAlgorithm.allCases {
            var whole = StreamingHasher(algorithm: algorithm)
            whole.update(input)
            // Independent xxhash 4.0.1 / Python hashlib reference, not this implementation.
            XCTAssertEqual(whole.finalize(), algorithm == .xxh64
                           ? "cbab15ce50b1eb20" : "2e7df8ce2c03b3b052faa1e3bb809159")
            for size in [1, 31, 32, 33, 1_048_576] {
                var chunks = StreamingHasher(algorithm: algorithm)
                for start in stride(from: 0, to: input.count, by: size) {
                    chunks.update(input.subdata(in: start..<min(start + size, input.count)))
                }
                XCTAssertEqual(chunks.finalize(), whole.finalize())
                XCTAssertEqual(chunks.finalize().count, algorithm == .xxh64 ? 16 : 32)
            }
        }
    }
}
