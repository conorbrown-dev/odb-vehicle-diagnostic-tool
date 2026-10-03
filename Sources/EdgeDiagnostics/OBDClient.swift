import Foundation

protocol OBDTransport: Sendable {
    func open() throws
    func close()
    func transact(_ command: String, timeout: TimeInterval) throws -> String
}

/// ELM/STN adapters may echo the command that changes echo state. Keep the raw
/// transport response intact for tracing, but normalize meaningful response lines
/// before deciding whether an adapter configuration command was acknowledged.
enum AdapterCommandResponse {
    static func meaningfulLines(command: String, raw: String) -> [String] {
        var lines = raw
            .replacingOccurrences(of: ">", with: "\n")
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = lines.first,
           first.caseInsensitiveCompare(command.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            lines.removeFirst()
        }
        return lines
    }

    static func acknowledges(command: String, raw: String) -> Bool {
        let lines = meaningfulLines(command: command, raw: raw)
        return !containsError(lines) && lines.contains { $0.caseInsensitiveCompare("OK") == .orderedSame }
    }

    static func containsError(_ lines: [String]) -> Bool {
        lines.contains {
            let line = $0.uppercased()
            return line == "?" || line.contains("ERROR") || line.contains("UNABLE") || line == "STOPPED" || line == "BUFFER FULL" || line == "BUS BUSY" || line == "FB ERROR"
        }
    }

    static func voltage(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard text.hasSuffix("V") else { return nil }
        let number = text.dropLast()
        guard !number.isEmpty, number.allSatisfy({ "0123456789.".contains($0) }),
              let value = Double(number), value.isFinite else { return nil }
        return value
    }
}

final class OBDClient: @unchecked Sendable {
    private let operationLock = NSRecursiveLock()
    private var absTrace: [ABSTrace] = []
    private var absSession: ABSValidationSession?
    private var captureABSAdapter = false
    private let transport: OBDTransport
    private let transcriptLock = NSLock()
    private var transcript: [DiagnosticTranscriptEntry] = []

    init(transport: OBDTransport) { self.transport = transport }

    func connect() throws -> String {
        operationLock.lock(); defer { operationLock.unlock() }
        try transport.open()
        for command in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP6", "ATAT2"] {
            _ = try send(command)
        }
        let elmIdentity = try send("ATI")
        // Genuine OBDLink devices intentionally emulate an ELM327 identity for
        // compatibility. STDI is the vendor command that exposes the hardware ID.
        if let deviceIdentity = try? send("STDI"), !deviceIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(deviceIdentity.trimmingCharacters(in: .whitespacesAndNewlines)) • \(elmIdentity.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return elmIdentity
    }

    func disconnect() { operationLock.lock(); defer { operationLock.unlock() }; transport.close() }

    /// Returns and clears the exchanges accumulated since the previous drain.
    /// Commands are already constrained by SafetyPolicy, so this is a passive log.
    func drainTranscript() -> [DiagnosticTranscriptEntry] {
        operationLock.lock(); defer { operationLock.unlock() }
        transcriptLock.lock(); defer { transcriptLock.unlock() }
        let captured = transcript
        transcript.removeAll()
        return captured
    }

    func voltage() throws -> Double? {
        let response = try sendAdapterQuery("ATRV")
        return AdapterCommandResponse.voltage(response)
    }

    /// Standalone supply check: only ATRV is sent; no ECU or setup requests.
    func checkAdapterVoltage() throws -> Double {
        operationLock.lock(); defer { operationLock.unlock() }
        defer { transport.close() }
        try transport.open()
        guard let reading = try voltage() else {
            throw OBDClientError.adapter("Adapter voltage is unavailable or malformed; raw reply is retained in the transcript.")
        }
        return reading
    }

    /// Standard OBD-II Mode 09/PID 02. This requests identification data only.
    func vehicleVIN() throws -> String? {
        let bytes = hexBytes(try send("0902"))
        guard let index = bytes.indices.dropLast().first(where: { bytes[$0] == 0x49 && bytes[$0 + 1] == 0x02 }) else { return nil }
        // The byte following 49 02 is the number of VIN data items; it is not part of the VIN.
        let vinBytes = Array(bytes.dropFirst(index + 3)).filter { $0 >= 0x20 && $0 <= 0x7E }.map(UInt8.init)
        let text = String(decoding: vinBytes, as: UTF8.self)
        let vin = text.uppercased().filter { $0.isLetter || $0.isNumber }
        return vin.count >= 17 ? String(vin.prefix(17)) : nil
    }

    /// Mode 09 identifiers help distinguish otherwise similar Ford configurations.
    /// They remain read-only requests and are not universally implemented by all ECUs.
    func moduleIdentification() throws -> ModuleIdentification {
        let vin = try vehicleVIN()
        return ModuleIdentification(
            vin: vin,
            calibrationID: try mode09Text(pid: "04"),
            ecuName: try mode09Text(pid: "0A")
        )
    }

    func storedCodes() throws -> [DiagnosticCode] { try troubleCodes(command: "03", source: "Stored") }
    func pendingCodes() throws -> [DiagnosticCode] { try troubleCodes(command: "07", source: "Pending") }

