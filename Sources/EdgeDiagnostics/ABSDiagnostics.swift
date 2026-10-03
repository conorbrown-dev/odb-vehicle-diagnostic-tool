import Foundation

struct CANFrame: Codable, Equatable {
    let id: UInt16
    let bytes: [UInt8]
}

enum ABSError: LocalizedError {
    case invalid(String)
    case unsupported
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .unsupported: "Unsupported until Ford diagnostic procedure is verified."
        }
    }
}

/// Classical CAN, normal addressing. No flow-control or ECU requests are emitted here.
enum ISOTP {
    static func assemble(_ frames: [CANFrame]) throws -> [UInt8] {
        guard let first = frames.first, first.id <= 0x7FF, !first.bytes.isEmpty,
              frames.allSatisfy({ $0.id == first.id && !$0.bytes.isEmpty && $0.bytes.count <= 8 }) else {
            throw ABSError.invalid("Missing or mixed CAN frames")
        }
        let b = first.bytes
        if b[0] >> 4 == 0 {
            let length = Int(b[0] & 15)
            guard length > 0, length <= 7, b.count >= length + 1, frames.count == 1 else { throw ABSError.invalid("Invalid single frame") }
            return Array(b.dropFirst().prefix(length))
        }
        guard b.count == 8, b[0] >> 4 == 1 else { throw ABSError.invalid("Expected ISO-TP first frame") }
        let length = Int(b[0] & 15) * 256 + Int(b[1])
        guard length > 7 else { throw ABSError.invalid("Invalid ISO-TP length") }
        var payload = Array(b.dropFirst(2))
        for (index, frame) in frames.dropFirst().enumerated() {
            guard payload.count < length, frame.bytes[0] == UInt8(0x20 | ((index + 1) & 15)),
                  frame.bytes.count >= min(7, length - payload.count) + 1 else { throw ABSError.invalid("Unexpected ISO-TP sequence or length") }
            payload += frame.bytes.dropFirst()
        }
        guard payload.count >= length else { throw ABSError.invalid("Incomplete ISO-TP response") }
        return Array(payload.prefix(length))
    }

    static func frames(payload: [UInt8], id: UInt16) throws -> [CANFrame] {
        guard !payload.isEmpty, payload.count <= 4095, id <= 0x7FF else { throw ABSError.invalid("Invalid ISO-TP payload/address") }
        if payload.count <= 7 { return [CANFrame(id: id, bytes: [UInt8(payload.count)] + payload)] }
        var result = [CANFrame(id: id, bytes: [0x10 | UInt8(payload.count >> 8), UInt8(payload.count & 255)] + payload.prefix(6))]
        var offset = 6, sequence = 1
        while offset < payload.count {
            result.append(CANFrame(id: id, bytes: [UInt8(0x20 | (sequence & 15))] + payload.dropFirst(offset).prefix(7)))
            offset += 7; sequence += 1
        }
        return result
    }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

enum DiagnosticResponse {
    static func summary(_ payload: [UInt8]) -> String {
        guard let service = payload.first else { return "Empty response" }
        if service == 0x7F, payload.count == 3 {
            return "Negative response: " + (OBDClientError.negativeResponse(service: payload[1], code: payload[2]).errorDescription ?? "Unknown NRC")
        }
        let name: String
        switch service {
        case 0x18, 0x58: name = "Ford ReadDTCByStatus (continuous DTCs; raw records)"
        case 0x19, 0x59: name = "ReadDTCInformation"
        case 0x22, 0x62: name = "ReadDataByIdentifier"
        default: return "Unknown response\nRaw payload: " + payload.hex
        }
        let identifier = (service == 0x22 || service == 0x62) && payload.count >= 3 ? String(format: " DID %02X%02X", payload[1], payload[2]) : ""
        let subfunction = (service == 0x19 || service == 0x59) && payload.count >= 2 ? String(format: " subfunction %02X", payload[1]) : ""
        let protocolVersion = (service == 0x22 || service == 0x62) && payload.count >= 3 && payload[1...2] == [0xE6, 0xF3]
        let versionLabel = protocolVersion ? " • Ford diagnostic specification version" : ""
        let undecodedDID = (service == 0x62 || service == 0x22) && payload.count >= 3 && (payload[1] != 0xF1 || payload[2] != 0x87) && !protocolVersion
        let undecodedSubfunction = (service == 0x59 || service == 0x19) && payload.count >= 2 && payload[1] != 2
        let unknown = undecodedDID || undecodedSubfunction ? "\nUnknown response (identifier/subfunction not implemented)\nRaw payload: " + payload.hex : ""
        return String(format: "0x%02X ", service) + name + identifier + versionLabel + subfunction + (service == 0x58 || service == 0x59 || service == 0x62 ? " • positive response" : " • request") + unknown
    }

