import XCTest
@testable import EdgeDiagnostics

final class ABSDiagnosticsTests: XCTestCase {
    // Synthetic addresses/frames are fixtures, never vehicle verification evidence.
    private var addressing: FordModuleAddressing { .init(responseID: 0x768, evidence: "Synthetic test fixture only") }

    func testISOTPRoundTripAndSequenceWrap() throws {
        for count in [1, 7, 8, 20, 130, 4095] {
            let payload = (0..<count).map { UInt8($0 & 255) }
            XCTAssertEqual(try ISOTP.assemble(ISOTP.frames(payload: payload, id: 0x768)), payload)
        }
        XCTAssertThrowsError(try ISOTP.frames(payload: [], id: 0x768))
        XCTAssertThrowsError(try ISOTP.frames(payload: [1], id: 0x800))
    }

    func testISOTPRejectsIncompleteWrongSequenceAndMixedIDs() throws {
        let frames = try ISOTP.frames(payload: Array(repeating: 0xAA, count: 20), id: 0x768)
        XCTAssertThrowsError(try ISOTP.assemble(Array(frames.prefix(1))))
        var wrong = frames
        wrong[1] = .init(id: 0x768, bytes: [0x22] + frames[1].bytes.dropFirst())
        XCTAssertThrowsError(try ISOTP.assemble(wrong))
        wrong[1] = .init(id: 0x769, bytes: frames[1].bytes)
        XCTAssertThrowsError(try ISOTP.assemble(wrong))
        XCTAssertThrowsError(try ISOTP.assemble([.init(id: 0x768, bytes: [0x07, 0x59])]))
    }

    func testDiagnosticPositiveAndNegativeResponses() throws {
        XCTAssertEqual(try DiagnosticResponse.validate([0x59, 2, 0xFF], request: [0x19, 2, 0xFF]), [0x59, 2, 0xFF])
        XCTAssertThrowsError(try DiagnosticResponse.validate([0x59, 2, 0xFF, 1], request: [0x19, 2, 0xFF]))
        XCTAssertThrowsError(try DiagnosticResponse.validate([0x62, 0xF1, 0x90, 1], request: [0x22, 0xF1, 0x87]))
        for nrc: UInt8 in [0x11, 0x33, 0x78] {
            XCTAssertThrowsError(try DiagnosticResponse.validate([0x7F, 0x19, nrc], request: [0x19, 2, 0xFF])) { error in
                guard case OBDClientError.negativeResponse(let service, let code) = error else { return XCTFail("Wrong error") }
                XCTAssertEqual(service, 0x19); XCTAssertEqual(code, nrc)
            }
        }
        XCTAssertThrowsError(try DiagnosticResponse.validate([0x7F, 0x22, 0x11], request: [0x19, 2, 0xFF]))
    }

    func testCANParserRejectsStatusTextAndPreservesHeaders() throws {
        XCTAssertEqual(try ABSCANParser.parse("768 03 59 02 FF\r>"), [.init(id: 0x768, bytes: [3, 0x59, 2, 0xFF])])
        XCTAssertEqual(try ABSCANParser.parse("768035902FF\r>").first?.id, 0x768)
        for text in ["NO DATA", "CAN ERROR", "SEARCHING...", "768 8 03 59 02 FF", "18DAF110 03 59 02 FF", ""] {
            XCTAssertThrowsError(try ABSCANParser.parse(text))
        }
    }

    func testAsBuiltParsingFormattingAndValidation() throws {
        let blocks = try FordAsBuiltBlock.parse("760-01-01 1234 AB CD\n760-02-01 00FF", source: "Manual fixture")
        XCTAssertEqual(blocks[0].bytes, [0x12, 0x34, 0xAB, 0xCD])
        XCTAssertEqual(blocks[0].formatted, "760-01-01 12 34 AB CD")
        XCTAssertEqual(try FordAsBuiltBlock.parse(blocks.map(\.formatted).joined(separator: "\n"), source: "Manual fixture"), blocks)
        XCTAssertNil(blocks[0].checksum)
        for invalid in ["", "760-1-01 00", "760-01-01 0", "760-01-01 ZZ", "760-01-01 00\n760-01-01 FF"] {
            XCTAssertThrowsError(try FordAsBuiltBlock.parse(invalid, source: "Test"))
        }
    }

    func testBackupRoundTripAndFutureSchemaRejection() throws {
        var backup = fixtureBackup()
        backup.configuration = try FordAsBuiltBlock.parse("760-01-01 1234", source: "Imported; unverified")
        XCTAssertEqual(try ABSBackup.decode(backup.encoded()), backup)
        backup.schemaVersion = 2
        XCTAssertThrowsError(try ABSBackup.decode(backup.encoded()))
    }

