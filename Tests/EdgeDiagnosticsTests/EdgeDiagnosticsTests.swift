import XCTest
import PDFKit
@testable import EdgeDiagnostics

final class EdgeDiagnosticsTests: XCTestCase {
    func testSafetyPolicyOnlyPermitsReadServices() {
        XCTAssertTrue(SafetyPolicy.permits("010C"))
        XCTAssertTrue(SafetyPolicy.permits("03"))
        XCTAssertTrue(SafetyPolicy.permits("ATI"))
        XCTAssertTrue(SafetyPolicy.permits("STDI"))
        XCTAssertTrue(SafetyPolicy.permits("STP 53"))
        XCTAssertTrue(SafetyPolicy.permits("STCSEGR 0"))
        XCTAssertTrue(SafetyPolicy.permits("ATSH7E0"))
        XCTAssertTrue(SafetyPolicy.permits("1902FF"))
        XCTAssertFalse(SafetyPolicy.permits("04"))
        XCTAssertTrue(SafetyPolicy.permits("ATSH7E7"))
        XCTAssertFalse(SafetyPolicy.permits("2E0101"))
    }

    func testParsesStandardLiveValuesAndDTCs() throws {
        let transport = MockTransport(responses: [
            "010C": "41 0C 1A F8>", "010D": "41 0D 28>", "0105": "41 05 80>",
            "010F": "41 0F 50>", "0111": "41 11 80>", "0142": "41 42 30 39>", "03": "43 01 33 00 00>", "07": "47 00 00>"
        ])
        let client = OBDClient(transport: transport)
        let snapshot = try client.liveSnapshot()
        XCTAssertEqual(snapshot.engineRPM, 1726)
        XCTAssertEqual(snapshot.speedKPH, 40)
        XCTAssertEqual(snapshot.coolantCelsius, 88)
        XCTAssertEqual(snapshot.controlModuleVoltage, 12.345)
        XCTAssertEqual(try client.storedCodes().map(\.id), ["P0133"])
    }

    func testUsesOBDLinkHardwareIdentityWhenAvailable() throws {
        let client = OBDClient(transport: MockTransport(responses: [
            "ATZ": "ELM327 v1.4b>", "ATE0": "OK>", "ATL0": "OK>", "ATS0": "OK>", "ATH0": "OK>", "ATSP6": "OK>", "ATAT2": "OK>",
            "ATI": "ELM327 v1.4b", "STDI": "OBDLink EX"
        ]))
        XCTAssertEqual(try client.connect(), "OBDLink EX • ELM327 v1.4b")
    }

    func testCapturesRawReadOnlyAdapterTranscript() throws {
        let client = OBDClient(transport: MockTransport(responses: ["010C": "41 0C 1A F8>"]))
        _ = try client.liveSnapshot()
        let entries = client.drainTranscript()
        XCTAssertTrue(entries.contains { $0.command == "010C" && $0.response.contains("41 0C") })
        XCTAssertTrue(client.drainTranscript().isEmpty)
    }

    func testProvidesKnownAndUnknownCodeDetails() {
        let misfire = DTCCatalog.details(for: "p0300")
        XCTAssertEqual(misfire.urgency, .stopDriving)
        XCTAssertEqual(misfire.title, "Random/multiple-cylinder misfire detected")
        XCTAssertEqual(misfire.confidence, .curated)
        XCTAssertFalse(misfire.commonCauses.isEmpty)
        XCTAssertFalse(misfire.diagnosticSteps.isEmpty)
        XCTAssertFalse(misfire.repairGuidance.isEmpty)
        XCTAssertTrue(DTCCatalog.details(for: "P1999").title.contains("Ford manufacturer-specific"))
        XCTAssertEqual(DTCCatalog.details(for: "P1999").confidence, .fallback)
        XCTAssertFalse(DTCCatalog.details(for: "P0101").description.isEmpty)
        XCTAssertEqual(DTCCatalog.normalizedCode(" p-0300 "), "P0300")
    }

