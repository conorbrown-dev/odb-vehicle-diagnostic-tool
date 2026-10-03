import Foundation
import Darwin

@main
@MainActor
enum DiagnosticsEntryPoint {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--cli" {
            exit(DiagnosticCLI.run(arguments: Array(arguments.dropFirst())))
        }
        guard arguments.isEmpty else {
            FileHandle.standardError.write(Data("Use --cli help for terminal commands.\n".utf8))
            exit(2)
        }
        EdgeDiagnosticsApp.main()
    }
}

struct DiagnosticCLIOptions {
    enum Command: String { case help, ports, voltage, absVersion = "abs-version", absDTCs = "abs-dtcs", absVINStart = "abs-vin-start" }
    let command: Command
    var port: String?
    var output: String?
    var vehicleVIN: String?
    var confirmations: Set<String> = []
    static let requiredConfirmations: Set<String> = ["--ignition-on", "--engine-off", "--parked", "--original-abs-installed", "--other-tools-closed", "--read-only"]

    init(arguments: [String]) throws {
        guard let first = arguments.first, let command = Command(rawValue: first) else {
            throw ABSError.invalid("Specify a command; use --cli help.")
        }
        self.command = command
        var index = 1
        var seen: Set<String> = []
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw ABSError.invalid("Duplicate option: " + flag) }
            if Self.requiredConfirmations.contains(flag) {
                confirmations.insert(flag)
            } else if ["--port", "--output", "--vehicle-vin"].contains(flag) {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw ABSError.invalid("Missing value for " + flag) }
                switch flag {
                case "--port": port = arguments[index]
                case "--output": output = arguments[index]
                default: vehicleVIN = arguments[index]
                }
            } else { throw ABSError.invalid("Unknown option: " + flag) }
            index += 1
        }
        if command == .help || command == .ports {
            guard seen.isEmpty else { throw ABSError.invalid("This command takes no options") }
            return
        }
        guard let port, port.hasPrefix("/dev/cu."), !port.dropFirst(8).isEmpty,
              !port.dropFirst(8).contains("/"), !port.contains("..") else {
            throw ABSError.invalid("Supply an explicit macOS /dev/cu.* serial device with --port; no automatic selection")
        }
        guard let output, !output.isEmpty else { throw ABSError.invalid("Supply --output for raw JSON and text captures") }
        if let vehicleVIN {
            guard vehicleVIN.utf8.count == 17, vehicleVIN.utf8.allSatisfy({ "0123456789ABCDEFGHJKLMNPRSTUVWXYZ".utf8.contains($0) }) else {
                throw ABSError.invalid("--vehicle-vin must be a 17-character VIN; it is a supplied reference, not read from ABS")
            }
        }
        if command != .voltage {
            let missing = Self.requiredConfirmations.subtracting(confirmations).sorted()
            guard missing.isEmpty else { throw ABSError.invalid("Fresh human confirmations required: " + missing.joined(separator: " ")) }
        } else {
            guard confirmations.isEmpty, vehicleVIN == nil else { throw ABSError.invalid("voltage takes only --port and --output") }
        }
    }

    var operation: ABSReadOperation? {
        switch command {
        case .absVersion: return .protocolVersion
        case .absDTCs: return .fordContinuousDTCs
        case .absVINStart: return .vinStart
        default: return nil
        }
    }
}

/// Uses the GUI's OBDClient and safety policy; no raw-command, write, sweep or retry interface.
enum DiagnosticCLI {
    static let help = """
    Usage: swift run EdgeDiagnostics --cli <command> [options]
    Commands: help, ports, voltage, abs-version, abs-dtcs, abs-vin-start
    Live reads require: --port /dev/cu.DEVICE --output DIRECTORY
    ABS reads also require fresh human confirmations for each invocation:
      --ignition-on --engine-off --parked --original-abs-installed --other-tools-closed --read-only
    Optional ABS reference: --vehicle-vin VIN (supplied reference; no extra VIN request)
    Fully quit the diagnostic GUI and other serial tools before running.
    Each ABS invocation sends one selected read to 760/768 after existing EX/voltage/RPM preflight.
    Captures are saved in a unique subdirectory, including failed attempts. Non-positive outcomes exit 1.
    No interactive prompt, automatic selection, retry, session control, clearing or writes.
    """

