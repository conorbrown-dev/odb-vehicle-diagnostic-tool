import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

struct EdgeDiagnosticsApp: App {
    @NSApplicationDelegateAdaptor(EdgeDiagnosticsAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Swift Package executables are not launched from an app bundle, so macOS may otherwise
/// classify them as background/accessory processes and hide them from the Dock.
final class EdgeDiagnosticsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let livePollingInterval: Duration = .seconds(1)
    @Published var serialPath = ""
    @Published var ports: [String] = []
    @Published var status = "Disconnected"
    @Published var adapterIdentity = ""
    @Published var adapterVoltageCheck: Double?
    @Published var adapterVoltageCheckExchanges: [DiagnosticTranscriptEntry] = []
    @Published var vehicleVIN: String?
    @Published var moduleIdentification: ModuleIdentification?
    @Published var vehicleProfile: VehicleProfile?
    @Published var isLookingUpVehicle = false
    @Published var vehicleLookupMessage: String?
    @Published var snapshot = LiveSnapshot()
    @Published var codes: [DiagnosticCode] = []
    @Published var monitorStatus: MonitorStatus?
    @Published var freezeFrame: FreezeFrame?
    @Published var fordModules: [FordModuleIdentity] = []
    @Published var moduleScanWarnings: [String] = []
    @Published var transcript: [DiagnosticTranscriptEntry] = []
    @Published var codeTrend: DiagnosticCodeTrend?
    @Published var history: [TelemetryPoint] = []
    @Published var isMonitoring = false
    @Published var savedSnapshots: [SavedDiagnosticSnapshot] = []
    @Published var viewedSavedSnapshot: SavedDiagnosticSnapshot?
    @Published var errorMessage: String?
    @Published var isConnected = false
    @Published var isWorking = false
    @Published var absValidationSession: ABSValidationSession?
    @Published var absBackup: ABSBackup?
    @Published var absOriginal: ABSBackup?
    @Published var absTrace: [ABSTrace] = []
    @Published var absAdapterExchanges: [DiagnosticTranscriptEntry] = []
    @Published var absCommunication = "Not tested"
    @Published var absVoltage: Double?
    private(set) var client: OBDClient?
    private var monitoringTask: Task<Void, Never>?

    init() {
        refreshPorts()
        loadSavedSnapshots()
    }

    func refreshPorts() {
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        ports = candidates.filter { $0.hasPrefix("cu.usb") || $0.hasPrefix("cu.SLAB") }.map { "/dev/\($0)" }.sorted()
        if serialPath.isEmpty { serialPath = ports.first ?? "/dev/cu.usbserial-…" }
    }

    func checkAdapterVoltage() {
        guard !isWorking, !isConnected else { return }
        guard !serialPath.isEmpty, !serialPath.contains("…") else {
            errorMessage = "Choose the OBDLink EX serial device first."; return
        }
        isWorking = true; errorMessage = nil; adapterVoltageCheck = nil
        adapterVoltageCheckExchanges = []; status = "Checking adapter voltage…"
        let path = serialPath
        Task {
            let voltageClient = OBDClient(transport: SerialTransport(path: path))
            do {
                adapterVoltageCheck = try await Task.detached { try voltageClient.checkAdapterVoltage() }.value
                status = "Voltage check complete — disconnected"
            } catch {
                errorMessage = error.localizedDescription; status = "Voltage check failed — disconnected"
            }
            adapterVoltageCheckExchanges = voltageClient.drainTranscript()
            isWorking = false
        }
    }

    func connect() {
        guard !isWorking, !isConnected else { return }
        guard !serialPath.contains("…") else { errorMessage = "Choose the adapter path shown in /dev after connecting the EX."; return }
        isWorking = true; errorMessage = nil; status = "Initializing adapter…"
        let path = serialPath
        Task {
            do {
                let newClient = OBDClient(transport: SerialTransport(path: path))
                let result = try await Task.detached { () throws -> (String, ModuleIdentification) in
                    let identity = try newClient.connect()
                    return (identity, try newClient.moduleIdentification())
                }.value
                client = newClient; adapterIdentity = result.0.trimmingCharacters(in: .whitespacesAndNewlines)
                moduleIdentification = result.1
                vehicleVIN = result.1.vin
                isConnected = true; status = "Connected — read-only mode"
                lookupVehicleProfile()
            } catch { errorMessage = error.localizedDescription; status = "Disconnected" }
            isWorking = false
        }
    }

    func disconnect() {
        guard !isWorking else { return }
        absBackup = nil; absCommunication = "Disconnected"
        stopMonitoring()
        client?.disconnect(); client = nil; vehicleVIN = nil; moduleIdentification = nil; vehicleProfile = nil; vehicleLookupMessage = nil; fordModules = []; moduleScanWarnings = []; transcript = []; isConnected = false; status = "Disconnected"
    }

    func refresh() {
        guard let client, isConnected, !isWorking else { return }
        isWorking = true; errorMessage = nil
        Task {
            do {
                let result = try await Task.detached {
                    let reading = try client.liveSnapshot()
                    let codes = try client.storedCodes() + client.pendingCodes()
                    let monitors = try client.monitorStatus()
                    let frame = try client.freezeFrame()
                    return (reading, codes, monitors, frame)
                }.value
                snapshot = result.0
                append(snapshot)
                codes = result.1
                monitorStatus = result.2
                freezeFrame = result.3
                transcript = client.drainTranscript()
                codeTrend = DiagnosticHistory.compare(current: codes, prior: savedSnapshots.first?.codes)
                viewedSavedSnapshot = nil
                saveCurrentSnapshot()
                status = "Updated \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))"
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }

    func scanFordModules() {
        guard let client, isConnected, !isWorking else { return }
        isWorking = true; errorMessage = nil; status = "Scanning accessible Ford modules (read-only)…"
        Task {
            do {
                let scan = try await Task.detached { try client.fordModuleScan() }.value
                let enhancedBaseCodes = Set(scan.codes.map(\.id))
                // A module-addressed UDS record is more useful than the anonymous
                // generic OBD duplicate, but retain any generic-only code.
                codes = scan.codes + codes.filter { !enhancedBaseCodes.contains($0.id) }
                fordModules = scan.modules
                moduleScanWarnings = scan.warnings
                transcript = client.drainTranscript()
                codeTrend = DiagnosticHistory.compare(current: codes, prior: savedSnapshots.first?.codes)
                viewedSavedSnapshot = nil
                snapshot.capturedAt = Date()
                saveCurrentSnapshot()
                status = "Ford module scan found \(scan.codes.count) DTC record\(scan.codes.count == 1 ? "" : "s") from \(scan.modules.count) responding module\(scan.modules.count == 1 ? "" : "s")\(scan.warnings.isEmpty ? "" : "; \(scan.warnings.count) probe\(scan.warnings.count == 1 ? "" : "s") skipped")"
            } catch {
                errorMessage = error.localizedDescription
                status = "Ford module scan could not finish"
            }
            isWorking = false
        }
    }

    func toggleMonitoring() { isMonitoring ? stopMonitoring() : startMonitoring() }

    private func startMonitoring() {
        guard client != nil else { return }
        isMonitoring = true
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollLiveData()
                try? await Task.sleep(for: Self.livePollingInterval)
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel(); monitoringTask = nil; isMonitoring = false
    }

    private func pollLiveData() async {
        guard let client, isConnected, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let next = try await Task.detached { try client.liveSnapshot() }.value
            snapshot = next
            append(next)
            status = "Monitoring — updated \(next.capturedAt.formatted(date: .omitted, time: .standard))"
        } catch {
            errorMessage = error.localizedDescription
            stopMonitoring()
        }
    }

    private func append(_ reading: LiveSnapshot) {
        history.append(TelemetryPoint(snapshot: reading))
        if history.count > 150 { history.removeFirst(history.count - 150) }
    }

    func lookupVehicleProfile() {
        guard let vehicleVIN, vehicleVIN.count == 17, !isLookingUpVehicle else { return }
        isLookingUpVehicle = true; vehicleLookupMessage = nil
        Task {
            defer { isLookingUpVehicle = false }
            do {
                vehicleProfile = try await VehicleProfileLookup.lookup(vin: vehicleVIN)
            } catch {
                vehicleLookupMessage = "Vehicle profile lookup unavailable. Code analysis will use the VIN and ECU identifiers captured from the adapter."
            }
        }
    }

    func exportTroubleCodeReport() {
        guard !codes.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Ford-Edge-Diagnostic-Report-\(Date().formatted(.iso8601.year().month().day())).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = codes.map { TroubleCodePDFExporter.Entry(code: $0, details: DTCCatalog.details(for: $0)) }
            try TroubleCodePDFExporter.export(.init(createdAt: Date(), vehicleProfile: vehicleProfile, moduleIdentification: moduleIdentification, entries: entries, fordModules: fordModules), to: url)
            status = "Trouble-code report exported to \(url.lastPathComponent)"
        } catch {
            errorMessage = "Could not export trouble-code report: \(error.localizedDescription)"
        }
    }

    func loadSavedSnapshots() {
        do { savedSnapshots = try SnapshotStore.loadAll() }
        catch { errorMessage = "Could not load saved diagnostic snapshots: \(error.localizedDescription)" }
    }

    func view(_ saved: SavedDiagnosticSnapshot) {
        stopMonitoring()
        viewedSavedSnapshot = saved
        adapterIdentity = saved.adapterIdentity
        vehicleProfile = saved.vehicleProfile
        moduleIdentification = saved.moduleIdentification
        vehicleVIN = saved.moduleIdentification?.vin
        snapshot = saved.liveSnapshot
        codes = saved.codes
        monitorStatus = saved.monitorStatus
        freezeFrame = saved.freezeFrame
        fordModules = saved.fordModules
        transcript = saved.transcript
        codeTrend = DiagnosticHistory.compare(current: saved.codes, prior: savedSnapshots.first(where: { $0.id != saved.id })?.codes)
        status = "Viewing saved snapshot from \(saved.capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func saveCurrentSnapshot() {
        let saved = SavedDiagnosticSnapshot(
            capturedAt: snapshot.capturedAt, adapterIdentity: adapterIdentity, vehicleProfile: vehicleProfile,
            moduleIdentification: moduleIdentification, liveSnapshot: snapshot, codes: codes,
            monitorStatus: monitorStatus, freezeFrame: freezeFrame, fordModules: fordModules, transcript: transcript
        )
        do {
            try SnapshotStore.save(saved)
            savedSnapshots.insert(saved, at: 0)
        } catch {
            errorMessage = "Vehicle data was read, but its disk snapshot could not be saved: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var manualCode = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                connection
                ABSModuleView(model: model)
                codeLookup
                savedSnapshots
                if model.isConnected || model.viewedSavedSnapshot != nil { diagnosticContent }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 560)
        .alert("Connection issue", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Edge Diagnostics").font(.largeTitle.weight(.bold))
            Text("Ford powertrain diagnostics • EX101 / OBDLink EX • Read-only")
                .foregroundStyle(.secondary)
        }
    }

    private var connection: some View {
        GroupBox("Adapter") {
            HStack {
                Picker("USB serial device", selection: $model.serialPath) {
                    if !model.ports.contains(model.serialPath) { Text(model.serialPath).tag(model.serialPath) }
                    ForEach(model.ports, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: .infinity)
                Button("Find ports") { model.refreshPorts() }
                Button("Check adapter voltage") { model.checkAdapterVoltage() }
                    .disabled(model.isWorking || model.isConnected)
                    .help("Reads adapter supply voltage only. Disconnect first; no vehicle diagnostic requests are sent.")
                Button(model.isConnected ? "Disconnect" : "Connect") { model.isConnected ? model.disconnect() : model.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
            }
            if let voltage = model.adapterVoltageCheck {
                Text(String(format: "Adapter voltage check: %.2f V — compare with the simultaneous multimeter reading.", voltage))
                    .font(.caption)
            }
            ForEach(Array(model.adapterVoltageCheckExchanges.enumerated()), id: \.offset) { _, exchange in
                Text("\(exchange.command) → \(String(reflecting: exchange.response))")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            Text(model.isConnected ? "\(model.status)  \(model.adapterIdentity)" : model.status)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var codeLookup: some View {
        GroupBox("Trouble-code analyzer") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Enter a code, e.g. P0300", text: $manualCode)
                    .textFieldStyle(.roundedBorder)
                let record = manualDiagnosticRecord
                if !manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let record {
                        DTCDetailCard(code: record, details: DTCCatalog.details(for: record))
                    } else {
                        Text("Enter a five-character DTC, optionally with its third UDS byte: P0300 or B1904:96.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Look up a code from another scanner, or read the vehicle to analyze stored and pending codes automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var savedSnapshots: some View {
        GroupBox("Saved diagnostic snapshots") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Each read saves vehicle context, decoded results, and raw read-only adapter exchanges to this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload") { model.loadSavedSnapshots() }.font(.caption)
                }
                if model.savedSnapshots.isEmpty {
                    Text("No saved snapshots yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.savedSnapshots) { saved in
                        let profileName = saved.vehicleProfile?.summary ?? ""
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profileName.isEmpty ? (saved.moduleIdentification?.vin ?? "Vehicle snapshot") : profileName)
                                    .font(.caption.weight(.semibold))
                                Text("\(saved.capturedAt.formatted(date: .abbreviated, time: .shortened)) - \(saved.codes.count) trouble code\(saved.codes.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("View") { model.view(saved) }.font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func isDiagnosticCode(_ code: String) -> Bool {
        guard code.count == 5, let family = code.first, "PCBU".contains(family) else { return false }
        let tail = code.dropFirst()
        return tail.allSatisfy(\.isHexDigit)
    }

    private var manualDiagnosticRecord: DiagnosticCode? {
        let pieces = manualCode.uppercased().split(separator: ":", maxSplits: 1).map(String.init)
        let code = DTCCatalog.normalizedCode(pieces.first ?? "")
        guard isDiagnosticCode(code) else { return nil }
        if pieces.count == 2 {
            let suffix = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard suffix.count == 2, let value = UInt8(suffix, radix: 16) else { return nil }
            return DiagnosticCode(id: code, source: "Manual lookup", failureTypeByte: value)
        }
        return DiagnosticCode(id: code, source: "Manual lookup")
    }

    private var diagnosticContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.viewedSavedSnapshot == nil ? "Live data" : "Saved diagnostic snapshot").font(.title2.weight(.semibold))
                if let vin = model.vehicleVIN { Text("VIN: \(vin)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                Spacer()
                Button(model.isWorking ? "Reading…" : "Read vehicle") { model.refresh() }
                    .disabled(model.isWorking || !model.isConnected)
                Button(model.isWorking ? "Scanning…" : "Scan Ford modules") { model.scanFordModules() }
                    .disabled(model.isWorking || !model.isConnected)
                Button("Export trouble-code PDF") { model.exportTroubleCodeReport() }
                    .disabled(model.codes.isEmpty)
                Button(model.isMonitoring ? "Stop monitoring" : "Start monitoring") { model.toggleMonitoring() }
                    .disabled(model.isWorking || !model.isConnected)
            }
            vehicleContext
            if !model.fordModules.isEmpty { fordModuleContext }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                GaugeCard(title: "Engine speed", value: model.snapshot.engineRPM.map { String(format: "%.0f RPM", $0) } ?? "—", accent: .blue)
                GaugeCard(title: "Vehicle speed", value: model.snapshot.speedKPH.map { String(format: "%.0f km/h", $0) } ?? "—", accent: .green)
                GaugeCard(title: "Coolant", value: model.snapshot.coolantCelsius.map { String(format: "%.0f °C", $0) } ?? "—", accent: .orange)
                GaugeCard(title: "Intake air", value: model.snapshot.intakeAirCelsius.map { String(format: "%.0f °C", $0) } ?? "—")
                GaugeCard(title: "Throttle", value: model.snapshot.throttlePercent.map { String(format: "%.0f%%", $0) } ?? "—")
                GaugeCard(title: "Module voltage", value: model.snapshot.controlModuleVoltage.map { String(format: "%.2f V", $0) } ?? "—", accent: .purple)
            }
            if !model.history.isEmpty { telemetryCharts }
            if !model.moduleScanWarnings.isEmpty { moduleScanWarnings }
            if !model.codes.isEmpty { diagnosticTriage }
            if let trend = model.codeTrend { codeTrend(trend) }
            if let saved = model.viewedSavedSnapshot ?? model.savedSnapshots.first { snapshotEvidence(for: saved) }
            if !model.codes.isEmpty { applicableServiceBulletins }
            GroupBox("Trouble codes") {
                if model.codes.isEmpty { Text("No stored or pending generic powertrain codes found. Use Scan Ford modules for an enhanced, read-only module scan.").foregroundStyle(.secondary) }
                else {
                    ForEach(Array(model.codes.enumerated()), id: \.offset) { _, code in
                        DTCDetailCard(code: code, details: DTCCatalog.details(for: code), vehicle: model.vehicleProfile)
                    }
                }
            }
            diagnosticContext
            Text("Safety boundary: module scan uses only UDS ReadDTCInformation. It cannot clear faults, open programming sessions, or write to a Ford module.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var vehicleContext: some View {
        GroupBox("Vehicle identification") {
            VStack(alignment: .leading, spacing: 4) {
                if let profile = model.vehicleProfile {
                    Text(profile.summary.isEmpty ? "VIN decoded" : profile.summary).font(.subheadline.weight(.semibold))
                    if let powertrain = profile.powertrainSummary { Text(powertrain).font(.caption).foregroundStyle(.secondary) }
                    Text("VIN decoded through NHTSA vPIC; this identifies the configuration, not Ford fault definitions.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.isLookingUpVehicle {
                    Text("Decoding VIN into vehicle configuration…").font(.caption).foregroundStyle(.secondary)
                } else if let message = model.vehicleLookupMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("Retry vehicle lookup") { model.lookupVehicleProfile() }.font(.caption)
                }
                if let calibration = model.moduleIdentification?.calibrationID {
                    Text("Calibration ID: \(calibration)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let ecu = model.moduleIdentification?.ecuName {
                    Text("ECU name: \(ecu)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var telemetryCharts: some View {
        GroupBox("Live history") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Last \(model.history.count) readings • sampled about once per second while monitoring").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)], spacing: 14) {
                    TelemetryChartCard(title: "Engine speed", unit: "RPM", color: .blue, history: model.history, value: \.engineRPM)
                    TelemetryChartCard(title: "Vehicle speed", unit: "km/h", color: .green, history: model.history, value: \.speedKPH)
                    TelemetryChartCard(title: "Coolant temperature", unit: "°C", color: .orange, history: model.history, value: \.coolantCelsius)
                    TelemetryChartCard(title: "Intake-air temperature", unit: "°C", color: .teal, history: model.history, value: \.intakeAirCelsius)
                    TelemetryChartCard(title: "Throttle position", unit: "%", color: .pink, history: model.history, value: \.throttlePercent)
                    TelemetryChartCard(title: "Module voltage", unit: "V", color: .purple, history: model.history, value: \.controlModuleVoltage)
                }
                Text("Each chart uses its own scale. A flat speed line while parked is expected; changes appear only when the underlying vehicle reading changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var diagnosticTriage: some View {
        let findings = DiagnosticTriage.findings(codes: model.codes, moduleVoltage: model.snapshot.controlModuleVoltage)
        return GroupBox("Diagnostic priorities") {
            if findings.isEmpty {
                Text("No cross-code pattern was recognized. Follow the module-specific confirmation steps on each trouble-code card.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(finding.severity.label): \(finding.title)").font(.subheadline.weight(.semibold))
                            Text(finding.explanation).font(.caption)
                            ForEach(finding.nextSteps, id: \.self) { step in
                                Text("• \(step)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func codeTrend(_ trend: DiagnosticCodeTrend) -> some View {
        GroupBox("Trouble-code trend") {
            VStack(alignment: .leading, spacing: 4) {
                if trend.newRecords.isEmpty {
                    Text("No new DTC records compared with the previous saved scan.").font(.caption)
                } else {
                    Text("New since previous scan: \(trend.newRecords.map(\.displayIdentifier).joined(separator: ", "))").font(.caption)
                }
                if trend.persistentRecords.isEmpty {
                    Text("No prior DTC records persisted into this scan.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Still present: \(trend.persistentRecords.map(\.displayIdentifier).joined(separator: ", "))").font(.caption)
                    Text("A persistent DTC is evidence to continue diagnosis; a missing code is not proof of repair unless the relevant monitor or module test has run.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func snapshotEvidence(for saved: SavedDiagnosticSnapshot) -> some View {
        let report = SnapshotForensics.report(for: saved, history: model.savedSnapshots)
        return GroupBox("Offline snapshot evidence") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compared (report.scanCount) saved scan\(report.scanCount == 1 ? "" : "s") for this vehicle.").font(.caption)
                if report.recurringCodeIDs.isEmpty {
                    Text("No code has appeared in two saved scans yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Recurring code IDs: \(report.recurringCodeIDs.joined(separator: ", ")).").font(.caption)
                    Text("Recurrence is evidence to continue diagnosis, not proof of a failed component.").font(.caption).foregroundStyle(.secondary)
                }
                if report.udsTimeoutCount + report.rawUDSRetryCount + report.validUDSResponseCount + report.canErrorCount > 0 {
                    Text("Transport evidence: \(report.udsTimeoutCount) UDS timeout\(report.udsTimeoutCount == 1 ? "" : "s"), \(report.rawUDSRetryCount) raw-frame retr\(report.rawUDSRetryCount == 1 ? "y" : "ies"), \(report.validUDSResponseCount) valid UDS response\(report.validUDSResponseCount == 1 ? "" : "s"), \(report.canErrorCount) CAN error\(report.canErrorCount == 1 ? "" : "s").")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var applicableServiceBulletins: some View {
        let bulletins = FordServiceBulletinCatalog.matching(codes: model.codes, vehicle: model.vehicleProfile)
        return GroupBox("Applicable public Ford service notices") {
            if bulletins.isEmpty {
                Text("No narrowly matched public bulletin is bundled for this vehicle/code combination.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(bulletins) { bulletin in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("TSB \(bulletin.number): \(bulletin.title)").font(.subheadline.weight(.semibold))
                            Text(bulletin.applicability).font(.caption)
                            Text(bulletin.repairSummary).font(.caption).foregroundStyle(.secondary)
                            Link("Read the public NHTSA copy", destination: bulletin.url).font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var fordModuleContext: some View {
        GroupBox("Responding Ford modules") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.fordModules) { module in
                    Text("\(module.name) • \(module.network) • request 0x\(module.requestHeader)\(module.softwareIdentifier.map { " • F187 identifier \($0)" } ?? "")")
                        .font(.caption.monospaced())
                }
                Text("Modules appear only after a read-only response. F187 identifiers (standardized spare-part number) are returned when that module permits it in its default diagnostic session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var moduleScanWarnings: some View {
        GroupBox("Module scan notes") {
            VStack(alignment: .leading, spacing: 3) {
                Text("Some module probes did not answer in time. Other module results were retained; the raw transcript records the failures.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.moduleScanWarnings, id: \.self) { warning in
                    Text("• \(warning)").font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticContext: some View {
        if let status = model.monitorStatus {
            GroupBox("Monitor status") {
                Text(status.malfunctionIndicatorOn ? "Check-engine indicator: ON" : "Check-engine indicator: OFF")
                Text("Confirmed generic powertrain codes reported by ECU: \(status.confirmedCodeCount)").foregroundStyle(.secondary)
            }
        }
        if let frame = model.freezeFrame {
            GroupBox("Freeze-frame data") {
                Text("Captured when \(frame.triggeringCode) was recorded").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], alignment: .leading, spacing: 8) {
                    FreezeValue(label: "Engine load", value: frame.engineLoadPercent.map { String(format: "%.1f%%", $0) })
                    FreezeValue(label: "Engine speed", value: frame.engineRPM.map { String(format: "%.0f RPM", $0) })
                    FreezeValue(label: "Vehicle speed", value: frame.speedKPH.map { String(format: "%.0f km/h", $0) })
                    FreezeValue(label: "Coolant", value: frame.coolantCelsius.map { String(format: "%.0f °C", $0) })
                    FreezeValue(label: "Intake air", value: frame.intakeAirCelsius.map { String(format: "%.0f °C", $0) })
                    FreezeValue(label: "Short fuel trim", value: frame.shortTermFuelTrimPercent.map { String(format: "%+.1f%%", $0) })
                    FreezeValue(label: "Long fuel trim", value: frame.longTermFuelTrimPercent.map { String(format: "%+.1f%%", $0) })
                    FreezeValue(label: "Engine runtime", value: frame.runtimeSeconds.map { String(format: "%.0f sec", $0) })
                }
                Text("Freeze-frame values are a historical snapshot, not the current readings above.").font(.caption).foregroundStyle(.secondary)
            }
        } else if !model.codes.isEmpty {
            Text("No generic freeze-frame snapshot was returned by the powertrain ECU.").font(.caption).foregroundStyle(.secondary)
        }
        if !model.transcript.isEmpty {
            GroupBox("Captured adapter transcript") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.transcript.count) read-only exchanges saved with this snapshot. This is diagnostic evidence, not a command console.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.transcript) { entry in
                                Text("\(entry.command) → \(entry.response.trimmingCharacters(in: .whitespacesAndNewlines))")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
    }
}

private struct FreezeValue: View {
    let label: String
    let value: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "Not reported").font(.caption.monospacedDigit())
        }
    }
}

private struct DTCDetailCard: View {
    let code: DiagnosticCode
    let details: DTCDetails
    var vehicle: VehicleProfile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(code.displayIdentifier).font(.headline.monospaced())
                Text(code.source).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                Spacer()
                Text(details.urgency.rawValue).font(.caption.weight(.medium)).foregroundStyle(details.urgency == .stopDriving ? .red : .orange)
            }
            Text(details.title).font(.subheadline.weight(.semibold))
            Text(details.confidence.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let module = code.module {
                Text("\(code.hasEnhancedModuleContext ? "Reported by" : "Addressed responder"): \(module)\(code.network.map { " • \($0)" } ?? "")")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if let status = code.statusByte {
                Text("UDS status: 0x\(String(format: "%02X", status)) — \(code.udsStatusSummary ?? "not decoded")\(code.failureTypeByte.map { " • additional DTC byte: 0x\(String(format: "%02X", $0))" } ?? "")")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(details.system).font(.caption).foregroundStyle(.secondary)
            if let source = details.source { Text("Data source: \(source)").font(.caption).foregroundStyle(.secondary) }
            Text(details.description).font(.caption)
            if let vehicle, !vehicle.summary.isEmpty {
                Text("Analysis context: \(vehicle.summary)").font(.caption).foregroundStyle(.secondary)
            }
            Text(details.urgency.advice).font(.caption).foregroundStyle(.secondary)
            DetailList(title: "Common causes", items: details.commonCauses)
            DetailList(title: "Typical symptoms", items: details.symptoms)
            DetailList(title: "How to confirm", items: details.diagnosticSteps)
            DetailList(title: "Repair path", items: details.repairGuidance)
        }
        .padding(.vertical, 6)
    }
}

private struct DetailList: View {
    let title: String
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                ForEach(items, id: \.self) { item in
                    Text("• \(item)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GaugeCard: View {
    let title: String
    let value: String
    var accent: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TelemetryChartCard: View {
    let title: String
    let unit: String
    let color: Color
    let history: [TelemetryPoint]
    let value: KeyPath<TelemetryPoint, Double?>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            Chart(history) { point in
                if let measurement = point[keyPath: value] {
                    LineMark(x: .value("Time", point.timestamp), y: .value(unit, measurement))
                        .foregroundStyle(color)
                    PointMark(x: .value("Time", point.timestamp), y: .value(unit, measurement))
                        .foregroundStyle(color)
                        .symbolSize(16)
                }
            }
            .chartYAxisLabel(unit)
            .frame(height: 130)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
