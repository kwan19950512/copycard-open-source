import Foundation
import Darwin

/// Works on open descriptors, never by reopening a potentially swapped path.
enum FileTimestamps {
    private struct Values {
        var creation: timespec
        var modification: timespec
    }
    private static func read(_ fd: Int32) throws -> Values {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixFailure() }
        return Values(creation: info.st_birthtimespec, modification: info.st_mtimespec)
    }
    static func preserve(source: Int32, target: Int32) throws {
        var values = try read(source)
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
        // Attribute buffers follow the bit order: creation, then modification.
        guard fsetattrlist(target, &attributes, &values, MemoryLayout<Values>.size, 0) == 0 else { throw posixFailure() }
        try verify(source: source, target: target)
    }
    static func verify(source: Int32, target: Int32) throws {
        let expected = try read(source), actual = try read(target)
        var filesystem = statfs()
        guard fstatfs(target, &filesystem) == 0 else { throw posixFailure() }
        let type = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let tolerance: Double
        switch type {
        case "msdos": tolerance = 2
        case "exfat": tolerance = 0.01
        case "hfs": tolerance = 1
        default: tolerance = 0
        }
        func matches(_ a: timespec, _ b: timespec) -> Bool {
            abs(Double(a.tv_sec - b.tv_sec) + Double(a.tv_nsec - b.tv_nsec) / 1_000_000_000) <= tolerance
        }
        guard matches(expected.creation, actual.creation), matches(expected.modification, actual.modification) else {
            throw CopyProblem.invalid("目标文件系统未正确保存来源的创建时间或修改时间")
        }
    }
}
