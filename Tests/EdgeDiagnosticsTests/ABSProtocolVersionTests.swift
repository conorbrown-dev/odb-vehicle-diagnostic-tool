import XCTest
@testable import EdgeDiagnostics

final class ABSProtocolVersionTests: XCTestCase {
    private var ready: ABSValidationPreflight {
        .init(adapterConnected: true, ignitionOn: true, engineOff: true, noWriteSessionConfirmed: true)
    }
    private func run(_ transport: ProtocolVersionTransport) -> ABSValidationSession {
        OBDClient(transport: transport).validateOriginalABS(preflight: ready, operation: .protocolVersion)
    }
    func testOneSourcedReadNoDTCOrIdentificationFallbackAndExport() throws {
        let transport = ProtocolVersionTransport()
        let session = run(transport)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertTrue(session.absResponded)
        XCTAssertEqual(session.addressing.status, .observed)
        XCTAssertEqual(session.protocolVersionResult?.payload, [0x62, 0xE6, 0xF3, 0x0C])
        XCTAssertTrue(session.protocolVersionResult?.detail.contains("v2003.0") == true)
        XCTAssertEqual(session.dtcResult.status, .notAttempted)
        XCTAssertEqual(session.f187Result.status, .notAttempted)
        XCTAssertEqual(transport.commands.filter { !$0.hasPrefix("AT") && !$0.hasPrefix("ST") }, ["010C", "22E6F3"])
        XCTAssertTrue(session.adapterExchanges.contains { $0.command == "22E6F3" && $0.response == transport.reply })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: session.jsonData()) as? [String: Any])
        XCTAssertNotNil(json["protocolVersionResult"])
        XCTAssertTrue(String(decoding: session.textData(), as: UTF8.self).contains("62 E6 F3 0C"))
    }
    func testDocumentedVersionValuesAndTimeoutRetention() {
        for (byte, label) in [("0A", "v2001.0"), ("0B", "v2001.1"), ("0C", "v2003.0")] {
            let transport = ProtocolVersionTransport(); transport.reply = "768 04 62 E6 F3 " + byte
            XCTAssertTrue(run(transport).protocolVersionResult?.detail.contains(label) == true)
        }
        let transport = ProtocolVersionTransport(); transport.timeout = true
        let session = run(transport)
        XCTAssertEqual(session.outcome, .transportFailure)
        XCTAssertFalse(session.absResponded)
        XCTAssertEqual(session.protocolVersionResult?.status, .failed)
        XCTAssertEqual(transport.commands.filter { $0 == "22E6F3" }.count, 1)
        XCTAssertTrue(transport.closed)
        XCTAssertTrue(session.adapterExchanges.last?.response.contains("partial") == true)
    }

    func testUnknownVersionPreservedWithoutInferringDTCServices() {
        let transport = ProtocolVersionTransport(); transport.reply = "768 04 62 E6 F3 FF"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertTrue(session.protocolVersionResult?.detail.contains("Unknown") == true)
        XCTAssertFalse(transport.commands.contains("1902FF"))
    }
    func testNegativeResponseObservesPairAndStopsWithoutRetry() {
        let transport = ProtocolVersionTransport(); transport.reply = "768 03 7F 22 31"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .negativeResponse)
        XCTAssertTrue(session.absResponded)
        XCTAssertEqual(session.protocolVersionResult?.nrc, 0x31)
        XCTAssertEqual(session.protocolVersionResult?.status, .negative)
        XCTAssertEqual(transport.commands.filter { $0 == "22E6F3" }.count, 1)
        XCTAssertEqual(transport.commands.last, "22E6F3")
        XCTAssertTrue(transport.closed)
    }
    func testMalformedWrongIdentifierAndWrongCANIDCannotObservePair() {
        for raw in ["768 03 62 E6 F3", "768 05 62 E6 F3 0C 00", "768 04 62 E6 F2 0C", "769 04 62 E6 F3 0C", "768 03 7F 19 11"] {
            let transport = ProtocolVersionTransport(); transport.reply = raw
            let session = run(transport)
            XCTAssertFalse(session.absResponded, raw)
            XCTAssertNotEqual(session.addressing.status, .observed, raw)
            XCTAssertEqual(transport.commands.filter { $0 == "22E6F3" }.count, 1)
            XCTAssertTrue(transport.closed)
        }
    }
    func testVoltageAndProbeProfileRestrictionsBlockBeforeRead() {
        let transport = ProtocolVersionTransport(); transport.voltage = "7.7V"
        XCTAssertEqual(run(transport).outcome, .preflightBlocked)
        XCTAssertFalse(transport.commands.contains("22E6F3"))
        for identification in [false, true] {
            let transport = ProtocolVersionTransport()
            let session = OBDClient(transport: transport).validateOriginalABS(
                addressing: .init(requestID: 0x761, responseID: 0x769, evidence: "Unverified"),
                preflight: ready, readIdentification: identification, operation: .protocolVersion)
            XCTAssertEqual(session.outcome, .preflightBlocked)
            XCTAssertTrue(transport.commands.isEmpty)
        }
        XCTAssertTrue(SafetyPolicy.permits("22E6F3"))
        for command in ["22E6F2", "22E6F300", "1801FF00", "21FF", "2EE6F300", "1003"] {
            XCTAssertFalse(SafetyPolicy.permits(command), command)
        }
    }
}
private final class ProtocolVersionTransport: OBDTransport, @unchecked Sendable {
    var commands: [String] = []
    var reply = "768 04 62 E6 F3 0C"
    var voltage = "12.0V"
    var timeout = false
    var closed = false
    func open() throws {}
    func close() { closed = true }
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        commands.append(command)
        if command == "22E6F3", self.timeout {
            throw OBDTransportFailure(timedOut: true, partialResponse: "partial", message: "Timed out")
        }
        switch command {
        case "ATZ", "ATI": return "ELM327 v1.4b"
        case "STDI": return "OBDLink EX r2.7.1"
        case "ATRV": return voltage
        case "010C": return "410C0000"
        case "22E6F3": return reply
        default: return "OK"
        }
    }
}
