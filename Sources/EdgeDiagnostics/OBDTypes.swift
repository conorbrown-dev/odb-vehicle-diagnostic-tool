import Foundation

/// A raw, read-only adapter exchange retained with a snapshot so an unfamiliar
/// Ford response can be decoded again later without reconnecting to the vehicle.
struct DiagnosticTranscriptEntry: Equatable, Codable, Identifiable {
    let timestamp: Date
    let command: String
    let response: String

    var id: String { "\(timestamp.timeIntervalSince1970)-\(command)-\(response)" }
}

struct DiagnosticCode: Identifiable, Equatable, Codable {
    let id: String
    let source: String
    /// For an enhanced UDS record this is the reporting ECU. For an addressed
    /// standard-OBD fallback it is only the ECU that returned the combined response;
    /// the originating module for each B/C/U record remains unknown.
    let module: String?
    /// HS-CAN or MS-CAN, when known.
    let network: String?
    /// The UDS DTC status byte, retained verbatim so a later catalog can reinterpret it.
    let statusByte: UInt8?
    /// The third UDS DTC byte. It is a failure-type byte only when the responding
    /// ECU uses the SAE/OBD DTC format; other UDS formats define it differently.
    let failureTypeByte: UInt8?

    init(id: String, source: String, module: String? = nil, network: String? = nil, statusByte: UInt8? = nil, failureTypeByte: UInt8? = nil) {
        self.id = id
        self.source = source
        self.module = module
        self.network = network
        self.statusByte = statusByte
        self.failureTypeByte = failureTypeByte
    }

    private enum CodingKeys: String, CodingKey { case id, source, module, network, statusByte, failureTypeByte }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        source = try values.decode(String.self, forKey: .source)
        module = try values.decodeIfPresent(String.self, forKey: .module)
        network = try values.decodeIfPresent(String.self, forKey: .network)
        statusByte = try values.decodeIfPresent(UInt8.self, forKey: .statusByte)
        failureTypeByte = try values.decodeIfPresent(UInt8.self, forKey: .failureTypeByte)
    }

    var displayIdentifier: String {
        guard let failureTypeByte else { return id }
        return "\(id):\(String(format: "%02X", failureTypeByte))"
    }

    var hasEnhancedModuleContext: Bool { source.contains("Ford enhanced") }

    /// ISO 14229 DTC-status flags. A confirmed record can be historical; only
    /// `test failed` describes the most recent test result.
    var udsStatusSummary: String? {
        guard let statusByte else { return nil }
        var flags: [String] = []
        if statusByte & 0x01 != 0 { flags.append("test failed") }
        if statusByte & 0x02 != 0 { flags.append("failed this drive cycle") }
        if statusByte & 0x04 != 0 { flags.append("pending") }
        if statusByte & 0x08 != 0 { flags.append("confirmed") }
        if statusByte & 0x10 != 0 { flags.append("test incomplete since clear") }
        if statusByte & 0x20 != 0 { flags.append("failed since clear") }
        if statusByte & 0x40 != 0 { flags.append("test incomplete this cycle") }
        if statusByte & 0x80 != 0 { flags.append("warning indicator requested") }
        return flags.isEmpty ? "no active status flags" : flags.joined(separator: ", ")
    }
}

struct ModuleIdentification: Equatable, Codable {
    let vin: String?
    let calibrationID: String?
    let ecuName: String?
}

struct VehicleProfile: Equatable, Codable {
    let vin: String
    let year: String?
    let make: String?
    let model: String?
    let trim: String?
    let engine: String?
    let driveType: String?

    var summary: String {
        [year, make, model, trim].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var powertrainSummary: String? {
        [engine, driveType].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ").nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct LiveSnapshot: Equatable, Codable {
    var engineRPM: Double?
    var speedKPH: Double?
    var coolantCelsius: Double?
    var intakeAirCelsius: Double?
    var throttlePercent: Double?
    var controlModuleVoltage: Double?
    var capturedAt = Date()
}

struct TelemetryPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let engineRPM: Double?
    let speedKPH: Double?
    let coolantCelsius: Double?
    let intakeAirCelsius: Double?
    let throttlePercent: Double?
    let controlModuleVoltage: Double?

    init(snapshot: LiveSnapshot) {
        timestamp = snapshot.capturedAt
        engineRPM = snapshot.engineRPM
        speedKPH = snapshot.speedKPH
        coolantCelsius = snapshot.coolantCelsius
        intakeAirCelsius = snapshot.intakeAirCelsius
        throttlePercent = snapshot.throttlePercent
        controlModuleVoltage = snapshot.controlModuleVoltage
    }
}

struct MonitorStatus: Equatable, Codable {
    let malfunctionIndicatorOn: Bool
    let confirmedCodeCount: Int
}

struct FreezeFrame: Equatable, Codable {
    let triggeringCode: String
    var engineLoadPercent: Double?
    var engineRPM: Double?
    var speedKPH: Double?
    var coolantCelsius: Double?
    var intakeAirCelsius: Double?
    var shortTermFuelTrimPercent: Double?
    var longTermFuelTrimPercent: Double?
    var runtimeSeconds: Double?
}

enum OBDClientError: LocalizedError {
    case unsafeCommand(String)
    case noData(String)
    case adapter(String)
    case negativeResponse(service: UInt8, code: UInt8)

    var errorDescription: String? {
        switch self {
        case .unsafeCommand(let command): "Blocked unsafe diagnostic command: \(command)"
        case .noData(let response): "No usable vehicle data in response: \(response)"
        case .adapter(let message): message
        case .negativeResponse(let service, let code):
            "UDS service 0x\(String(format: "%02X", service)) was rejected: \(udsNegativeResponseDescription(code)) (NRC 0x\(String(format: "%02X", code)))."
        }
    }

    private func udsNegativeResponseDescription(_ code: UInt8) -> String {
        switch code {
        case 0x10: "general reject"
        case 0x11: "service not supported"
        case 0x12: "sub-function not supported"
        case 0x13: "incorrect message length or format"
        case 0x21: "busy; repeat request later"
        case 0x22: "conditions not correct"
        case 0x31: "request out of range"
        case 0x33: "security access required"
        case 0x78: "response pending"
        default: "unknown negative response"
        }
    }
}
