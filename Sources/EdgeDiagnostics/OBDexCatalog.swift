import Foundation

/// Offline generic-code enrichment from OBDex, revision bc58b0eb7273226a1aabae98e956b70b8362bda1
/// (2026-08-22). Data is CC0-1.0; the bundled license is in Resources/OBDex-LICENSE-DATA.txt.
/// This is community-authored guidance, not Ford factory repair information.
enum OBDexCatalog {
    static func details(for code: String) -> DTCDetails? {
        records[code].map { $0.asDetails() }
    }

    private static let records: [String: Record] = {
        guard let url = Bundle.module.url(forResource: "obdex-generic", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Record].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.code, $0) })
    }()

    private struct Record: Decodable {
        let code: String
        let category: String
        let title: LocalizedText
        let description: LocalizedText
        let affectedComponents: [String]?
        let commonCauses: [Cause]?
        let symptoms: [LocalizedText]?
        let repair: Repair?
        let flags: Flags?
        let relatedCodes: [String]?

        enum CodingKeys: String, CodingKey {
            case code, category, title, description, symptoms, repair, flags
            case affectedComponents = "affected_components", commonCauses = "common_causes", relatedCodes = "related_codes"
        }

        func asDetails() -> DTCDetails {
            let causes = (commonCauses ?? []).map { cause in
                let likelihood = cause.likelihood.map { " (\($0) likelihood)" } ?? ""
                return cause.label.en + likelihood
            }
            let components = (affectedComponents ?? []).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
            var diagnostics: [String] = []
            if !components.isEmpty { diagnostics.append("Inspect and test the related components and their wiring/connectors: \(components).") }
            if let relatedCodes, !relatedCodes.isEmpty { diagnostics.append("Check for related codes: \(relatedCodes.joined(separator: ", ")).") }
            diagnostics.append("Confirm the fault with scan data and vehicle-specific tests before replacing parts.")
            var repairGuidance = ["Repair the confirmed root cause, then clear the code and verify it does not return after the applicable drive cycle."]
            if let repair {
                let diy = repair.diyPossible == true ? "DIY may be practical with the correct tools." : "Professional diagnosis/repair is recommended."
                repairGuidance.append("Estimated difficulty: \(repair.difficulty ?? "unknown"). \(diy)")
            }
            let urgency: DTCUrgency = flags?.limpModePossible == true ? .servicePromptly : .inspectSoon
            return DTCDetails(title: title.en, system: category.capitalized, urgency: urgency, description: description.en, commonCauses: causes, symptoms: (symptoms ?? []).map(\.en), diagnosticSteps: diagnostics, repairGuidance: repairGuidance, source: "OBDex community catalog (CC0)", confidence: .community)
        }
    }

    private struct LocalizedText: Decodable { let en: String }
    private struct Cause: Decodable { let likelihood: String?; let label: LocalizedText }
    private struct Repair: Decodable {
        let difficulty: String?
        let diyPossible: Bool?
        enum CodingKeys: String, CodingKey { case difficulty; case diyPossible = "diy_possible" }
    }
    private struct Flags: Decodable {
        let limpModePossible: Bool?
        enum CodingKeys: String, CodingKey { case limpModePossible = "limp_mode_possible" }
    }
}