    func testProvidesPrioritizedGuidanceForSnapshotCodes() {
        XCTAssertEqual(DTCCatalog.details(for: "P0700").urgency, .servicePromptly)
        XCTAssertTrue(DTCCatalog.details(for: "P0700").description.contains("notification code"))
        XCTAssertEqual(DTCCatalog.details(for: "B0200").system, "Supplemental restraint system")
        XCTAssertTrue(DTCCatalog.details(for: "U3021").diagnosticSteps.joined().contains("full-module scan"))
    }

    func testLabelsPublicLegacyFordDefinitionsWithoutOverclaimingApplication() {
        let injector = DTCCatalog.details(for: "P1202")
        XCTAssertEqual(injector.confidence, .definitionOnly)
        XCTAssertTrue(injector.title.contains("Cylinder 2 injector"))
        XCTAssertTrue(injector.description.contains("does not establish"))
        let restraint = DTCCatalog.details(for: "B1904")
        XCTAssertEqual(restraint.confidence, .definitionOnly)
        XCTAssertTrue(restraint.diagnosticSteps.joined().contains("Do not probe yellow airbag"))
        XCTAssertEqual(DTCCatalog.details(for: "C1504").confidence, .definitionOnly)
        XCTAssertEqual(DTCCatalog.details(for: "B1622").confidence, .definitionOnly)
    }

    func testTailorsGuidanceToModuleAndUDSStatus() {
        let details = DTCCatalog.details(for: DiagnosticCode(id: "P0700", source: "Ford enhanced", module: "TCM", network: "HS-CAN", statusByte: 0x0D, failureTypeByte: 0x96))
        XCTAssertTrue(details.description.contains("Reporting module: TCM"))
        XCTAssertTrue(details.description.contains("test failed"))
        XCTAssertTrue(details.diagnosticSteps.joined().contains("reporting TCM"))
        XCTAssertTrue(details.repairGuidance.joined().contains("no longer reports a failed test"))
    }

    func testGroupsElectricalAndRestraintCodeCluster() {
        let findings = DiagnosticTriage.findings(codes: [
            DiagnosticCode(id: "B0200", source: "Stored"),
            DiagnosticCode(id: "P0600", source: "Stored"),
            DiagnosticCode(id: "U3021", source: "Stored")
        ], moduleVoltage: 14.2)
        XCTAssertEqual(findings.first?.id, "restraint-voltage")
        XCTAssertTrue(findings.contains { $0.id == "power-network-cluster" })
        XCTAssertTrue(findings.contains { $0.explanation.contains("14.20 V") })
        XCTAssertTrue(findings.contains { $0.id == "enhanced-scan-required" })
    }

    func testComparesDTCRecordsAcrossSnapshots() {
        let prior = [DiagnosticCode(id: "P0700", source: "Stored"), DiagnosticCode(id: "B0200", source: "Ford enhanced", module: "RCM", failureTypeByte: 0x13)]
        let current = [DiagnosticCode(id: "P0700", source: "Stored"), DiagnosticCode(id: "B0200", source: "Ford enhanced", module: "RCM", failureTypeByte: 0x13), DiagnosticCode(id: "U3021", source: "Ford enhanced", module: "BCM")]
        let trend = try! XCTUnwrap(DiagnosticHistory.compare(current: current, prior: prior))
        XCTAssertEqual(trend.persistentRecords.map(\.id), ["P0700", "B0200"])
        XCTAssertEqual(trend.newRecords.map(\.id), ["U3021"])
        XCTAssertNil(DiagnosticHistory.compare(current: current, prior: nil))
    }

    func testSummarizesOfflineEvidenceOnlyForTheSameVehicle() {
        let first = snapshotForensicsFixture(vin: "2FMPK4J90KBB00000", codes: ["P0700", "U3021"], transcript: [
            .init(timestamp: .distantPast, command: "1902FF", response: "TRANSPORT ERROR: Timed out waiting for 1902FF."),
            .init(timestamp: .distantPast, command: "1902FF", response: "5902FB")
        ])
        let second = snapshotForensicsFixture(vin: "2FMPK4J90KBB00000", codes: ["P0700", "B0200"], transcript: [
            .init(timestamp: .distantPast, command: "STCSEGR 0", response: "OK"),
            .init(timestamp: .distantPast, command: "1902FF", response: "CAN ERROR")
        ])
        let otherVehicle = snapshotForensicsFixture(vin: "1FMCU9D736DUA0000", codes: ["P0700"], transcript: [])
        let report = SnapshotForensics.report(for: second, history: [first, second, otherVehicle])
        XCTAssertEqual(report.scanCount, 2)
        XCTAssertEqual(report.recurringCodeIDs, ["P0700"])
        XCTAssertEqual(report.udsTimeoutCount, 1)
        XCTAssertEqual(report.rawUDSRetryCount, 1)
        XCTAssertEqual(report.validUDSResponseCount, 1)
        XCTAssertEqual(report.canErrorCount, 1)
    }

