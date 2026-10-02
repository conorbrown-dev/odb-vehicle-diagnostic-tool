import Foundation

/// Parses the adapter's textual envelope without changing the logged wire response.
/// Acknowledgments and informational replies are distinct: banners/identity/voltage
/// do not need OK, while setup commands require an acknowledgment and no error token.
struct ELMResponse: Equatable {
    let raw: String
    let meaningfulLines: [String]

    init(command: String, raw: String, removeEcho: Bool = true) {
        self.raw = raw
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: ">", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if removeEcho, let first = lines.first,
           first.caseInsensitiveCompare(command.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            lines.removeFirst()
        }
        meaningfulLines = lines
    }

    var normalized: String { meaningfulLines.joined(separator: "\n") }
    var hasError: Bool {
        meaningfulLines.contains { line in
            let token = line.uppercased()
            return token == "?" || token.hasPrefix("UNABLE ") || token == "UNABLE"
                || token.range(of: "\\bERROR\\b", options: .regularExpression) != nil
        }
    }
    var isAcknowledged: Bool { !hasError && meaningfulLines.contains { $0.uppercased() == "OK" } }
    var isInformational: Bool { !hasError && !meaningfulLines.isEmpty && !isAcknowledged }
}
