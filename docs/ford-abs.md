# Ford ABS diagnostic workflow

This is an incremental read-only implementation for investigating an ABS/HCU replacement on a 2012 Fusion SEL 2.5L FWD. No live vehicle validation has been performed. It does not configure a replacement module or determine compatibility.

See [Validate Original ABS Module](ford-abs-validation.md) for the current in-car workflow and session export. The configurable `760/768` HS-CAN profile is explicitly a user-supplied candidate until a valid matching positive or negative diagnostic response is observed in that session. The user reports a real 760/768 negative reply; see the research ledger for provenance.

## Existing project review and architecture

The repository is a Swift 6 macOS 14+ Swift Package executable, not an Xcode project. `EdgeDiagnosticsApp.swift` contains SwiftUI views and a main-actor `AppModel`; AppKit provides the application delegate, open/save dialogs and PDF output. Charts provides telemetry plots. Resources are offline DTC catalogs and their licenses. Existing XCTest fixtures use `OBDTransport` mocks.

`SerialTransport` implements `OBDTransport` with POSIX serial I/O at 115200 baud, an NSLock, a prompt-terminated transaction and a deadline (normally 10 seconds). It includes partial responses in timeout errors. `OBDClient` handles OBDLink/ELM commands, generic OBD modes 01/02/03/07/09, UDS 19 02 FF and optional 22 F187. There is no KWP implementation, security algorithm or module-programming support. `FordModuleScanner` contains candidate addresses and HS/MS-CAN presets. Its historical broad scan has a timeout fallback; the dedicated ABS reader does not use that fallback.

`DiagnosticTranscriptEntry` already stores raw adapter exchanges; `SnapshotStore` serializes versioned general diagnostic snapshots. DTC history, triage, VIN metadata lookup and PDF export remain separate. ABS backups use their own versioned format because generic powertrain VIN data must not be represented as an ABS VIN.

The implementation follows existing flat source layout:

- `SerialTransport` → existing USB serial transport (no second transport).
- `OBDClient.readABS` / `validateOriginalABS` → serialized adapter setup and addressed read orchestration. Its recursive operation lock prevents other commands interleaving with CAN-header changes. Generic refresh requests now execute sequentially. Both Ford scanning and ABS reading restore the functional `7DF` header; ABS setup and restoration require explicit adapter OK replies.
- `ABSCANParser` / `CANFrame` → strict 11-bit header-enabled adapter output; DLC and extended-addressing formats are rejected. Every parseable line is logged independently so unknown/status lines cannot erase prior reported frames.
- `ISOTP` → classical normal-addressing reconstruction with length, sequence, responder and completeness checks; segmentation is available for offline tests only. It never drives flow control.
- `DiagnosticResponse` → UDS positive/negative response validation and decoding. Unexpected services, DID/subfunction mismatches and malformed records are failures, with their raw responses preserved.
- `FordModuleAddressing` / `FordABSService` → ABS addressing evidence and DTC-domain decoding; unsupported state-changing services fail closed.
- `ABSModuleInfo`, `FordAsBuiltBlock`, `ABSBackup`, `ABSComparison`, `ABSPreflight` → domain models, versioned JSON, syntax parsing, comparison and future preflight validation.
- `ABSValidationSession` / `ABSModuleView` → KOEO/read-only validation, typed outcomes, per-attempt session export, identification/DTC display, manual imports, backups, comparison and raw console.

