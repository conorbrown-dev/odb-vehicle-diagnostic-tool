# Validate Original ABS Module

This document describes the existing read-only capture workflow from the original ABS unit on a 2012 Ford Fusion SEL 2.5L FWD with an OBDLink EX. **The user reports a valid negative reply at 760/768 on this vehicle. Service 0x19 is unsupported; do not repeat this workflow until voltage is externally verified and a next request is justified.** No programming, clearing, security access, reset or actuator requests are implemented.

## In-car steps

1. Leave the original ABS module installed for this capture. Park the vehicle. Turn ignition ON and keep the engine OFF (KOEO). Connect a battery maintainer / ensure a fully charged battery. Turn off lights, HVAC, radio and unnecessary accessories. Keep the USB adapter and Mac connected throughout the read.
2. Close other diagnostic applications and ensure no programming / write-capable diagnostic session is active. The app cannot determine an ECU's current diagnostic session. Adapter initialization is not an ECU reset and does not establish an ECU default session.
3. Start the native app with `swift run`. Select the OBDLink EX USB serial device and click **Connect**. This uses the existing connection flow, including generic read-only vehicle identification. An already-known vehicle VIN will be included in the validation export with explicit provenance; it is not an ABS VIN read.
4. In **ABS Module**, keep the default draft profile: HS-CAN, normal 11-bit addressing, request `760`, response `768`. It is labeled **Candidate / not vehicle-verified**. IDs can be changed individually; changed IDs are **User configured / not vehicle-verified** until observed in this attempt. Do not sweep addresses. Leave the profile source as the supplied candidate reference or record the source for any edits.
5. Check **Ignition ON**, **Engine OFF**, and **Other diagnostic tools closed; no programming / write-capable session active**. READ ONLY is mandatory and HS-CAN is selected by the workflow. The app stops telemetry when validation starts. A recent known nonzero RPM sample blocks starting; a fresh generic RPM read also blocks before any ABS request if nonzero. If RPM is unavailable, the application relies on your engine-OFF confirmation and says so in the result/export.
6. Leave **Attempt optional F187 identification** unchecked for the first capture. F187 is the already-supported UDS manufacturer spare-part-number read; its availability on this ABS unit is unknown.
7. Click **Validate Original ABS Module** once. The workflow reinitializes the adapter, verifies OBDLink EX identity via STDI, requires a valid voltage within the app’s 10–16 V preflight window, checks RPM, configures the selected HS-CAN/header/filter/flow-control pair, and submits `19 02 FF`. This existing DTC read is also the communication test: no second discovery request is sent. A valid `59 02` response, even with zero records, establishes the observed pair and supplies the DTC results.
8. Read the result. A negative response, timeout, missing response, CAN traffic on another ID, malformed ISO-TP or adapter failure are distinct outcomes. Failures stop without retries, fallback reads or restoration commands and normally require reconnecting. No additional undocumented services are tried.
9. Select **JSON** and click **Export ABS Validation Session**, then save the capture. Change the format to **Text** and click the same button to save the human-readable version. These controls work for failed/partial attempts as well as successes. Export before starting another validation: the one-click exporter contains the latest attempt. The raw console exporter retains the accumulated ABS traces for this app lifetime.
10. If the DTC read succeeded and you want F187 identification, reconnect when required, leave the confirmed conditions in place, enable the optional F187 checkbox and run a second validation. `22 F1 87` is sent only after a valid DTC response. An F187 negative response or timeout stops the attempt, while the prior DTC result and observed pair remain in the session. Export that second attempt separately.
11. **Save ABS backup** saves any positively read DTC/identification evidence. No ECU configuration has been read, so this backup cannot configure a replacement module. The validation session export contains additional adapter/voltage/RPM/preflight/outcome metadata and should be retained with the backup.

## Trace interpretation

Every event contains a host timestamp, direction, optional CAN ID/raw bytes/payload, frame classification and interpretation. Structured fields include service, DID, subfunction, positive-response disposition and NRC when identifiable.

| Visibility | Meaning |
| --- | --- |
| PHYSICAL | Receive frame reported by the adapter, with CAN ID and original PCI/data bytes. Not an independent bus-analyzer measurement. |
| LOGICAL | Submitted diagnostic request, implied ISO-TP TX framing, adapter settings, or instructed/expected automatic FC behavior. It is never proof of a physical TX frame. |
| RECONSTRUCTED | Complete payload derived from reported RX frames, or the existing header-free generic RPM response. |
| ADAPTER | Verbatim command/response/status/error text. Unknown text and partial timeout replies are preserved. |

Single, First, Consecutive and Flow Control frames are classified independently. For each reported First Frame on the expected ID, a logical TX FC event describes what the configured adapter is instructed to do. Actual FC bytes, block size, STmin, timing, repeat count and successful transmission are unobserved. Do not infer a physical `30 00 00` packet from that logical event. Any FC packet reported in received output is retained as PHYSICAL RX and excluded from diagnostic payload assembly. Logical request-frame bytes show PCI plus diagnostic data; padding is explicitly unobserved.

