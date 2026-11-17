import Foundation

public enum MHLWriter {
    /// Legacy MHL 1.0, matching Pomfort's reference fixtures (xxhash64be / md5).
    /// Stored at destination root so all file paths remain local relative paths.
    public static func document(job: TransferJob) throws -> Data {
        let root = XMLElement(name: "hashlist")
        root.addAttribute(XMLNode.attribute(withName: "version", stringValue: "1.0") as! XMLNode)
        let creator = XMLElement(name: "creatorinfo")
        creator.addChild(XMLElement(name: "tool", stringValue: "CopyCard 0.1"))
        let date = ISO8601DateFormatter()
        creator.addChild(XMLElement(name: "startdate", stringValue: date.string(from: job.createdAt)))
        creator.addChild(XMLElement(name: "finishdate", stringValue: date.string(from: Date())))
        root.addChild(creator)
        for entry in job.manifest.entries where entry.kind == .file {
            guard let result = job.confirmedResult(for: entry.id), result.status.verified, let digest = result.digest else { continue }
            try PathSafety.validateRelative(entry.relativePath)
            let hash = XMLElement(name: "hash")
            hash.addChild(XMLElement(name: "file", stringValue: entry.relativePath))
            hash.addChild(XMLElement(name: "size", stringValue: String(entry.size)))
            hash.addChild(XMLElement(name: "lastmodificationdate", stringValue: date.string(from: Date(timeIntervalSince1970: Double(entry.fingerprint.modifiedSeconds)))))
            hash.addChild(XMLElement(name: job.algorithm == .xxh64 ? "xxhash64be" : "md5", stringValue: digest))
            hash.addChild(XMLElement(name: "hashdate", stringValue: date.string(from: result.completedAt)))
            root.addChild(hash)
        }
        let document = XMLDocument(rootElement: root); document.version = "1.0"; document.characterEncoding = "UTF-8"
        return document.xmlData(options: .nodePrettyPrint)
    }
}