    func testComparisonDisplaysDifferencesWithoutCompatibilityVerdict() throws {
        let original = fixtureBackup(software: "ABC-A")
        var replacement = fixtureBackup(software: "ABC-B")
        replacement.configuration = try FordAsBuiltBlock.parse("760-01-01 00", source: "Fixture")
        let rows = ABSComparison.rows(original, replacement)
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.label == "Software" }).differs)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.label == "VIN" }).differs)
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.label == "760-01-01" }).differs)
    }

    func testPreflightDefaultsReadOnlyAndBlocksRunningEngine() {
        var state = ABSPreflight()
        XCTAssertTrue(state.blockers.contains("READ ONLY"))
        state.readOnly = false; state.ignitionOn = true; state.engineOffConfirmed = true
        state.voltageAcceptable = true; state.maintainerConnected = true; state.accessoriesOff = true
        state.adapterConnected = true; state.stableCommunication = true; state.backupSaved = true
        state.rpm = 700
        XCTAssertTrue(state.blockers.contains("Engine RPM must be zero"))
        state.rpm = .nan
        XCTAssertFalse(state.blockers.isEmpty)
        state.rpm = 0
        XCTAssertTrue(state.blockers.isEmpty) // Does not authorize any command.
        for command in ["14FFFFFF", "2E123400", "1101", "3101FFFF", "2701", "1003", "04", "ATMA", "STPX"] {
            XCTAssertFalse(SafetyPolicy.permits(command))
        }
    }

    func testStateChangingServiceBoundaryAlwaysFailsClosed() {
        let state = ABSPreflight()
        XCTAssertThrowsError(try FordABSService.restore(configuration: [], preflight: state))
        XCTAssertThrowsError(try FordABSService.clearDTCs(preflight: state))
        XCTAssertThrowsError(try FordABSService.serviceBleed(preflight: state))
    }

    func testAddressEvidenceIsRequiredBeforeSending() {
        let transport = ABSFixtureTransport()
        XCTAssertThrowsError(try OBDClient(transport: transport).readABS(addressing: .init(responseID: 0x768, evidence: "")))
        XCTAssertTrue(transport.commands.isEmpty)
    }

    func testABSZeroDTCResponseEstablishesCommunicationAndRestoresHeader() throws {
        let transport = ABSFixtureTransport()
        let client = OBDClient(transport: transport)
        let backup = try client.readABS(addressing: addressing, readIdentification: true)
        XCTAssertTrue(backup.dtcs.isEmpty)
        XCTAssertEqual(backup.module.partNumber, "ABC")
        XCTAssertNil(backup.module.software)
        XCTAssertEqual(transport.commands.last, "ATSH7DF")
        XCTAssertFalse(transport.closed)
        XCTAssertTrue(backup.transcript.contains { $0.direction == "TX" && $0.rawCAN == nil })
        XCTAssertTrue(backup.transcript.contains { $0.rawCAN == [3, 0x59, 2, 0xFF] })
        XCTAssertFalse(backup.configurationReadFromECU)
    }

    func testABSRetainsManufacturerDTCBytes() throws {
        let transport = ABSFixtureTransport()
        transport.dtcReply = "768 07 59 02 FF C1 50 96 0D"
        let backup = try OBDClient(transport: transport).readABS(addressing: addressing, readIdentification: false)
        XCTAssertEqual(backup.dtcs.first?.displayIdentifier, "U0150:96")
        XCTAssertEqual(backup.dtcs.first?.statusByte, 0x0D)
    }

    func testABSAbortsOnNegativeUnexpectedMissingOrIncompleteResponse() {
        for response in ["768 03 7F 19 11", "768 03 7F 19 78", "768 03 62 02 FF", "769 03 59 02 FF", "NO DATA", "768 10 0B 59 02 FF 12 34 56"] {
            let transport = ABSFixtureTransport(); transport.dtcReply = response
            let client = OBDClient(transport: transport)
            XCTAssertThrowsError(try client.readABS(addressing: addressing))
            XCTAssertTrue(transport.closed)
            XCTAssertEqual(transport.commands.last, "1902FF")
            XCTAssertEqual(client.capturedABSTrace().last?.direction, "ERROR")
            XCTAssertTrue(client.drainTranscript().contains { $0.command == "1902FF" && $0.response == response })
        }
    }

    func testOptionalIdentificationNegativeStopsWithoutMoreCommands() {
        let transport = ABSFixtureTransport(); transport.identificationReply = "768 03 7F 22 31"
        let client = OBDClient(transport: transport)
        XCTAssertThrowsError(try client.readABS(addressing: addressing, readIdentification: true))
        XCTAssertTrue(transport.closed)
        XCTAssertEqual(transport.commands.last, "22F187")
        XCTAssertTrue(client.capturedABSTrace().contains { $0.payload == [0x59, 2, 0xFF] })
    }

    func testABSTimeoutClosesAndNeverRetries() {
        let transport = ABSFixtureTransport(); transport.timeout = true
        let client = OBDClient(transport: transport)
        XCTAssertThrowsError(try client.readABS(addressing: addressing))
        XCTAssertTrue(transport.closed)
        XCTAssertEqual(transport.commands.filter { $0 == "1902FF" }.count, 1)
        XCTAssertEqual(transport.commands.last, "1902FF")
        XCTAssertTrue(client.drainTranscript().contains { $0.response.contains("TRANSPORT ERROR") })
    }

    func testAdapterSetupMustBeAcknowledgedAndRestoreFailureCloses() {
        for command in ["ATH1", "ATSH7DF"] {
            let transport = ABSFixtureTransport(); transport.failCommand = command
            XCTAssertThrowsError(try OBDClient(transport: transport).readABS(addressing: addressing))
            XCTAssertTrue(transport.closed)
            XCTAssertEqual(transport.commands.last, command)
        }
    }

    private func fixtureBackup(software: String? = nil) -> ABSBackup {
        ABSBackup(capturedAt: Date(timeIntervalSince1970: 100), addressing: addressing,
                  module: ABSModuleInfo(software: software), dtcs: [], configuration: [], transcript: [], adapterExchanges: [])
    }
}

private final class ABSFixtureTransport: OBDTransport, @unchecked Sendable {
    var commands: [String] = []
    var closed = false
    var timeout = false
    var failCommand: String?
    var dtcReply = "768 03 59 02 FF"
    var identificationReply = "768 06 62 F1 87 41 42 43"
    func open() throws {}
    func close() { closed = true }
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        commands.append(command)
        if command == failCommand { return "NO DATA" }
        if command == "1902FF" {
            if self.timeout { throw OBDClientError.adapter("Timed out; partial adapter response: 768 10") }
            return dtcReply
        }
        if command == "22F187" { return identificationReply }
        return "OK"
    }
}
