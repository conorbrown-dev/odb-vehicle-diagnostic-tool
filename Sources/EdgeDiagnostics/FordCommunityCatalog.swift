import Foundation

/// Community Ford-code titles from Wal33D/dtc-database, revision
/// 04c43d72e7db7197658b6f72fe582c5076d9eee8. Bundled under its MIT license.
/// Titles are useful lookup hints only; Ford factory information remains required
/// for module-specific definitions and pinpoint procedures.
enum FordCommunityCatalog {
    static func details(for code: String) -> DTCDetails? {
        titles[code].map { title in
            DTCDetails(
                title: title,
                system: "Ford powertrain diagnostics",
                urgency: .inspectSoon,
                description: "Community-sourced Ford definition for \(code). Ford code meaning can vary by model year, engine, calibration, and reporting module; use the vehicle context and test before replacing parts.",
                commonCauses: ["The component, circuit, or condition named by this code", "Related wiring, connectors, power supply, or ground", "A related system fault that causes this monitor to fail"],
                diagnosticSteps: ["Record the source module, stored/pending status, freeze-frame data, VIN, and calibration ID.", "Inspect the named circuit/system and use scan data to confirm the fault before replacing a component."],
                repairGuidance: ["Repair the confirmed root cause, clear the code, and verify it does not return.", "For an exact Ford pinpoint test or module procedure, consult Ford service information."],
                source: "Wal33D community Ford catalog (MIT; definition only)",
                confidence: .definitionOnly
            )
        }
    }

    private static let titles: [String: String] = {
        guard let url = Bundle.module.url(forResource: "ford-community-codes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [:] }
        // The upstream community file contains a few duplicate codes. Keep the first
        // listed title deterministically instead of making the entire catalog unusable.
        return Dictionary(records.map { ($0.code, $0.title) }, uniquingKeysWith: { first, _ in first })
    }()

    private struct Record: Decodable { let code: String; let title: String }
}