    static func validate(_ payload: [UInt8], request: [UInt8]) throws -> [UInt8] {
        guard let service = request.first, service <= 0xBF else { throw ABSError.invalid("Invalid diagnostic request service") }
        if payload.first == 0x7F {
            guard payload.count == 3, payload[1] == service else { throw ABSError.invalid("Malformed negative response") }
            throw OBDClientError.negativeResponse(service: service, code: payload[2])
        }
        guard payload.first == service + 0x40 else { throw ABSError.invalid("Unexpected diagnostic response") }
        if service == 0x22 {
            guard payload.count >= 4, payload.prefix(3).dropFirst() == request.dropFirst() else { throw ABSError.invalid("DID response mismatch") }
        }
        if request == [0x22, 0xE6, 0xF3] {
            guard payload.count == 4 else { throw ABSError.invalid("Malformed Ford diagnostic specification version response") }
        }
        if request == [0x18, 0x00, 0xFF, 0x00] {
            guard payload.count >= 2, (payload.count - 2) % 3 == 0 else { throw ABSError.invalid("Malformed Ford continuous DTC record layout") }
            let records = (payload.count - 2) / 3
            guard Int(payload[1]) == min(records, 255) else { throw ABSError.invalid("Ford continuous DTC count mismatch") }
        }
        if service == 0x19 {
            guard payload.count >= 3, payload[1] == 0x02, (payload.count - 3) % 4 == 0 else { throw ABSError.invalid("Malformed DTC response") }
        }
        return payload
    }
}

enum ABSAddressingStatus: String, Codable {
    case candidate = "Candidate / not vehicle-verified"
    case observed = "Observed on vehicle"
    case userConfigured = "User configured / not vehicle-verified"
}

struct FordModuleAddressing: Codable, Equatable {
    static let candidateRequestID = UInt16(FordModuleProbe.absCandidate.requestHeader, radix: 16)!
    static let candidateResponseID: UInt16 = 0x768
    var requestID: UInt16 = FordModuleAddressing.candidateRequestID
    var responseID: UInt16 = FordModuleAddressing.candidateResponseID
    var evidence: String = "User-supplied 2012 Fusion candidate profile; not vehicle-verified"
    var network: FordNetwork = .highSpeed
    var addressingBits = 11
    var status: ABSAddressingStatus = .candidate
    var observedAt: Date?
    static let fusionCandidate = Self()
    var protocolName: String { "HS-CAN / ISO 15765-2 normal 11-bit / application protocol unverified" }
    func validate() throws {
        guard requestID <= 0x7FF, responseID <= 0x7FF, responseID != requestID,
              network == .highSpeed, addressingBits == 11,
              !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ABSError.invalid("Supply distinct 11-bit CAN IDs and a source; this workflow supports HS-CAN only.")
        }
    }
    mutating func markObserved(at timestamp: Date) {
        status = .observed
        if observedAt == nil { observedAt = timestamp }
    }
    private enum CodingKeys: String, CodingKey { case requestID, responseID, evidence, network, addressingBits, status, observedAt }
    init(requestID: UInt16 = FordModuleAddressing.candidateRequestID, responseID: UInt16 = FordModuleAddressing.candidateResponseID,
         evidence: String = "User-supplied 2012 Fusion candidate profile; not vehicle-verified",
         network: FordNetwork = .highSpeed, addressingBits: Int = 11, status: ABSAddressingStatus = .candidate, observedAt: Date? = nil) {
        self.requestID = requestID; self.responseID = responseID; self.evidence = evidence
        self.network = network; self.addressingBits = addressingBits; self.status = status; self.observedAt = observedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(UInt16.self, forKey: .requestID)
        responseID = try c.decode(UInt16.self, forKey: .responseID)
        evidence = try c.decode(String.self, forKey: .evidence)
        network = try c.decodeIfPresent(FordNetwork.self, forKey: .network) ?? .highSpeed
        addressingBits = try c.decodeIfPresent(Int.self, forKey: .addressingBits) ?? 11
        status = try c.decodeIfPresent(ABSAddressingStatus.self, forKey: .status) ?? .userConfigured
        observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt)
    }
}

enum ABSTraceVisibility: String, Codable { case physical, logical, reconstructed, adapter }
enum ISOTPFrameType: String, Codable {
    case singleFrame, firstFrame, consecutiveFrame, flowControl, unknown, diagnosticPayload, adapterCommand, adapterResponse, timeout, transportError, validation
    static func classify(_ bytes: [UInt8]) -> Self {
        guard let first = bytes.first else { return .unknown }
        switch first >> 4 {
        case 0: return .singleFrame
        case 1: return .firstFrame
        case 2: return .consecutiveFrame
        case 3: return .flowControl
        default: return .unknown
        }
    }
}

