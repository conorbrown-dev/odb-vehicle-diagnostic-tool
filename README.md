# Edge Diagnostics

A native macOS, read-only diagnostic companion for a Ford Edge and an OBDLink EX (EX101) USB adapter.

## What it does

- Connects through a macOS USB serial device (normally `/dev/cu.usbserial-*`)
- Reads generic OBD-II stored and pending engine codes
- Performs a separate, read-only Ford enhanced scan across a conservative set of HS-CAN and MS-CAN physical module addresses; records the responding module, UDS status, and raw third DTC byte with each DTC
- Reads the standardized manufacturer spare-part-number DID (`F187`) when a responding module permits it, and carries that identifier into snapshots and PDF reports
- Analyzes supported common codes with an issue description, likely causes, confirmation steps, and repair path; codes can also be looked up manually
- Includes an offline open-data catalog for 9,533 generic OBD-II codes, including generic powertrain, body, chassis, and network families
- Shows common live powertrain gauges: RPM, vehicle speed, coolant, intake-air temperature, throttle, and control-module voltage
- Exports a timestamped CSV snapshot of displayed values
- Exports a print-ready PDF trouble-code report with vehicle context, descriptions, symptoms, causes, confirmation steps, and repair guidance
- Saves every manual vehicle read as a restorable disk snapshot, including codes, ECU/VIN context, live values, monitor state, and freeze-frame data

The connection and enhanced scan configure only the OBDLink EX adapter's HS-CAN/MS-CAN transceiver and CAN message header. They never change vehicle settings.

It deliberately cannot clear codes, program modules, change configuration, or perform security/key functions. The new ABS workflow provides read-only evidence and a future verified-procedure boundary; those operations remain disabled.

## Before connecting

1. Install the current FTDI Virtual COM Port driver if macOS does not show the EX after plugging it in. OBDLink documents the EX as a USB adapter and its official supported platforms are Android and Windows, so this macOS app depends on the serial driver exposing the adapter.
2. Plug the EX into the Edge’s OBD-II port, turn ignition to **ON** (or start the engine for live data), then connect the USB cable.
3. In Terminal, run `ls /dev/cu.*` and copy the device path that appears after the adapter is connected.

## Run

```sh
cd ford-edge-diagnostics
swift run
```

For best results, use the app while parked. The app sends only standard read requests, but live values are still distracting while driving.

## Vehicle coverage

The app reads legislated OBD-II powertrain data and includes a read-only Ford module-DTC scan. Module candidates are intentionally conservative; a module is treated as present only when it responds. The scan uses UDS ReadDTCInformation (`19 02 FF`) and does not open an extended session, write data, run routines, clear faults, or program/configure modules.

UDS DTC records contain three code bytes plus a status byte. The report preserves the third byte, but labels it as an additional DTC byte rather than assuming it is a failure-type byte: its precise meaning depends on the DTC format configured by the responding Ford module.

It intentionally does not include FORScan-style programming/configuration, key/security, module resets, actuator tests, or service routines. Those vehicle-changing operations remain blocked by the command allowlist.

The built-in repair guidance is diagnostic guidance, not an instruction to replace the named component. For a Ford manufacturer-specific code (`P1xxx`) or any code without a code-specific entry, record the source module, model year, engine, VIN, and freeze-frame data, then use Ford service information for the matching pinpoint test.

## Diagnostic-code data

The bundled generic-code catalog is a pinned snapshot of [OBDex](https://github.com/foerbsnavi/obdex), revision `bc58b0eb7273226a1aabae98e956b70b8362bda1` (2026-08-22), released under CC0-1.0. Its full license is bundled with the app. It provides community-authored guidance for generic `P0`, `P2`, `P3`, `B0`, `C0`, `U0`, and `U3` codes. It is not Ford factory service information.

For additional practical coverage, the app also bundles 416 Ford powertrain-code titles from [Wal33D/dtc-database](https://github.com/Wal33D/dtc-database), revision `04c43d72e7db7197658b6f72fe582c5076d9eee8`, under its MIT license. Those entries are visibly labeled as community definitions and deliberately do not claim to be Ford pinpoint tests or factory repair procedures.

## Saved snapshots

Snapshots are JSON files stored in `~/Library/Application Support/EdgeDiagnostics/Snapshots`. They are retained until you remove them from disk and can be reopened from the app without connecting the adapter. A newer code catalog can therefore analyze an older snapshot again without losing its original vehicle context or readings.

## Ford ABS replacement investigation

The native ABS screen adds an addressed read/test workflow, optional F187 identification, strict ISO-TP/DTC parsing, raw receive-frame inspection, text/JSON transcript export, versioned ABS backups, manual As-Built import and original/replacement comparison. The configurable `760/768` HS-CAN profile starts each session as a candidate; a matching valid positive or negative diagnostic response records an observation in that validation session. The user reports a real 760/768 negative reply; see the research ledger for provenance.

Configuration reads/writes, DTC clearing, reset, security access and hydraulic service bleed remain unsupported. Imported As-Built data is marked unverified and is never transmitted. READ ONLY remains mandatory. Use KOEO for ABS work and follow the displayed battery/connection reminders.

Run **Validate Original ABS Module** with the required KOEO/no-external-programming confirmations. The workflow initializes the adapter, checks fresh RPM, retains partial/failure outcomes and exports a complete validation session as JSON or text. TX framing and automatic FC are explicitly logical where the adapter hides physical transmission.

See [in-car validation steps](docs/ford-abs-validation.md), [ABS workflow and architecture](docs/ford-abs.md) and the [protocol research ledger](docs/ford-abs-research.md) for exact capabilities, capture limitations and missing Ford procedures.

## Read-only CLI

The same executable supports terminal operations without launching the GUI:

```sh
swift run EdgeDiagnostics --cli help
swift run EdgeDiagnostics --cli ports
```

Available reads are `voltage` (ATRV only), `abs-version` (22 E6 F3), `abs-dtcs` (18 00 FF 00), and `abs-vin-start` (22 E3 00). Each ABS invocation performs the existing OBDLink EX identity, fresh voltage and engine RPM preflight, then sends exactly one selected read at 760/768. It uses the same client, parser and hard read-only allowlist as the GUI. No raw command, address override, sweep, automatic retry or write interface exists.

Fully quit the GUI and other diagnostic/serial tools. Verify current physical conditions with the human operator before supplying confirmation flags; flags record that verification and must not be treated as lasting permission for future runs. Example for the next single E300 read:

```sh
swift run EdgeDiagnostics --cli abs-vin-start \
  --port /dev/cu.YOUR_OBDLINK_DEVICE --output ./captures \
  --ignition-on --engine-off --parked --original-abs-installed \
  --other-tools-closed --read-only
```

`--vehicle-vin VIN` optionally supplies a known reference without an additional vehicle request. E300 yields only the documented first VIN character; support on this ABS must be established from its response before enabling further segments.

The CLI creates a unique capture directory before opening the adapter, records the invocation/confirmation provenance, and exports JSON and text even for negative responses, malformed replies or blocked preflight. Exit 0 means a positive read, 1 a failed/non-positive read or export failure, and 2 invalid arguments or an unavailable capture destination. A negative response still preserves observed addressing in the session. `pending.txt` remains if an attempt is interrupted or export does not complete. Captures under `./captures` are Git-ignored and remain local.

For an adapter-only check, use `--cli voltage --port /dev/cu.YOUR_OBDLINK_DEVICE --output ./captures`; it sends only ATRV and closes the serial port. `help` and `ports` never open the adapter. GUI launch remains `swift run EdgeDiagnostics` without arguments.
