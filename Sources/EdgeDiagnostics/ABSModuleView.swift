import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension AppModel {
    func validateOriginalABS(requestHeader: String, responseHeader: String, evidence: String,
                             preflight: ABSValidationPreflight, readIdentification: Bool) {
        guard let client, isConnected, !isWorking else { return }
        guard requestHeader.count == 3, responseHeader.count == 3,
              let requestID = UInt16(requestHeader, radix: 16), let responseID = UInt16(responseHeader, radix: 16) else {
            errorMessage = "Enter three-digit 11-bit request/response CAN IDs."; return
        }
        let addressing = FordModuleAddressing(requestID: requestID, responseID: responseID, evidence: evidence)
        do { try addressing.validate() } catch { errorMessage = error.localizedDescription; return }
        var checks = preflight
        checks.adapterConnected = isConnected
        // A recent known running-engine sample blocks even before adapter initialization.
        if Date().timeIntervalSince(snapshot.capturedAt) < 5 { checks.rpm = snapshot.engineRPM }
        guard checks.blockers.isEmpty else { errorMessage = checks.blockers.joined(separator: "; "); return }
        stopMonitoring()
        isWorking = true; errorMessage = nil; absBackup = nil; absVoltage = nil
        absCommunication = "Validating original ABS module…"
        let vin = vehicleVIN, adapter = adapterIdentity
        let validatedChecks = checks
        Task {
            defer { isWorking = false }
            let session = await Task.detached {
                client.validateOriginalABS(addressing: addressing, preflight: validatedChecks, vehicleVIN: vin,
                                           adapterInformation: adapter, readIdentification: readIdentification)
            }.value
            absValidationSession = session
            absVoltage = session.adapterVoltage
            absCommunication = session.outcome.rawValue
            absTrace += session.transcript
            absAdapterExchanges += session.adapterExchanges
            _ = client.drainTranscript()
            if session.absResponded { absBackup = client.backupForABS(session) }
            if session.requiresReconnect {
                isConnected = false
                status = "Validation stopped — reconnect required"
            } else { status = session.outcome.rawValue }
        }
    }

    func exportABSValidationSession(asJSON: Bool) {
        guard let session = absValidationSession else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = asJSON ? [.json] : [.plainText]
        panel.nameFieldStringValue = asJSON ? "ABS-validation-\(session.id).json" : "ABS-validation-\(session.id).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = asJSON ? try session.jsonData() : session.textData()
            try data.write(to: url, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }

    func exportABSBackup() {
        guard let absBackup else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ABS-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try absBackup.encoded().write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }

    func importABSOriginal() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { absOriginal = try ABSBackup.decode(Data(contentsOf: url)) }
        catch { errorMessage = error.localizedDescription }
    }

    func importABSConfiguration(_ text: String, source: String) {
        guard var backup = absBackup else { errorMessage = "Read the connected module before attaching imported configuration."; return }
        do {
            backup.configuration = try FordAsBuiltBlock.parse(text, source: source)
            backup.configurationReadFromECU = false
            absBackup = backup
        } catch { errorMessage = error.localizedDescription }
    }

    func importABSConfigurationFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importABSConfiguration(try String(contentsOf: url, encoding: .utf8), source: url.lastPathComponent) }
        catch { errorMessage = error.localizedDescription }
    }

    func exportABSTranscript(asJSON: Bool) {
        let panel = NSSavePanel(); panel.allowedContentTypes = asJSON ? [.json] : [.plainText]
        panel.nameFieldStringValue = asJSON ? "ABS-transcript.json" : "ABS-transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if asJSON {
                struct Export: Encodable { let schemaVersion = 2; let events: [ABSTrace]; let adapterExchanges: [DiagnosticTranscriptEntry] }
                let encoder = ABSValidationSession.jsonEncoder()
                data = try encoder.encode(Export(events: absTrace, adapterExchanges: absAdapterExchanges))
            } else {
                let lines = absTrace.map(\.textLine).joined(separator: "\n")
                let exchanges = absAdapterExchanges.map { "\($0.timestamp.formatted(.iso8601)) TX adapter: \($0.command)\nRX adapter: \($0.response)" }.joined(separator: "\n")
                data = Data((lines + "\n\nAdapter exchanges (including errors/partial replies):\n" + exchanges).utf8)
            }
            try data.write(to: url, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ABSModuleView: View {
    @ObservedObject var model: AppModel
    @State private var requestHeader = String(format: "%03X", FordModuleAddressing.candidateRequestID)
    @State private var responseHeader = String(format: "%03X", FordModuleAddressing.candidateResponseID)
    @State private var evidence = FordModuleAddressing.fusionCandidate.evidence
    @State private var validationPreflight = ABSValidationPreflight()
    @State private var exportValidationJSON = true
    @State private var readIdentification = false
    @State private var asBuiltText = ""
    @State private var preflight = ABSPreflight()

    static func traceLine(_ entry: ABSTrace) -> String { entry.textLine }

    private var draftProfileLabel: String {
        UInt16(requestHeader, radix: 16) == FordModuleAddressing.candidateRequestID && UInt16(responseHeader, radix: 16) == FordModuleAddressing.candidateResponseID ? ABSAddressingStatus.candidate.rawValue : ABSAddressingStatus.userConfigured.rawValue
    }

    var body: some View {
        GroupBox("ABS Module • 2012 Fusion research workflow") {
            VStack(alignment: .leading, spacing: 10) {
                Text("READ ONLY").font(.headline).foregroundStyle(.green)
                Text("Use ignition ON, engine OFF (KOEO). Connect a battery maintainer / fully charged battery. Turn off lights, HVAC, radio and accessories. Keep the adapter and Mac connected.").font(.callout)
                Text("Draft addressing profile: \(draftProfileLabel). HS-CAN, normal 11-bit addressing.").font(.caption)
                HStack {
                    TextField("Request CAN ID", text: $requestHeader)
                    TextField("Response CAN ID", text: $responseHeader)
                }
                TextField("Profile source / capture reference", text: $evidence)
                GroupBox("Validate Original ABS Module • read-only preflight") {
                    VStack(alignment: .leading) {
                        Text("OBDLink EX: \(model.isConnected ? model.adapterIdentity : "Connect first")")
                        Text("HS-CAN will be selected. READ ONLY is enforced. Adapter voltage and fresh RPM are checked before ABS requests.")
                        Toggle("Ignition ON", isOn: $validationPreflight.ignitionOn)
                        Toggle("Engine OFF (user confirmation; unavailable RPM does not prove KOEO)", isOn: $validationPreflight.engineOff)
                        Toggle("Other diagnostic tools closed; no programming / write-capable session active", isOn: $validationPreflight.noWriteSessionConfirmed)
                        Text("Adapter initialization does not reset the ECU or prove its diagnostic session state.").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle("Attempt optional F187 identification after a valid DTC response (unsupported responses stop validation)", isOn: $readIdentification)
                HStack {
                    Button("Validate Original ABS Module") {
                        model.validateOriginalABS(requestHeader: requestHeader.uppercased(), responseHeader: responseHeader.uppercased(), evidence: evidence,
                                                  preflight: validationPreflight, readIdentification: readIdentification)
                    }.disabled(!model.isConnected || model.isWorking || !validationPreflight.ignitionOn || !validationPreflight.engineOff || !validationPreflight.noWriteSessionConfirmed)
                    Button("Save ABS backup…") { model.exportABSBackup() }.disabled(model.absBackup == nil || model.isWorking)
                    Button("Import original backup…") { model.importABSOriginal() }.disabled(model.isWorking)
                }
                if let session = model.absValidationSession {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Validation result: \(session.outcome.rawValue)").font(.headline)
                        Text(session.detail).textSelection(.enabled)
                        Text("ABS responded: \(session.absResponded ? "Yes" : "No valid positive DTC response")")
                        Text("Session pair: \(String(format: "%03X / %03X", session.addressing.requestID, session.addressing.responseID)) • \(session.addressing.status.rawValue)")
                        Text("DTC read: \(session.dtcResult.status.rawValue) • \(session.dtcs.count) records. F187: \(session.f187Result.status.rawValue)")
                        Text("F187 raw payload: \(session.f187Result.payload?.hex ?? "Unavailable / not attempted")")
                        Text("Fresh generic RPM: \(session.engineRPM.map { String(format: "%.0f", $0) } ?? "Unavailable; manual engine-OFF confirmation used")")
                        if session.requiresReconnect { Text("Reconnect before another validation attempt.").foregroundStyle(.orange) }
                        HStack {
                            Picker("Session format", selection: $exportValidationJSON) {
                                Text("JSON").tag(true); Text("Text").tag(false)
                            }.frame(width: 180)
                            Button("Export ABS Validation Session") { model.exportABSValidationSession(asJSON: exportValidationJSON) }.disabled(model.isWorking)
                        }
                        Text("This export preserves this attempt, including failures and partial results. It does not imply vehicle compatibility or programming verification.").font(.caption)
                    }
                }
                Text("Communication: \(model.absCommunication)")
                Text("Adapter voltage: \(model.absVoltage.map { String(format: "%.2f V", $0) } ?? "Unavailable"). Engine state is not automatically verified.").font(.caption)
                if let backup = model.absBackup {
                    identification(backup)
                    Text("DTC count: \(backup.dtcs.count)")
                    ForEach(backup.dtcs.indices, id: \.self) { index in
                        let code = backup.dtcs[index]
                        Text("\(code.displayIdentifier) • status \(code.statusByte.map { String(format: "%02X", $0) } ?? "—") • \(code.udsStatusSummary ?? "Unavailable")\n\(DTCCatalog.details(for: code).title)").textSelection(.enabled)
                    }
                    Text("Raw DTC response is retained in the console and backup. Third DTC byte is preserved; its Ford interpretation is unverified.").font(.caption)
                    DisclosureGroup("Manually imported As-Built (unverified; never sent)") {
                        TextEditor(text: $asBuiltText).font(.system(.caption, design: .monospaced)).frame(height: 80)
                        HStack {
                            Button("Parse entered data") { model.importABSConfiguration(asBuiltText, source: "Manual user entry") }
                            Button("Import text file…") { model.importABSConfigurationFile() }
                        }.disabled(model.isWorking)
                        ForEach(backup.configuration) { block in Text("\(block.formatted) • \(block.validationStatus) • \(block.source)").font(.caption) }
                        Text("Configuration read from ECU: \(backup.configurationReadFromECU ? "Yes" : "No")")
                    }
                    if let original = model.absOriginal {
                        Text("Original backup vs currently read replacement").font(.headline)
                        Text("Differences are diagnostic evidence; suffix differences do not determine compatibility.").font(.caption)
                        Grid(alignment: .leading) {
                            GridRow { Text("Field"); Text("Original"); Text("Replacement") }
                            ForEach(ABSComparison.rows(original, backup)) { row in
                                GridRow { Text(row.label); Text(row.original); Text(row.replacement) }.foregroundStyle(row.differs ? .orange : .primary)
                            }
                        }.textSelection(.enabled)
                    }
                }
                DisclosureGroup("ABS Module Programming Preconditions") {
                    Toggle("Ignition ON (user confirmation)", isOn: $preflight.ignitionOn)
                    Toggle("Engine OFF (user confirmation)", isOn: $preflight.engineOffConfirmed)
                    Toggle("Battery voltage acceptable (user assessment)", isOn: $preflight.voltageAcceptable)
                    Toggle("Battery maintainer connected (recommended)", isOn: $preflight.maintainerConnected)
                    Toggle("Lights / HVAC / accessories OFF", isOn: $preflight.accessoriesOff)
                    Toggle("OBDLink EX connected", isOn: $preflight.adapterConnected)
                    Toggle("Stable communication established", isOn: $preflight.stableCommunication)
                    Toggle("Existing module backup saved", isOn: $preflight.backupSaved)
                    Text("Checklist is advisory. It cannot enable unsupported operations.").font(.caption)
                }
                HStack {
                    Button("Clear ABS DTCs") {}.disabled(true)
                    Button("Restore configuration") {}.disabled(true)
                }
                Text("Unsupported until Ford diagnostic procedure is verified. Configuration/As-Built reads, DTC clearing, security access, writes and reset sequences require research.").font(.caption)
                Text("ABS Service Bleed\nNot yet implemented – Ford service routine required.")
                DisclosureGroup("Raw diagnostic console") {
                    Text("PHYSICAL = adapter-reported RX frames. LOGICAL = submitted requests / implied TX framing / instructed automatic FC, not proof of wire transmission. RECONSTRUCTED = complete payloads. Adapter commands and unknown responses are retained. No passive sniffing.").font(.caption)
                    HStack {
                        Button("Export JSON…") { model.exportABSTranscript(asJSON: true) }
                        Button("Export text…") { model.exportABSTranscript(asJSON: false) }
                    }.disabled(model.absTrace.isEmpty || model.isWorking)
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(model.absTrace) { entry in Text(Self.traceLine(entry)).font(.system(.caption, design: .monospaced)) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 250).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func identification(_ backup: ABSBackup) -> some View {
        VStack(alignment: .leading) {
            Text("Response CAN ID: \(String(format: "%03X", backup.addressing.responseID))")
            Text("Part number (F187): \(backup.module.partNumber ?? "Unavailable / not requested")")
            Text("Strategy/calibration: \(backup.module.strategy ?? "Unavailable")")
            Text("VIN: \(backup.module.vin ?? "Unavailable")")
            Text("Hardware: \(backup.module.hardware ?? "Unavailable")")
            Text("Software: \(backup.module.software ?? "Unavailable / not requested")")
            Text("Other identification: Unavailable")
        }.font(.caption).textSelection(.enabled)
    }
}