    /// Reads UDS DTC records from a conservative, fixed set of Ford module addresses.
    /// This changes only OBDLink's CAN transceiver/header settings and sends ISO 14229
    /// service 0x19 (ReadDTCInformation); it never opens a diagnostic session, clears
    /// memory, writes a DID, or invokes a routine.
    func fordModuleTroubleCodes() throws -> [DiagnosticCode] { try fordModuleScan().codes }

    func fordModuleScan() throws -> FordModuleScanResult {
        operationLock.lock(); defer { operationLock.unlock() }
        var records: [DiagnosticCode] = []
        var modules: [FordModuleIdentity] = []
        var warnings: [String] = []
        var selectedNetwork: FordNetwork?
        var unavailableNetworks: Set<FordNetwork> = []
        defer {
            do {
                _ = try send(FordNetwork.highSpeed.adapterPreset)
                _ = try send("ATSH7DF")
                _ = try send("STCSEGR 0")
            } catch { transport.close() }
        }
        for probe in FordModuleProbe.commonFordCandidates {
            guard !unavailableNetworks.contains(probe.network) else { continue }
            do {
                if probe.network != selectedNetwork {
                    _ = try send(probe.network.adapterPreset)
                    _ = try send("STCSEGR 1") // adapter-side ISO-TP reassembly
                    selectedNetwork = probe.network
                }
                _ = try send("ATSH\(probe.requestHeader)")
                let moduleCodes: [DiagnosticCode]
                var shouldReadSoftwareIdentifier = false
                do {
                    moduleCodes = try udsTroubleCodes(for: probe)
                    shouldReadSoftwareIdentifier = !moduleCodes.isEmpty
                } catch {
                    // Some Ford controllers expose emissions DTCs through the
                    // standard OBD services but do not complete UDS 19 02 FF in
                    // the default session.  A timeout is not evidence of an empty
                    // DTC memory, so try only the read-only OBD equivalents at the
                    // same physical address.  Do not do this after a normal NO DATA
                    // response, which is already an explicit answer from the ECU.
                    guard isTimeout(error) else { throw error }
                    warnings.append("\(probe.name) (\(probe.network.rawValue), 0x\(probe.requestHeader)): Timed out reading UDS DTCs; used addressed standard-OBD fallback if available.")
                    let stored = try addressedTroubleCodes(command: "03", source: "Ford addressed OBD-II • Stored (UDS unavailable)", probe: probe)
                    let pending = try addressedTroubleCodes(command: "07", source: "Ford addressed OBD-II • Pending (UDS unavailable)", probe: probe)
                    moduleCodes = stored + pending
                }
                // Read F187 identification only after a module returned DTC data. This
                // keeps a silent optional DID from delaying the core DTC scan.
                // Addressed OBD fallback results intentionally do not trigger this
                // optional UDS query: its prior timeout is evidence it would only
                // delay or discard otherwise useful standard-OBD results.
                let softwareIdentifier = shouldReadSoftwareIdentifier ? (try? udsText(did: "F187")) : nil
                if !moduleCodes.isEmpty {
                    modules.append(FordModuleIdentity(name: probe.name, requestHeader: probe.requestHeader, network: probe.network.rawValue, softwareIdentifier: softwareIdentifier))
                }
                records.append(contentsOf: moduleCodes)
            } catch {
                if probe.network == .mediumSpeed, isCANError(error) {
                    unavailableNetworks.insert(.mediumSpeed)
                    warnings.append("MS-CAN is unavailable (first probe \(probe.name), 0x\(probe.requestHeader): CAN ERROR). Remaining MS-CAN probes were skipped.")
                } else {
                    warnings.append("\(probe.name) (\(probe.network.rawValue), 0x\(probe.requestHeader)): \(error.localizedDescription)")
                }
            }
        }
        return FordModuleScanResult(modules: modules, codes: records, warnings: warnings)
    }

    func monitorStatus() throws -> MonitorStatus? {
        guard let bytes = try value(mode: "01", pid: "01"), let first = bytes.first else { return nil }
        return MonitorStatus(malfunctionIndicatorOn: (first & 0x80) != 0, confirmedCodeCount: first & 0x7F)
    }

    func freezeFrame() throws -> FreezeFrame? {
        guard let codeBytes = try value(mode: "02", pid: "02"), codeBytes.count >= 2,
              let triggeringCode = decodeCode(first: codeBytes[0], second: codeBytes[1]) else { return nil }
        var frame = FreezeFrame(triggeringCode: triggeringCode)
        frame.engineLoadPercent = try optionalValue(mode: "02", pid: "04").map { Double($0[0]) * 100 / 255 }
        frame.coolantCelsius = try optionalValue(mode: "02", pid: "05").map { Double($0[0]) - 40 }
        frame.shortTermFuelTrimPercent = try optionalValue(mode: "02", pid: "06").map { Double($0[0]) * 100 / 128 - 100 }
        frame.longTermFuelTrimPercent = try optionalValue(mode: "02", pid: "07").map { Double($0[0]) * 100 / 128 - 100 }
        frame.engineRPM = try optionalValue(mode: "02", pid: "0C").map { Double(($0[0] << 8) + $0[1]) / 4 }
        frame.speedKPH = try optionalValue(mode: "02", pid: "0D").map { Double($0[0]) }
        frame.intakeAirCelsius = try optionalValue(mode: "02", pid: "0F").map { Double($0[0]) - 40 }
        frame.runtimeSeconds = try optionalValue(mode: "02", pid: "1F").map { Double(($0[0] << 8) + $0[1]) }
        return frame
    }

