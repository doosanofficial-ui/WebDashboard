# Four-app physical benchmark and adoption backlog

Date: 2026-09-30. Repository baseline: ce5e3d0. Product: iPhone native CAN/GPS measurement.

## Evidence status

Current device inventory confirms these installed apps:

| App | Version | Bundle ID | Current direct exploration |
| --- | --- | --- | --- |
| Pelican | 5.0.3 (855) | com.featherless.apps.electricsidecar | BLOCKED: XCTest passcode prompt |
| Car Scanner | 2.1.46 | ovz.Car-Scanner | BLOCKED: XCTest passcode prompt |
| ABRP | 7.1.7 (5980) | com.iternio.abrpapp | BLOCKED: XCTest passcode prompt |
| OBDeleven | 2.12.0 (1790149781) | com.voltasit.obdeleven.ios.basic | BLOCKED: XCTest passcode prompt |

The attached home-screen photos establish installation, not feature execution. Current
capture shows “Enter iPhone Passcode for XCTest / Enable UI Automation”. The user must
enter the passcode on the phone. No app feature was directly verified in this run yet.
The harness log is /tmp/vehicle-benchmark-20260930/entry.log with result bundle
/tmp/vehicle-benchmark-20260930/entry.xcresult. The run terminated with exit 65: timed out while enabling automation mode. Retry only after device authentication.

Prior evidence, not current-run proof:
- car-scanner-demo-physical-2026-09-29.md: last-vehicle demo selector and synthetic readings.
- obdb-car-scanner-audit-2026-09-28.md: vehicle/profile, statistics, recording exploration.
- pelican-matlab-mobile-benchmark-2026-09-28.md: Pelican welcome screen only.

## Official feature inventory (documented, awaiting physical cross-check)

| App | Published functions | Product distinction | Primary source |
| --- | --- | --- | --- |
| Pelican | OBD parameter monitoring, faults, trips; manufacturer extended parameters; Shortcuts; community leaderboard | Vehicle-centered assistant with automation | https://pelican.clutch.engineering/features/ ; https://pelican.clutch.engineering/scanning/extended-pids/ ; https://pelican.clutch.engineering/help/ |
| Car Scanner | Configurable connection, custom PID header/command/formula, recording, diagnostics and service functions | User-configurable diagnostic measurements | https://www.carscanner.info/ ; https://www.carscanner.info/custompids/ |
| ABRP | EV route/charging planning, consumption calibration, live vehicle data, charger filters/status, traffic/weather, trip/charge history, CarPlay navigation | Prediction and trip decisions around battery consumption | https://abetterrouteplanner.com/premium/ |
| OBDeleven | Vehicle/control-unit fault logs, diagnostics, supported-brand customization and service functions; plan/device dependence | Vehicle and ECU organization with compatibility gating | https://obdeleven.com/features ; https://obdeleven.com/plans ; https://support.obdeleven.com/en/collections/16220744-using-obdeleven |

Cross-app synthesis is a design inference, not proof of identical behavior:
vehicle identity, connection status, supported-data availability, current measurements,
history, and settings are reusable concepts. Their acquisition capabilities, hardware,
subscription requirements and export formats must be verified separately. ABRP is an EV
planner; its functions are not automatically applicable to the Santa Fe HEV. OBDeleven's
VAG app must not be confused with the installed basic app.

## Screen-by-screen exploration contract

For each screen, record a stable feature ID, app/version, navigation steps, visible
controls, result after tapping, before/after screenshot, official source, dependency,
and proposed acceptance test. Status is OBSERVED, DOCUMENTED, BLOCKED, NOT TESTED, or
OUT OF SCOPE. A visible menu is not proof its underlying operation works.

