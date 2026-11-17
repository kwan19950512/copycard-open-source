import Foundation

/// Streaming xxHash64, seed 0. All arithmetic is explicitly modulo 2^64.
struct XXHash64 {
    private static let p1: UInt64 = 11400714785074694791
    private static let p2: UInt64 = 14029467366897019727
    private static let p3: UInt64 = 1609587929392839161
    private static let p4: UInt64 = 9650029242287828579
    private static let p5: UInt64 = 2870177450012600261
    private var v1 = p1 &+ p2
    private var v2 = p2
    private var v3: UInt64 = 0
    private var v4 = 0 &- p1
    private var length: UInt64 = 0
    private var tail = Data()

    private static func rotate(_ x: UInt64, _ n: UInt64) -> UInt64 { (x << n) | (x >> (64 - n)) }
    private static func round(_ a: UInt64, _ x: UInt64) -> UInt64 { rotate(a &+ x &* p2, 31) &* p1 }
    private static func merge(_ a: UInt64, _ x: UInt64) -> UInt64 { (a ^ round(0, x)) &* p1 &+ p4 }
    private static func word(_ bytes: UnsafeRawBufferPointer, _ i: Int) -> UInt64 {
        UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self))
    }
    private mutating func stripe(_ bytes: UnsafeRawBufferPointer, _ i: Int) {
        v1 = Self.round(v1, Self.word(bytes, i))
        v2 = Self.round(v2, Self.word(bytes, i + 8))
        v3 = Self.round(v3, Self.word(bytes, i + 16))
        v4 = Self.round(v4, Self.word(bytes, i + 24))
    }
    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        if tail.count + data.count < 32 { tail.append(data); return }
        var offset = 0
        if !tail.isEmpty {
            let needed = 32 - tail.count
            tail.append(data.prefix(needed))
            let block = tail
            block.withUnsafeBytes { stripe($0, 0) }
            tail.removeAll(keepingCapacity: true)
            offset = needed
        }
        data.withUnsafeBytes { bytes in
            while offset + 32 <= bytes.count {
                stripe(bytes, offset)
                offset += 32
            }
        }
        if offset < data.count { tail.append(data.dropFirst(offset)) }
    }
    func digest() -> UInt64 {
        var h: UInt64
        if length >= 32 {
            h = Self.rotate(v1, 1) &+ Self.rotate(v2, 7) &+ Self.rotate(v3, 12) &+ Self.rotate(v4, 18)
            for v in [v1, v2, v3, v4] { h = Self.merge(h, v) }
        } else { h = Self.p5 }
        h &+= length
        tail.withUnsafeBytes { bytes in
            var i = 0
            while i + 8 <= bytes.count {
                h ^= Self.round(0, Self.word(bytes, i))
                h = Self.rotate(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if i + 4 <= bytes.count {
                let w = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: UInt32.self))
                h ^= UInt64(w) &* Self.p1
                h = Self.rotate(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < bytes.count {
                h ^= UInt64(bytes[i]) &* Self.p5
                h = Self.rotate(h, 11) &* Self.p1
                i += 1
            }
        }
        h ^= h >> 33
        h &*= Self.p2
        h ^= h >> 29
        h &*= Self.p3
        h ^= h >> 32
        return h
    }
}