    func testMatchesNarrowlyApplicablePublicFordBulletin() {
        let profile = VehicleProfile(vin: "2FMPK4J90KBB00000", year: "2019", make: "FORD", model: "Edge", trim: "SEL", engine: "2.0L 4-cyl Gasoline", driveType: "AWD")
        let matches = FordServiceBulletinCatalog.matching(codes: [DiagnosticCode(id: "P0128", source: "Stored")], vehicle: profile)
        XCTAssertEqual(matches.map(\.number), ["19-2046"])
        XCTAssertTrue(FordServiceBulletinCatalog.matching(codes: [DiagnosticCode(id: "P0128", source: "Stored"), DiagnosticCode(id: "P0300", source: "Stored")], vehicle: profile).isEmpty)
        XCTAssertEqual(FordServiceBulletinCatalog.matching(codes: [DiagnosticCode(id: "P0128", source: "Ford enhanced", module: "PCM"), DiagnosticCode(id: "B0200", source: "Ford enhanced", module: "RCM")], vehicle: profile).map(\.number), ["19-2046"])
        XCTAssertTrue(FordServiceBulletinCatalog.matching(codes: [DiagnosticCode(id: "P0128", source: "Stored")], vehicle: nil).isEmpty)
        XCTAssertTrue(FordServiceBulletinCatalog.matching(codes: [DiagnosticCode(id: "P0128", source: "Stored")], vehicle: VehicleProfile(vin: "x", year: "2020", make: "FORD", model: "Edge", trim: nil, engine: "2.0L", driveType: nil)).isEmpty)
    }

    func testProvidesBundledOpenCatalogDetailsForUncuratedGenericCode() {
        let details = DTCCatalog.details(for: "P0001")
        XCTAssertEqual(details.title, "Fuel Volume Regulator A Control Circuit/Open")
        XCTAssertFalse(details.description.isEmpty)
        XCTAssertFalse(details.commonCauses.isEmpty)
        XCTAssertFalse(details.repairGuidance.isEmpty)
    }

    func testProvidesCommunityFordDefinitionWhenAvailable() {
        let details = DTCCatalog.details(for: "P1233")
        XCTAssertEqual(details.title, "Fuel Pump Driver Module Off-Line")
        XCTAssertTrue(details.source?.contains("community Ford") == true)
    }