| IDs | Screens/actions to inspect after authentication | Missing prerequisites to record |
| --- | --- | --- |
| PEL-01..08 | Welcome; Garage; vehicle detail; scanner selection; parameters; Logbook; Map; Settings/Shortcuts entry | Vehicle, subscription, adapter, account as encountered |
| CSC-01..14 | Home; connection/profile; last-vehicle demo; dashboard/pages/editor; live graphs; all sensors/search; sensor detail/custom PID; DTC; freeze frame; readiness; ECU IDs; vehicle; recording/import/export; statistics | Demo vs live explicitly; never clear DTC or run service action |
| ABR-01..10 | First run; vehicle selector; map; destination; route alternatives; charging stops; charger detail/filter; consumption settings; live-data setup; history/CarPlay entry | Login, route network data, premium, supported EV |
| OBD-01..09 | First run; Garage; vehicle selection; device pairing; ECU list; fault detail; live data; history; settings/plan/One-Click entry | Dedicated device, supported brand, account/plan; no writes |

Completion denominator: every visible top-level feature plus discovered child actions is
entered in the inventory. Hidden, paid, hardware-only and region-specific functionality
remains explicitly untested. “All features tested” is prohibited until the inventory has
no unexplained rows. Menus behind login/payment require a user handoff, not fabricated UI.

## Adoption plan

Reuse existing Transport, QuerySession, SignalDefinition, TelemetryStore, Recorder and
Dashboard models. Implement our own behavior and assets; do not extract private PID
catalogs, branding, account secrets, or vendor-authorized ECU actions.

| Priority / task | Deliverable | Acceptance / dependency |
| --- | --- | --- |
| P0 BENCH-01 | Four-app evidence inventory with linked screenshots | Each observed claim has same-run evidence; blocked rows name exact prerequisite |
| P0 DATA-01 | Query provenance and ordered durable recording | Raw response, query/definition revision, sample/time and decoded value survive DB/CSV/replay |
| P0 UX-01 | Vehicle -> ECU -> signal -> detail -> widget flow | SOC binds to numeric and gauge/bar; unavailable/zero/stale remain distinct; layout restores |
| P0 REPLAY-01 | Session list/reopen/export/playback UI | Reopen after app restart; same times/values/quality; no transport writes or duplicate records |
| P0 LIVE-01 | Stationary BT4N/Santa Fe diagnostic validation | Actual observed GATT, supported baseline and SOC evidence; then 10-minute E2E |
| P1 CONFIG-01 | Car Scanner-inspired versioned signal configuration | Read-query allowlist, validated decoding and units, independent golden samples, import/export |
| P1 VEHICLE-01 | Pelican/OBDeleven-inspired vehicle and ECU capability catalog | Profile switching restores dashboards; unsupported signal never blocks supported acquisition |
| P1 REVIEW-01 | Session synchronized trend/map/markers | Cursor shows original samples and gaps; map failure leaves logging operational |
| P1 PRIVACY-01 | Redacted local export | User can remove VIN/location identifiers; data remains usable offline |
| P2 ANALYTICS-01 | ABRP-inspired local consumption/energy summaries | Only verified voltage/current/speed inputs; measured vs estimated explicit; HEV energy boundaries documented |
| P2 AUTOMATION-01 | Pelican-inspired App Intents for session actions | Explicit start/stop/MARK; permission and lifecycle tests; no ECU control |
| P2 CARPLAY-01 | Glanceable status companion | Apple category/entitlement/template approval and physical runtime are separate gates |

External vehicle accounts, ABRP uploads/OAuth, routing infrastructure, cloud fleet service,
ECU coding/control/security access/DTC clear remain OUT OF SCOPE. Reference apps exposing
these features does not authorize adding them to this product.

## Execution sequence

1. Authenticate XCTest on the iPhone, then capture four entry states and inspect actual trees.
2. Explore discovered safe navigation, demo and read-only settings, maintaining a coverage table.
3. Cross-check observations against the linked official pages; resolve version/plan conflicts.
4. Add accepted reusable feature specifications and regression criteria to the backlog before implementation.

No product code, version, or recorded measurement data changed for this benchmark setup.