    func liveSnapshot() throws -> LiveSnapshot {
        var result = LiveSnapshot()
        result.engineRPM = try optionalValue(mode: "01", pid: "0C").map { Double(($0[0] << 8) + $0[1]) / 4 }
        result.speedKPH = try optionalValue(mode: "01", pid: "0D").map { Double($0[0]) }
        result.coolantCelsius = try optionalValue(mode: "01", pid: "05").map { Double($0[0]) - 40 }
        result.intakeAirCelsius = try optionalValue(mode: "01", pid: "0F").map { Double($0[0]) - 40 }
        result.throttlePercent = try optionalValue(mode: "01", pid: "11").map { Double($0[0]) * 100 / 255 }
        result.controlModuleVoltage = try optionalValue(mode: "01", pid: "42").map { Double(($0[0] << 8) + $0[1]) / 1000 }
        return result
    }


    func capturedABSTrace() -> [ABSTrace] {
        operationLock.lock(); defer { operationLock.unlock() }
        return absTrace
    }

    private func beginABS(addressing: FordModuleAddressing, preflight: ABSValidationPreflight, vehicleVIN: String? = nil, adapterInformation: String = "Not captured") {
        absTrace = []
        var profile = addressing
        // Observation belongs to this session, not a previous backup or caller-provided label.
        profile.status = profile.requestID == FordModuleAddressing.candidateRequestID && profile.responseID == FordModuleAddressing.candidateResponseID ? .candidate : .userConfigured
        profile.observedAt = nil
        absSession = ABSValidationSession(startedAt: Date(), vehicleVIN: vehicleVIN, adapterInformation: adapterInformation,
                                          preflight: preflight, addressing: profile)
        captureABSAdapter = true
    }

    private func finishABS() -> ABSValidationSession {
        captureABSAdapter = false
        absSession!.finishedAt = Date()
        absSession!.transcript = absTrace
        transcriptLock.lock()
        absSession!.adapterExchanges = transcript.filter { $0.timestamp >= absSession!.startedAt }
        transcriptLock.unlock()
        return absSession!
    }

    private func absAdapterCommand(_ command: String) throws {
        let response = try send(command, timeout: 3)
        guard AdapterCommandResponse.acknowledges(command: command, raw: response) else {
            throw ABSValidationFailure(outcome: .adapterFailure, message: "Adapter did not acknowledge \(command): \(response)")
        }
    }

    private func configureABS(_ profile: FordModuleAddressing) throws {
        // Explicit receive filter and FC mapping: no implicit RxID-8 assumption for custom profiles.
        for command in ["STP 33", "STCAF 0", "ATCAF1", "ATCFC1", "ATD0", "ATH1", "ATS1", "STCSEGR 0", "STCFCPC",
                        String(format: "ATSH%03X", profile.requestID),
                        String(format: "STCFCPA %03X, %03X", profile.requestID, profile.responseID),
                        "STFFCC", String(format: "STFFCA %03X, 7FF", profile.responseID),
                        String(format: "ATCRA%03X", profile.responseID)] {
            try absAdapterCommand(command)
        }
        absTrace.append(.init(timestamp: Date(), direction: "TX", canID: profile.requestID, rawCAN: nil, payload: nil,
                              detail: "Adapter instructed: CAF1 inserts request PCI/padding; CFC1 generates FC internally for the configured STCFCPA pair and exact STFFCA response-ID filter. ATH1 + STCSEGR 0 retain reported RX PCI. TX/FC transmission, exact padding, FC bytes, timing and count are unobserved.",
                              visibility: .logical, frameType: .validation))
    }

    private func restoreAfterABS() throws {
        for command in ["ATCRA", "STCFCPC", "ATAR", "ATH0", "ATS0", "STCSEGR 0", "ATSH7DF"] { try absAdapterCommand(command) }
    }

    private func storeABSReadResult(_ result: ABSReadResult, request: [UInt8]) {
        if request == [0x22, 0xE6, 0xF3] { absSession!.protocolVersionResult = result }
        else if request == [0x22, 0xF1, 0x87] { absSession!.f187Result = result }
        else { absSession!.dtcResult = result }
    }

