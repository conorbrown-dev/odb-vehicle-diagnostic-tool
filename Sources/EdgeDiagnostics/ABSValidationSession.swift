import Foundation

struct ABSValidationPreflight: Codable, Equatable {
    var adapterConnected = false
    var ignitionOn = false
    var engineOff = false
    var highSpeedCAN = true
    var readOnly = true
    var noWriteSessionConfirmed = false
    var rpm: Double?
    var blockers: [String] {
        var result: [String] = []
        if !adapterConnected { result.append("Connect the OBDLink EX") }
        if !ignitionOn || !engineOff { result.append("Confirm ignition ON / engine OFF") }
        if !highSpeedCAN || !readOnly { result.append("HS-CAN and READ ONLY are required") }
        if !noWriteSessionConfirmed { result.append("Close other diagnostic tools and confirm no programming session is active") }
        if let rpm, !rpm.isFinite || rpm < 0 || rpm > 0 { result.append("Engine RPM is nonzero or invalid; stop validation") }
        return result
    }
}

enum ABSReadOperation: String {
    case dtcs
    case protocolVersion
    case fordContinuousDTCs
}

enum ABSValidationOutcome: String, Codable {
    case responded = "ABS responded"
    case noResponse = "ABS did not respond"
    case trafficWithoutResponse = "CAN traffic observed but no valid ABS response"
    case negativeResponse = "Negative diagnostic response"
    case transportFailure = "Transport/ISO-TP failure"
    case adapterFailure = "Adapter failure"
    case preflightBlocked = "Preflight blocked"
}

struct ABSValidationFailure: LocalizedError {
    let outcome: ABSValidationOutcome
    let message: String
    var errorDescription: String? { message }
}

struct ABSReadResult: Codable, Equatable {
    enum Status: String, Codable { case notAttempted, positive, negative, failed }
    var status: Status = .notAttempted
    var payload: [UInt8]?
    var nrc: UInt8?
    var detail: String = "Not requested"
}

struct ABSValidationSession: Codable, Equatable, Identifiable {
    var schemaVersion = 1
    var id = UUID()
    let startedAt: Date
    var finishedAt: Date?
    let vehicleVIN: String?
    var vinSource: String = "Already known vehicle VIN; not read from ABS"
    var adapterInformation: String
    var adapterVoltage: Double?
    var engineRPM: Double?
    var preflight: ABSValidationPreflight
    var addressing: FordModuleAddressing
    var outcome: ABSValidationOutcome = .preflightBlocked
    var detail = "Not started"
    var module = ABSModuleInfo()
    var dtcs: [DiagnosticCode] = []
    var dtcResult = ABSReadResult()
    var f187Result = ABSReadResult()
    var protocolVersionResult: ABSReadResult?
    var fordContinuousDTCResult: ABSReadResult?
    var transcript: [ABSTrace] = []
    var adapterExchanges: [DiagnosticTranscriptEntry] = []
    var requiresReconnect = false
    var absResponded: Bool { addressing.status == .observed && ([.positive, .negative].contains(dtcResult.status) || protocolVersionResult.map { [.positive, .negative].contains($0.status) } == true || fordContinuousDTCResult.map { [.positive, .negative].contains($0.status) } == true) }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer(); try value.encode(formatter.string(from: date))
        }
        return encoder
    }
    func jsonData() throws -> Data { try Self.jsonEncoder().encode(self) }
    func textData() -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = """
        ABS Validation Session (schema \(schemaVersion))
        Session: \(id)
        Start: \(formatter.string(from: startedAt))
        Finish: \(finishedAt.map(formatter.string) ?? "Incomplete")
        Vehicle VIN: \(vehicleVIN ?? "Unavailable") (\(vinSource))
        Adapter: \(adapterInformation)
        Adapter voltage: \(adapterVoltage.map { String(format: "%.2f V", $0) } ?? "Unavailable")
        Engine RPM: \(engineRPM.map { String(format: "%.0f", $0) } ?? "Unavailable; user confirms engine OFF")
        Network: \(addressing.network.rawValue), \(addressing.addressingBits)-bit
        Request: \(String(format: "0x%03X", addressing.requestID)) Response: \(String(format: "0x%03X", addressing.responseID))
        Addressing: \(addressing.status.rawValue)
        Observed at: \(addressing.observedAt.map(formatter.string) ?? "Not observed")
        Source: \(addressing.evidence)
        Outcome: \(outcome.rawValue)
        ABS responded: \(absResponded)
        Detail: \(detail)
        Part number (F187): \(module.partNumber ?? "Unavailable")
        ABS VIN / hardware / software / strategy: unavailable (not requested)
        DTC result: \(dtcResult.status.rawValue) \(dtcResult.detail) raw=\(dtcResult.payload?.hex ?? "Unavailable")
        Ford continuous DTC raw result: \(fordContinuousDTCResult?.status.rawValue ?? "notAttempted") \(fordContinuousDTCResult?.detail ?? "Not requested") raw=\(fordContinuousDTCResult?.payload?.hex ?? "Unavailable")
        Protocol version E6F3 result: \(protocolVersionResult?.status.rawValue ?? "notAttempted") \(protocolVersionResult?.detail ?? "Not requested") raw=\(protocolVersionResult?.payload?.hex ?? "Unavailable")
        F187 result: \(f187Result.status.rawValue) \(f187Result.detail) raw=\(f187Result.payload?.hex ?? "Unavailable") NRC=\(f187Result.nrc.map { String(format: "%02X", $0) } ?? "—")
        Reconnect required: \(requiresReconnect)
        READ ONLY: \(preflight.readOnly). Ignition ON confirmed: \(preflight.ignitionOn). Engine OFF confirmed: \(preflight.engineOff).
        No external write session confirmed: \(preflight.noWriteSessionConfirmed).
        TX formatting and automatic FC are LOGICAL unless actually reported by the adapter. Logical FC means instructed/expected, not proof of transmission. RX timestamps are host processing times.
        """
        let codes = dtcs.map { "\($0.displayIdentifier) status=\($0.statusByte.map { String(format: "%02X", $0) } ?? "—") \($0.udsStatusSummary ?? "")" }.joined(separator: "\n")
        let events = transcript.map(\.textLine).joined(separator: "\n")
        let raw = adapterExchanges.map { "\(formatter.string(from: $0.timestamp)) COMMAND \($0.command)\nRESPONSE \($0.response)" }.joined(separator: "\n")
        return Data((header + "\n\nDTCs:\n" + codes + "\n\nChronological trace:\n" + events + "\n\nRaw adapter exchanges:\n" + raw + "\n").utf8)
    }
}
