# Ford ABS protocol evidence ledger

Updated 2026-10-02. Target: 2012 Ford Fusion SEL 2.5L FWD, original Ford/ATE BE5C-2C219-AA installed; replacement label AE5C-2C219-FE. Label differences establish no compatibility verdict.

## Verified on this car — user-reported capture

The supplied request summary reports HS-CAN TX to 0x760 with `19 02 FF` and RX from 0x768 with reconstructed `7F 19 11`. This is a valid negative diagnostic response: the address pair was observed, and service 0x19 was rejected with NRC 0x11. It is not a communication failure, successful DTC read, proof of UDS support, or proof of programming compatibility. The original JSON capture has not been supplied in this checkout; provenance is the user's reported real capture, not independent replay.

The same report contains `ATE0\rOK\r\r`, `ATRV -> 7.7V`, and `010C -> 410C0000` (zero RPM during KOEO). The low voltage blocks further ABS activity. External multimeter verification is required before any future run. Software must not compensate or calibrate away this reading.

## Documented / sourced

- [OBDLink FRPM revision E](https://www.scantool.net/scantool/downloads/678/obdlink_frpm_e.pdf), sections 6–8 and 12–13, documents adapter command/response handling, device identity, voltage querying, CAN addressing and ISO-TP reception. These are adapter capabilities, not evidence of a Ford ABS application service. STDI returns identity rather than OK; ATRV reads voltage (supported for backward compatibility). No new adapter command or calibration is enabled.
- [ISO 14230-3:1999](https://www.iso.org/standard/23921.html) identifies the KWP2000 application-layer standard. Its existence does not establish this controller's protocol or any safe target-specific request.
- Searches of public Ford service content, FORScan material and ISO metadata did not establish a target-specific DTC or identification request for BE5C-2C219-AA at 760/768. Public material about a different Fusion generation, hybrid brake system or other ABS vendor is insufficient. No such command is marked documented for this target.

## Hypothesis — not authorized for transmission

A legacy Ford/KWP-style application layer is a research possibility only. Rejection of service 0x19 does not uniquely identify an alternative protocol. No replacement service, subfunction, DID, local identifier, session sequence or DTC record layout is verified. The branch name does not establish KWP support.

## Current implementation and next evidence

The existing `19 02 FF` read remains in the hard read-only allowlist; it has no fallback. Valid matching positive or negative responses promote the session's address pair to Observed on vehicle. Wrong IDs, incomplete ISO-TP and malformed negative replies do not. Optional `22 F1 87` remains unverified for this module and is sent only after a successful DTC read; leave it disabled.

Raw adapter exchanges, reported receive CAN frames, reconstructed payloads and NRCs are retained. TX and automatic flow-control traces remain logical unless physically reported. Tests use mocks and never access a serial device.

The voltage guard requires a finite, parseable adapter value within 10–16 V. This is the existing application's conservative rejection window, not a sourced Ford module operating specification or a guarantee of adequate battery health. Missing/malformed voltage also blocks before RPM and ABS requests.

Next: obtain the original JSON export and Ford/ATE documentation for the exact module, or an existing known read-only scan capture with source, vehicle/module identity, request bytes and responses. Establish request purpose, default-session availability and response layout before implementing one bounded change. Do not repeat the rejected DTC request merely to rediscover the address pair.

All As-Built/configuration/VIN writes, security access, session control, ECU reset, DTC clearing, memory access, flashing, pump/solenoid routines, bleed and PMI remain disabled. No vehicle request was transmitted during this development.