    private func absRequest(_ bytes: [UInt8], profile: FordModuleAddressing) throws -> [UInt8] {
        guard bytes == [0x19, 0x02, 0xFF] || bytes == [0x22, 0xF1, 0x87] || bytes == [0x22, 0xE6, 0xF3], absSession?.preflight.readOnly == true else {
            throw OBDClientError.unsafeCommand(bytes.hex)
        }
        let identification = bytes == [0x22, 0xF1, 0x87]
        let pending = ABSReadResult(status: .failed, detail: "Request started; no valid response yet")
        storeABSReadResult(pending, request: bytes)
        absTrace.append(.diagnostic(direction: "TX", canID: profile.requestID, payload: bytes, visibility: .logical))
        for frame in try ISOTP.frames(payload: bytes, id: profile.requestID) {
            absTrace.append(.init(timestamp: Date(), direction: "TX", canID: frame.id, rawCAN: frame.bytes, payload: nil,
                                  detail: "Logical ISO-TP frame implied by the submitted payload and CAF1. Not observed on wire; adapter padding is unobserved.",
                                  visibility: .logical, frameType: .classify(frame.bytes)))
        }
        let raw: String
        do { raw = try send(bytes.hex.replacingOccurrences(of: " ", with: ""), timeout: 5, interpretAdapterErrors: false) }
        catch {
            if let error = error as? OBDTransportFailure, !error.partialResponse.isEmpty {
                _ = recordABSFrames(error.partialResponse, profile: profile)
            }
            throw error
        }
        let frames = recordABSFrames(raw, profile: profile)
        let lines = raw.replacingOccurrences(of: ">", with: "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
        let badLines = lines.filter { (try? ABSCANParser.parseLine($0)) == nil && $0 != "NO DATA" }
        if let bad = badLines.first {
            let adapterStatus = ["CAN ERROR", "BUS ERROR", "BUS BUSY", "UNABLE", "?", "BUFFER FULL", "STOPPED", "FC RX TIMEOUT", "DATA ERROR", "<RX ERROR"]
            let outcome: ABSValidationOutcome = adapterStatus.contains(where: { bad.contains($0) }) ? .adapterFailure : .transportFailure
            throw ABSValidationFailure(outcome: outcome, message: "Unrecognized/status adapter output retained: \(bad)")
        }
        guard !frames.isEmpty else {
            absTrace.append(.init(timestamp: Date(), direction: "ERROR", canID: profile.responseID, rawCAN: nil, payload: nil,
                                  detail: "No adapter-reported CAN response; not evidence of an absent module.", visibility: .logical, frameType: .timeout))
            throw ABSValidationFailure(outcome: identification ? .transportFailure : .noResponse, message: identification ? "No response to F187; the prior valid ABS DTC response is preserved" : "ABS did not respond within the adapter response window")
        }
        let expected = frames.filter { $0.id == profile.responseID }
        guard !expected.isEmpty else { throw ABSValidationFailure(outcome: .trafficWithoutResponse, message: "CAN traffic reported only on unexpected IDs; no response accepted") }
        // FC frames are retained and classified; they are control traffic, not UDS response bytes.
        let flowFrames = expected.filter { ISOTPFrameType.classify($0.bytes) == .flowControl }
        guard flowFrames.allSatisfy({ $0.bytes.count >= 3 && $0.bytes[0] & 0x0F <= 2 }) else {
            throw ABSValidationFailure(outcome: .transportFailure, message: "Malformed flow-control frame retained")
        }
        let dataFrames = expected.filter { ISOTPFrameType.classify($0.bytes) != .flowControl }
        guard !dataFrames.isEmpty else { throw ABSValidationFailure(outcome: .trafficWithoutResponse, message: "Only flow-control traffic reported; no diagnostic response") }
        let payload: [UInt8]
        do { payload = try ISOTP.assemble(dataFrames) }
        catch { throw ABSValidationFailure(outcome: .transportFailure, message: "ISO-TP reconstruction failed: \(error.localizedDescription)") }
        absTrace.append(.diagnostic(direction: "RX", canID: profile.responseID, payload: payload, visibility: .reconstructed))
        var result = ABSReadResult(status: .failed, payload: payload, detail: DiagnosticResponse.summary(payload))
        do { _ = try DiagnosticResponse.validate(payload, request: bytes) }
        catch {
            if case OBDClientError.negativeResponse(_, let nrc) = error {
                // A syntactically valid negative response from the configured response
                // ID proves that this request/response address pair reaches an ECU,
                // even though the requested service itself was rejected.
                absSession!.addressing.markObserved(at: Date())
                absTrace.append(.init(timestamp: Date(), direction: "RX", canID: profile.responseID, rawCAN: nil, payload: nil,
                                      detail: "Address pair observed in this session from a valid negative diagnostic response. Service support and programming compatibility are separate questions.",
                                      visibility: .logical, frameType: .validation))
                result.status = .negative; result.nrc = nrc
                storeABSReadResult(result, request: bytes)
                throw ABSValidationFailure(outcome: .negativeResponse, message: error.localizedDescription)
            }
            storeABSReadResult(result, request: bytes)
            throw ABSValidationFailure(outcome: .trafficWithoutResponse, message: "Unknown/unexpected diagnostic response retained: \(payload.hex). \(error.localizedDescription)")
        }
        result.status = .positive
        storeABSReadResult(result, request: bytes)
        absSession!.addressing.markObserved(at: Date())
        absTrace.append(.init(timestamp: Date(), direction: "RX", canID: profile.responseID, rawCAN: nil, payload: nil,
                              detail: "Address pair observed in this session after a matching valid positive diagnostic response. Vehicle/module applicability still requires user context; no programming compatibility implied.", visibility: .logical, frameType: .validation))
        return payload
    }

    @discardableResult
    private func recordABSFrames(_ raw: String, profile: FordModuleAddressing) -> [CANFrame] {
        var frames: [CANFrame] = []
        for line in raw.replacingOccurrences(of: ">", with: "").split(whereSeparator: \.isNewline) {
            guard let frame = try? ABSCANParser.parseLine(String(line)) else {
                absTrace.append(.init(timestamp: Date(), direction: "RX", canID: nil, rawCAN: nil, payload: nil,
                                      detail: "Unknown/status adapter line preserved verbatim", visibility: .adapter, frameType: .unknown, adapterText: String(line)))
                continue
            }
            frames.append(frame)
            let type = ISOTPFrameType.classify(frame.bytes)
            absTrace.append(.init(timestamp: Date(), direction: "RX", canID: frame.id, rawCAN: frame.bytes, payload: nil,
                                  detail: frame.id == profile.responseID ? "Adapter-reported RX frame (host parse timestamp)" : "Unexpected CAN ID; retained but not accepted as ABS response",
                                  visibility: .physical, frameType: type))
            if type == .firstFrame && frame.id == profile.responseID {
                absTrace.append(.init(timestamp: Date(), direction: "TX", canID: profile.requestID, rawCAN: nil, payload: nil,
                                      detail: "Automatic FC instructed by ATCFC1, STCFCPA and STFFCA if this is a valid First Frame. Adapter handles FC internally; actual transmission, bytes, block size, STmin, repeats and timing are unobserved. This is expected logical behavior, not confirmation of a transmitted FC.",
                                      visibility: .logical, frameType: .flowControl))
            }
        }
        return frames
    }

    private func performABSRead(profile: FordModuleAddressing, readIdentification: Bool) throws {
        try configureABS(profile)
        // The communication test is the DTC read itself; no redundant/undocumented probe.
        let payload = try absRequest([0x19, 0x02, 0xFF], profile: profile)
        absSession!.dtcs = try FordABSService.decodeDTCs(payload)
        if readIdentification {
            let value = Array(try absRequest([0x22, 0xF1, 0x87], profile: profile).dropFirst(3))
            absSession!.module.partNumber = value.allSatisfy { (0x20...0x7E).contains($0) } ? String(decoding: value, as: UTF8.self) : value.hex
        }
        try restoreAfterABS()
        absSession!.outcome = .responded
        absSession!.detail = "Valid addressed DTC response received. No configuration or write-capable services invoked."
    }

    private func failABS(_ error: Error) {
        let outcome: ABSValidationOutcome
        if let failure = error as? ABSValidationFailure { outcome = failure.outcome }
        else if error is OBDTransportFailure { outcome = .transportFailure }
        else if error.localizedDescription.localizedCaseInsensitiveContains("timed out") || error.localizedDescription.localizedCaseInsensitiveContains("lost communication") { outcome = .transportFailure }
        else { outcome = .adapterFailure }
        absSession!.outcome = outcome; absSession!.detail = error.localizedDescription; absSession!.requiresReconnect = true
        absTrace.append(.init(timestamp: Date(), direction: "ERROR", canID: nil, rawCAN: nil, payload: nil,
                              detail: outcome.rawValue + ": " + error.localizedDescription, visibility: .logical,
                              frameType: error.localizedDescription.localizedCaseInsensitiveContains("timed out") ? .timeout : .transportError))
        // No retries, fallback, session-control, or restoration commands after a failure.
        transport.close()
    }

    func readABS(addressing: FordModuleAddressing, readIdentification: Bool = false) throws -> ABSBackup {
        operationLock.lock(); defer { operationLock.unlock() }
        try addressing.validate()
        beginABS(addressing: addressing, preflight: ABSValidationPreflight())
        do { try performABSRead(profile: addressing, readIdentification: readIdentification) }
        catch { failABS(error); _ = finishABS(); throw error }
        return backupForABS(finishABS())
    }

    func validateOriginalABS(addressing: FordModuleAddressing = .fusionCandidate, preflight: ABSValidationPreflight,
                             vehicleVIN: String? = nil, adapterInformation: String = "Not captured", readIdentification: Bool = false,
                             operation: ABSReadOperation = .dtcs) -> ABSValidationSession {
        operationLock.lock(); defer { operationLock.unlock() }
        beginABS(addressing: addressing, preflight: preflight, vehicleVIN: vehicleVIN, adapterInformation: adapterInformation)
        do {
            try addressing.validate()
            if operation == .protocolVersion {
                guard addressing.requestID == 0x760, addressing.responseID == 0x768, !readIdentification else {
                    throw ABSValidationFailure(outcome: .preflightBlocked, message: "Protocol version probe requires the observed 760/768 pair and no optional identification read.")
                }
                absSession!.protocolVersionResult = ABSReadResult()
            }
            guard preflight.blockers.isEmpty else { throw ABSValidationFailure(outcome: .preflightBlocked, message: preflight.blockers.joined(separator: "; ")) }
        } catch {
            absSession!.outcome = .preflightBlocked; absSession!.detail = error.localizedDescription
            absTrace.append(.init(timestamp: Date(), direction: "ERROR", canID: nil, rawCAN: nil, payload: nil, detail: error.localizedDescription, visibility: .logical, frameType: .validation))
            return finishABS() // No transport open or commands on failed preflight.
        }
        do {
            try transport.open()
            _ = try send("ATZ", timeout: 10) // Adapter reset only; never an ECU reset/session control.
            for command in ["ATE0", "ATL0", "ATS0", "ATH0", "ATSP6", "ATAT2", "STP 33", "STCAF 0", "ATCAF1", "ATCFC1", "ATCRA", "STCFCPC", "ATAR", "ATSH7DF"] { try absAdapterCommand(command) }
            let elm = try sendAdapterQuery("ATI")
            let device = try sendAdapterQuery("STDI").trimmingCharacters(in: .whitespacesAndNewlines)
            absSession!.adapterInformation = device + " • " + elm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard device.uppercased().contains("OBDLINK EX") else { throw ABSValidationFailure(outcome: .adapterFailure, message: "STDI did not identify an OBDLink EX: \(device)") }
            let voltageText = try sendAdapterQuery("ATRV")
            absSession!.adapterVoltage = AdapterCommandResponse.voltage(voltageText)
            guard let voltage = absSession!.adapterVoltage else {
                throw ABSValidationFailure(outcome: .preflightBlocked, message: "ABS validation stopped: adapter voltage is unavailable or invalid. Verify vehicle voltage externally before continuing.")
            }
            if voltage < 10.0 || voltage > 16.0 {
                throw ABSValidationFailure(
                    outcome: .preflightBlocked,
                    message: String(format: "ABS validation stopped: adapter reports %.1f V. The app requires 10-16 V for this read-only preflight; verify vehicle voltage externally before continuing. This software guard is not a verified module operating specification.", voltage)
                )
            }
            absTrace.append(.init(timestamp: Date(), direction: "TX", canID: 0x7DF, rawCAN: [2, 1, 0x0C], payload: [1, 0x0C],
                                  detail: "Logical generic OBD Mode 01 PID 0C RPM request. CAF1 supplies PCI/padding; no physical TX capture. Response headers are off for this existing generic query.", visibility: .logical, frameType: .singleFrame, service: 1))
            let rpmText = try send("010C", timeout: 5)
            if rpmText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "NO DATA" {
                let compact = rpmText.filter { !$0.isWhitespace }.uppercased()
                let bytes = hexBytes(rpmText)
                guard compact.count == 8, compact.allSatisfy({ "0123456789ABCDEF".contains($0) }), bytes.count == 4, bytes.prefix(2) == [0x41, 0x0C] else { throw ABSValidationFailure(outcome: .transportFailure, message: "Unexpected generic RPM response retained; cannot safely continue") }
                absTrace.append(.init(timestamp: Date(), direction: "RX", canID: nil, rawCAN: nil, payload: bytes.map(UInt8.init),
                                      detail: "Generic OBD Mode 01 PID 0C RPM response; physical response CAN ID/PCI not observable with headers off.", visibility: .reconstructed, frameType: .diagnosticPayload, service: 0x41, positiveResponse: true))
                let rpm = Double(bytes[2] * 256 + bytes[3]) / 4
                absSession!.engineRPM = rpm; absSession!.preflight.rpm = rpm
                guard rpm == 0 else { throw ABSValidationFailure(outcome: .preflightBlocked, message: "Engine RPM is \(rpm); validation stopped before any ABS request") }
            }
            absTrace.append(.init(timestamp: Date(), direction: "TX", canID: nil, rawCAN: nil, payload: nil,
                                  detail: "Read-only preflight passed. Engine OFF and absence of external write sessions are user confirmations; ATZ resets only the adapter, not an ECU diagnostic session. No session-control commands are sent.", visibility: .logical, frameType: .validation))
            if operation == .protocolVersion {
                try configureABS(addressing)
                let payload = try absRequest([0x22, 0xE6, 0xF3], profile: addressing)
                let version = payload[3]
                let known: [UInt8: String] = [0x0A: "Ford CAN diagnostic specification v2001.0", 0x0B: "Ford CAN diagnostic specification v2001.1", 0x0C: "Ford CAN diagnostic specification v2003.0"]
                let detail = known[version] ?? String(format: "Unknown diagnostic specification version 0x%02X; retain raw value without inferring services", version)
                absSession!.protocolVersionResult!.detail = detail
                try restoreAfterABS()
                absSession!.outcome = .responded
                absSession!.detail = detail + ". No DTC, identification or configuration read was attempted."
            } else {
                try performABSRead(profile: addressing, readIdentification: readIdentification)
            }
        } catch { failABS(error) }
        return finishABS()
    }

    func backupForABS(_ session: ABSValidationSession) -> ABSBackup {
        ABSBackup(capturedAt: session.startedAt, addressing: session.addressing, module: session.module, dtcs: session.dtcs,
                  configuration: [], transcript: session.transcript, adapterExchanges: session.adapterExchanges)
    }

    private func send(_ command: String, timeout: TimeInterval = 10, interpretAdapterErrors: Bool = true) throws -> String {
        operationLock.lock(); defer { operationLock.unlock() }
        guard SafetyPolicy.permits(command) else { throw OBDClientError.unsafeCommand(command) }
        // Ford Edge powertrain modules are normally on 11-bit / 500 kbit CAN.
        // A longer response window also accommodates an adapter waking up the bus.
        let response: String
        if captureABSAdapter {
            absTrace.append(.init(timestamp: Date(), direction: "TX", canID: nil, rawCAN: nil, payload: nil, detail: "Submitted adapter command", visibility: .adapter, frameType: .adapterCommand, adapterText: command))
        }
        do {
            response = try transport.transact(command, timeout: timeout)
        } catch {
            transcriptLock.lock()
            transcript.append(DiagnosticTranscriptEntry(timestamp: Date(), command: command, response: "TRANSPORT ERROR: \(error.localizedDescription)"))
            transcriptLock.unlock()
            if captureABSAdapter {
                absTrace.append(.init(timestamp: Date(), direction: "ERROR", canID: nil, rawCAN: nil, payload: nil, detail: error.localizedDescription,
                                      visibility: .adapter, frameType: error.localizedDescription.localizedCaseInsensitiveContains("timed out") ? .timeout : .transportError,
                                      adapterText: (error as? OBDTransportFailure)?.partialResponse))
            }
            throw error
        }
        if captureABSAdapter {
            absTrace.append(.init(timestamp: Date(), direction: "RX", canID: nil, rawCAN: nil, payload: nil, detail: "Verbatim adapter response", visibility: .adapter, frameType: .adapterResponse, adapterText: response))
        }
        transcriptLock.lock()
        transcript.append(DiagnosticTranscriptEntry(timestamp: Date(), command: command, response: response))
        transcriptLock.unlock()
        if interpretAdapterErrors && AdapterCommandResponse.containsError(AdapterCommandResponse.meaningfulLines(command: command, raw: response)) {
            throw OBDClientError.adapter(response)
        }
        return response
    }

    private func sendAdapterQuery(_ command: String) throws -> String {
        let raw = try send(command, timeout: 3)
        return AdapterCommandResponse.meaningfulLines(command: command, raw: raw).joined(separator: "\n")
    }

    private func optionalValue(mode: String, pid: String) throws -> [Int]? {
        do { return try value(mode: mode, pid: pid) }
        catch OBDClientError.noData { return nil }
    }

    private func value(mode: String, pid: String) throws -> [Int]? {
        let response = try send("\(mode)\(pid)")
        let bytes = hexBytes(response)
        let responseMode = (Int(mode, radix: 16) ?? 0) + 0x40
        guard let index = bytes.indices.dropLast().first(where: { bytes[$0] == responseMode && bytes[$0 + 1] == Int(pid, radix: 16)! }) else {
            if response.uppercased().contains("NO DATA") { return nil }
            throw OBDClientError.noData(response)
        }
        return Array(bytes.dropFirst(index + 2))
    }

    private func troubleCodes(command: String, source: String) throws -> [DiagnosticCode] {
        let bytes = hexBytes(try send(command))
        return decodeTroubleCodes(bytes: bytes, command: command, source: source)
    }

    /// Standard OBD services sent after a fixed physical CAN header.  The header
    /// provides module provenance, while Mode 03/07 supplies only the usual two-byte
    /// DTC format (not UDS status or failure-type bytes).
    private func addressedTroubleCodes(command: String, source: String, probe: FordModuleProbe) throws -> [DiagnosticCode] {
        let bytes = hexBytes(try send(command, timeout: 3))
        if let index = bytes.indices.dropLast(2).first(where: { bytes[$0] == 0x7F }) {
            throw OBDClientError.negativeResponse(service: UInt8(bytes[index + 1]), code: UInt8(bytes[index + 2]))
        }
        return decodeTroubleCodes(bytes: bytes, command: command, source: source).map {
            DiagnosticCode(id: $0.id, source: $0.source, module: probe.name, network: probe.network.rawValue)
        }
    }

    private func decodeTroubleCodes(bytes: [Int], command: String, source: String) -> [DiagnosticCode] {
        guard let responseIndex = bytes.firstIndex(of: command == "03" ? 0x43 : 0x47) else { return [] }
        let payload = Array(bytes.dropFirst(responseIndex + 1))
        return stride(from: 0, to: payload.count - 1, by: 2).compactMap { index in
            let first = payload[index], second = payload[index + 1]
            guard first != 0 || second != 0 else { return nil }
            return decodeCode(first: first, second: second).map { DiagnosticCode(id: $0, source: source) }
        }
    }

    private func isTimeout(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }

    private func isCANError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("can error")
    }