    func testExportsPrintableTroubleCodeReport() throws {
        let output = URL(fileURLWithPath: "/private/tmp/edge-diagnostic-report-test.pdf")
        try? FileManager.default.removeItem(at: output)
        let entry = TroubleCodePDFExporter.Entry(
            code: DiagnosticCode(id: "P0001", source: "Stored"),
            details: DTCCatalog.details(for: "P0001")
        )
        let report = TroubleCodePDFExporter.Report(
            createdAt: Date(timeIntervalSince1970: 0),
            vehicleProfile: VehicleProfile(vin: "2FMPK4J90LBB00000", year: "2020", make: "FORD", model: "Edge", trim: "SEL", engine: "2.0L 4-cyl Gasoline", driveType: "AWD"),
            moduleIdentification: ModuleIdentification(vin: "2FMPK4J90LBB00000", calibrationID: "CAL123", ecuName: "PCM"),
            entries: [entry]
        )
        try TroubleCodePDFExporter.export(report, to: output)
        XCTAssertNotNil(PDFDocument(url: output))
        XCTAssertGreaterThan(PDFDocument(url: output)?.pageCount ?? 0, 0)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0, 1_000)
    }

    func testSavesAndLoadsCompleteDiagnosticSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edge-snapshot-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var live = LiveSnapshot(engineRPM: 900, speedKPH: 0, coolantCelsius: 90, intakeAirCelsius: 20, throttlePercent: 4, controlModuleVoltage: 14.1)
        live.capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = SavedDiagnosticSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), adapterIdentity: "OBDLink EX",
            vehicleProfile: VehicleProfile(vin: "2FMPK4J90LBB00000", year: "2020", make: "FORD", model: "Edge", trim: "SEL", engine: "2.0L", driveType: "AWD"),
            moduleIdentification: ModuleIdentification(vin: "2FMPK4J90LBB00000", calibrationID: "CAL123", ecuName: "PCM"),
            liveSnapshot: live,
            codes: [DiagnosticCode(id: "P0300", source: "Stored")],
            monitorStatus: MonitorStatus(malfunctionIndicatorOn: true, confirmedCodeCount: 1),
            freezeFrame: FreezeFrame(triggeringCode: "P0300", engineLoadPercent: 18, engineRPM: 900, speedKPH: 0, coolantCelsius: 90, intakeAirCelsius: 20, shortTermFuelTrimPercent: 4, longTermFuelTrimPercent: 2, runtimeSeconds: 60),
            fordModules: [FordModuleIdentity(name: "PCM", requestHeader: "7E0", network: "HS-CAN", softwareIdentifier: "CKMR1HT.H32")],
            transcript: [DiagnosticTranscriptEntry(timestamp: Date(timeIntervalSince1970: 1_700_000_000), command: "1902FF", response: "59 02 FF 12 02 96 0D")]
        )
        try SnapshotStore.save(saved, to: directory)
        let restored = try XCTUnwrap(SnapshotStore.loadAll(from: directory).first)
        XCTAssertEqual(restored, saved)
    }

    func testReadsVehicleVIN() throws {
        let client = OBDClient(transport: MockTransport(responses: ["0902": "49 02 01 31 46 4D 43 55 39 44 37 33 36 44 55 41 30 30 30 30 30>"]))
        XCTAssertEqual(try client.vehicleVIN(), "1FMCU9D736DUA0000")
    }

    func testReadsModuleIdentification() throws {
        let client = OBDClient(transport: MockTransport(responses: [
            "0902": "49 02 01 31 46 4D 43 55 39 44 37 33 36 44 55 41 30 30 30 30 30>",
            "0904": "49 04 01 43 41 4C 31 32 33>", "090A": "49 0A 01 50 43 4D>"
        ]))
        let identification = try client.moduleIdentification()
        XCTAssertEqual(identification.vin, "1FMCU9D736DUA0000")
        XCTAssertEqual(identification.calibrationID, "CAL123")
        XCTAssertEqual(identification.ecuName, "PCM")
    }

    func testDecodesVehicleProfileResponse() throws {
        let json = """
        {"Results":[{"ModelYear":"2020","Make":"FORD","Model":"Edge","Trim":"SEL","DisplacementL":"2.0","EngineModel":"","EngineCylinders":"4","FuelTypePrimary":"Gasoline","DriveType":"AWD"}]}
        """.data(using: .utf8)!
        let profile = try VehicleProfileLookup.decode(data: json, vin: "2FMPK4J90LBB00000")
        XCTAssertEqual(profile.summary, "2020 FORD Edge SEL")
        XCTAssertEqual(profile.powertrainSummary, "2.0L 4-cyl Gasoline • AWD")
    }

    func testReadsFreezeFrameAndMonitorStatus() throws {
        let client = OBDClient(transport: MockTransport(responses: [
            "0101": "41 01 82 00 00 00>", "0202": "42 02 03 00>", "0204": "42 04 80>",
            "0205": "42 05 80>", "0206": "42 06 88>", "0207": "42 07 78>", "020C": "42 0C 1A F8>",
            "020D": "42 0D 28>", "020F": "42 0F 50>", "021F": "42 1F 00 78>"
        ]))
        XCTAssertEqual(try client.monitorStatus(), MonitorStatus(malfunctionIndicatorOn: true, confirmedCodeCount: 2))
        let frame = try XCTUnwrap(client.freezeFrame())
        XCTAssertEqual(frame.triggeringCode, "P0300")
        XCTAssertEqual(frame.engineRPM, 1726)
        XCTAssertEqual(frame.shortTermFuelTrimPercent, 6.25)
        XCTAssertEqual(frame.runtimeSeconds, 120)
    }

    func testReadsModuleAddressedUDSDTCsWithContext() throws {
        let transport = MockTransport(responses: [
            "STP 33": "OK>", "STP 53": "OK>", "STCSEGR 1": "OK>",
            "ATSH7E0": "OK>", "ATSH7E1": "OK>", "ATSH706": "OK>", "ATSH720": "OK>", "ATSH724": "OK>", "ATSH726": "OK>", "ATSH727": "OK>", "ATSH730": "OK>", "ATSH733": "OK>", "ATSH737": "OK>", "ATSH736": "OK>", "ATSH760": "OK>", "ATSH7D0": "OK>", "ATSH783": "OK>", "ATSH784": "OK>", "ATSH7D6": "OK>",
            "1902FF": "59 02 FF 12 02 96 0D C1 50 04 08>"
        ])
        let client = OBDClient(transport: transport)
        let codes = try client.fordModuleTroubleCodes()
        XCTAssertFalse(codes.isEmpty)
        let first = try XCTUnwrap(codes.first)
        XCTAssertEqual(first.id, "P1202")
        XCTAssertEqual(first.displayIdentifier, "P1202:96")
        XCTAssertEqual(first.module, "PCM")
        XCTAssertEqual(first.network, "HS-CAN")
        XCTAssertEqual(first.statusByte, 0x0D)
        XCTAssertEqual(first.failureTypeByte, 0x96)
        XCTAssertTrue(first.source.contains("confirmed"))
    }

    func testReadsModuleSoftwareIdentifierWhenPermitted() throws {
        let transport = MockTransport(responses: [
            "STP 33": "OK>", "STP 53": "OK>", "STCSEGR 1": "OK>",
            "ATSH7E0": "OK>", "ATSH7E1": "OK>", "ATSH706": "OK>", "ATSH720": "OK>", "ATSH724": "OK>", "ATSH726": "OK>", "ATSH727": "OK>", "ATSH730": "OK>", "ATSH733": "OK>", "ATSH737": "OK>", "ATSH736": "OK>", "ATSH760": "OK>", "ATSH7D0": "OK>", "ATSH783": "OK>", "ATSH784": "OK>", "ATSH7D6": "OK>",
            "22F187": "62 F1 87 43 4B 4D 52 31 48 54 2E 48 33 32>", "1902FF": "59 02 FF 12 02 96 0D"
        ])
        let result = try OBDClient(transport: transport).fordModuleScan()
        XCTAssertEqual(result.modules.first?.softwareIdentifier, "CKMR1HT.H32")
    }

    func testContinuesFordScanWhenOneOrMoreDTCRequestsTimeOut() throws {
        let result = try OBDClient(transport: TimeoutOnDTCTransport()).fordModuleScan()
        XCTAssertTrue(result.codes.isEmpty)
        XCTAssertEqual(result.warnings.count, FordModuleProbe.commonFordCandidates.count)
        XCTAssertTrue(result.warnings.allSatisfy { $0.contains("Timed out") })
    }

    func testUsesAddressedStandardOBDFallbackAfterUDSTimeout() throws {
        let result = try OBDClient(transport: AddressedFallbackTransport()).fordModuleScan()
        XCTAssertEqual(result.codes.map(\.id), ["P1202", "P0700"])
        XCTAssertTrue(result.codes.allSatisfy { $0.module == "PCM" && $0.network == "HS-CAN" })
        XCTAssertTrue(result.codes.allSatisfy { $0.source.contains("UDS unavailable") })
        XCTAssertEqual(result.modules.map(\.name), ["PCM"])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("Timed out reading UDS DTCs"))
    }

    func testDecodesRawISOTPFramesAfterReassembledUDSTimeout() throws {
        let result = try OBDClient(transport: RawUDSRetryTransport()).fordModuleScan()
        let record = try XCTUnwrap(result.codes.first)
        XCTAssertEqual(record.id, "P1202")
        XCTAssertEqual(record.module, "PCM")
        XCTAssertEqual(record.failureTypeByte, 0x96)
        XCTAssertEqual(record.statusByte, 0x0D)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testExplainsUDSNegativeResponseInsteadOfSilentlyDroppingIt() throws {
        let result = try OBDClient(transport: NegativeResponseTransport()).fordModuleScan()
        XCTAssertTrue(result.codes.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("service not supported (NRC 0x11)"))
    }

    func testStopsRemainingMSCANProbesAfterFirstCANError() throws {
        let transport = MSCANFailureTransport()
        let result = try OBDClient(transport: transport).fordModuleScan()
        XCTAssertEqual(transport.mediumSpeedDTCRequests, 1)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("Remaining MS-CAN probes were skipped"))
    }
}

