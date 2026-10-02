# Ford ABS protocol findings

Target: 2012 Ford Fusion SEL, 2.5L, FWD; compatible used Ford/ATE ABS/HCU replacement. **No vehicle captures or Ford service procedure have been supplied. Nothing below is verified on that target vehicle.** Synthetic test fixtures are not evidence of vehicle support.

| Operation | Request | Expected response / finding | Verified on target | Source / notes |
| --- | --- | --- | --- | --- |
| Candidate addressing | Candidate HS-CAN `760/768`, normal 11-bit; both IDs configurable | Valid matching positive read response records session observation | No | Request inherited from `FordModuleProbe.absCandidate`; response candidate explicitly supplied by user in follow-up. Candidate profile is not car-verified. `observedAt` is recorded only after a matching valid positive response in an actual session. No hardware captures supplied. |
| Identify module (spare-part number only) | `22 F1 87`, optional | `62 F1 87 <data>` | No | Existing `OBDClient.udsText` request reused. Its old software-number label was incorrect; [udsoncan DID definitions](https://udsoncan.readthedocs.io/en/latest/_modules/udsoncan/common/dids.html) map F187 to manufacturer spare-part number. Support/session availability unknown. |
| Software/hardware/strategy identification | Unknown | Unknown | No | No additional DIDs probed or invented. |
| Read VIN from ABS | Unknown for target | Unknown | No | Generic OBD `09 02` remains powertrain vehicle identification, never substituted for ABS VIN. |
| Read DTCs | `19 02 FF` | `59 02 <availability mask> <3-byte DTC + status>...` | No | Existing project UDS read, now strictly parsed in dedicated ABS path. Empty positive response establishes communication; NO DATA/timeout does not mean zero DTCs. Third-byte interpretation unverified. |
| Clear DTCs | Ford sequence unknown | Unknown | No | UDS clear service existence alone does not verify the correct group/session/procedure. No request implemented. |
| Read As-Built | Unknown | Unknown | No | No ABS addresses, DID mapping or checksum algorithm supplied. Manual block-format import only. |
| Write As-Built | Unknown | Unknown | No | Disabled; sessions/security/write/checksum/compatibility/readback procedures all required. |
| ECU reset | Unknown required sequence | Unknown | No | Disabled. No reset/cycle inferred. |
| Security access | Unknown | Unknown | No | No seeds/keys/algorithms implemented or bypassed. |
| ABS service bleed | Unknown Ford service routine | Unknown | No | Disabled pump/valve routine placeholder only. |

## Adapter findings (distinct from vehicle verification)

Official [OBDLink Reference and Programming Manual](https://www.scantool.net/scantool/downloads/678/obdlink_frpm_e.pdf) documents STP preset selection and `STCSEGR`: enabled receive segmentation reconstructs multi-frame messages; disabled preserves frames for local reconstruction. This supports retaining receive frames rather than making up CAN traffic. Existing HS-CAN preset `STP 33` is reused. The dedicated reader uses existing ELM header/spacing controls with header display enabled. It requires OK acknowledgments and rejects unrecognized output formats rather than silently decoding them.

The transport exposes prompt-terminated command responses, not observed outgoing CAN frames. It cannot promise full TX/flow-control visibility or passive sniffing. Logical TX framing and explicitly instructed automatic FC are now included in validation traces. Actual TX/FC bus capture still requires a separately verified monitoring workflow; no monitoring command is enabled.

## Evidence to collect next

1. Obtain Ford factory replacement/PMI information for this VIN and exact original/replacement part/hardware identifiers, including supersession/compatibility information. Suffix differences alone establish nothing.
2. Run [Validate Original ABS Module](ford-abs-validation.md) with the user-supplied 760/768 candidate. Export text and JSON, including failures. Retain vehicle context, date, ECU identity and raw unmodified output. Mock observations never verify this car.
3. Confirm DTC format and supported identification reads in the default session. Add only sourced, bounded requests with strict response decoding and tests.
4. Establish configuration-read mapping and integrity checks; retain original raw responses and readable current configuration before proposing restoration.
5. Separately establish exact configuration-write and clearing procedures and any documented security access. If unavailable, keep the boundary unsupported.
6. Obtain the hydraulic service bleed procedure independently, including prerequisites, activation sequence, responses and abort behavior. Never experiment with pump/valve commands.

Update this table with actual evidence before marking a command verified. Protocol parsing tests verify software behavior only.

## Read-only validation additions

The candidate is now supplied in the UI; sessions start Candidate (or User configured for edited IDs) and only a matching valid positive diagnostic response records Observed on vehicle. Negative replies, incorrect IDs and incomplete messages do not promote the pair. Adapter setup uses documented normal addressing, explicit request/response FC mapping, an exact ISO-TP/FC classification filter and a receive filter. It logs every submitted adapter command, raw reply, logical request and instructed automatic FC, reported RX frame and reconstructed response. See the [validation workflow](ford-abs-validation.md) for sources and exact visibility limits. Writes, security, resets and bleed remain disabled.
