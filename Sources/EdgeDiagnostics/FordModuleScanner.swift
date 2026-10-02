import Foundation

enum FordNetwork: String, Codable, CaseIterable, Hashable {
    case highSpeed = "HS-CAN"
    case mediumSpeed = "MS-CAN"

    /// OBDLink ISO 15765 presets documented by ScanTool.net. Selecting a preset only
    /// changes the adapter's transceiver; it sends nothing to the vehicle.
    var adapterPreset: String { self == .highSpeed ? "STP 33" : "STP 53" }
}

struct FordModuleProbe: Hashable {
    let name: String
    let requestHeader: String
    let network: FordNetwork

    /// Conservative physical-address candidates used by late-model Ford passenger
    /// vehicles. A response, rather than this list, is the evidence that a module is
    /// installed. Names are intentionally labels, not a claim of vehicle build data.
    static let absCandidate = FordModuleProbe(name: "ABS", requestHeader: "760", network: .highSpeed)

    static let commonFordCandidates: [FordModuleProbe] = [
        .init(name: "PCM", requestHeader: "7E0", network: .highSpeed),
        .init(name: "TCM", requestHeader: "7E1", network: .highSpeed),
        .init(name: "Gateway", requestHeader: "706", network: .highSpeed),
        .init(name: "Instrument cluster", requestHeader: "720", network: .highSpeed),
        .init(name: "Steering column", requestHeader: "724", network: .highSpeed),
        .init(name: "Body control", requestHeader: "726", network: .highSpeed),
        .init(name: "Audio", requestHeader: "727", network: .highSpeed),
        .init(name: "Power steering", requestHeader: "730", network: .highSpeed),
        .init(name: "HVAC", requestHeader: "733", network: .highSpeed),
        .init(name: "Restraints", requestHeader: "737", network: .highSpeed),
        .init(name: "Parking aid", requestHeader: "736", network: .highSpeed),
        absCandidate,
        .init(name: "SYNC/APIM", requestHeader: "7D0", network: .highSpeed),
        .init(name: "Body control", requestHeader: "726", network: .mediumSpeed),
        .init(name: "Instrument cluster", requestHeader: "720", network: .mediumSpeed),
        .init(name: "HVAC", requestHeader: "733", network: .mediumSpeed),
        .init(name: "Driver door", requestHeader: "783", network: .mediumSpeed),
        .init(name: "Passenger door", requestHeader: "784", network: .mediumSpeed),
        .init(name: "Seat/comfort", requestHeader: "7D6", network: .mediumSpeed)
    ]
}

struct FordModuleIdentity: Identifiable, Equatable, Codable {
    let name: String
    let requestHeader: String
    let network: String
    /// ISO 14229 DID F187 when the module permits it in the default session.
    /// Standard meaning: manufacturer spare-part number. Legacy field name is
    /// retained for snapshot compatibility; this is not a verified software number.
    /// This is not a claim that every Ford module supports the DID.
    let softwareIdentifier: String?

    var id: String { "\(network)-\(requestHeader)" }
}

struct FordModuleScanResult: Equatable {
    let modules: [FordModuleIdentity]
    let codes: [DiagnosticCode]
    /// A missing or slow module is evidence, not a reason to discard results from
    /// every other module on the network.
    let warnings: [String]
}
