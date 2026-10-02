import XCTest
@testable import EdgeDiagnostics

final class ELMResponseTests: XCTestCase {
    func testATE0EchoRegression() {
        let raw = "ATE0\rOK\r\r"
        let response = ELMResponse(command: "ATE0", raw: raw)
        XCTAssertTrue(response.isAcknowledged)
        XCTAssertEqual(response.meaningfulLines, ["OK"])
        XCTAssertEqual(response.raw, raw)
    }

    func testAcknowledgmentWhitespaceEchoAndPrompts() {
        for raw in ["OK\r", "\r\rOK\r\r", "ATE0\r\rOK\r\r>", "ATE0\nOK\n>", "ATE0\r\nOK\r\n>", ">ATE0\rOK\r>", "ATE0\rOK\r", "ATE0\r\rOK\r\r", "ATE0\rOK\r>", "ATE0\nOK\n", "\rOK\r\r"] {
            let response = ELMResponse(command: "ATE0", raw: raw)
            XCTAssertTrue(response.isAcknowledged, raw)
            XCTAssertEqual(response.meaningfulLines, ["OK"])
            XCTAssertEqual(response.raw, raw)
        }
    }

    func testErrorsOverrideOKIncludingEchoedPromptWrappedErrors() {
        for raw in ["ERROR\r", "?\r", ">ATE0\r?\r>", "ATE0\rUNABLE TO CONNECT\r", "OK\rCAN ERROR\r"] {
            let response = ELMResponse(command: "ATE0", raw: raw)
            XCTAssertTrue(response.hasError)
            XCTAssertFalse(response.isAcknowledged)
        }
        XCTAssertFalse(ELMResponse(command: "ATE0", raw: "NOT OK").isAcknowledged)
        XCTAssertFalse(ELMResponse(command: "ATE0", raw: ">\r\r").isAcknowledged)
    }

    func testResetAndInformationalCommandsDoNotRequireOK() {
        for (command, raw, expected) in [
            ("ATZ", "\r\rELM327 v1.4b\r\r", "ELM327 v1.4b"),
            ("ATZ", "ATZ\rOBDLink EX STN2232\r>", "OBDLink EX STN2232"),
            ("ATI", ">ATI\rELM327 v1.4b\r>", "ELM327 v1.4b"),
            ("STDI", "STDI\rOBDLink EX\r", "OBDLink EX"),
            ("ATRV", "ATRV\r12.6V\r>", "12.6V")
        ] {
            let response = ELMResponse(command: command, raw: raw)
            XCTAssertTrue(response.isInformational)
            XCTAssertFalse(response.hasError)
            XCTAssertEqual(response.normalized, expected)
        }
    }

    func testEchoRemovalOnlyAppliesToFirstMatchingLineAndIsOptional() {
        XCTAssertEqual(ELMResponse(command: "ATE0", raw: "ate0\rOK").meaningfulLines, ["OK"])
        XCTAssertEqual(ELMResponse(command: "ATE0", raw: "OK\rATE0").meaningfulLines, ["OK", "ATE0"])
        XCTAssertEqual(ELMResponse(command: "ATE0", raw: "ATI\rOK").meaningfulLines, ["ATI", "OK"])
        XCTAssertEqual(ELMResponse(command: "ATE0", raw: "ATE0\rOK", removeEcho: false).meaningfulLines, ["ATE0", "OK"])
    }

    func testValidationAcceptsEchoedATAndSTSetupAndPreservesRawExports() throws {
        let transport = EchoInitializationTransport()
        let session = OBDClient(transport: transport).validateOriginalABS(preflight: .init(adapterConnected: true, ignitionOn: true, engineOff: true, noWriteSessionConfirmed: true))
        XCTAssertEqual(session.outcome, .responded)
        let raw = "ATE0\rOK\r\r"
        XCTAssertEqual(session.adapterExchanges.first { $0.command == "ATE0" }?.response, raw)
        XCTAssertTrue(session.transcript.contains { $0.adapterText == raw && $0.direction == "RX" })
        XCTAssertTrue(session.transcript.contains { $0.adapterText == "\r\rELM327 v1.4b\r\r" })
        XCTAssertEqual(session.adapterVoltage, 12.6)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: session.jsonData()) as? [String: Any])
        let exchanges = try XCTUnwrap(json["adapterExchanges"] as? [[String: Any]])
        XCTAssertEqual(exchanges.first { $0["command"] as? String == "ATE0" }?["response"] as? String, raw)
        // Byte comparison avoids Swift treating a final CR plus the exporter's LF
        // as a single CRLF grapheme at the substring boundary.
        XCTAssertNotNil(session.textData().range(of: Data(raw.utf8)))
        XCTAssertEqual(session.addressing.requestID, 0x760)
        XCTAssertEqual(session.addressing.responseID, 0x768)
    }

    func testGenericConnectionNormalizesEchoedIdentityWithoutLosingRaw() throws {
        let client = OBDClient(transport: EchoInitializationTransport())
        XCTAssertEqual(try client.connect(), "OBDLink EX • ELM327 v1.4b")
        XCTAssertEqual(try client.voltage(), 12.6)
        XCTAssertEqual(client.drainTranscript().first { $0.command == "ATE0" }?.response, "ATE0\rOK\r\r")
    }
}

private final class EchoInitializationTransport: OBDTransport, @unchecked Sendable {
    func open() throws {}
    func close() {}
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        switch command {
        case "ATZ": return "\r\rELM327 v1.4b\r\r"
        case "ATE0": return "ATE0\rOK\r\r"
        case "ATI": return ">ATI\rELM327 v1.4b\r>"
        case "STDI": return "STDI\rOBDLink EX\r>"
        case "ATRV": return "ATRV\r12.6V\r>"
        case "010C": return "41 0C 00 00"
        case "1902FF": return "768 03 59 02 FF"
        default: return ">\(command)\r\rOK\r\r>"
        }
    }
}
