import Foundation
import CryptoKit

/// A factory file reference, deliberately distinct from an ECU-read ABSBackup.
struct FactoryABSReference: Codable, Equatable {
    let schemaVersion: Int
    let vin: String
    let sourcePath: String
    let sourceSHA256: String
    let blocks: [Block]
    let nodeIdentifiers: [String: String]
    let sourceErrors: [SourceError]
    let provenance: String
    let validation: String
    struct Block: Codable, Equatable {
        let label: String
        let codeGroups: [String]
    }
    struct SourceError: Codable, Equatable {
        let code: String
        let message: String
    }

    static func parse(_ data: Data, expectedVIN: String, sourcePath: String) throws -> Self {
        guard validVIN(expectedVIN) else { throw ABSError.invalid("Reference VIN has an invalid alphabet or check digit") }
        guard data.count <= 5_000_000, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw ABSError.invalid("Factory file must be bounded UTF-8 XML without DTDs or entities")
        }
        let reader = FactoryXMLReader()
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.root == "AS_BUILT_DATA", reader.vehicles == 1,
              reader.vins.count == 1, reader.vins.first == expectedVIN else {
            throw ABSError.invalid("Malformed factory XML or VIN mismatch; no factory reference accepted")
        }
        guard !reader.errors.contains(where: { ["612", "613"].contains($0.code) }) else {
            throw ABSError.invalid("Factory source reports missing PCM/BCE data; repeat the VIN lookup")
        }
        guard !reader.blocks.isEmpty, reader.nodes == 1 else {
            throw ABSError.invalid("Factory file lacks ABS 760 blocks or has missing/ambiguous node 760 metadata")
        }
        var labels: Set<String> = []
        for block in reader.blocks {
            guard block.codeGroups.count == 3, labels.insert(block.label).inserted else {
                throw ABSError.invalid("Duplicate ABS block or unexpected CODE group count")
            }
            _ = try FordAsBuiltBlock.parse(block.label + " " + block.codeGroups.joined(), source: "Factory XML")
            guard block.codeGroups.allSatisfy({ $0.isEmpty || ($0.count % 2 == 0 && $0.utf8.allSatisfy { "0123456789ABCDEF".utf8.contains($0) }) }) else {
                throw ABSError.invalid("Invalid factory CODE group")
            }
        }
        guard !reader.ambiguousIdentifier else { throw ABSError.invalid("Duplicate factory node identifier") }
        return .init(schemaVersion: 1, vin: expectedVIN, sourcePath: sourcePath,
                     sourceSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                     blocks: reader.blocks.sorted { $0.label < $1.label }, nodeIdentifiers: reader.identifiers,
                     sourceErrors: reader.errors, provenance: "User-supplied factory download; not ECU-read configuration or independently authenticated Ford content",
                     validation: "VIN/check digit and XML/block syntax checked. Original CODE groups preserved; checksum, hardware compatibility and write procedure unverified. Not programming-ready.")
    }

    static func validVIN(_ vin: String) -> Bool {
        let bytes = Array(vin.utf8)
        guard bytes.count == 17, bytes.allSatisfy({ "0123456789ABCDEFGHJKLMNPRSTUVWXYZ".utf8.contains($0) }) else { return false }
        let groups = ["AJ", "BKS", "CLT", "DMU", "ENV", "FW", "GPX", "HY", "RZ"]
        let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
        let sum = zip(bytes, weights).reduce(0) { total, pair in
            let value = pair.0 >= 48 && pair.0 <= 57 ? Int(pair.0 - 48) : (groups.firstIndex { $0.utf8.contains(pair.0) }! + 1)
            return total + value * pair.1
        }
        return bytes[8] == (sum % 11 == 10 ? 88 : UInt8(sum % 11 + 48))
    }

    var text: String {
        (["Factory ABS reference", "VIN: " + vin, "Source: " + sourcePath, "SHA-256: " + sourceSHA256, provenance, validation, "", "Original ABS CODE groups:"]
         + blocks.map { $0.label + " " + $0.codeGroups.joined(separator: " ") }
         + ["", "Factory node 760 identifiers (raw tags):"]
         + nodeIdentifiers.keys.sorted().map { $0 + ": " + nodeIdentifiers[$0]! }
         + ["", "Source messages:"] + sourceErrors.map { $0.code + " " + $0.message }).joined(separator: "\n") + "\n"
    }
}

private final class FactoryXMLReader: NSObject, XMLParserDelegate {
    var root: String?
    var vehicles = 0
    var vins: [String] = []
    var blocks: [FactoryABSReference.Block] = []
    var errors: [FactoryABSReference.SourceError] = []
    var identifiers: [String: String] = [:]
    var nodes = 0
    var ambiguousIdentifier = false
    private var stack: [String] = []
    private var texts: [String] = []
    private var label = ""
    private var groups: [String] = []
    private var errorCode = "", errorMessage = ""
    private var nodeFields: [String: String] = [:]
    private var duplicateNodeField = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if stack.isEmpty { root = name }
        stack.append(name); texts.append("")
        if stack == ["AS_BUILT_DATA", "VEHICLE"] { vehicles += 1 }
        if stack == ["AS_BUILT_DATA", "VEHICLE", "BCE_MODULE", "DATA"] { label = attributes["LABEL"] ?? ""; groups = [] }
        if stack == ["AS_BUILT_DATA", "VEHICLE", "NODEID"] { nodeFields = [:]; duplicateNodeField = false }
        if stack == ["AS_BUILT_DATA", "VEHICLE", "ERROR"] { errorCode = ""; errorMessage = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !texts.isEmpty { texts[texts.count - 1] += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = (texts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if stack == ["AS_BUILT_DATA", "VEHICLE", "VIN"] { vins.append(value) }
        if stack == ["AS_BUILT_DATA", "VEHICLE", "BCE_MODULE", "DATA", "CODE"] { groups.append(value) }
        if stack == ["AS_BUILT_DATA", "VEHICLE", "BCE_MODULE", "DATA"], label.hasPrefix("760-") { blocks.append(.init(label: label, codeGroups: groups)) }
        if stack.count == 4, Array(stack.prefix(3)) == ["AS_BUILT_DATA", "VEHICLE", "NODEID"] {
            if nodeFields.updateValue(value, forKey: name) != nil { duplicateNodeField = true }
        }
        if stack == ["AS_BUILT_DATA", "VEHICLE", "NODEID"], value == "760" { nodes += 1; identifiers = nodeFields; ambiguousIdentifier = ambiguousIdentifier || duplicateNodeField }
        if stack == ["AS_BUILT_DATA", "VEHICLE", "ERROR", "ERRORCODE"] { errorCode = value }
        if stack == ["AS_BUILT_DATA", "VEHICLE", "ERROR", "ERRORMSG"] { errorMessage = value }
        if stack == ["AS_BUILT_DATA", "VEHICLE", "ERROR"] { errors.append(.init(code: errorCode, message: errorMessage)) }
        stack.removeLast(); texts.removeLast()
    }
}
