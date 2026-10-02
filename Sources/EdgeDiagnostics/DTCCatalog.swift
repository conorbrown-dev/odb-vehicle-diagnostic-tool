import Foundation

enum DTCUrgency: String, Equatable, Codable {
    case inspectSoon = "Inspect soon"
    case servicePromptly = "Service promptly"
    case stopDriving = "Stop driving if the warning is active"

    var advice: String {
        switch self {
        case .inspectSoon: "A drivability or emissions concern is possible. Inspect it before clearing any code."
        case .servicePromptly: "Arrange diagnosis soon. Continued driving may cause poor performance or damage."
        case .stopDriving: "If the check-engine light is flashing, reduce load and stop driving as soon as safe."
        }
    }
}

enum DiagnosticConfidence: String, Equatable {
    case curated = "Curated diagnostic guidance"
    case community = "Open community guidance"
    case definitionOnly = "Definition only — verify procedure"
    case fallback = "Fallback — Ford procedure required"
}

/// A DTC names a monitor failure, not automatically the part needing replacement.
struct DTCDetails: Equatable {
    let title: String
    let system: String
    let urgency: DTCUrgency
    let description: String
    let commonCauses: [String]
    let symptoms: [String]
    let diagnosticSteps: [String]
    let repairGuidance: [String]
    let source: String?
    let confidence: DiagnosticConfidence

    init(title: String, system: String, urgency: DTCUrgency, description: String, commonCauses: [String], symptoms: [String] = [], diagnosticSteps: [String], repairGuidance: [String], source: String? = nil, confidence: DiagnosticConfidence = .fallback) {
        self.title = title
        self.system = system
        self.urgency = urgency
        self.description = description
        self.commonCauses = commonCauses
        self.symptoms = symptoms
        self.diagnosticSteps = diagnosticSteps
        self.repairGuidance = repairGuidance
        self.source = source
        self.confidence = confidence
    }

    var checks: String { diagnosticSteps.joined(separator: " ") }
}

enum DTCCatalog {
    /// Adds facts captured from the vehicle to the catalog guidance. This keeps a
    /// code definition separate from evidence that the fault is currently present.
    static func details(for record: DiagnosticCode) -> DTCDetails {
        let base = details(for: record.id)
        var diagnostics = base.diagnosticSteps
        var repairs = base.repairGuidance
        var context: [String] = []

        if let module = record.module, record.hasEnhancedModuleContext {
            context.append("Reporting module: \(module)\(record.network.map { " on \($0)" } ?? "").")
            diagnostics.insert("Start with the wiring diagrams, powers, grounds, and pinpoint test for the reporting \(module) module—not a similarly named component in another module.", at: 0)
        } else if let module = record.module {
            context.append("Addressed standard-OBD response: \(module)\(record.network.map { " on \($0)" } ?? ""). This confirms the responding ECU, not the originating module for each code.")
            diagnostics.insert("Do not select a module-specific repair from this responder alone; obtain enhanced UDS module records and full Ford suffixes first.", at: 0)
        } else {
            context.append("Reporting module was not available from the generic OBD-II response.")
            diagnostics.insert("Run the read-only Ford module scan before selecting a repair path; an anonymous generic DTC may be only a notification from another module.", at: 0)
        }

        if let status = record.statusByte {
            context.append("UDS status 0x\(String(format: "%02X", status)): \(record.udsStatusSummary ?? "not decoded").")
            if status & 0x01 != 0 {
                diagnostics.insert("The module's most recent test result is failed. Reproduce the enabling conditions and diagnose this code before treating it as historical.", at: 0)
                repairs.append("After repair, rerun the same conditions and confirm the module no longer reports a failed test—not merely that a code was cleared.")
            } else if status & 0x08 != 0 {
                diagnostics.insert("This is a confirmed record, but its latest test is not marked failed. Check for intermittent power, ground, connector, or environmental causes before replacing parts.", at: 0)
                repairs.append("Use a repeat scan after normal operation to distinguish a returning fault from a retained historical record.")
            }
            if status & 0x04 != 0 {
                diagnostics.insert("The code is pending, so capture current conditions and companion faults; it has not necessarily met the module's confirmation criteria.", at: min(1, diagnostics.count))
            }
        }

        if let thirdByte = record.failureTypeByte {
            context.append("Additional UDS DTC byte: 0x\(String(format: "%02X", thirdByte)); preserve it for the module-specific Ford lookup.")
        }
        let description = context.isEmpty ? base.description : "\(base.description)\n\nScan context: \(context.joined(separator: " "))"
        return DTCDetails(title: base.title, system: base.system, urgency: base.urgency, description: description, commonCauses: base.commonCauses, symptoms: base.symptoms, diagnosticSteps: diagnostics, repairGuidance: repairs, source: base.source, confidence: base.confidence)
    }

