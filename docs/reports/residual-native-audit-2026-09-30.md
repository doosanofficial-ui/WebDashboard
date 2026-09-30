# Residual native audit — diagnostic profile safety and decoding (2026-09-30)

Baseline: `0c9b3abe97636c46f9d4bd3e25295620aa6e6361`. Tracking: [issue #25](https://github.com/doosanofficial-ui/WebDashboard/issues/25). Completed issue #24 is not reopened.

## Scope and execution plan
1. Reconcile the historical backlog with the active iPhone/local-first goal and separate software work from physical/external gates.
2. Reproduce configuration and catalog failures with complete current source files and independent synthetic fixtures before editing.
3. Add constructor/JSON/decoding regressions and apply minimal fixes, preserving valid wire formats and manufacturer request candidates.
4. Recheck main and integrate without force; inspect full Core, coordinator harness, hosted lifecycle, native Simulator build and existing CI on the exact resulting commit.

## Four reproduced defect groups
### 1. Signal identity collisions
OBDQueryDefinition accepted repeated signal IDs. Decoding a synthetic response and feeding those results to the same unique-key Dictionary expression used by TelemetryModel reproduced a SIGILL trap: `Duplicate values for key: 'soc'`. Across distinct diagnostic queries, or between raw and diagnostic catalogs, AdapterProfile also accepted shared IDs although Dashboard bindings, local snapshots and stored signal identities share a namespace.

Fix: reject repeated IDs inside a query with OBDQueryError.duplicateSignalID; extend AdapterProfile's existing duplicateSignalID check across raw and all diagnostic definitions. Duplicate display labels remain valid. This is exact-source consumer evidence, not an actual iPhone crash claim.

### 2. Polling conversion overflow and zero truncation
A finite `pollInterval = 1e20` with a matching finite timeout passed validation. Applying the scheduler's actual `UInt64(pollInterval * 1_000_000_000)` expression reproduced a SIGILL trap. Very small positive intervals converted to zero.

Fix: validate a positive representable UInt64 nanosecond value with the existing truncation semantics before constructing the immutable query. Constructors and JSON decoding share this path. Ordinary intervals remain unchanged; no arbitrary 30-second polling cap or new vehicle request was added. The minimum representable delay is not a feasible vehicle sampling-rate claim.

### 3. Diagnostic offsets incorrectly limited to one classical CAN frame
The existing expandedQueries catalog uses offsets 88...152 for wheel speed, tire pressure and auxiliary charge candidates. OBDSignalDefinition rejected every position after bit 63, so that catalog could not even be constructed. Reassembled diagnostic payloads and individual CAN frames were incorrectly given the same offset bound.

Fix: bound diagnostic offsets to the parser's supported 12-bit ISO-TP length domain, while keeping each scalar at 1...64 bits. The decoder still rejects an actually short response. Classical CAN SignalDefinition remains limited to 64 bits. The transport's existing buffer bound is unchanged: this change does not certify 4095-byte physical transfers or CAN FD. Expanded candidates remain opt-in and require real vehicle support evidence.

### 4. Wrong byte order for standard multi-byte Mode 01 fields
The Santa Fe baseline catalog used Intel order for standard RPM and the supported-PID bitmap. With the known RPM bytes `1A F8`, it decoded 15878.5 rpm instead of `(0x1A * 256 + 0xF8) / 4 = 1726`. The supported-PID bytes `08 18 00 01` were similarly reversed.

Fix: use Motorola start bit 7 for these two standard multi-byte fields. Single-byte speed/coolant and manufacturer HV SOC definitions are unchanged. The independent fixtures already appear in `docs/reports/obd-codec-implementation-plan.md`. This changes the built-in catalog; user-imported and already-persisted definitions are not silently rewritten.

## Verification before integration
- Swift 6.2.1/Linux focused package contains complete production CAN.swift, OBDQuery.swift, AdapterProfile.swift and SantaFeMX5HybridProfile.swift; no model/decoder stubs in that package. It is not the full app or entire repository suite.
- Original blobs verified against GitHub: CAN `969f60190682903b4c5b57c5932de61a28739fc8`, OBDQuery `841984ff92f31ecd7fe53244f25fc8badd8948d3`, AdapterProfile `0fb1e0c45e3a36f483371e2a4db31e5fd52fe058`, SantaFe catalog `aacc89a6b7040102307b812105768742ee2b5ee6`.
- First pre-fix suite: 16 XCTest cases, 13 failed assertions across 9 cases; separate child processes reproduced duplicate-key and integer-conversion traps.
- Catalog pre-fix suite: 11 XCTest cases, 15 failures including 9 unexpected errors from invalidBitRange; observed wrong RPM and supported-PID bitmap values.
- Final focused suite: **27 XCTest cases, 0 failures**, rerun before integration. Synthetic multi-frame input traverses the production response parser and decodes four wheel values 83/84/85/86 at their existing offsets. Separate fixtures verify TPMS, auxiliary-charge units, boundary/short-payload rejection, standard RPM/bitmap and unchanged single-byte/SOC values.
- `git diff --check` passes. Production diff: 3 files, 30 additions and 5 deletions. No schema migration, build-number change, user-data deletion or transport operation.
- Full macOS/Xcode CI results must be read from the resulting commit and recorded in issue #25; do not substitute the focused package for those results.

## Remaining work by feasibility
| Area | Disposition |
| --- | --- |
| Failure-atomic profile import/save | Next software investigation: retain previous valid configuration if replacement decoding or persistence fails. Reproduce against actual TelemetryModel before fixing. |
| Database initialization/migration | Investigate repeat mode-column probe and reopen/error handling; logs alone are not a reproduced product failure. |
| Optional URLSession XPC logs | Existing simulator observation; do not suppress or declare a physical-network defect without reproduction. |
| Persisted session browser / interactive replay | Separate product slice: current SessionsView has controls/export, not the complete requested session browser and replay timeline. Core Replay PASS does not close this UX requirement. |
| Native widget UI acceptance | Verify all editing, persistence, orientation and stale/error interactions separately. |
| iOS 27 SDK/runtime qualification | Distinct from whichever SDK/runtime CI actually uses. |
| BT4N, real ECU, passive CAN, endurance, CarPlay | Physical or approval-gated evidence still required. No software result closes these gates. |

Android/iPad, screen-lock qualification, ABRP API/OAuth/upload, proprietary OEM data extraction and ECU-changing commands remain excluded. Historical docs mentioning them do not reactivate them.

## Reproduction and references
- `swift test --package-path mobile-ios/TelemetryCore --filter DiagnosticProfileSafetyTests`
- `swift test --package-path mobile-ios/TelemetryCore --filter DiagnosticCatalogDecodingTests`
- Full regression: `swift test --package-path mobile-ios/TelemetryCore`
- Coordinator: `python3 scripts/verify_telemetry_model.py`
- macOS hosted tests: `python3 scripts/verify_ios_lifecycle.py --result-directory /tmp/telemetry-lifecycle-UNIQUE`
- [Swift Dictionary unique-key precondition](https://developer.apple.com/documentation/swift/dictionary/init(uniquekeyswithvalues:))
- [Swift numeric conversions](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/thebasics/)
- Existing independent Mode 01 fixtures: `docs/reports/obd-codec-implementation-plan.md`.

A passing catalog test means the application can construct and correctly interpret the tested definitions; it is not proof that this vehicle exposes those measurements.