private final class MockTransport: OBDTransport, @unchecked Sendable {
    let responses: [String: String]
    init(responses: [String: String]) { self.responses = responses }
    func open() throws {}
    func close() {}
    func transact(_ command: String, timeout: TimeInterval) throws -> String { responses[command] ?? "NO DATA>" }
}

private func snapshotForensicsFixture(vin: String, codes: [String], transcript: [DiagnosticTranscriptEntry]) -> SavedDiagnosticSnapshot {
    SavedDiagnosticSnapshot(
        capturedAt: .distantPast, adapterIdentity: "OBDLink EX",
        vehicleProfile: VehicleProfile(vin: vin, year: "2019", make: "FORD", model: "Edge", trim: nil, engine: nil, driveType: nil),
        moduleIdentification: nil, liveSnapshot: LiveSnapshot(),
        codes: codes.map { DiagnosticCode(id: $0, source: "Stored") }, monitorStatus: nil, freezeFrame: nil,
        transcript: transcript
    )
}

private final class TimeoutOnDTCTransport: OBDTransport, @unchecked Sendable {
    func open() throws {}
    func close() {}
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        if command == "1902FF" { throw OBDClientError.adapter("Timed out waiting for 1902FF.") }
        return "OK>"
    }
}

private final class AddressedFallbackTransport: OBDTransport, @unchecked Sendable {
    private var header = ""
    func open() throws {}
    func close() {}
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        if command.hasPrefix("ATSH") {
            header = String(command.dropFirst(4))
            return "OK>"
        }
        if header == "7E0" && command == "1902FF" {
            throw OBDClientError.adapter("Timed out waiting for 1902FF.")
        }
        if header == "7E0" && command == "03" { return "43 12 02 07 00 00 00>" }
        if header == "7E0" && command == "07" { return "47 00 00>" }
        if command == "1902FF" { return "NO DATA>" }
        return "OK>"
    }
}

