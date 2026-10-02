import Foundation

/// Cross-code observations. These are deliberately phrased as diagnostic priorities,
/// not conclusions about a failed part.
struct DiagnosticFinding: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case information, inspectSoon, servicePromptly, safetyCritical

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .information: "Information"
            case .inspectSoon: "Inspect soon"
            case .servicePromptly: "Service promptly"
            case .safetyCritical: "Safety system"
            }
        }
    }

    let id: String
    let severity: Severity
    let title: String
    let explanation: String
    let nextSteps: [String]
}

enum DiagnosticTriage {
    static func findings(codes: [DiagnosticCode], moduleVoltage: Double?) -> [DiagnosticFinding] {
        let identifiers = Set(codes.map(\.id))
        var result: [DiagnosticFinding] = []

        let unresolvedManufacturerRecords = codes.filter {
            !$0.hasEnhancedModuleContext && ($0.id.hasPrefix("B") || $0.id.hasPrefix("C") || $0.id.hasPrefix("U") || $0.id.hasPrefix("P1"))
        }
        if !unresolvedManufacturerRecords.isEmpty {
            result.append(.init(
                id: "enhanced-scan-required", severity: .servicePromptly,
                title: "Run the Ford module scan before choosing repairs",
                explanation: "\(unresolvedManufacturerRecords.count) body, chassis, network, or manufacturer-specific record\(unresolvedManufacturerRecords.count == 1 ? " lacks" : "s lack") a reporting module and full UDS context. A five-character code alone can be reused across Ford modules and model years.",
                nextSteps: ["With ignition ON and the vehicle parked, select Scan Ford modules.", "Keep the resulting module name, CAN network, UDS status, additional DTC byte, software identifier, and transcript with the snapshot.", "Use module-specific guidance only after the responding module is known."]))
        }

        if identifiers.contains("B0200") {
            result.append(.init(
                id: "restraint-voltage", severity: .safetyCritical,
                title: "Restraint-system voltage fault needs priority",
                explanation: "B0200 can mean restraint protection is unavailable or degraded while the fault is active. A current battery-voltage reading does not prove voltage was stable during cranking or when the code set.",
                nextSteps: ["Do not probe yellow airbag connectors or disconnect restraint components.", "Test battery condition, cranking voltage drop, charging voltage, restraint fuses, powers, and grounds using Ford procedures.", "After the electrical fault is repaired, verify the restraint warning stays off with a module scan."]))
        }

        let electricalCluster = identifiers.intersection(["P0562", "P0600", "B0200", "U3021", "U3022"])
        if electricalCluster.count >= 2 {
            let voltageText = moduleVoltage.map { String(format: " Current generic-OBD voltage was %.2f V.", $0) } ?? ""
            result.append(.init(
                id: "power-network-cluster", severity: .servicePromptly,
                title: "Multiple power/wake-up/network faults can share one electrical cause",
                explanation: "The scan includes \(electricalCluster.sorted().joined(separator: ", ")). This pattern can result from a weak battery, cranking voltage drop, poor ground, fuse/power-feed problem, or intermittent network connection rather than independent module failures.\(voltageText)",
                nextSteps: ["Load-test the battery and measure voltage drop while cranking; inspect terminals and primary grounds.", "Verify alternator output and inspect related fuses, relays, power feeds, and connectors before replacing modules.", "Rescan after correcting a confirmed electrical fault and pursue only codes that return."]))
        }

        if identifiers.contains("P0700") {
            let tcmCodes = codes.filter { $0.module == "TCM" }
            let explanation = tcmCodes.isEmpty
                ? "P0700 is the PCM's request to illuminate the MIL for a transmission-control concern. The root code has not yet been obtained from a responding TCM."
                : "P0700 is a notification; use the accompanying TCM records as the root-cause evidence."
            result.append(.init(
                id: "p0700-root-cause", severity: .servicePromptly,
                title: "Find the transmission controller's root DTC",
                explanation: explanation,
                nextSteps: ["Retain TCM code status, module software ID, and any freeze-frame data.", "Use the model-specific Ford fluid-level and pinpoint-test procedure; do not replace a transmission component from P0700 alone."]))
        }

        let active = codes.filter { ($0.statusByte ?? 0) & 0x01 != 0 }
        if !active.isEmpty {
            result.append(.init(
                id: "active-status", severity: .inspectSoon,
                title: "Prioritize currently failed module tests",
                explanation: "\(active.count) enhanced DTC record\(active.count == 1 ? " is" : "s are") marked test failed by the responding module. Confirmed records without this flag may be retained history.",
                nextSteps: ["Diagnose currently failed records first under the conditions that set them.", "Do not clear codes merely to make a warning disappear; verify the module's test passes after repair."]))
        }

        return result.sorted { $0.severity > $1.severity }
    }
}
