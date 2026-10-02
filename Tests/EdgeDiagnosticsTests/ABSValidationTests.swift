import XCTest
@testable import EdgeDiagnostics

final class ABSValidationTests: XCTestCase {
    private var ready: ABSValidationPreflight {
        .init(adapterConnected: true, ignitionOn: true, engineOff: true, noWriteSessionConfirmed: true)
    }
    private func run(_ transport: ValidationTransport, profile: FordModuleAddressing = .fusionCandidate,
                     identification: Bool = false) -> ABSValidationSession {
        OBDClient(transport: transport).validateOriginalABS(addressing: profile, preflight: ready,
            vehicleVIN: "KNOWN-VEHICLE-VIN", adapterInformation: "Previous adapter identity", readIdentification: identification)
    }

    func testCandidateOnlyBecomesObservedAfterValidResponseAndBackupStoresObservation() throws {
        XCTAssertEqual(FordModuleAddressing.fusionCandidate.status, .candidate)
        let transport = ValidationTransport()
        let client = OBDClient(transport: transport)
        let session = client.validateOriginalABS(preflight: ready)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertEqual(session.addressing.status, .observed)
        XCTAssertNotNil(session.addressing.observedAt)
        XCTAssertTrue(session.absResponded)
        XCTAssertTrue(session.dtcs.isEmpty)
        XCTAssertEqual(try ABSBackup.decode(client.backupForABS(session).encoded()).addressing.status, .observed)
        XCTAssertEqual(transport.commands.filter { $0 == "1902FF" }.count, 1)
        XCTAssertEqual(transport.commands.last, "ATSH7DF")
        XCTAssertTrue(transport.commands.contains("ATCRA768"))
        XCTAssertTrue(transport.commands.contains("STCFCPA 760, 768"))
    }

    func testATE0EchoedAcknowledgementContinuesValidation() {
        let transport = ValidationTransport()
        transport.echoATE0 = true
        let session = run(transport)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertTrue(transport.commands.contains("1902FF"))
        XCTAssertTrue(session.adapterExchanges.contains { $0.command == "ATE0" && $0.response == "ATE0\rOK\r\r" })
    }

    func testAdapterCommandResponseNormalization() {
        for raw in ["ATE0\rOK\r", "ATE0\r\rOK\r\r", "ATE0\rOK\r>", "OK\r", "\rOK\r\r", "ATE0\nOK\n"] {
            XCTAssertTrue(AdapterCommandResponse.acknowledges(command: "ATE0", raw: raw), raw)
        }
        XCTAssertFalse(AdapterCommandResponse.acknowledges(command: "ATE0", raw: "ERROR\r"))
        XCTAssertFalse(AdapterCommandResponse.acknowledges(command: "ATE0", raw: "?\r"))
    }