ISO-TP responses are assembled only from the expected ID and validated for length, sequence, completeness, service and DID/subfunction. Unexpected CAN IDs are logged but never substituted for the expected response. The configured receive filter ordinarily prevents unrelated traffic appearing; this workflow is not a passive full-bus sniffer. Multiple replies or malformed/status output fail closed and remain available in raw adapter events. Unknown reconstructed payloads display **Unknown response / Raw payload**, or their recognizable service with the original bytes and a failed result if they do not match the request.

Timestamps mark host submission, adapter response completion, and parsing, rather than hardware bus timestamps. Logical FC events follow the associated reported First Frame in the exported narrative; that placement is an explanation of expected behavior, not measured bus timing.

## Address observation and outcomes

Each attempt starts fresh as Candidate or User configured. Imported/past observation does not promote a new attempt. Only a matching valid positive or negative diagnostic response marks the session's configured request/response pair **Observed on vehicle** and records `observedAt`. Matching valid negative responses also establish address observation without establishing service support. Unknown payloads, incomplete messages and traffic on another CAN ID never promote it. Backups carry the session's status and observation time. Observation establishes that pair's read conversation; it does not establish Ford compatibility or programming capability. The user-reported 7F 19 11 capture establishes address observation on this car; test fixtures remain synthetic.

Results distinguish:

- **ABS responded**: matching, complete, valid DTC response received.
- **ABS did not respond**: no CAN frames returned for the ABS DTC read; this is not proof of a missing module.
- **CAN traffic observed but no valid ABS response**: wrong CAN ID, only control traffic or unexpected diagnostic payload.
- **Negative diagnostic response**: matching negative service reply, including raw NRC. Response-pending is retained and stops this conservative reader without an automatic retry.
- **Transport/ISO-TP failure**: serial timeout/loss, incomplete/out-of-sequence frames, malformed raw output or missing F187 response after a successful DTC read.
- **Adapter failure**: setup acknowledgment/identity failure or adapter/CAN error status.
- **Preflight blocked**: missing confirmations/read-only settings, a running-engine RPM reading, or unavailable/invalid/out-of-window adapter voltage. No ABS request is sent.

A session says **ABS responded: Yes** for a valid matching negative DTC reply too; DTC result remains negative. It can also retain that status after an F187 failure. It retains the successfully read DTCs and observation instead of collapsing the entire attempt to “module not found.”

JSON includes schema/session ID, ISO-8601 millisecond dates, known VIN/provenance, adapter identity/voltage, RPM/preflight, network/IDs/status/observation, available module information, DTC/F187 outcomes/raw payload/NRC, chronological trace, verbatim adapter exchanges and reconnect requirement. Text includes the same evidence. Credentials/passwords are not collected by this transport or included in either format.

## Adapter behavior sources

The [OBDLink Reference and Programming Manual](https://www.scantool.net/scantool/downloads/678/obdlink_frpm_e.pdf), sections 8.8, 8.10, 11, 12 and 13, documents normal addressing, receive-segmentation control and explicit FC address pairs. The workflow sets `STCFCPA <request>, <response>`, an exact `STFFCA <response>, 7FF` ISO-TP classification filter, and `ATCRA<response>` rather than relying on an implicit offset for edited profiles. After success it clears the custom pair, resets filtering with `ATAR`, and restores header-free functional powertrain communication. Failure closes the transport instead of sending more commands.

The [ELM327 datasheet](https://www.elmelectronics.com/wp-content/uploads/2016/07/ELM327DS.pdf), AT command descriptions for CAF, CFC, H and CRA, documents automatic request formatting, internal flow control, header-enabled raw RX display and receive filtering. The workflow explicitly enables automatic formatting/FC, enables headers, disables DLC display and disables STN receive reassembly. These published adapter behaviors support logical tracing; they do not verify Ford ABS service support or vehicle addresses.

## Development validation

`ABSValidationTests` uses synthetic mock transports only. It covers logical TX/physical RX, First/Consecutive/FC classification, multi-frame reconstruction, response identity, Candidate-to-Observed promotion, unknown/NRC/timeout/partial-frame preservation, fail-stop behavior, custom profiles, fresh RPM/preflight blocking, adapter identity, export completeness and legacy backup decoding. No test opens a serial device or sends a hardware command. All write-capable services and routine boundaries remain blocked.

## Current next test: protocol version only

1. Leave the original module installed. Park, ignition ON / engine OFF; use the battery support already in place. Close other diagnostic tools.
2. From branch `abs/kwp-validation`, run `swift run`. Select the EX USB serial device and connect. The existing connection reads generic powertrain identification; it sends no ABS request.
3. In ABS Module keep request `760`, response `768`, and enter the prior capture reference as the profile source. Confirm the KOEO / other-tools-closed preflight boxes. Leave optional F187 identification unchecked.
4. Click **Read diagnostic protocol version** once. Do not click Validate Original ABS Module. The probe checks fresh voltage/RPM and sends only `22 E6 F3` to ABS. It makes no DTC, identification, configuration or write request and no session change.
5. Export the ABS validation session as JSON and text regardless of the outcome. Send those exports before choosing any next request. Do not retry an NRC or timeout. The probe records its own `protocolVersionResult`; DTC/F187 results remain notAttempted.

The request purpose is documented in the [research ledger](ford-abs-research.md); target support remains unverified. A returned specification version does not establish module compatibility or permission to transfer configuration.
