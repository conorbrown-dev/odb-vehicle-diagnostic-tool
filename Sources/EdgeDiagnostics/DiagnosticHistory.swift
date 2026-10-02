import Foundation

struct DiagnosticCodeTrend: Equatable {
    let newRecords: [DiagnosticCode]
    let persistentRecords: [DiagnosticCode]

    var hasComparison: Bool { !newRecords.isEmpty || !persistentRecords.isEmpty }
}

enum DiagnosticHistory {
    static func compare(current: [DiagnosticCode], prior: [DiagnosticCode]?) -> DiagnosticCodeTrend? {
        guard let prior else { return nil }
        let priorKeys = Set(prior.map(key(for:)))
        return DiagnosticCodeTrend(
            newRecords: current.filter { !priorKeys.contains(key(for: $0)) },
            persistentRecords: current.filter { priorKeys.contains(key(for: $0)) }
        )
    }

    private static func key(for code: DiagnosticCode) -> String {
        "\(code.module ?? "generic")|\(code.id)|\(code.failureTypeByte.map(String.init) ?? "none")"
    }
}