    func testImplausiblyLowVoltageBlocksBeforeABSRequest() {
        let transport = ValidationTransport()
        transport.voltageResponse = "7.7V"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .preflightBlocked)
        XCTAssertFalse(transport.commands.contains("1902FF"))
        XCTAssertEqual(session.adapterVoltage, 7.7)
    }

    func testTXPayloadAndLogicalCANFrameAreLoggedWithDIDAndSubfunction() {
        let session = run(ValidationTransport(), identification: true)
        let tx = session.transcript.filter { $0.direction == "TX" && $0.visibility == .logical }
        XCTAssertTrue(tx.contains { $0.payload == [0x19, 2, 0xFF] && $0.service == 0x19 && $0.subfunction == 2 })
        XCTAssertTrue(tx.contains { $0.payload == [0x22, 0xF1, 0x87] && $0.did == 0xF187 })
        XCTAssertTrue(tx.contains { $0.frameType == .singleFrame && $0.rawCAN == [3, 0x19, 2, 0xFF] })
        XCTAssertFalse(session.transcript.contains { $0.direction == "TX" && $0.visibility == .physical })
        XCTAssertEqual(session.module.partNumber, "ABC")
        XCTAssertEqual(session.f187Result.status, .positive)
    }

    func testRXPhysicalAndReconstructedResponseAreLogged() {
        let session = run(ValidationTransport())
        XCTAssertTrue(session.transcript.contains { $0.visibility == .physical && $0.direction == "RX" && $0.canID == 0x768 && $0.rawCAN == [3, 0x59, 2, 0xFF] && $0.frameType == .singleFrame })
        XCTAssertTrue(session.transcript.contains { $0.visibility == .reconstructed && $0.payload == [0x59, 2, 0xFF] && $0.positiveResponse == true })
        XCTAssertTrue(session.transcript.contains { $0.visibility == .adapter && $0.adapterText == "1902FF" })
    }

    func testFirstConsecutiveAndAutomaticFlowControlLoggingAndReconstruction() {
        let transport = ValidationTransport()
        transport.dtcResponse = "768 10 0B 59 02 FF C1 50 96\r768 21 0D 40 01 02 08 00 00"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertEqual(session.dtcs.count, 2)
        XCTAssertTrue(session.transcript.contains { $0.frameType == .firstFrame && $0.visibility == .physical })
        XCTAssertTrue(session.transcript.contains { $0.frameType == .consecutiveFrame && $0.visibility == .physical })
        let fc = session.transcript.first { $0.frameType == .flowControl && $0.direction == "TX" }
        XCTAssertEqual(fc?.visibility, .logical)
        XCTAssertEqual(fc?.canID, 0x760)
        XCTAssertNil(fc?.rawCAN)
        XCTAssertTrue(fc?.detail.contains("not confirmation") == true)
        XCTAssertEqual(session.dtcResult.payload, [0x59, 2, 0xFF, 0xC1, 0x50, 0x96, 0x0D, 0x40, 1, 2, 8])
    }

    func testMalformedFlowControlIsLoggedAndAborts() {
        let transport = ValidationTransport(); transport.dtcResponse = "768 30 00\r768 03 59 02 FF"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .transportFailure)
        XCTAssertEqual(session.addressing.status, .candidate)
        XCTAssertTrue(session.transcript.contains { $0.frameType == .flowControl && $0.rawCAN == [0x30, 0] })
    }

    func testReportedRXFlowControlIsNotHiddenOrReassembledAsDTCBytes() {
        let transport = ValidationTransport()
        transport.dtcResponse = "768 30 00 00\r768 03 59 02 FF"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertTrue(session.transcript.contains { $0.frameType == .flowControl && $0.direction == "RX" && $0.visibility == .physical && $0.rawCAN == [0x30, 0, 0] })
        XCTAssertEqual(session.dtcResult.payload, [0x59, 2, 0xFF])
    }

    func testUnexpectedResponseIDIsRetainedWithoutObservation() {
        let transport = ValidationTransport(); transport.dtcResponse = "769 03 59 02 FF"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .trafficWithoutResponse)
        XCTAssertEqual(session.addressing.status, .candidate)
        XCTAssertNil(session.addressing.observedAt)
        XCTAssertTrue(session.transcript.contains { $0.canID == 0x769 && $0.visibility == .physical })
        XCTAssertEqual(transport.commands.last, "1902FF")
        XCTAssertTrue(transport.closed)
    }

    func testUnknownDiagnosticResponseIsPreservedAndNotObserved() {
        let transport = ValidationTransport(); transport.dtcResponse = "768 03 6A 12 34"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .trafficWithoutResponse)
        XCTAssertEqual(session.addressing.status, .candidate)
        XCTAssertEqual(session.dtcResult.payload, [0x6A, 0x12, 0x34])
        XCTAssertTrue(session.transcript.contains { $0.detail.contains("Unknown response") && $0.detail.contains("6A 12 34") })
    }

    func testNegativeResponseAndNRCArePreservedWithoutCandidatePromotion() {
        for nrc in [0x11, 0x31, 0x33, 0x78] {
            let transport = ValidationTransport(); transport.dtcResponse = String(format: "768 03 7F 19 %02X", nrc)
            let session = run(transport)
            XCTAssertEqual(session.outcome, .negativeResponse)
            XCTAssertEqual(session.dtcResult.status, .negative)
            XCTAssertEqual(session.dtcResult.nrc, UInt8(nrc))
            XCTAssertEqual(session.addressing.status, .observed)
            XCTAssertTrue(session.transcript.contains { $0.service == 0x19 && $0.nrc == UInt8(nrc) && $0.positiveResponse == false })
            XCTAssertEqual(transport.commands.last, "1902FF")
        }
    }

    func testF187NegativeKeepsObservedAddressingAndCompletedDTCResult() {
        let transport = ValidationTransport(); transport.f187Response = "768 03 7F 22 31"
        let session = run(transport, identification: true)
        XCTAssertEqual(session.outcome, .negativeResponse)
        XCTAssertEqual(session.addressing.status, .observed)
        XCTAssertTrue(session.absResponded)
        XCTAssertEqual(session.dtcResult.status, .positive)
        XCTAssertEqual(session.f187Result.nrc, 0x31)
        XCTAssertEqual(transport.commands.last, "22F187")
    }

    func testF187NoDataDoesNotErasePriorSuccessfulResponse() {
        let transport = ValidationTransport(); transport.f187Response = "NO DATA"
        let session = run(transport, identification: true)
        XCTAssertTrue(session.absResponded)
        XCTAssertEqual(session.outcome, .transportFailure)
        XCTAssertEqual(session.addressing.status, .observed)
    }

    func testTimeoutPreservesPartialFramesAndNeverRetriesOrObserves() {
        let transport = ValidationTransport(); transport.timeoutCommand = "1902FF"
        transport.partial = "768 10 0B 59 02 FF 12 34 56"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .transportFailure)
        XCTAssertEqual(session.addressing.status, .candidate)
        XCTAssertTrue(session.transcript.contains { $0.frameType == .timeout })
        XCTAssertTrue(session.transcript.contains { $0.frameType == .firstFrame && $0.visibility == .physical })
        XCTAssertTrue(session.adapterExchanges.contains { $0.response.contains(transport.partial) })
        XCTAssertEqual(transport.commands.filter { $0 == "1902FF" }.count, 1)
        XCTAssertEqual(transport.commands.last, "1902FF")
    }

    func testIncompleteISOTransportIsDistinctFromNoResponse() {
        let transport = ValidationTransport(); transport.dtcResponse = "768 10 0B 59 02 FF 12 34 56"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .transportFailure)
        XCTAssertEqual(session.addressing.status, .candidate)
    }

    func testNoDataAdapterErrorAndTrafficHaveDistinctOutcomes() {
        let noData = ValidationTransport(); noData.dtcResponse = "NO DATA"
        XCTAssertEqual(run(noData).outcome, .noResponse)
        let adapter = ValidationTransport(); adapter.failCommand = "ATH1"
        XCTAssertEqual(run(adapter).outcome, .adapterFailure)
        let busError = ValidationTransport(); busError.dtcResponse = "CAN ERROR"
        XCTAssertEqual(run(busError).outcome, .adapterFailure)
        let mixed = ValidationTransport(); mixed.dtcResponse = "768 03 59 02 FF\rCAN ERROR"
        let session = run(mixed)
        XCTAssertEqual(session.outcome, .adapterFailure)
        XCTAssertTrue(session.transcript.contains { $0.visibility == .physical })
        XCTAssertEqual(session.addressing.status, .candidate)
    }

    func testUserConfiguredProfileUsesItsOwnFilterAndFCPair() {
        let transport = ValidationTransport(); transport.dtcResponse = "769 03 59 02 FF"
        let profile = FordModuleAddressing(requestID: 0x761, responseID: 0x769, evidence: "Synthetic custom fixture")
        let session = run(transport, profile: profile)
        XCTAssertEqual(session.addressing.status, .observed)
        XCTAssertTrue(transport.commands.contains("ATSH761"))
        XCTAssertTrue(transport.commands.contains("ATCRA769"))
        XCTAssertTrue(transport.commands.contains("STCFCPA 761, 769"))
        let bad = ValidationTransport(); bad.dtcResponse = "NO DATA"
        XCTAssertEqual(run(bad, profile: profile).addressing.status, .userConfigured)
    }

    func testNonOffsetCustomProfileHasExplicitISOFlowFilterAndRestoresAutomaticFilters() {
        let transport = ValidationTransport(); transport.dtcResponse = "6A0 03 59 02 FF"
        let profile = FordModuleAddressing(requestID: 0x761, responseID: 0x6A0, evidence: "Synthetic non-offset pair")
        let session = run(transport, profile: profile)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertTrue(transport.commands.contains("STCFCPA 761, 6A0"))
        XCTAssertTrue(transport.commands.contains("STFFCC"))
        XCTAssertTrue(transport.commands.contains("STFFCA 6A0, 7FF"))
        XCTAssertTrue(transport.commands.contains("ATCRA6A0"))
        XCTAssertTrue(transport.commands.suffix(7).contains("ATAR"))
        XCTAssertFalse(SafetyPolicy.permits("STFFCA 6A0, 000"))
        XCTAssertFalse(SafetyPolicy.permits("STFFCA 800, 7FF"))
    }

    func testCallerCannotPreMarkObservedForNewSession() {
        let transport = ValidationTransport(); transport.dtcResponse = "NO DATA"
        var profile = FordModuleAddressing.fusionCandidate
        profile.markObserved(at: .distantPast)
        XCTAssertEqual(run(transport, profile: profile).addressing.status, .candidate)
    }

    func testReadOnlyAndKOEOPreflightBlockAllCommands() {
        for index in 0..<6 {
            let transport = ValidationTransport()
            var preflight = ready
            switch index {
            case 0: preflight.readOnly = false
            case 1: preflight.engineOff = false
            case 2: preflight.ignitionOn = false
            case 3: preflight.noWriteSessionConfirmed = false
            case 4: preflight.adapterConnected = false
            default: preflight.rpm = 100
            }
            let session = OBDClient(transport: transport).validateOriginalABS(preflight: preflight)
            XCTAssertEqual(session.outcome, .preflightBlocked)
            XCTAssertTrue(transport.commands.isEmpty)
            XCTAssertFalse(transport.opened)
        }
    }

    func testFreshRPMBlocksABSRequestsAndUnknownRPMRequiresManualEngineOff() {
        let transport = ValidationTransport(); transport.rpmResponse = "41 0C 0F A0"
        let session = run(transport)
        XCTAssertEqual(session.outcome, .preflightBlocked)
        XCTAssertEqual(session.engineRPM, 1000)
        XCTAssertFalse(transport.commands.contains("1902FF"))
        let unavailable = ValidationTransport(); unavailable.rpmResponse = "NO DATA"
        XCTAssertEqual(run(unavailable).outcome, .responded)
        let malformed = ValidationTransport(); malformed.rpmResponse = "41 0C 00"
        XCTAssertEqual(run(malformed).outcome, .transportFailure)
        XCTAssertFalse(malformed.commands.contains("1902FF"))
    }

    func testUnknownRPMTextCannotBeSilentlyParsedAsZeroAndVoltageNaNIsUnavailable() throws {
        let transport = ValidationTransport(); transport.rpmResponse = "41 0C 00 00 unknown"
        XCTAssertEqual(run(transport).outcome, .transportFailure)
        XCTAssertFalse(transport.commands.contains("1902FF"))
        let unavailable = ValidationTransport(); unavailable.voltageResponse = "NaN"
        let session = run(unavailable)
        XCTAssertEqual(session.outcome, .responded)
        XCTAssertNil(session.adapterVoltage)
        XCTAssertNoThrow(try session.jsonData())
    }

    func testNonEXAdapterIsRejectedBeforeABSRequests() {
        let transport = ValidationTransport(); transport.deviceIdentity = "Unknown ELM clone"
        XCTAssertEqual(run(transport).outcome, .adapterFailure)
        XCTAssertFalse(transport.commands.contains("1902FF"))
    }

    func testSessionTextAndJSONContainMetadataTraceAndFailedIdentification() throws {
        let transport = ValidationTransport(); transport.f187Response = "768 03 7F 22 31"
        let session = run(transport, identification: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: session.jsonData()) as? [String: Any])
        XCTAssertEqual(json["vehicleVIN"] as? String, "KNOWN-VEHICLE-VIN")
        XCTAssertEqual(json["adapterVoltage"] as? Double, 12.6)
        XCTAssertTrue(json["startedAt"] is String)
        let jsonTrace = try XCTUnwrap(json["transcript"] as? [[String: Any]])
        XCTAssertFalse(jsonTrace.isEmpty)
        for event in jsonTrace {
            for key in ["timestamp", "direction", "canID", "rawCAN", "frameType", "visibility", "payload", "detail"] {
                XCTAssertNotNil(event[key], "Missing trace field \(key)")
            }
            XCTAssertTrue((event["timestamp"] as? String)?.contains(".") == true)
        }
        let text = String(decoding: session.textData(), as: UTF8.self)
        for expected in ["KNOWN-VEHICLE-VIN", "OBDLink EX", "12.60 V", "0x760", "0x768", "Observed on vehicle", "NRC", "7F 22 31", "TX LOGICAL", "RX PHYSICAL", "READ ONLY"] {
            XCTAssertTrue(text.contains(expected), "Missing \(expected)")
        }
        XCTAssertEqual(session.outcome, .negativeResponse)
        XCTAssertTrue(zip(session.transcript, session.transcript.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp })
    }

    func testLegacyBackupWithoutNewTraceAndProfileKeysRemainsReadable() throws {
        let session = run(ValidationTransport())
        let backup = OBDClient(transport: ValidationTransport()).backupForABS(session)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any])
        var profile = try XCTUnwrap(json["addressing"] as? [String: Any])
        for key in ["status", "observedAt", "network", "addressingBits"] { profile.removeValue(forKey: key) }
        json["addressing"] = profile
        json["transcript"] = [["id": UUID().uuidString, "timestamp": 100, "direction": "TX", "detail": "Legacy payload"]]
        let restored = try ABSBackup.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.addressing.status, .userConfigured)
        XCTAssertNil(restored.transcript.first?.visibility)
    }

    func testOnlyReadVehicleServicesAndBoundedAdapterConfigurationAreAllowed() {
        for command in ["2EF19000", "2701", "1003", "1101", "3101FFFF", "14FFFFFF", "23FFFFFF", "3DFFFFFF", "34", "STPX", "ATSH800", "ATCRAFFF", "STCFCPA 760, 800", "ATSH760\r2EF19000"] {
            XCTAssertFalse(SafetyPolicy.permits(command), command)
        }
        for command in ["ATSH761", "ATCRA769", "STCFCPA 761, 769", "ATCFC1", "ATCAF1"] { XCTAssertTrue(SafetyPolicy.permits(command), command) }
        let transport = ValidationTransport()
        _ = run(transport, identification: true)
        let vehicleCommands = transport.commands.filter { !$0.hasPrefix("AT") && !$0.hasPrefix("ST") }
        XCTAssertEqual(vehicleCommands, ["010C", "1902FF", "22F187"])
    }
}

private final class ValidationTransport: OBDTransport, @unchecked Sendable {
    var commands: [String] = []
    var opened = false
    var closed = false
    var dtcResponse = "768 03 59 02 FF"
    var f187Response = "768 06 62 F1 87 41 42 43"
    var rpmResponse = "41 0C 00 00"
    var deviceIdentity = "OBDLink EX"
    var voltageResponse = "12.6V"
    var timeoutCommand: String?
    var partial = ""
    var failCommand: String?
    var echoATE0 = false
    func open() throws { opened = true }
    func close() { closed = true }
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        commands.append(command)
        if command == timeoutCommand { throw OBDTransportFailure(timedOut: true, partialResponse: partial, message: "Timed out waiting for \(command)") }
        if command == failCommand { return "?" }
        switch command {
        case "ATE0" where echoATE0: return "ATE0\rOK\r\r"
        case "ATZ", "ATI": return "ELM327 v1.4b"
        case "STDI": return deviceIdentity
        case "ATRV": return voltageResponse
        case "010C": return rpmResponse
        case "1902FF": return dtcResponse
        case "22F187": return f187Response
        default: return "OK"
        }
    }
}
