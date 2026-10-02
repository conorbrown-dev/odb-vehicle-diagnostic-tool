import Foundation

/// Uses NHTSA's public vPIC VIN decoder for vehicle attributes. This service supplies
/// VIN metadata only; it is not a source of Ford or SAE diagnostic-code definitions.
enum VehicleProfileLookup {
    static func lookup(vin: String) async throws -> VehicleProfile {
        guard vin.count == 17 else { throw OBDClientError.adapter("A 17-character VIN is required for vehicle lookup.") }
        let escapedVIN = vin.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? vin
        let url = URL(string: "https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValuesExtended/\(escapedVIN)?format=json")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw OBDClientError.adapter("Vehicle profile lookup was unavailable.")
        }
        return try decode(data: data, vin: vin)
    }

    static func decode(data: Data, vin: String) throws -> VehicleProfile {
        let response = try JSONDecoder().decode(VPICResponse.self, from: data)
        guard let result = response.results.first else { throw OBDClientError.noData("VIN decoder returned no vehicle profile") }
        return VehicleProfile(
            vin: vin, year: value(result.modelYear), make: value(result.make), model: value(result.model), trim: value(result.trim),
            engine: [value(result.displacementL).map { "\($0)L" }, value(result.engineModel), value(result.engineCylinders).map { "\($0)-cyl" }, value(result.fuelTypePrimary)].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
            driveType: value(result.driveType)
        )
    }

    private static func value(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.uppercased() != "NOT APPLICABLE" else { return nil }
        return text
    }

    private struct VPICResponse: Decodable {
        let results: [Result]
        enum CodingKeys: String, CodingKey { case results = "Results" }
    }

    private struct Result: Decodable {
        let modelYear: String?
        let make: String?
        let model: String?
        let trim: String?
        let displacementL: String?
        let engineModel: String?
        let engineCylinders: String?
        let fuelTypePrimary: String?
        let driveType: String?

        enum CodingKeys: String, CodingKey {
            case modelYear = "ModelYear", make = "Make", model = "Model", trim = "Trim"
            case displacementL = "DisplacementL", engineModel = "EngineModel", engineCylinders = "EngineCylinders"
            case fuelTypePrimary = "FuelTypePrimary", driveType = "DriveType"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
