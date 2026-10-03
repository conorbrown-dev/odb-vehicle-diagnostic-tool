import XCTest
@testable import EdgeDiagnostics

final class DiagnosticCLITests: XCTestCase {
    private let confirmations = DiagnosticCLIOptions.requiredConfirmations.sorted()
    private func arguments(_ command: String, output: URL) -> [String] {
        [command, "--port", "/dev/cu.usbserial-test", "--output", output.path] + (command == "voltage" ? [] : confirmations)
    }
    private func destination() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("cli-test-" + UUID().uuidString) }
    private func session(_ directory: URL) throws -> [String: Any] {
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ABS-validation.txt").path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("ABS-validation.json"))) as? [String: Any])
    }
    func testRejectsMissingConfirmationBeforeTransportCreation() {
        let folder = destination(); defer { try? FileManager.default.removeItem(at: folder) }
        for flag in confirmations {
            var created = false
            let args = arguments("abs-vin-start", output: folder).filter { $0 != flag }
            XCTAssertEqual(DiagnosticCLI.run(arguments: args, transportFactory: { _ in created = true; return CLITransport() }, emit: { _ in }), 2)
            XCTAssertFalse(created)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
    }
    func testRejectsArbitraryCommandsOptionsPortsAndMalformedArguments() {
        let folder = destination()
        let base = arguments("abs-vin-start", output: folder)
        var invalid: [[String]] = [[], ["raw", "22E301"], ["help", "--ignition-on"], ["ports", "--port", "/dev/cu.x"]]
        let forbiddenOptions: [[String]] = [["--request", "22E301"], ["--ignition-on"], ["--vehicle-vin"], ["--vehicle-vin", "INVALID"], ["--clear-dtcs"]]
        for options in forbiddenOptions { invalid.append(base + options) }
        invalid.append(["voltage", "--port", "/tmp/file", "--output", folder.path])
        invalid.append(["voltage", "--port", "/dev/cu.x/other", "--output", folder.path])
        for args in invalid {
            XCTAssertThrowsError(try DiagnosticCLIOptions(arguments: args), args.joined(separator: " "))
        }
    }
    func testEachCommandUsesOnlyItsExistingBoundedRequestAndExports() throws {
        for (command, request, result) in [("abs-version", "22E6F3", "protocolVersionResult"), ("abs-dtcs", "1800FF00", "fordContinuousDTCResult"), ("abs-vin-start", "22E300", "vinStartResult")] {
            let folder = destination(); defer { try? FileManager.default.removeItem(at: folder) }
            let transport = CLITransport()
            XCTAssertEqual(DiagnosticCLI.run(arguments: arguments(command, output: folder), transportFactory: { _ in transport }, emit: { _ in }), 0)
            XCTAssertEqual(transport.commands.filter { !$0.hasPrefix("AT") && !$0.hasPrefix("ST") }, ["010C", request])
            XCTAssertTrue(transport.closed)
            let json = try session(folder)
            XCTAssertEqual(json["outcome"] as? String, "ABS responded")
            XCTAssertEqual((json[result] as? [String: Any])?["status"] as? String, "positive")
        }
    }
    func testNegativeResponseExitsNonzeroAndExportsWithoutRetry() throws {
        let folder = destination(); defer { try? FileManager.default.removeItem(at: folder) }
        let transport = CLITransport(); transport.vinReply = "768 03 7F 22 31"
        XCTAssertEqual(DiagnosticCLI.run(arguments: arguments("abs-vin-start", output: folder), transportFactory: { _ in transport }, emit: { _ in }), 1)
        XCTAssertEqual(transport.commands.last, "22E300")
        XCTAssertEqual(transport.commands.filter { $0 == "22E300" }.count, 1)
        let json = try session(folder)
        XCTAssertEqual((json["vinStartResult"] as? [String: Any])?["nrc"] as? Int, 0x31)
    }
    func testLowVoltageAndRunningEngineBlockABSAndRetainCapture() throws {
        for running in [false, true] {
            let folder = destination(); defer { try? FileManager.default.removeItem(at: folder) }
            let transport = CLITransport()
            if running { transport.rpm = "410C0FA0" } else { transport.voltage = "7.7V" }
            XCTAssertEqual(DiagnosticCLI.run(arguments: arguments("abs-vin-start", output: folder), transportFactory: { _ in transport }, emit: { _ in }), 1)
            XCTAssertFalse(transport.commands.contains("22E300"))
            XCTAssertEqual(try session(folder)["outcome"] as? String, "Preflight blocked")
            XCTAssertTrue(transport.closed)
        }
    }
    func testUnwritableDestinationStopsBeforeTransport() throws {
        let file = destination(); defer { try? FileManager.default.removeItem(at: file) }
        try Data("file".utf8).write(to: file)
        var created = false
        XCTAssertEqual(DiagnosticCLI.run(arguments: arguments("abs-vin-start", output: file), transportFactory: { _ in created = true; return CLITransport() }, emit: { _ in }), 2)
        XCTAssertFalse(created)
    }
    func testVoltageOnlyATRVAndFailedReplyRetained() throws {
        for reply in ["12.7V", "bad"] {
            let folder = destination(); defer { try? FileManager.default.removeItem(at: folder) }
            let transport = CLITransport(); transport.voltage = reply
            XCTAssertEqual(DiagnosticCLI.run(arguments: arguments("voltage", output: folder), transportFactory: { _ in transport }, emit: { _ in }), reply == "bad" ? 1 : 0)
            XCTAssertEqual(transport.commands, ["ATRV"])
            XCTAssertTrue(transport.closed)
            let subdir = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: subdir.appendingPathComponent("adapter-voltage.json"))) as? [String: Any])
            XCTAssertEqual((json["adapterExchanges"] as? [[String: Any]])?.first?["response"] as? String, reply)
        }
    }
}
private final class CLITransport: OBDTransport, @unchecked Sendable {
    var commands: [String] = []
    var voltage = "12.7V"
    var rpm = "410C0000"
    var vinReply = "768 07 62 E3 00 00 00 00 33"
    var closed = false
    func open() throws {}
    func close() { closed = true }
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        commands.append(command)
        switch command {
        case "ATZ", "ATI": return "ELM327 v1.4b"
        case "STDI": return "OBDLink EX r2.7.1"
        case "ATRV": return voltage
        case "010C": return rpm
        case "22E300": return vinReply
        case "22E6F3": return "768 04 62 E6 F3 0C"
        case "1800FF00": return "768 02 58 00"
        default: return "OK"
        }
    }
}