    static func ports() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usb") || $0.hasPrefix("cu.SLAB") }
            .sorted().map { "/dev/" + $0 }
    }

    static func run(arguments: [String], transportFactory: (String) -> any OBDTransport = { SerialTransport(path: $0) },
                    emit: (String) -> Void = { print($0) }) -> Int32 {
        let options: DiagnosticCLIOptions
        do { options = try DiagnosticCLIOptions(arguments: arguments) }
        catch { emit("CLI argument error: " + error.localizedDescription); return 2 }
        if options.command == .help { emit(help); return 0 }
        if options.command == .ports { emit(ports().joined(separator: "\n")); return 0 }

        // Establish a writable destination before opening the adapter or sending anything.
        let directory = URL(fileURLWithPath: options.output!, isDirectory: true)
            .appendingPathComponent("capture-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let invocation = Invocation(command: options.command.rawValue, port: options.port!, suppliedVehicleVIN: options.vehicleVIN,
                                        humanConfirmationFlags: options.confirmations.sorted())
            try ABSValidationSession.jsonEncoder().encode(invocation).write(to: directory.appendingPathComponent("invocation.json"), options: .atomic)
            try Data("Read-only capture pending\n".utf8).write(to: directory.appendingPathComponent("pending.txt"), options: .atomic)
        } catch { emit("Capture destination error; adapter not opened: " + error.localizedDescription); return 2 }
        let client = OBDClient(transport: transportFactory(options.port!))
        defer { client.disconnect() }
        if let operation = options.operation {
            let preflight = ABSValidationPreflight(adapterConnected: true, ignitionOn: true, engineOff: true, noWriteSessionConfirmed: true)
            let session = client.validateOriginalABS(preflight: preflight, vehicleVIN: options.vehicleVIN, operation: operation)
            do {
                try session.jsonData().write(to: directory.appendingPathComponent("ABS-validation.json"), options: .atomic)
                try session.textData().write(to: directory.appendingPathComponent("ABS-validation.txt"), options: .atomic)
                try FileManager.default.removeItem(at: directory.appendingPathComponent("pending.txt"))
            } catch {
                emit("Export failed: " + error.localizedDescription + "\n" + String(decoding: session.textData(), as: UTF8.self))
                return 1
            }
            emit("Outcome: " + session.outcome.rawValue + "\n" + session.detail)
            emit("Voltage: \(session.adapterVoltage.map { String(format: "%.2f V", $0) } ?? "unavailable"); RPM: \(session.engineRPM.map { String(format: "%.0f", $0) } ?? "unavailable (human engine-off confirmation)")")
            for record in session.fordContinuousDTCRecords ?? [] { emit("\(record.code) raw Ford status \(String(format: "%02X", record.rawStatus))") }
            emit("Captures: " + directory.path)
            return session.outcome == .responded ? 0 : 1
        }
        var voltage: Double?
        var failure: String?
        do { voltage = try client.checkAdapterVoltage() } catch { failure = error.localizedDescription }
        let exchanges = client.drainTranscript()
        let capture = VoltageCapture(port: options.port!, voltage: voltage, error: failure, adapterExchanges: exchanges)
        do {
            try ABSValidationSession.jsonEncoder().encode(capture).write(to: directory.appendingPathComponent("adapter-voltage.json"), options: .atomic)
            let raw = exchanges.map { "COMMAND \($0.command)\nRESPONSE \($0.response)" }.joined(separator: "\n")
            try Data(("Voltage: \(voltage.map(String.init(describing:)) ?? "unavailable")\nError: \(failure ?? "none")\n" + raw).utf8)
                .write(to: directory.appendingPathComponent("adapter-voltage.txt"), options: .atomic)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("pending.txt"))
        } catch { emit("Export failed: \(error.localizedDescription)\nRaw exchanges: \(exchanges)"); return 1 }
        emit(failure ?? "Adapter voltage: \(voltage!) V")
        emit("Captures: " + directory.path)
        return failure == nil ? 0 : 1
    }

    private struct Invocation: Encodable {
        let startedAt = Date()
        let command: String
        let port: String
        let suppliedVehicleVIN: String?
        let humanConfirmationFlags: [String]
        let confirmationSource = "CLI flags supplied by operator after human verification; not sensor-verified or reusable authorization"
    }

    private struct VoltageCapture: Encodable {
        let capturedAt = Date()
        let port: String
        let voltage: Double?
        let error: String?
        let adapterExchanges: [DiagnosticTranscriptEntry]
    }
}