    private func udsTroubleCodes(for probe: FordModuleProbe) throws -> [DiagnosticCode] {
        let response: String
        do {
            response = try send("1902FF", timeout: 3)
        } catch {
            // Keep the normal adapter-reassembled fast path. If it never finishes,
            // repeat this read-only request with reassembly disabled. That preserves
            // individual ISO-TP frames in the snapshot and lets us distinguish a
            // silent ECU from an incomplete multi-frame exchange.
            guard isTimeout(error) else { throw error }
            _ = try send("STCSEGR 0")
            defer { _ = try? send("STCSEGR 1") }
            response = try send("1902FF", timeout: 5)
        }
        guard !response.uppercased().contains("NO DATA") else { return [] }
        let bytes = isoTPPayload(from: hexBytes(response))
        if let index = bytes.indices.dropLast(2).first(where: { bytes[$0] == 0x7F }) {
            throw OBDClientError.negativeResponse(service: UInt8(bytes[index + 1]), code: UInt8(bytes[index + 2]))
        }
        guard let index = bytes.indices.dropLast(2).first(where: { bytes[$0] == 0x59 && bytes[$0 + 1] == 0x02 }) else { return [] }
        // 59 02 <availability mask>, followed by 3-byte DTC + 1-byte status records.
        // The third DTC byte is retained verbatim. It is only an SAE failure-type
        // byte when the ECU's configured DTC format says it is.
        let payload = Array(bytes.dropFirst(index + 3))
        return stride(from: 0, to: payload.count - 3, by: 4).compactMap { offset in
            guard let code = decodeCode(first: payload[offset], second: payload[offset + 1]) else { return nil }
            let failureType = UInt8(payload[offset + 2])
            let status = UInt8(payload[offset + 3])
            return DiagnosticCode(
                id: code,
                source: "Ford enhanced • \(DiagnosticCode(id: code, source: "", statusByte: status).udsStatusSummary ?? "status unavailable")",
                module: probe.name,
                network: probe.network.rawValue,
                statusByte: status,
                failureTypeByte: failureType
            )
        }
    }