struct ABSTrace: Codable, Equatable, Identifiable {
    var id = UUID()
    let timestamp: Date
    let direction: String
    let canID: UInt16?
    let rawCAN: [UInt8]?
    let payload: [UInt8]?
    let detail: String
    // Optional fields allow reading first-generation backups without claiming legacy visibility.
    var visibility: ABSTraceVisibility? = nil
    var frameType: ISOTPFrameType? = nil
    var service: UInt8? = nil
    var did: UInt16? = nil
    var subfunction: UInt8? = nil
    var positiveResponse: Bool? = nil
    var nrc: UInt8? = nil
    var adapterText: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, direction, canID, rawCAN, payload, detail, visibility, frameType, service, did, subfunction, positiveResponse, nrc, adapterText
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(timestamp, forKey: .timestamp); try c.encode(direction, forKey: .direction)
        try c.encode(canID, forKey: .canID); try c.encode(rawCAN, forKey: .rawCAN); try c.encode(payload, forKey: .payload)
        try c.encode(detail, forKey: .detail); try c.encode(visibility, forKey: .visibility); try c.encode(frameType, forKey: .frameType)
        try c.encode(service, forKey: .service); try c.encode(did, forKey: .did); try c.encode(subfunction, forKey: .subfunction)
        try c.encode(positiveResponse, forKey: .positiveResponse); try c.encode(nrc, forKey: .nrc); try c.encode(adapterText, forKey: .adapterText)
    }

    static func diagnostic(direction: String, canID: UInt16, payload: [UInt8], visibility: ABSTraceVisibility) -> Self {
        let sid = payload.first
        let negative = sid == 0x7F
        let decodedService = negative && payload.count >= 2 ? payload[1] : sid
        let positive = direction == "RX" && !negative && (sid == 0x58 || sid == 0x59 || sid == 0x62)
        let did: UInt16? = (sid == 0x22 || sid == 0x62) && payload.count >= 3 ? UInt16(payload[1]) << 8 | UInt16(payload[2]) : nil
        return Self(timestamp: Date(), direction: direction, canID: canID, rawCAN: nil, payload: payload,
                    detail: DiagnosticResponse.summary(payload), visibility: visibility, frameType: .diagnosticPayload,
                    service: decodedService, did: did,
                    subfunction: (sid == 0x19 || sid == 0x59) && payload.count >= 2 ? payload[1] : nil,
                    positiveResponse: direction == "RX" ? positive : nil,
                    nrc: negative && payload.count >= 3 ? payload[2] : nil)
    }

    var textLine: String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let address = canID.map { String(format: "0x%03X", $0) } ?? "—"
        let didText = did.map { String(format: " DID=%04X", $0) } ?? ""
        let subText = subfunction.map { String(format: " subfunction=%02X", $0) } ?? ""
        return "\(formatter.string(from: timestamp)) \(direction) \(visibility?.rawValue.uppercased() ?? "LEGACY") \(address) \(frameType?.rawValue ?? "unknown") raw=\(rawCAN?.hex ?? "unobserved") payload=\(payload?.hex ?? "—")\(didText)\(subText) \(detail)" + (adapterText.map { "\n  Adapter text: " + $0 } ?? "")
    }
}

struct ABSModuleInfo: Codable, Equatable {
    var vin: String?
    var partNumber: String?
    var hardware: String?
    var software: String?
    var strategy: String?
}

struct FordAsBuiltBlock: Codable, Equatable, Identifiable {
    let address: String
    let bytes: [UInt8]
    let source: String
    var checksum: UInt8? = nil
    var validationStatus = "Syntax valid; checksum and module applicability unverified"
    var id: String { address }
    var formatted: String { "\(address) \(bytes.hex)" }

    static func parse(_ text: String, source: String) throws -> [Self] {
        var result: [Self] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { throw ABSError.invalid("Expected address and hex data") }
            let address = parts[0].uppercased()
            guard address.range(of: "^[0-9A-F]{3}-[0-9A-F]{2}-[0-9A-F]{2}$", options: .regularExpression) != nil else { throw ABSError.invalid("Invalid As-Built address") }
            let hex = parts.dropFirst().joined().uppercased()
            guard !hex.isEmpty, hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { throw ABSError.invalid("Invalid As-Built hex bytes") }
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let end = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<end], radix: 16) else { throw ABSError.invalid("Invalid byte") }
                bytes.append(byte); index = end
            }
            guard !result.contains(where: { $0.address == address }) else { throw ABSError.invalid("Duplicate As-Built address") }
            result.append(Self(address: address, bytes: bytes, source: source))
        }
        guard !result.isEmpty else { throw ABSError.invalid("No As-Built blocks") }
        return result.sorted { $0.address < $1.address }
    }
}

