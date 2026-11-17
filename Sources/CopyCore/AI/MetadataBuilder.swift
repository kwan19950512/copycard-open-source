import Foundation
import Darwin

public struct MetadataItem: Codable, Sendable {
    public var id: UUID
    public var path: String
    public var kind: EntryKind
    public var size: Int64
    public var camera: [String: String]
}
public struct MetadataBatch: Codable, Sendable {
    public var items: [MetadataItem]
    public var part: Int
    public var parts: Int
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}
public struct MetadataBuilder {
    public init() {}
    public func build(manifest: CopyManifest) throws -> [MetadataBatch] {
        var batches: [MetadataBatch] = [], items: [MetadataItem] = []
        for entry in manifest.entries {
            try PathSafety.validateRelative(entry.relativePath)
            var camera: [String: String] = [:]
            if entry.kind == .file, entry.sourceURL.pathExtension.lowercased() == "xml", entry.size <= 65536 {
                let fd = open(entry.sourceURL.path, O_RDONLY | O_NOFOLLOW)
                if fd >= 0 {
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var info = stat()
                    if fstat(fd, &info) == 0, FileFingerprint.from(info) == entry.fingerprint,
                       let data = try? handle.read(upToCount: 65537), data.count <= 65536 {
                        camera = Self.cameraFields(data)
                    }
                    try? handle.close()
                }
            }
            let item = MetadataItem(id: entry.id, path: entry.relativePath, kind: entry.kind, size: entry.size, camera: camera)
            let candidate = MetadataBatch(items: items + [item], part: 999999, parts: 999999)
            let encodedSize = try candidate.encoded().count
            if candidate.items.count > 500 || encodedSize > 200 * 1024 {
                guard !items.isEmpty else { throw CopyProblem.invalid("单项目录信息过长，请缩小选择范围") }
                batches.append(MetadataBatch(items: items, part: 0, parts: 0)); items = []
            }
            items.append(item)
            guard try MetadataBatch(items: items, part: 999999, parts: 999999).encoded().count <= 200 * 1024 else {
                throw CopyProblem.invalid("单项目录信息过长，请缩小选择范围")
            }
        }
        if !items.isEmpty { batches.append(MetadataBatch(items: items, part: 0, parts: 0)) }
        for i in batches.indices { batches[i].part = i + 1; batches[i].parts = batches.count }
        return batches
    }
    public static func cameraFields(_ data: Data) -> [String: String] {
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { return [:] }
        let reader = CameraXMLReader(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        return parser.parse() ? reader.fields : [:]
    }
}

private final class CameraXMLReader: NSObject, XMLParserDelegate {
    let allowed: Set<String> = ["CameraModel", "ModelName", "Codec", "FrameRate", "Width", "Height", "CreationDate"]
    var fields: [String: String] = [:]
    var current = "", value = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        current = allowed.contains(elementName) ? elementName : ""; value = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !current.isEmpty { value = String((value + string).prefix(160)) } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == current {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.isEmpty { fields[current] = trimmed }
        }
        current = ""; value = ""
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