    /// `STCSEGR 0` prints ISO-TP protocol-control bytes. Reconstruct their payload
    /// locally; already reassembled output is retained unchanged.
    private func isoTPPayload(from bytes: [Int]) -> [Int] {
        guard let first = bytes.first else { return [] }
        if first >> 4 == 0x0, first <= 0x0F, bytes.count > first {
            return Array(bytes.dropFirst().prefix(first))
        }
        guard first >> 4 == 0x1, bytes.count >= 2 else { return bytes }
        let expectedCount = ((first & 0x0F) << 8) | bytes[1]
        var payload = Array(bytes.dropFirst(2).prefix(6))
        var offset = 8
        var expectedSequence = 1
        while offset < bytes.count && payload.count < expectedCount {
            let pci = bytes[offset]
            guard pci >> 4 == 0x2, pci & 0x0F == expectedSequence & 0x0F else { break }
            payload.append(contentsOf: bytes.dropFirst(offset + 1).prefix(7))
            expectedSequence += 1
            offset += 8
        }
        return Array(payload.prefix(expectedCount))
    }

    /// UDS ReadDataByIdentifier. DID F187 is the standardized vehicle-manufacturer
    /// spare-part number, but it is optional and may be session-protected.
    /// Legacy snapshot field softwareIdentifier retains its name for compatibility.
    private func udsText(did: String) throws -> String? {
        let response = try send("22\(did)", timeout: 3)
        guard !response.uppercased().contains("NO DATA") else { return nil }
        let bytes = hexBytes(response)
        let didBytes = [Int(did.prefix(2), radix: 16)!, Int(did.suffix(2), radix: 16)!]
        guard let index = bytes.indices.dropLast(2).first(where: { bytes[$0] == 0x62 && bytes[$0 + 1] == didBytes[0] && bytes[$0 + 2] == didBytes[1] }) else { return nil }
        let text = String(decoding: bytes.dropFirst(index + 3).filter { $0 >= 0x20 && $0 <= 0x7E }.map(UInt8.init), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func mode09Text(pid: String) throws -> String? {
        guard let payload = try optionalValue(mode: "09", pid: pid) else { return nil }
        // Mode 09 text responses can include an item-count byte. Retain printable bytes only.
        let text = String(decoding: payload.filter { $0 >= 0x20 && $0 <= 0x7E }.map(UInt8.init), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func decodeCode(first: Int, second: Int) -> String? {
        guard first != 0 || second != 0 else { return nil }
        let families = ["P", "C", "B", "U"]
        return "\(families[first >> 6])\((first >> 4) & 0x3)\(String(first & 0xF, radix: 16).uppercased())\(String(format: "%02X", second))"
    }

    private func hexBytes(_ response: String) -> [Int] {
        response
            .split(whereSeparator: { !$0.isHexDigit })
            .flatMap { token -> [Int] in
                stride(from: 0, to: token.count - 1, by: 2).compactMap { start in
                    Int(token.dropFirst(start).prefix(2), radix: 16)
                }
            }
    }
}
