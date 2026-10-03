import XCTest
@testable import EdgeDiagnostics

final class AdapterVoltageCheckTests: XCTestCase {
    func testStandaloneCheckSendsOnlyATRVAndRetainsRawReply() throws {
        let transport = VoltageCheckTransport(response: "ATRV\r12.5V\r\r>")
        let client = OBDClient(transport: transport)
        XCTAssertEqual(try client.checkAdapterVoltage(), 12.5)
        XCTAssertEqual(transport.commands, ["ATRV"])
        XCTAssertTrue(transport.closed)
        let exchanges = client.drainTranscript()
        XCTAssertEqual(exchanges.count, 1)
        XCTAssertEqual(exchanges.first?.response, transport.response)
    }

    func testStandaloneCheckReportsLowVoltageWithoutSendingVehicleRequests() throws {
        let transport = VoltageCheckTransport(response: "7.7V\r\r")
        XCTAssertEqual(try OBDClient(transport: transport).checkAdapterVoltage(), 7.7)
        XCTAssertEqual(transport.commands, ["ATRV"])
        XCTAssertTrue(transport.closed)
    }

    func testMalformedErrorAndTimeoutClosePortWithoutRetries() {
        for response in ["NaN", "ATRV\r?\r>", "12.5V\rERROR", ""] {
            let transport = VoltageCheckTransport(response: response)
            let client = OBDClient(transport: transport)
            XCTAssertThrowsError(try client.checkAdapterVoltage())
            XCTAssertEqual(transport.commands, ["ATRV"])
            XCTAssertTrue(transport.closed)
            XCTAssertEqual(client.drainTranscript().first?.response, response)
        }
        let transport = VoltageCheckTransport(response: "partial", timeout: true)
        let client = OBDClient(transport: transport)
        XCTAssertThrowsError(try client.checkAdapterVoltage())
        XCTAssertEqual(transport.commands, ["ATRV"])
        XCTAssertTrue(transport.closed)
        XCTAssertTrue(client.drainTranscript().first?.response.contains("partial") == true)
    }
}

private final class VoltageCheckTransport: OBDTransport, @unchecked Sendable {
    let response: String
    let timeout: Bool
    var commands: [String] = []
    var closed = false
    init(response: String, timeout: Bool = false) { self.response = response; self.timeout = timeout }
    func open() throws {}
    func close() { closed = true }
    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        commands.append(command)
        if self.timeout { throw OBDTransportFailure(timedOut: true, partialResponse: response, message: "Timed out") }
        return response
    }
}