The original code mislabeled F187 as a software number. The ABS model now stores it as a part number; legacy general-snapshot `softwareIdentifier` retains its serialized name for compatibility and is displayed as an F187 identifier. The standard DID meaning is documented by the [udsoncan project](https://udsoncan.readthedocs.io/en/latest/_modules/udsoncan/common/dids.html); this does not establish target-module support.

## Operations implemented

The app remains permanently READ ONLY. There is no mode toggle that unlocks vehicle-changing commands.

- Validate the original ABS module using the candidate 760/768 profile or a user-configured 11-bit pair. No address scanning. A valid matching positive or negative diagnostic response records an observation in that session and backup.
- Request DTC records with `19 02 FF`. A valid empty `59 02` response establishes communication independently of DTC count. Preserve all three DTC bytes and status; descriptions are existing catalog hints, not factory ABS definitions.
- Optionally request manufacturer spare-part number with `22 F187`, already present in the project. VIN, software number, hardware, strategy and other unavailable identifiers display as unavailable.
- Read adapter voltage with `ATRV`; this is an approximate adapter supply measurement, not battery health or an engine-state determination.
- Export the successfully read module state and raw evidence as versioned JSON. No ECU configuration read is implemented.
- Import/format manual As-Built text, preserving source and marking checksum/applicability unverified. Attach imports to a backup without representing them as ECU reads.
- Import an original backup and compare available identity fields and the union of configuration block addresses. Missing values stay unavailable. Differences do not imply compatibility or incompatibility.
- Export session console events and full adapter exchanges as text/JSON, including errors and partial timeout replies.

## Using the workflow and console

Follow the step-by-step [read-only validation instructions](ford-abs-validation.md). The existing DTC read serves as the communication test. Optional F187 identification is explicitly selected, and every unknown/status/negative/partial response stays in the exported evidence. No fallback services are sent after failures.

Save an original ABS backup and a complete validation session export before swapping units. The backup contains only the obtainable read evidence, not a restorable ECU configuration image. Import the original backup after reading the replacement to compare available identity fields and manually attached configuration. Manual As-Built input such as `760-01-01 12 34 AB CD` demonstrates syntax only, not a verified block/memory mapping. Imported blocks remain unverified and are never sent to the vehicle.

Console events distinguish physical adapter-reported RX frames, logical TX requests/implied ISO-TP framing/instructed automatic flow control, reconstructed payloads, and raw adapter commands/responses/errors. Physical outgoing frames and automatic FC bytes/timing are not observable through this transport; logical events say this explicitly. The validation JSON/text export includes adapter/voltage/RPM, known vehicle VIN provenance, preflight, profile status/observation, partial results, full chronological trace and failure details. It is not a passive full-bus capture.

## Future state-changing operations

`FordABSVerifiedProcedure` defines the future boundary. Shipped `FordABSService.restore`, `clearDTCs` and `serviceBleed` always throw **Unsupported until Ford diagnostic procedure is verified.** UI controls are disabled and SafetyPolicy rejects clear, reset, session-control, security, write and routine services. No firmware flashing is implemented.

Before enabling any future procedure, obtain vehicle/module-specific evidence for the exact requests, response IDs, sessions, security procedure (if required), block mapping, checksums, compatible identities, voltage requirements, reset/cycle instructions, readback and self-test. Use a freshly read current state, save a durable backup, present exact proposed changes, require explicit confirmation tied to that module and configuration, check every response, and abort on loss of communication or unexpected NRC. Never interpret a responder as permission to write.

`ABSPreflight` defaults to read-only, requires manual KOEO confirmation, battery support, accessories off, connection stability and saved backup, and rejects any supplied nonzero/invalid RPM sample. The UI checklist is advisory and cannot unlock operations. It does not claim to verify ignition/engine state. Future writes need a reliable fresh RPM/state signal or explicit supported manual-state policy; the existing telemetry display is not adequate proof.

## Terms

| Term | Meaning |
| --- | --- |
| Module configuration | Parameters governing a controller's behavior and vehicle integration. Exact storage/services are module-specific. |
| As-Built configuration | Ford block-formatted build configuration data. A printed block address is not automatically a diagnostic DID or physical memory address. |
| PMI | Programmable Module Installation: Ford's prescribed replacement workflow, potentially involving identity, configuration, software and required initialization. A JSON backup/compare is not PMI. |
| Firmware flashing | Replacing executable/calibration software. Excluded from this implementation. |
| ABS hydraulic service bleed | A documented service routine operating pump/valves to purge hydraulic air. Separate from configuration and disabled until the Ford routine is known. |

## Validation

Use mock frames only. `swift build` and `swift test` build the native executable and run both legacy and ABS tests. Tests cover assembly/segmentation including sequence wrap, malformed/incomplete responses, negative NRCs, transport timeout abort, strict header parsing, As-Built syntax/formatting, backup round trips/version rejection, comparison, preflight and allowlist enforcement. No test connects to a vehicle or sends a state-changing command.