    static func details(for rawCode: String) -> DTCDetails {
        let code = normalizedCode(rawCode)
        if let known = knownCodes[code] { return known }
        if let community = OBDexCatalog.details(for: code) { return community }
        if let fordCommunity = FordCommunityCatalog.details(for: code) { return fordCommunity }
        if code.hasPrefix("P0") || code.hasPrefix("P2") || code.hasPrefix("P3") { return genericPowertrainDetails(for: code) }
        if code.hasPrefix("P1") {
            return DTCDetails(
                title: "Ford manufacturer-specific powertrain code", system: powertrainSystem(for: code), urgency: .inspectSoon,
                description: "P1xxx definitions are assigned by Ford and can change by model year, engine, transmission, and reporting module. A generic scan tool cannot safely supply an exact repair definition.",
                commonCauses: ["A fault in the Ford subsystem named by the code", "Wiring, connector, power, or ground faults", "A calibration- or module-specific condition"],
                diagnosticSteps: ["Record stored/pending status, freeze-frame data, model year, engine, and VIN.", "Use Ford service information or a Ford-capable scan tool to identify the reporting module and pinpoint-test procedure."],
                repairGuidance: ["Repair only the fault confirmed by Ford's pinpoint test; do not replace a module or sensor based on the code number alone."])
        }
        return DTCDetails(
            title: "Manufacturer-specific chassis, body, or network code", system: "Ford module diagnostics", urgency: .inspectSoon,
            description: "This code is outside legislated generic OBD-II powertrain definitions. Its meaning depends on the module that reported it and the vehicle configuration.",
            commonCauses: ["Module power, ground, wiring, or network communication issue", "A subsystem fault reported by a body, chassis, or gateway module"],
            diagnosticSteps: ["Record the source module, full code, model year, and VIN.", "Use Ford service information to run the module-specific pinpoint test and inspect related wiring before replacing parts."],
            repairGuidance: ["Apply the repair specified by the confirmed Ford diagnostic test, then verify the fault does not return."])
    }