struct ABSBackup: Codable, Equatable {
    var schemaVersion = 1
    let capturedAt: Date
    let addressing: FordModuleAddressing
    let module: ABSModuleInfo
    let dtcs: [DiagnosticCode]
    var configuration: [FordAsBuiltBlock]
    let transcript: [ABSTrace]
    let adapterExchanges: [DiagnosticTranscriptEntry]
    // Imported data is never represented as configuration read from the ECU.
    var configurationReadFromECU = false
    static func decode(_ data: Data) throws -> Self {
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.schemaVersion == 1 else { throw ABSError.invalid("Unsupported ABS backup schema") }
        try backup.addressing.validate()
        return backup
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

struct ABSComparisonRow: Identifiable {
    let label: String
    let original: String
    let replacement: String
    var id: String { label }
    var differs: Bool { original != replacement }
}

enum ABSComparison {
    static func rows(_ original: ABSBackup, _ replacement: ABSBackup) -> [ABSComparisonRow] {
        let a = original.module, b = replacement.module
        var rows = [ABSComparisonRow]()
        for (label, left, right) in [("Part number", a.partNumber, b.partNumber), ("VIN", a.vin, b.vin), ("Hardware", a.hardware, b.hardware), ("Software", a.software, b.software), ("Strategy", a.strategy, b.strategy)] {
            rows.append(.init(label: label, original: left ?? "Unavailable", replacement: right ?? "Unavailable"))
        }
        for address in Set(original.configuration.map(\.address) + replacement.configuration.map(\.address)).sorted() {
            rows.append(.init(label: address, original: original.configuration.first { $0.address == address }?.formatted ?? "Unavailable", replacement: replacement.configuration.first { $0.address == address }?.formatted ?? "Unavailable"))
        }
        return rows
    }
}

struct ABSPreflight {
    var readOnly = true
    var ignitionOn = false
    var engineOffConfirmed = false
    var voltageAcceptable = false
    var maintainerConnected = false
    var accessoriesOff = false
    var adapterConnected = false
    var stableCommunication = false
    var backupSaved = false
    var rpm: Double?
    var blockers: [String] {
        var result: [String] = []
        if readOnly { result.append("READ ONLY") }
        if !ignitionOn || !engineOffConfirmed { result.append("Confirm KOEO") }
        if let rpm, !rpm.isFinite || rpm < 0 || rpm > 0 { result.append("Engine RPM must be zero") }
        if !voltageAcceptable || !maintainerConnected { result.append("Confirm battery support") }
        if !accessoriesOff || !adapterConnected || !stableCommunication || !backupSaved { result.append("Complete connection, accessories and backup checks") }
        return result
    }
}

/// Future verified procedures must implement this boundary; no implementation is shipped.
protocol FordABSVerifiedProcedure {
    var evidence: String { get }
    func restore(configuration: [FordAsBuiltBlock], preflight: ABSPreflight) throws
    func clearDTCs(preflight: ABSPreflight) throws
    func serviceBleed(preflight: ABSPreflight) throws
}

/// Header-enabled OBDLink output with spaces or compact 11-bit headers.
/// Reject text/status output instead of interpreting incidental hex characters.
enum ABSCANParser {
    static func parseLine(_ line: String) throws -> CANFrame {
        guard let frame = try parse(line).first else { throw ABSError.invalid("Empty CAN line") }
        return frame
    }
    static func parse(_ response: String) throws -> [CANFrame] {
        var frames: [CANFrame] = []
        for rawLine in response.replacingOccurrences(of: ">", with: "").split(whereSeparator: \.isNewline) {
            let line = rawLine.filter { !$0.isWhitespace }.uppercased()
            guard !line.isEmpty else { continue }
            guard line.allSatisfy(\.isHexDigit), line.count >= 7,
                  let id = UInt16(line.prefix(3), radix: 16), id <= 0x7FF else { throw ABSError.invalid("Unexpected adapter output: \(rawLine)") }
            let data = String(line.dropFirst(3))
            guard data.count % 2 == 0, data.count <= 16 else { throw ABSError.invalid("Unsupported CAN line format (DLC/extended headers are not enabled)") }
            var bytes: [UInt8] = []
            var index = data.startIndex
            while index < data.endIndex {
                let end = data.index(index, offsetBy: 2)
                guard let byte = UInt8(data[index..<end], radix: 16) else { throw ABSError.invalid("Invalid CAN hex") }
                bytes.append(byte); index = end
            }
            frames.append(CANFrame(id: id, bytes: bytes))
        }
        guard !frames.isEmpty else { throw ABSError.invalid("No CAN response") }
        return frames
    }
}
