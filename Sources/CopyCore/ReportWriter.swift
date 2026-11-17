import Foundation
import Darwin

public struct ReportLocations: Sendable {
    public var summary: URL
    public var details: URL
    public var mhl: URL
    public var all: [URL] { [summary, details, mhl] }
}
public struct ReportWriter {
    public init() {}
    public func write(job: TransferJob, directory: URL) throws -> ReportLocations {
        let rootName: String? = job.manifest.selections.count == 1 && job.manifest.selections[0].includeRoot
            ? job.manifest.entries.first(where: { $0.kind == .directory && $0.sourceURL == job.manifest.selections[0].root && !$0.relativePath.contains("/") })?.relativePath : nil
        let base = rootName.map { directory.appendingPathComponent($0) } ?? directory
        let reportFolder = try SecureDirectory(root: base, subdirectory: "拷贝校验报告")
        let mhlFolder = try SecureDirectory(root: base)
        var mhlJob = job
        if let rootName {
            mhlJob.manifest.entries = job.manifest.entries.filter { $0.kind == .file }.map { entry in
                var rebased = entry
                rebased.relativePath = String(entry.relativePath.dropFirst(rootName.count + 1))
                return rebased
            }
        }
        let prefix = "CopyCard-" + job.id.uuidString + "-" + UUID().uuidString
        let summaryName = prefix + ".txt"; let detailName = prefix + ".json"; let mhlName = prefix + ".mhl"
        let rows = job.manifest.entries.map { entry in
            ReportRow(path: entry.relativePath, size: entry.size, kind: entry.kind.rawValue,
                      status: job.confirmedResult(for: entry.id)?.status.rawValue ?? (job.results[entry.id] == nil ? "pending" : "historicalUnconfirmed"),
                      digest: job.confirmedResult(for: entry.id)?.digest,
                      error: job.confirmedResult(for: entry.id)?.message ?? (job.results[entry.id] != nil && job.confirmedResult(for: entry.id) == nil ? "异常中断后尚未重新核验，历史结果不作为本次校验通过依据" : nil))
        } + (job.excludedEntries ?? []).map { entry in
            ReportRow(path: entry.relativePath, size: entry.fingerprint.size, kind: entry.kind.rawValue,
                      status: "excludedUnverified", digest: nil,
                      error: "用户明确排除，未复制、未校验：" + (entry.unsupportedReason ?? "不支持的文件对象"))
        }
        let details = ReportDocument(jobID: job.id, createdAt: Date(), algorithm: job.algorithm,
                                     state: job.state, files: rows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let heading = job.state == .completed ? job.completionLabel : "本次任务尚未全部完成，请检查下列结果"
        let text = """
        拷卡校验报告
        \(heading)
        任务：\(job.id)
        算法：\(job.algorithm == .xxh64 ? "XXH64BE" : "MD5")
        已校验文件：\(job.successfulFiles) / \(job.manifest.fileCount)
        明确排除：\(job.excludedCount) 项（未复制、未校验；不计入 MHL 校验通过清单）
        校验只证明本次复制内容一致，不证明来源视频能够播放。
        报告保存位置：\(base.path)/拷贝校验报告
        MHL 清单位于本次报告所属目录：\(mhlName)
        来源：\(job.manifest.selections.map { $0.root.path }.joined(separator: "、"))
        目标：\(job.destination.path)

        """ + rows.map { "\($0.status)\t\($0.path)\t\($0.size) bytes\t\($0.digest ?? "—")\t\($0.error ?? "")" }.joined(separator: "\n") + "\n"
        try writeExclusive(try MHLWriter.document(job: mhlJob), name: mhlName, directory: mhlFolder)
        try writeExclusive(try encoder.encode(details), name: detailName, directory: reportFolder)
        try writeExclusive(Data(text.utf8), name: summaryName, directory: reportFolder)
        return ReportLocations(summary: base.appendingPathComponent("拷贝校验报告/" + summaryName),
                               details: base.appendingPathComponent("拷贝校验报告/" + detailName),
                               mhl: base.appendingPathComponent(mhlName))
    }
    private func writeExclusive(_ data: Data, name: String, directory: SecureDirectory) throws {
        try directory.validate()
        let fd = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        let io = SystemFileIO(); try io.write(fd, data: data); try io.synchronize(fd)
        try directory.validate()
    }
}

private struct ReportRow: Codable { var path: String; var size: Int64; var kind: String; var status: String; var digest: String?; var error: String? }
private struct ReportDocument: Codable { var jobID: UUID; var createdAt: Date; var algorithm: HashAlgorithm; var state: JobState; var files: [ReportRow] }