    static func normalizedCode(_ rawCode: String) -> String {
        rawCode.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func genericPowertrainDetails(for code: String) -> DTCDetails {
        DTCDetails(
            title: "Generic OBD-II powertrain diagnostic code", system: powertrainSystem(for: code), urgency: .inspectSoon,
            description: "\(code) is a standardized powertrain code, but this app does not yet have a verified code-specific entry for it. The code identifies a monitor failure; it is not a parts-replacement instruction.",
            commonCauses: ["The component, circuit, or system monitored by this code", "Related wiring, connectors, vacuum lines, fluid level, or mechanical condition", "A related fault that causes the monitor to fail"],
            diagnosticSteps: ["Record stored/pending status and freeze-frame data before clearing anything.", "Look up the exact SAE definition for \(code) and follow the year- and engine-specific Ford pinpoint test.", "Test the circuit and related mechanical system before replacing a component."],
            repairGuidance: ["Repair the confirmed root cause, clear codes only after the repair, and complete a drive cycle to verify the monitor passes."])
    }

    private static func powertrainSystem(for code: String) -> String {
        guard code.count >= 4 else { return "Powertrain" }
        return switch code.dropFirst(2).first {
        case "0", "1", "2": "Fuel, air metering, and emissions"
        case "3": "Ignition and misfire"
        case "4": "Emissions controls"
        case "5": "Vehicle speed, idle control, or ECU inputs"
        case "7", "8", "9": "Transmission or drivetrain"
        default: "Powertrain"
        }
    }

    private static func entry(_ title: String, _ system: String, _ urgency: DTCUrgency, _ description: String, _ causes: [String], _ diagnostics: [String], _ repairs: [String]) -> DTCDetails {
        .init(title: title, system: system, urgency: urgency, description: description, commonCauses: causes, diagnosticSteps: diagnostics, repairGuidance: repairs, confidence: .curated)
    }

    private static func definitionOnly(_ title: String, _ system: String, _ urgency: DTCUrgency, _ description: String, _ causes: [String], _ diagnostics: [String], _ repairs: [String], source: String) -> DTCDetails {
        .init(title: title, system: system, urgency: urgency, description: description, commonCauses: causes, diagnosticSteps: diagnostics, repairGuidance: repairs, source: source, confidence: .definitionOnly)
    }

    private static let knownCodes: [String: DTCDetails] = [
        "P0016": entry("Crankshaft/camshaft position correlation — Bank 1 sensor A", "Engine timing", .servicePromptly, "The controller sees camshaft timing that does not agree with crankshaft position. Poor running, hard starting, rattling, or reduced power can occur.", ["Low, dirty, or incorrect-viscosity oil", "Sticking variable-cam timing solenoid/phaser", "Cam or crank sensor/circuit fault", "Stretched, skipped, or damaged timing components"], ["Check oil level, condition, and correct specification first.", "Inspect sensor and solenoid connectors; compare cam/crank timing data and run Ford timing tests.", "If mechanical timing is suspected, inspect timing components before driving further."], ["Correct the oil condition or repair the confirmed wiring/sensor/solenoid fault.", "Repair timing components only after mechanical timing is confirmed out of specification."]),
        "P0128": entry("Coolant temperature below thermostat regulating temperature", "Engine cooling", .inspectSoon, "The engine did not warm to its expected operating temperature in the allowed time. Cabin heat and fuel economy may be reduced.", ["Thermostat stuck open", "Low coolant or air in the system", "Biased coolant-temperature sensor or wiring", "Cooling fan operation issue"], ["Verify coolant level only when the engine is cold and inspect for leaks.", "Compare scan-tool coolant temperature with actual warm-up behavior.", "Test thermostat operation and sensor/circuit readings before replacement."], ["Replace the confirmed failed thermostat, sensor, or wiring fault.", "Refill and bleed the cooling system to Ford specifications, then verify normal warm-up."]),
        "P0133": oxygenSensor("Bank 1 sensor 1"), "P0153": oxygenSensor("Bank 2 sensor 1"),
        "P0171": leanSystem("Bank 1"), "P0174": leanSystem("Bank 2"),
        "P0300": entry("Random/multiple-cylinder misfire detected", "Ignition and misfire", .stopDriving, "The controller detected misfires on more than one cylinder or could not isolate one cylinder. A flashing check-engine light means catalyst-damaging misfire may be occurring.", ["Worn plugs, failed coil, or ignition wiring", "Fuel pressure/injector problem", "Vacuum or intake leak", "Mechanical compression or timing issue"], ["If the light flashes or the engine shakes badly, stop driving when safe.", "Read cylinder-specific codes and misfire counters if available; inspect plugs and coils.", "Check fuel delivery, intake leaks, compression, and timing as indicated by test results."], ["Replace ignition or fuel components only after swapping/testing confirms the fault.", "Repair air leaks or mechanical faults, then confirm misfire counters stay clear under load."]),
        "P0420": catalyst("Bank 1"), "P0430": catalyst("Bank 2"),
        "P0442": evapLeak("small"), "P0455": evapLeak("gross"), "P0456": evapLeak("very small"),
        "P0600": entry("Serial communication link", "Powertrain network communication", .servicePromptly, "The PCM recorded a serial communication fault. It does not identify a failed module by itself; power, ground, CAN wiring, connectors, or another module can cause it.", ["Low voltage during starting or poor battery/ground connection", "CAN wiring or connector damage", "A module with intermittent power/ground or an internal network fault"], ["Perform a full-module Ford scan and record the reporting modules and complete code suffixes.", "Check battery condition at rest and during cranking, charging output, primary grounds, and relevant fuses.", "Diagnose companion communication codes before replacing a PCM or transmission component."], ["Repair the confirmed power, ground, wiring, connector, or module fault.", "Verify communication remains stable through a drive cycle."]),
        "P0700": entry("Transmission control system malfunction request", "Transmission and powertrain control", .servicePromptly, "The PCM received a request from the transmission control system to turn on the malfunction indicator. P0700 is a notification code, not the underlying transmission failure.", ["A transmission-control-module code not visible to a generic scan", "Transmission sensor, solenoid, wiring, fluid, or mechanical fault", "Low-voltage or network communication event affecting the transmission controller"], ["Use a Ford-capable scan tool to read the transmission-control module directly and record all companion codes and freeze-frame data.", "Check transmission fluid only by the model-specific procedure.", "Prioritize any transmission-specific or network/power code found with P0700."], ["Repair the fault identified by the transmission module's pinpoint test.", "Verify shift operation and that both the transmission module and PCM remain clear after a drive cycle."]),
        "P1202": definitionOnly("Cylinder 2 injector circuit open/shorted — legacy Ford definition", "Fuel injection electrical circuit", .servicePromptly, "A Ford-published 2012 OBD-II code list defines P1202 as a cylinder 2 injector circuit open/shorted. That publication does not establish the exact definition for this 2019 Edge calibration, so treat it as a lead—not a confirmed repair instruction.", ["Injector connector, terminal tension, or harness damage", "Open/shorted injector-control circuit", "Injector electrical fault", "PCM driver only after circuit testing"], ["Keep the stored/pending evidence and obtain an enhanced PCM record or Ford pinpoint test before testing the circuit.", "With the ignition off and using the correct Ford wiring diagram, inspect the injector-2 connector/harness for damage, oil intrusion, or poor terminal retention.", "Do not replace an injector or PCM from this code alone; confirm the circuit and injector with the applicable Ford test."], ["Repair the confirmed connector, wiring, or injector fault.", "Verify the code does not return under the monitor conditions after repair."], source: "Ford Performance 2012 OBD-II code list; legacy-definition evidence only"),
        "P0562": entry("System voltage low", "Charging and electrical system", .servicePromptly, "Module supply voltage fell below its expected range. It can create unrelated sensor and communication codes, slow cranking, or stalling.", ["Weak battery", "Loose/corroded battery terminals or grounds", "Charging-system or belt problem", "High-resistance cable or excessive electrical load"], ["Test battery state and terminals, including voltage drop on grounds and cables.", "With the engine running, test alternator output and belt condition to Ford specifications.", "Diagnose low voltage first, then rescan for codes that remain."], ["Charge or replace a failed battery and repair confirmed cable, ground, belt, or alternator faults.", "Verify charging voltage and recheck modules after repair."]),
        "B1904": definitionOnly("Air-bag crash sensor #2 feed/return circuit failure — legacy Ford definition", "Supplemental restraint system", .servicePromptly, "Several public code dictionaries publish this as a Ford restraint crash-sensor circuit fault. The exact component and test are not confirmed for this 2019 Edge because the restraints module did not return an enhanced record.", ["Damaged, loose, corroded, or water-intruded restraint wiring/connector", "Crash-sensor circuit fault", "Restraint-module power/ground concern"], ["Do not probe yellow airbag connectors or use an improvised test light on restraint circuits.", "First test battery/cranking voltage, restraint fuses, module powers, and grounds using Ford procedures.", "Obtain an RCM-enhanced DTC record and the Ford pinpoint test before disconnecting a sensor or component."], ["Repair only the circuit/component identified by the Ford restraint-system test.", "Verify restraint warning behavior after the repair; do not treat clearing a code as a repair."], source: "Open Ford code dictionaries; legacy-definition evidence only"),
        "B1622": definitionOnly("Rear-wiper low-limit input circuit short to ground — legacy Ford definition", "Body electrical / rear wiper", .inspectSoon, "Public Ford code dictionaries associate B1622 with the rear-wiper low-limit input circuit shorted to ground. It is unverified for this vehicle until a body-module enhanced record identifies the reporting module and suffix.", ["Rear-wiper motor/limit-switch circuit", "Harness damage near liftgate hinge or motor", "Water intrusion, connector corrosion, or a body-module input fault"], ["Check whether the rear wiper behaves abnormally and inspect only accessible exterior/liftgate harness routing.", "Use the Ford wiring diagram and enhanced body-module scan before testing the circuit."], ["Repair the confirmed wiring, connector, motor/switch, or module input fault.", "Verify rear-wiper operation and that the record does not return."], source: "Open Ford code dictionaries; legacy-definition evidence only"),
        "B0200": entry("Air bag system voltage out of range", "Supplemental restraint system", .servicePromptly, "A restraint-system module recorded supply voltage outside its expected range. Airbag or restraint protection may be unavailable or degraded while the fault is active.", ["Weak battery or voltage drop during cranking", "Loose/corroded terminals, ground, fuse, or restraint-module power feed", "Charging-system voltage issue", "Harness or connector issue at the restraint-control module"], ["Do not probe or disconnect airbag circuits with improvised test equipment.", "Check battery, charging system, fuses, and grounds using Ford procedures; record the restraint module's full DTC suffix and status.", "Use a Ford-capable scanner to determine whether the code is current and whether other restraint codes are present."], ["Correct the confirmed power/ground/charging fault and have the restraint system verified with the proper Ford procedure.", "Do not clear an airbag warning as a repair; confirm the warning stays off after the underlying issue is corrected."]),
        "C1504": definitionOnly("Dynamic-stability-control right-front valve malfunction — possible Ford definition", "ABS / stability control", .servicePromptly, "A public multi-manufacturer catalog lists this as a Ford/Mazda dynamic-stability-control right-front valve malfunction, but also documents different meanings for other makes. This cannot be treated as an exact 2019 Edge definition without an ABS-module enhanced record.", ["ABS hydraulic-unit valve/circuit", "Connector or harness damage", "ABS module/power issue"], ["Do not replace an ABS hydraulic unit from this anonymous generic record.", "Obtain ABS-module enhanced DTC status and Ford suffix; then use the matching Ford wiring diagram and pinpoint test."], ["Repair the circuit, hydraulic unit, or module only after the specific Ford test identifies the fault.", "Verify ABS/stability-control warnings remain off after repair."], source: "TorqFix multi-manufacturer code catalog; possible Ford definition only"),
        "U3021": entry("Control module wake-up circuit B performance", "Vehicle network and module power", .servicePromptly, "A module detected an abnormal wake-up signal. Modules may intermittently fail to wake, communicate, or enter sleep mode; this can create unrelated warning lamps or codes.", ["Low battery voltage or voltage drop during start", "Fuse, relay, wake circuit, power, or ground fault", "Corroded/damaged connector or wiring", "Module internal wake-up or network fault"], ["Perform a full-module scan to identify the reporting module and full suffix.", "Test battery state, cranking voltage, charging system, module fuses, powers, and grounds.", "Inspect the affected module's wake/network wiring before disconnecting modules or replacing parts."], ["Repair the confirmed power, ground, wiring, connector, or module fault.", "Verify all modules wake, communicate, and enter sleep mode normally after repair."]),
        "U3022": entry("Ignition input accessory/off", "Vehicle network and ignition input", .servicePromptly, "A module recorded a fault associated with its accessory/off ignition input. It can be caused by an ignition-state signal, module power issue, or related network/wiring concern.", ["Intermittent ignition/accessory signal", "Battery, fuse, relay, power, or ground issue", "Damaged/corroded wiring or connector", "Module fault"], ["Identify the reporting module and record the complete DTC suffix with a Ford-capable scan.", "Check battery and ignition-input voltage at the affected module using the correct wiring diagram.", "Inspect related fuses, grounds, connectors, and harness routing before replacing a module."], ["Repair the confirmed ignition-input, power, ground, wiring, or module fault.", "Verify accessory/off state changes and module communication after repair."])
    ]

    private static func oxygenSensor(_ location: String) -> DTCDetails {
        entry("Oxygen sensor circuit slow response — \(location)", "Fuel, air metering, and emissions", .inspectSoon, "The upstream oxygen sensor signal changed more slowly than expected during a fuel-control test. Fuel economy may drop and the check-engine light may illuminate.", ["Aged/contaminated oxygen sensor", "Intake or exhaust leak ahead of the sensor", "Wiring, connector, or heater circuit damage", "Fuel-control problem causing an abnormal exhaust mixture"], ["Inspect for exhaust leaks, damaged harnesses, and intake leaks.", "Review fuel trims and upstream sensor response with a scan tool.", "Correct mixture or wiring faults before condemning the sensor."], ["Repair leaks or circuit faults found during testing.", "Replace the sensor only when its response/heater test fails after related faults are corrected."])
    }

    private static func leanSystem(_ bank: String) -> DTCDetails {
        entry("System too lean — \(bank)", "Fuel, air metering, and emissions", .inspectSoon, "The controller had to add substantial fuel to maintain the commanded mixture. Hesitation, rough idle, or reduced power may be present.", ["Vacuum/intake leak or split PCV hose", "Contaminated or biased mass-airflow sensor", "Low fuel pressure or restricted fuel delivery", "Exhaust leak ahead of the upstream oxygen sensor"], ["Use short- and long-term fuel trims at idle and higher RPM to narrow the fault.", "Inspect intake ducting, PCV/vacuum lines, and exhaust joints; test fuel pressure and MAF readings.", "Address shared causes first if both banks are lean."], ["Repair the confirmed leak, fuel-delivery, wiring, or MAF fault.", "Verify trims return toward normal and that the monitor completes without the code returning."])
    }

    private static func catalyst(_ bank: String) -> DTCDetails {
        entry("Catalyst system efficiency below threshold — \(bank)", "Emissions controls", .servicePromptly, "The downstream oxygen-sensor pattern indicates the catalytic converter is storing less oxygen than expected. The converter may be damaged, but upstream engine faults commonly cause this code.", ["Catalyst deterioration from age, overheating, or contamination", "Misfire or rich/lean condition", "Exhaust leak", "Upstream or downstream oxygen-sensor/circuit issue"], ["Check for companion misfire, fuel-trim, oxygen-sensor, and exhaust-leak codes first.", "Inspect exhaust for leaks and compare upstream/downstream sensor behavior.", "Confirm engine operation is correct before using catalyst-efficiency testing."], ["Repair the underlying misfire, mixture, leak, or sensor fault first.", "Replace the catalytic converter only after testing confirms low efficiency and the cause of damage has been corrected."])
    }

    private static func evapLeak(_ size: String) -> DTCDetails {
        entry("Evaporative-emissions system leak detected — \(size) leak", "Emissions controls", .inspectSoon, "The EVAP self-test could not seal the fuel-vapor system to the expected level. This normally does not affect drivability, but can trigger an emissions warning.", ["Loose, damaged, or incorrect fuel cap", "Cracked/disconnected EVAP hose or vapor line", "Purge or vent valve that does not seal", "Leak at canister or fuel-tank component"], ["Inspect the fuel-cap seal and filler neck, then visible EVAP hoses and connectors.", "Command/test purge and vent valves with appropriate equipment.", "Use an EVAP smoke test for small leaks rather than replacing parts by guesswork."], ["Replace the cap only if its seal or fit is defective.", "Repair the confirmed hose, canister, valve, or tank-side leak and verify the EVAP monitor runs to completion."])
    }
}
