import Foundation
import Darwin

/// Minimal POSIX serial transport for FTDI-backed OBDLink EX adapters.
final class SerialTransport: OBDTransport, @unchecked Sendable {
    private let path: String
    private var descriptor: Int32 = -1
    private let lock = NSLock()

    init(path: String) { self.path = path }

    func open() throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor == -1 else { return }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw OBDClientError.adapter("Could not open \(path). Check the FTDI driver and serial-device path.") }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { Darwin.close(fd); throw OBDClientError.adapter("Could not configure serial port.") }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSTOPB | PARENB)
        options.c_cflag = (options.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
        _ = cfsetspeed(&options, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { Darwin.close(fd); throw OBDClientError.adapter("Could not set serial speed.") }
        descriptor = fd
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func transact(_ command: String, timeout: TimeInterval) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { throw OBDClientError.adapter("Adapter is not connected.") }
        tcflush(descriptor, TCIFLUSH)
        let request = Array((command + "\r").utf8)
        guard Darwin.write(descriptor, request, request.count) == request.count else { throw OBDTransportFailure(timedOut: false, partialResponse: "", message: "Could not write to adapter.") }

        let deadline = Date().addingTimeInterval(timeout)
        var response = ""
        var byte: UInt8 = 0
        while Date() < deadline {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                let character = Character(UnicodeScalar(byte))
                if character == ">" { return response }
                response.append(character)
            } else if count == -1 && errno != EAGAIN && errno != EWOULDBLOCK {
                throw OBDTransportFailure(timedOut: false, partialResponse: response, message: "Lost communication with adapter.")
            }
            usleep(10_000)
        }
        throw OBDTransportFailure(timedOut: true, partialResponse: response, message: "Timed out waiting for \(command). Ensure ignition is ON and the adapter is seated.")
    }
}

/// Structured transport failures preserve partial bytes for the diagnostic trace.
struct OBDTransportFailure: LocalizedError {
    let timedOut: Bool
    let partialResponse: String
    let message: String
    var errorDescription: String? { message + (partialResponse.isEmpty ? "" : " Partial adapter response: " + partialResponse) }
}
