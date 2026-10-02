import Foundation

/// Offline-only evidence distilled from saved scans. This deliberately counts what
/// the adapter recorded; it never turns a repeated code into a parts diagnosis.
enum SnapshotForensics {
    struct Report: Equatable {
        let scanCount: Int
        let recurringCodeIDs: [String]
        let udsTimeoutCount: Int
        let rawUDSRetryCount: Int
        let validUDSResponseCount: Int
        let canErrorCount: Int
    }

    static func report(for snapshot: SavedDiagnosticSnapshot, history: [SavedDiagnosticSnapshot]) -> Report {
        let vehicleKey = snapshot.vehicleProfile?.vin ?? snapshot.moduleIdentification?.vin
        let comparable = history.filter {
            guard let vehicleKey else { return $0.id == snapshot.id }
            return $0.vehicleProfile?.vin == vehicleKey || $0.moduleIdentification?.vin == vehicleKey
        }
        let scans = comparable.isEmpty ? [snapshot] : comparable
        let codeOccurrences = Dictionary(grouping: scans.flatMap { Set($0.codes.map(\.id)) }, by: { $0 })
        let transcript = scans.flatMap(\.transcript)
        return Report(
            scanCount: scans.count,
            recurringCodeIDs: codeOccurrences.filter { $0.value.count >= 2 }.map(\.key).sorted(),
            udsTimeoutCount: transcript.filter { $0.response.localizedCaseInsensitiveContains("Timed out waiting for 1902FF") }.count,
            rawUDSRetryCount: transcript.filter { $0.command == "STCSEGR 0" }.count,
            validUDSResponseCount: transcript.filter { $0.response.uppercased().contains("5902") }.count,
            canErrorCount: transcript.filter { $0.response.uppercased().contains("CAN ERROR") }.count
        )
    }
}
