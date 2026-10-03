import XCTest
@testable import EdgeDiagnostics

final class FactoryABSReferenceTests: XCTestCase {
    private let vin = "1M8GDM9AXKP042788" // Public check-digit example; fixture is not vehicle configuration.
    private var xml: String {
        "<AS_BUILT_DATA><VEHICLE><VIN>\(vin)</VIN><BCE_MODULE><DATA LABEL=\"760-01-01\"><CODE>3346</CODE><CODE>4148</CODE><CODE>50BB</CODE></DATA></BCE_MODULE><NODEID>760<E610>TEST-HARDWARE</E610><E611>TEST-STRATEGY</E611></NODEID><ERROR><ERRORCODE> 614</ERRORCODE><ERRORMSG> CCC DATA NOT FOUND</ERRORMSG></ERROR></VEHICLE></AS_BUILT_DATA>"
    }
    private func parse(_ text: String) throws -> FactoryABSReference { try .parse(Data(text.utf8), expectedVIN: vin, sourcePath: "fixture.ab") }
    func testPreservesGroupsIdentifiersWarningsAndProvenance() throws {
        let reference = try parse(xml)
        XCTAssertEqual(reference.blocks.first?.codeGroups, ["3346", "4148", "50BB"])
        XCTAssertEqual(reference.nodeIdentifiers["E611"], "TEST-STRATEGY")
        XCTAssertEqual(reference.sourceErrors.first?.code, "614")
        XCTAssertEqual(reference.sourceSHA256.count, 64)
        XCTAssertTrue(reference.provenance.contains("not ECU-read"))
        XCTAssertTrue(reference.validation.contains("checksum"))
        XCTAssertTrue(reference.text.contains("760-01-01 3346 4148 50BB"))
    }
    func testRejectsMissingDuplicateOrMalformedABSDataAndErrorDownloads() {
        let invalid = [xml.replacingOccurrences(of: "760-01-01", with: "737-01-01"),
                       xml.replacingOccurrences(of: "</BCE_MODULE>", with: "<DATA LABEL=\"760-01-01\"><CODE>3346</CODE><CODE>4148</CODE><CODE>50BB</CODE></DATA></BCE_MODULE>"),
                       xml.replacingOccurrences(of: "50BB", with: "ZZZZ"),
                       xml.replacingOccurrences(of: "50BB", with: "5"),
                       xml.replacingOccurrences(of: "<CODE>50BB</CODE>", with: ""),
                       xml.replacingOccurrences(of: " 614", with: " 613"),
                       xml.replacingOccurrences(of: "</VEHICLE>", with: "<NODEID>760<E610>OTHER</E610></NODEID></VEHICLE>"),
                       xml.replacingOccurrences(of: "<E611>", with: "<E610>"),
                       "<!DOCTYPE AS_BUILT_DATA [<!ENTITY test 'value'>]>" + xml,
                       String(xml.dropLast(5))]
        for text in invalid { XCTAssertThrowsError(try parse(text)) }
    }
    func testVINMismatchAndBadCheckDigitAreRejected() {
        XCTAssertTrue(FactoryABSReference.validVIN(vin))
        XCTAssertFalse(FactoryABSReference.validVIN("1M8GDM9ABKP042788"))
        XCTAssertFalse(FactoryABSReference.validVIN("1M8GDM9A0KP042788"))
        XCTAssertThrowsError(try parse(xml.replacingOccurrences(of: vin, with: "1M8GDM9A0KP042788")))
    }
    func testOfflineCLIExportsWithoutCreatingTransport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("input.ab")
        try Data(xml.utf8).write(to: source)
        let output = directory.appendingPathComponent("output")
        let args = ["factory-abs", "--input", source.path, "--output", output.path, "--vehicle-vin", vin]
        var created = false
        XCTAssertEqual(DiagnosticCLI.run(arguments: args, transportFactory: { _ in created = true; return UnusedFactoryTransport() }, emit: { _ in }), 0)
        XCTAssertFalse(created)
        let result = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("original.ab")), Data(xml.utf8))
        let reference = try JSONDecoder().decode(FactoryABSReference.self, from: Data(contentsOf: result.appendingPathComponent("factory-ABS-reference.json")))
        XCTAssertEqual(reference.vin, vin)
        XCTAssertThrowsError(try DiagnosticCLIOptions(arguments: args + ["--port", "/dev/cu.test"]))
    }
}
private struct UnusedFactoryTransport: OBDTransport {
    func open() throws { XCTFail("Offline import must not open a transport") }
    func close() {}
    func transact(_ command: String, timeout: TimeInterval) throws -> String { XCTFail("Offline import must not send requests"); return "" }
}
