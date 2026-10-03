import Foundation

/// Ford ABS domain layer. Only reads already present in the project are used.
/// Neither UDS service support nor addressing applicability is assumed for a Fusion.
enum FordABSService {
    static func decodeDTCs(_ payload: [UInt8]) throws -> [DiagnosticCode] {
        _ = try DiagnosticResponse.validate(payload, request: [0x19, 0x02, 0xFF])
        return stride(from: 3, to: payload.count, by: 4).map { offset in
            let first = payload[offset], second = payload[offset + 1]
            let code = "\(["P", "C", "B", "U"][Int(first >> 6)])\((first >> 4) & 3)\(String(format: "%01X%02X", first & 15, second))"
            return DiagnosticCode(id: code, source: "Ford enhanced ABS", module: "ABS", network: "HS-CAN", statusByte: payload[offset + 3], failureTypeByte: payload[offset + 2])
        }
    }

    static func decodeContinuousDTCs(_ payload: [UInt8]) throws -> [FordContinuousDTCRecord] {
        _ = try DiagnosticResponse.validate(payload, request: [0x18, 0x00, 0xFF, 0x00])
        return stride(from: 2, to: payload.count, by: 3).map { offset in
            FordContinuousDTCRecord(codeBytes: [payload[offset], payload[offset + 1]], rawStatus: payload[offset + 2])
        }
    }

    // Fail closed even if the UI or a future caller supplies a complete checklist.
    // Do not add requests here without a verified procedure and confirmation/backup/readback design.
    static func restore(configuration: [FordAsBuiltBlock], preflight: ABSPreflight) throws { throw ABSError.unsupported }
    static func clearDTCs(preflight: ABSPreflight) throws { throw ABSError.unsupported }
    static func serviceBleed(preflight: ABSPreflight) throws { throw ABSError.unsupported }
}

/// Ford CGDS two-byte DTC and raw status; never interpreted as UDS flags.
struct FordContinuousDTCRecord: Codable, Equatable {
    let codeBytes: [UInt8]
    let rawStatus: UInt8
    var code: String {
        guard codeBytes.count == 2 else { return "Invalid DTC" }
        let first = codeBytes[0]
        return "\(["P", "C", "B", "U"][Int(first >> 6)])\((first >> 4) & 3)\(String(format: "%01X%02X", first & 15, codeBytes[1]))"
    }
    var diagnosticCode: DiagnosticCode {
        DiagnosticCode(id: code, source: "Ford continuous ABS (raw status retained separately)", module: "ABS", network: "HS-CAN")
    }
}
