import XCTest
@testable import EdgeDiagnostics

final class ABSVINStartTests: XCTestCase {
    private var ready: ABSValidationPreflight {
        .init(adapterConnected: true, ignitionOn: true, engineOff: true, noWriteSessionConfirmed: true)
    }
    private func run(_ transport: VINStartTransport) -> ABSValidationSession {
        OBDClient(transport: transport).validateOriginalABS(preflight: ready, operation: .vinStart)
    }
    func testOneSourcedReadNoDTCOrIdentificationFallbackAndExport() throws {
        let transport = VINStartTransport()
        let session = run(transport)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertTrue(session.absResponded)
        XCTAssertEqual(session.addressing.status, .observed)
        XCTAssertEqual(session.vinStartResult?.payload, [0x62, 0xE3, 0x00, 0, 0, 0, 0x33])
        XCTAssertTrue(session.vinStartResult?.detail.contains("VIN character 1: 3") == true)
        XCTAssertEqual(session.dtcResult.status, .notAttempted)
        XCTAssertEqual(session.f187Result.status, .notAttempted)
        XCTAssertEqual(transport.commands.filter { !$0.hasPrefix("AT") && !$0.hasPrefix("ST") }, ["010C", "22E300"])
        XCTAssertTrue(session.adapterExchanges.contains { $0.command == "22E300" && $0.response == transport.reply })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: session.jsonData()) as? [String: Any])
        XCTAssertNotNil(json["vinStartResult"])
        XCTAssertTrue(String(decoding: session.textData(), as: UTF8.self).contains("62 E3 00 00 00 00 33"))
    }
    func testTimeoutRetainsPartialAndStops() {
        let transport = VINStartTransport(); transport.timeout = true
        let session = run(transport)
        XCTAssertEqual(session.outcome, .transportFailure)
        XCTAssertFalse(session.absResponded)
        XCTAssertEqual(session.vinStartResult?.status, .failed)
        XCTAssertEqual(transport.commands.filter { $0 == "22E300" }.count, 1)
        XCTAssertTrue(transport.closed)
        XCTAssertTrue(session.adapterExchanges.last?.response.contains("partial") == true)
    }
    func testFirstCharacterNeverBecomesFullModuleVIN() {
        let session = run(VINStartTransport())
        XCTAssertNil(session.module.vin)
        XCTAssertTrue(session.vinStartResult?.detail.contains("not a complete ABS VIN") == true)
        XCTAssertFalse(DiagnosticResponse.summary([0x62, 0xE3, 0, 0, 0, 0, 0x33]).contains("Unknown"))
    }
    func testNegativeResponseObservesPairAndStopsWithoutRetry() {
        let transport = VINStartTransport(); transport.reply = "768 03 7F 22 31"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .negativeResponse)
        XCTAssertTrue(session.absResponded)
        XCTAssertEqual(session.vinStartResult?.nrc, 0x31)
        XCTAssertEqual(session.vinStartResult?.status, .negative)
        XCTAssertEqual(transport.commands.filter { $0 == "22E300" }.count, 1)
        XCTAssertEqual(transport.commands.last, "22E300")
        XCTAssertTrue(transport.closed)
    }
    func testMalformedWrongIdentifierAndWrongCANIDCannotObservePair() {
        for raw in ["768 06 62 E3 00 00 00 33", "768 07 62 E3 00 01 00 00 33", "768 07 62 E3 00 00 00 00 49", "768 07 62 E3 00 00 00 00 FF", "768 07 62 E3 01 00 00 00 33", "769 07 62 E3 00 00 00 00 33", "768 03 7F 19 11"] {
            let transport = VINStartTransport(); transport.reply = raw
            let session = run(transport)
            XCTAssertFalse(session.absResponded, raw)
            XCTAssertNotEqual(session.addressing.status, .observed, raw)
            XCTAssertEqual(transport.commands.filter { $0 == "22E300" }.count, 1)
            XCTAssertTrue(transport.closed)
        }
    }
    func testVoltageAndProbeProfileRestrictionsBlockBeforeRead() {
        let transport = VINStartTransport(); transport.voltage = "7.7V"
        XCTAssertEqual(run(transport).outcome, .preflightBlocked)
        XCTAssertFalse(transport.commands.contains("22E300"))
        for identification in [false, true] {
            let transport = VINStartTransport()
            let session = OBDClient(transport: transport).validateOriginalABS(
                addressing: .init(requestID: 0x761, responseID: 0x769, evidence: "Unverified"),
                preflight: ready, readIdentification: identification, operation: .vinStart)
            XCTAssertEqual(session.outcome, .preflightBlocked)
            XCTAssertTrue(transport.commands.isEmpty)
        }
        XCTAssertTrue(SafetyPolicy.permits("22E300"))
        for command in ["22E301", "22E302", "22E303", "22E304", "22F190", "22E30000", "2EE30000", "1003"] {
            XCTAssertFalse(SafetyPolicy.permits(command), command)
        }
    }
}
private final class VINStartTransport: OBDTransport, @unchecked Sendable {
    var commands: [String] = []
    var reply = "768 07 62 E3 00 00 00 00 33"
    var voltage = "12.0V"
    var timeout = false
    var closed = false
    func open() throws {}
    func close() { closed = true }
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        commands.append(command)
        if command == "22E300", self.timeout {
            throw OBDTransportFailure(timedOut: true, partialResponse: "partial", message: "Timed out")
        }
        switch command {
        case "ATZ", "ATI": return "ELM327 v1.4b"
        case "STDI": return "OBDLink EX r2.7.1"
        case "ATRV": return voltage
        case "010C": return "410C0000"
        case "22E300": return reply
        default: return "OK"
        }
    }
}
