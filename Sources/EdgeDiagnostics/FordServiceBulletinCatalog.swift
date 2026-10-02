import Foundation

struct FordServiceBulletin: Identifiable, Equatable {
    let number: String
    let title: String
    let applicableCodes: Set<String>
    let applicability: String
    let repairSummary: String
    let url: URL

    var id: String { number }
}

/// Curated, public NHTSA-hosted Ford bulletins. Entries must retain their exact
/// eligibility restrictions; a matching DTC alone is never proof a bulletin applies.
enum FordServiceBulletinCatalog {
    static func matching(codes: [DiagnosticCode], vehicle: VehicleProfile?) -> [FordServiceBulletin] {
        guard let vehicle, vehicle.year == "2019", vehicle.make?.uppercased() == "FORD", vehicle.model?.caseInsensitiveCompare("Edge") == .orderedSame,
              vehicle.engine?.contains("2.0") == true else { return [] }
        // The bulletin's restriction concerns PCM records. Other module DTCs do not
        // disqualify it, but an additional PCM or anonymous powertrain DTC does.
        let pcmOrGenericPowertrainCodes = Set(codes.filter {
            $0.module == "PCM" || ($0.module == nil && $0.id.hasPrefix("P"))
        }.map(\.id))
        return bulletins.filter {
            !pcmOrGenericPowertrainCodes.intersection($0.applicableCodes).isEmpty &&
            pcmOrGenericPowertrainCodes.isSubset(of: $0.applicableCodes)
        }
    }

    private static let bulletins: [FordServiceBulletin] = [
        .init(
            number: "19-2046",
            title: "2.0L EcoBoost — MIL with specified PCM DTCs",
            applicableCodes: ["P0128", "P0217", "P02EE", "P02EF", "P02F0", "P02F1", "P044C", "P1285", "P1299", "P2196"],
            applicability: "Only 2019 Edge/Nautilus 2.0L EcoBoost vehicles built on or before January 23, 2019, and only when these are the PCM's only stored DTCs.",
            repairSummary: "Ford's published remedy is a PCM software update using the appropriate Ford diagnostic tool. This app does not perform programming; verify build date, module, and all stored codes with a qualified service provider.",
            url: URL(string: "https://static.nhtsa.gov/odi/tsbs/2019/MC-10156867-9999.pdf")!
        )
    ]
}