private final class RawUDSRetryTransport: OBDTransport, @unchecked Sendable {
    private var header = ""
    private var rawFrames = false
    func open() throws {}
    func close() {}
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        if command.hasPrefix("ATSH") {
            header = String(command.dropFirst(4))
            return "OK>"
        }
        if command == "STCSEGR 0" { rawFrames = true; return "OK>" }
        if command == "STCSEGR 1" { return "OK>" }
        if header == "7E0" && command == "1902FF" && !rawFrames {
            throw OBDClientError.adapter("Timed out waiting for 1902FF.")
        }
        if header == "7E0" && command == "1902FF" && rawFrames {
            return "10 07 59 02 FF 12 02 96 21 0D 00 00 00 00 00>"
        }
        if command == "1902FF" { return "NO DATA>" }
        return "OK>"
    }
}

private final class NegativeResponseTransport: OBDTransport, @unchecked Sendable {
    private var header = ""
    func open() throws {}
    func close() {}
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        if command.hasPrefix("ATSH") { header = String(command.dropFirst(4)); return "OK>" }
        if header == "7E0" && command == "1902FF" { return "7F 19 11>" }
        if command == "1902FF" { return "NO DATA>" }
        return "OK>"
    }
}

private final class MSCANFailureTransport: OBDTransport, @unchecked Sendable {
    private var isMediumSpeed = false
    private(set) var mediumSpeedDTCRequests = 0
    func open() throws {}
    func close() {}
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        if command == "STP 53" { isMediumSpeed = true; return "OK>" }
        if command == "STP 33" { isMediumSpeed = false; return "OK>" }
        if command == "1902FF" && isMediumSpeed {
            mediumSpeedDTCRequests += 1
            return "CAN ERROR>"
        }
        if command == "1902FF" { return "NO DATA>" }
        return "OK>"
    }
}
