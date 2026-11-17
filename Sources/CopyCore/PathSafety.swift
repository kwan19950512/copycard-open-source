import Foundation
import Darwin

public enum PathSafety {
    /// Only macOS-owned root aliases are normalized. User paths are never realpath-resolved.
    static func directoryWithoutLinks(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw CopyProblem.invalid("目标必须是本机文件路径") }
        var components = url.standardizedFileURL.pathComponents
        if components.count > 1, ["tmp", "var", "etc"].contains(components[1]) { components.insert("private", at: 1) }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for name in components.dropFirst() {
            current.appendPathComponent(name)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw CopyProblem.invalid("目标路径含链接或非目录对象，请选择真实目录") }
            } else if errno != ENOENT { throw posixFailure() }
        }
        return current
    }
    public static func validateRelative(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CopyProblem.invalid("无效的相对路径：\(path)")
        }
    }
    public static func contains(_ parent: URL, _ child: URL) -> Bool {
        let a = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let b = child.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return b.starts(with: a)
    }
    static func existingAncestor(_ url: URL) throws -> URL {
        var result = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: result.path) {
            let next = result.deletingLastPathComponent()
            guard next.path != result.path else { throw CopyProblem.invalid("找不到目标所在磁盘") }
            result = next
        }
        return result
    }
}
