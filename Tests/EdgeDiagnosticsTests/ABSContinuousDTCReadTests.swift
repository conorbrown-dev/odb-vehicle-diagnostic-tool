import XCTest
@testable import EdgeDiagnostics

final class ABSContinuousDTCReadTests: XCTestCase {
    private var ready: ABSValidationPreflight {
        .init(adapterConnected: true, ignitionOn: true, engineOff: true, noWriteSessionConfirmed: true)
    }
    private func run(_ transport: ContinuousDTCTransport) -> ABSValidationSession {
        OBDClient(transport: transport).validateOriginalABS(preflight: ready, operation: .fordContinuousDTCs)
    }
    func testSingleDocumentedReadRetainsRawRecordsWithoutUDSDecoding() throws {
        let transport = ContinuousDTCTransport()
        let session = run(transport)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertTrue(session.absResponded)
        XCTAssertEqual(session.fordContinuousDTCResult?.payload, [0x58, 1, 0x52, 0x34, 0x60])
        XCTAssertEqual(session.fordContinuousDTCResult?.status, .positive)
        XCTAssertEqual(session.dtcResult.status, .notAttempted)
        XCTAssertEqual(session.f187Result.status, .notAttempted)
        XCTAssertNil(session.protocolVersionResult)
        XCTAssertEqual(session.dtcs.map(\.id), ["C1234"])
        XCTAssertNil(session.dtcs.first?.statusByte)
        XCTAssertNil(session.dtcs.first?.failureTypeByte)
        XCTAssertNil(session.dtcs.first?.udsStatusSummary)
        XCTAssertEqual(transport.commands.filter { !$0.hasPrefix("AT") && !$0.hasPrefix("ST") }, ["010C", "1800FF00"])
        XCTAssertTrue(session.adapterExchanges.contains { $0.command == "1800FF00" && $0.response == transport.reply })
        XCTAssertTrue(String(decoding: session.textData(), as: UTF8.self).contains("58 01 52 34 60"))
        XCTAssertTrue(session.transcript.contains { $0.payload == [0x58, 1, 0x52, 0x34, 0x60] && $0.positiveResponse == true })
    }
    func testActualVehicleThreeRecordCapture() throws {
        let frames = try ABSCANParser.parse("768 10 0B 58 03 A9 00 E0 52 \r768 21 77 E0 50 9E 20 00 00 \r\r")
        let payload = try ISOTP.assemble(frames)
        XCTAssertEqual(payload, [0x58, 3, 0xA9, 0, 0xE0, 0x52, 0x77, 0xE0, 0x50, 0x9E, 0x20])
        let records = try FordABSService.decodeContinuousDTCs(payload)
        XCTAssertEqual(records.map(\.code), ["B2900", "C1277", "C109E"])
        XCTAssertEqual(records.map(\.rawStatus), [0xE0, 0xE0, 0x20])
        XCTAssertTrue(records.allSatisfy { $0.diagnosticCode.statusByte == nil && $0.diagnosticCode.failureTypeByte == nil })
        let transport = ContinuousDTCTransport()
        transport.reply = "768 10 0B 58 03 A9 00 E0 52 \r768 21 77 E0 50 9E 20 00 00 \r\r"
        let session = run(transport)
        XCTAssertEqual(session.fordContinuousDTCRecords, records)
        XCTAssertTrue(String(decoding: session.textData(), as: UTF8.self).contains("B2900 Ford raw status=E0"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: session.jsonData()) as? [String: Any])
        XCTAssertNotNil(json["fordContinuousDTCRecords"])
    }

    func testZeroRecordResponseAndCappedCountValidation() throws {
        let transport = ContinuousDTCTransport(); transport.reply = "768 02 58 00"
        XCTAssertEqual(run(transport).outcome, .responded)
        let record: [UInt8] = [0x52, 0x34, 0x60]
        let capped: [UInt8] = [0x58, 255] + Array(repeating: record, count: 256).flatMap { $0 }
        XCTAssertNoThrow(try DiagnosticResponse.validate(capped, request: [0x18, 0, 0xFF, 0]))
        XCTAssertThrowsError(try DiagnosticResponse.validate([0x58, 255, 0x52, 0x34, 0x60], request: [0x18, 0, 0xFF, 0]))
    }
    func testNegativeAndMalformedResponsesStopWithoutFallback() {
        for (reply, negative) in [("768 03 7F 18 11", true), ("768 01 58", false), ("768 02 58 01", false), ("768 04 58 01 52 34", false), ("769 02 58 00", false), ("768 03 7F 19 11", false)] {
            let transport = ContinuousDTCTransport(); transport.reply = reply
            let session = run(transport)
            XCTAssertEqual(session.absResponded, negative, reply)
            if negative { XCTAssertEqual(session.fordContinuousDTCResult?.nrc, 0x11) }
            XCTAssertEqual(transport.commands.last, "1800FF00")
            XCTAssertEqual(transport.commands.filter { $0 == "1800FF00" }.count, 1)
            XCTAssertTrue(transport.closed)
        }
    }
    func testTimeoutLowVoltageAndReadOnlyBoundary() {
        let timeout = ContinuousDTCTransport(); timeout.timeout = true
        let session = run(timeout)
        XCTAssertEqual(session.outcome, .transportFailure)
        XCTAssertTrue(session.adapterExchanges.last?.response.contains("partial") == true)
        XCTAssertTrue(timeout.closed)
        let low = ContinuousDTCTransport(); low.voltage = "7.7V"
        XCTAssertEqual(run(low).outcome, .preflightBlocked)
        XCTAssertFalse(low.commands.contains("1800FF00"))
        XCTAssertTrue(SafetyPolicy.permits("1800FF00"))
        for command in ["1801FF00", "18000000", "1800FF0000", "14FF00", "1003", "2701"] { XCTAssertFalse(SafetyPolicy.permits(command), command) }
    }
    func testRealProtocolVersionReplyIsRecognizedInTrace() {
        for payload: [UInt8] in [[0x22, 0xE6, 0xF3], [0x62, 0xE6, 0xF3, 0x0C]] {
            let text = DiagnosticResponse.summary(payload)
            XCTAssertTrue(text.contains("Ford diagnostic specification version"))
            XCTAssertFalse(text.contains("Unknown response"))
        }
    }
}
private final class ContinuousDTCTransport: OBDTransport, @unchecked Sendable {
    var commands: [String] = []
    var reply = "768 05 58 01 52 34 60"
    var voltage = "11.3V"
    var timeout = false
    var closed = false
    func open() throws {}
    func close() { closed = true }
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        commands.append(command)
        if command == "1800FF00", self.timeout { throw OBDTransportFailure(timedOut: true, partialResponse: "partial", message: "Timed out") }
        switch command {
        case "ATZ", "ATI": return "ELM327 v1.4b"
        case "STDI": return "OBDLink EX r2.7.1"
        case "ATRV": return voltage
        case "010C": return "410C0000"
        case "1800FF00": return reply
        default: return "OK"
        }
    }
}
