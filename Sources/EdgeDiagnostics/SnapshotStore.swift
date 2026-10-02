import Foundation

struct SavedDiagnosticSnapshot: Identifiable, Codable, Equatable {
    static let formatVersion = 2

    let id: UUID
    let formatVersion: Int
    let capturedAt: Date
    let adapterIdentity: String
    let vehicleProfile: VehicleProfile?
    let moduleIdentification: ModuleIdentification?
    let liveSnapshot: LiveSnapshot
    let codes: [DiagnosticCode]
    let monitorStatus: MonitorStatus?
    let freezeFrame: FreezeFrame?
    let fordModules: [FordModuleIdentity]
    let transcript: [DiagnosticTranscriptEntry]

    init(capturedAt: Date, adapterIdentity: String, vehicleProfile: VehicleProfile?, moduleIdentification: ModuleIdentification?, liveSnapshot: LiveSnapshot, codes: [DiagnosticCode], monitorStatus: MonitorStatus?, freezeFrame: FreezeFrame?, fordModules: [FordModuleIdentity] = [], transcript: [DiagnosticTranscriptEntry] = []) {
        id = UUID()
        formatVersion = Self.formatVersion
        self.capturedAt = capturedAt
        self.adapterIdentity = adapterIdentity
        self.vehicleProfile = vehicleProfile
        self.moduleIdentification = moduleIdentification
        self.liveSnapshot = liveSnapshot
        self.codes = codes
        self.monitorStatus = monitorStatus
        self.freezeFrame = freezeFrame
        self.fordModules = fordModules
        self.transcript = transcript
    }

    private enum CodingKeys: String, CodingKey { case id, formatVersion, capturedAt, adapterIdentity, vehicleProfile, moduleIdentification, liveSnapshot, codes, monitorStatus, freezeFrame, fordModules, transcript }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        adapterIdentity = try values.decode(String.self, forKey: .adapterIdentity)
        vehicleProfile = try values.decodeIfPresent(VehicleProfile.self, forKey: .vehicleProfile)
        moduleIdentification = try values.decodeIfPresent(ModuleIdentification.self, forKey: .moduleIdentification)
        liveSnapshot = try values.decode(LiveSnapshot.self, forKey: .liveSnapshot)
        codes = try values.decode([DiagnosticCode].self, forKey: .codes)
        monitorStatus = try values.decodeIfPresent(MonitorStatus.self, forKey: .monitorStatus)
        freezeFrame = try values.decodeIfPresent(FreezeFrame.self, forKey: .freezeFrame)
        fordModules = try values.decodeIfPresent([FordModuleIdentity].self, forKey: .fordModules) ?? []
        transcript = try values.decodeIfPresent([DiagnosticTranscriptEntry].self, forKey: .transcript) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(formatVersion, forKey: .formatVersion)
        try values.encode(capturedAt, forKey: .capturedAt)
        try values.encode(adapterIdentity, forKey: .adapterIdentity)
        try values.encodeIfPresent(vehicleProfile, forKey: .vehicleProfile)
        try values.encodeIfPresent(moduleIdentification, forKey: .moduleIdentification)
        try values.encode(liveSnapshot, forKey: .liveSnapshot)
        try values.encode(codes, forKey: .codes)
        try values.encodeIfPresent(monitorStatus, forKey: .monitorStatus)
        try values.encodeIfPresent(freezeFrame, forKey: .freezeFrame)
        try values.encode(fordModules, forKey: .fordModules)
        try values.encode(transcript, forKey: .transcript)
    }
}

enum SnapshotStore {
    static func loadAll() throws -> [SavedDiagnosticSnapshot] {
        try loadAll(from: directoryURL())
    }

    static func save(_ snapshot: SavedDiagnosticSnapshot) throws {
        try save(snapshot, to: directoryURL())
    }

    static func loadAll(from directory: URL) throws -> [SavedDiagnosticSnapshot] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.compactMap { url in try? decoder.decode(SavedDiagnosticSnapshot.self, from: Data(contentsOf: url)) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    static func save(_ snapshot: SavedDiagnosticSnapshot, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stamp = String(Int(snapshot.capturedAt.timeIntervalSince1970))
        let filename = "snapshot-\(stamp)-\(snapshot.id.uuidString).json"
        try encoder.encode(snapshot).write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    private static func directoryURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("EdgeDiagnostics", isDirectory: true).appendingPathComponent("Snapshots", isDirectory: true)
    }
}
