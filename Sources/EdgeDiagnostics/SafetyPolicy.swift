import Foundation

enum SafetyPolicy {
    /// This allowlist is the app's hard safety boundary: every transmitted vehicle
    /// request is read-only. Adapter configuration is limited to documented settings and bounded 11-bit headers, filters and FC pairs.
    static func permits(_ command: String) -> Bool {
        let normalized = command.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("AT") {
            if ["ATZ", "ATI", "ATE0", "ATL0", "ATS0", "ATH0", "ATH1", "ATS1", "ATSH7DF", "ATSP0", "ATSP6", "ATAT2", "ATRV", "ATST20", "ATCAF1", "ATCFC1", "ATD0", "ATCRA", "ATAR"].contains(normalized) { return true }
            for prefix in ["ATSH", "ATCRA"] {
                if normalized.hasPrefix(prefix) {
                    let value = normalized.dropFirst(prefix.count)
                    return value.count == 3 && value.allSatisfy { "0123456789ABCDEF".contains($0) } && (UInt16(value, radix: 16).map { $0 <= 0x7FF } ?? false)
                }
            }
            return false
        }

        if ["STDI", "STP 33", "STP 53", "STCSEGR 0", "STCSEGR 1", "STCAF 0", "STCFCPC", "STFFCC"].contains(normalized) { return true }

        if normalized.hasPrefix("STFFCA ") {
            let filter = normalized.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return filter.count == 2 && filter[1] == "7FF" && filter[0].count == 3 && filter[0].allSatisfy { "0123456789ABCDEF".contains($0) } && (UInt16(filter[0], radix: 16).map { $0 <= 0x7FF } ?? false)
        }
        if normalized.hasPrefix("STCFCPA ") {
            let pair = normalized.dropFirst(8).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return pair.count == 2 && pair.allSatisfy { $0.count == 3 && $0.allSatisfy { "0123456789ABCDEF".contains($0) } && (UInt16($0, radix: 16).map { $0 <= 0x7FF } ?? false) } && pair[0] != pair[1]
        }
        guard normalized.allSatisfy(\.isHexDigit) else { return false }
        if ["03", "07", "1902FF", "22F187", "22E6F3", "22E300", "1800FF00"].contains(normalized) { return true }
        guard normalized.count == 4 else { return false }
        let service = String(normalized.prefix(2))
        return ["01", "02", "09"].contains(service)
    }
}
