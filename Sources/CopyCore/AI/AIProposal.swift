import Foundation

public struct AIGroup: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var folder: String
    public var entries: [UUID]
    public var reason: String
    public init(folder: String, entries: [UUID], reason: String = "") { self.folder = folder; self.entries = entries; self.reason = reason }
    enum CodingKeys: String, CodingKey { case folder, entries, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decode(String.self, forKey: .folder); entries = try c.decode([UUID].self, forKey: .entries)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}
public struct AIProposal: Codable, Sendable {
    public var groups: [AIGroup]
    public init(groups: [AIGroup]) { self.groups = groups }
    public func validate(expected: Set<UUID>) throws {
        guard !groups.isEmpty, groups.count <= 500 else { throw CopyProblem.invalid("AI 分组数量无效") }
        var seen = Set<UUID>(), names = Set<String>()
        for group in groups {
            try PathSafety.validateRelative(group.folder)
            guard group.folder.utf8.count <= 200, !group.folder.contains("/"), !group.folder.contains("\\"),
                  !group.folder.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !group.entries.isEmpty, group.reason.count <= 2000 else { throw CopyProblem.invalid("分组名称、说明或内容无效") }
            let name = group.folder.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(name).inserted else { throw CopyProblem.invalid("分组文件夹名称重复，请合并或改名") }
            for id in group.entries {
                guard expected.contains(id) else { throw CopyProblem.invalid("AI 引用了所选范围外的文件") }
                guard seen.insert(id).inserted else { throw CopyProblem.invalid("有文件重复归属，请调整分组") }
            }
        }
        guard seen == expected else { throw CopyProblem.invalid("分组遗漏了所选文件，请补充分配") }
    }
    public func jobs(manifest: CopyManifest, destination: URL, volume: VolumeInfo, algorithm: HashAlgorithm) throws -> [TransferJob] {
        try validate(expected: Set(manifest.entries.map(\.id)))
        return groups.map { group in
            var subset = manifest
            subset.entries = manifest.entries.filter { group.entries.contains($0.id) }
            return TransferJob(manifest: subset, destination: destination.appendingPathComponent(group.folder), destinationVolume: volume, algorithm: algorithm)
        }
    }
}
