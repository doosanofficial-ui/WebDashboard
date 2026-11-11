# WrenchTime Live Activity slice: verification record

## Scope

Independent implementation from public WrenchTime/Apple behavior, following the [behavior matrix](../reports/wrenchtime-behavior-integration-2026-11-11.md). This slice adds local, opt-in, REC-linked ActivityKit presentation. It does not add automatic trip detection, vehicle querying, push delivery, account access, a new background mode or a full CarPlay app entitlement.

Default is off. An operator selects at most two signals explicitly; enabling the setting does not start recording or an adapter. A successful foreground REC starts one Activity attempt. Stop/failure invalidates its generation before durable recording closes; pending updates cannot revive that session. User dismissal is not automatically reversed. Relaunch ends orphaned Activities before allowing a new session. Activity failure is independent of recording.

The projection rejects missing, nonfinite, future, pre-session and stale samples. Real zero remains zero. Names/units are bounded by Unicode scalar count, and content is capped before requesting. Update work is paced and coalesced. Replay never creates an Activity; demo presentation is labelled DEMO. No raw CAN payload, location, VIN, endpoint or unselected signal is included.

## Platform and test boundary

- Canonical baseline for this slice: `2f0635f` on main. All 12 canonical source/configuration files match the final tested snapshot byte for byte; see [source hashes](evidence/wrenchtime-live-activity-20261111/source-sha256.json).
- Xcode 27.0 (27A266a); dedicated iPhone 17 / iOS 27.0 (24A434) Simulator `CF44E21B-06DF-4AD4-8356-9381B6DB982D`; portrait 402×874 points / 1206×2622 pixels.
- App and embedded WidgetKit extension both compile for minimum iOS 17. Supplemental small family APIs are gated at iOS 18. Actual CarPlay Live Activity availability starts at iOS 26; no physical head-unit or earlier OS runtime was tested.
- The final installed bundle contains `NSSupportsLiveActivities=true` and the embedded `local.webdashboard.Telemetry.RecordingActivity` extension. Existing location/Bluetooth background modes are unchanged; no App Group, push token/server or CarPlay entitlement is introduced.
- All captures and records use a synthetic diagnostic profile at loopback 127.0.0.1, never connected. Existing user Simulators and the pre-existing PosterBoard report were preserved. No physical iPhone, radio, vehicle or GPS operation was performed.

## Authorization and test integrity

The dedicated Simulator first showed “Telemetry의 실시간 현황을 허용하겠습니까?” and later “Telemetry의 실시간 현황을 계속 허용하겠습니까?”. Only those app-specific Live Activity choices were handled under the development/verification permission authorization. The first one-time permission fixture is outside production and outside the ordinary UI suite. Ordinary UI tests stop at unexpected system choices; they contain no automatic Allow action.

The later “항상 허용” choice was freshly observed and applied only on this synthetic Simulator. No real device setting or account/security access changed. Permission screenshots are provenance, not final clean UI evidence.

## Automated checks

- Pure projection/generation tests: RED before implementation, then 6 focused cases green. Full TelemetryCore suite: **472 passed, 0 failed** (`activity-core-full.log`).
- App/extension build-for-testing and embedding: passed.
- Prior safe regression: PID 4 + Korean largest text setting 1 = 5 passed, 0 failed, 0 skipped.
- One-time permission/REC sequence: 1 passed after exact prompt matching; not a general regression substitute.
- Combined regression: 6 of 7 passed. All four PID cases and the REC/system-surface case passed. The relaunch assertions passed, but the final OFF cleanup tap did not change the switch once; its root cause was not established. This run is not reported as a full pass.
- A subsequent test-helper change required the whole element frame inside a fixed viewport, which incorrectly excluded a reachable REC button and caused scroll oscillation. Shorter drags alone did not resolve the excessive full-frame constraint. The final helper targets the actual UISwitch, uses navigation/tab bar boundaries and a stable center point, limits scroll distance, and fails with a capture if there is no progress. It does not repeat failed taps.
- Final Activity suite: **3 passed, 0 failed, 0 skipped**, including cleanup OFF. [Final result summary](evidence/wrenchtime-live-activity-20261111/activity-reviewed-final-summary.json). The four PID cases passed in the combined run; do not describe that earlier seven-case batch as all green.
- `git diff --check`, platform-doc validation and both source plist validations: passed after the final evidence update. App/Info.plist was synchronized to the exact tested XcodeGen output: its existing local-network/location text now matches pre-existing project.yml declarations; this introduces no additional permission or background mode.
- Independent read-only safety review found no confirmed defects after fixes. Remaining boundaries include delayed update/end race injection, actual user dismissal, populated real sample display, older OS and physical CarPlay.

## Stale rendering: measured limitation

Core validity and the requested `staleDate` are bounded; they are not a hard visual expiry SLA. In the synthetic iOS 27 run, ActivityKit logged staleDate 14:28:40 UTC, while a 14:29:07 screenshot still showed Recording. A later 14:30 screenshot showed Update delayed with dashes. The app process was no longer present when checked; no forced process suspension was performed. The earlier hypothesis that the app was continuously updating was not established and is not the finding.

The system owns stale rendering timing. The Lock Screen/small-family card now always includes its actual snapshot generation time, labelled Snapshot updated, and settings explicitly warn that iOS can delay updates and stale indicators. Do not claim that a stale number disappears exactly at 15 seconds, or that this screen proves uninterrupted background acquisition. SpringBoard's accessibility snapshot omitted the widget text, so absence from AX is not proof of disappearance. Final stale/end acceptance requires direct pixel inspection; the 130-second UI capture window is an observed test window, not a product guarantee.

## Visual evidence

All 11 final captures below were directly opened at readable scale by the primary implementation worker. They are unmodified XCTest screenshots of the running app or actual synthetic system screen. No unexpected prompt remains in these final captures. Capture source is the final tested snapshot/hash set above. Parent direct review of selected/no-value, stale, system-ended and Korean largest-text core screenshots is still required before a user-facing UI-complete claim.

| State | Screenshot | Capture UTC | Pixel finding | Result |
| --- | --- | --- | --- | --- |
| ko-largest-status | [SYNTHETIC-live-activity-ko-largest-status.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-ko-largest-status.png) | 2026-11-11T14:48:54.496000+00:00 | Korean iOS-delay caveat wraps without horizontal truncation; next-recording status remains visible above the tab bar. | PASS for stated scope |
| ko-largest-toggle | [SYNTHETIC-live-activity-ko-largest-toggle.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-ko-largest-toggle.png) | 2026-11-11T14:48:35.746000+00:00 | Korean accessibility XXXL wraps vertically; toggle remains reachable without horizontal clipping. Longer content scrolls. | PASS for stated scope |
| system-ended | [SYNTHETIC-live-activity-system-ended.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-system-ended.png) | 2026-11-11T14:52:27.951000+00:00 | The previously present system card is absent after REC stopped and the app setting was turned off. | PASS for stated scope |
| stopped | [SYNTHETIC-live-activity-stopped.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-stopped.png) | 2026-11-11T14:52:19.328000+00:00 | App status shows Live Activity stopped; selected signal controls remain reachable. | PASS for stated scope |
| stale | [SYNTHETIC-live-activity-stale.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-stale.png) | 2026-11-11T14:52:05.882000+00:00 | Actual system card shows orange Update delayed, no running elapsed timer, dashes and the unchanged snapshot time. | PASS for stated scope |
| notification-center | [SYNTHETIC-live-activity-notification-center.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-notification-center.png) | 2026-11-11T14:49:55.326000+00:00 | Actual system card shows two selected synthetic signal names, dashes rather than invented zero, Recording and a legible Snapshot updated time. No permission prompt remains. | PASS for stated scope |
| home | [SYNTHETIC-live-activity-home.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-home.png) | 2026-11-11T14:49:49.816000+00:00 | Home screen is settled and unobscured. No visible Dynamic Island was established; this is not Island-rendering evidence. | OBSERVED; Island unverified |
| recording | [SYNTHETIC-live-activity-recording.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-recording.png) | 2026-11-11T14:49:48.756000+00:00 | Activity active status is visible with the explicit selected signals and caveat. | PASS for stated scope |
| opted-in | [SYNTHETIC-live-activity-opted-in.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-opted-in.png) | 2026-11-11T14:49:40.638000+00:00 | Both named signal selectors and iOS stale-snapshot caveat are legible; status is ready, not recording. | PASS for stated scope |
| off | [SYNTHETIC-live-activity-off.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-off.png) | 2026-11-11T14:49:23.442000+00:00 | Default/explicit OFF, recording and CAN remain off. Setting and its privacy disclosure are visible. | PASS for stated scope |
| relaunched | [SYNTHETIC-live-activity-relaunched.png](evidence/wrenchtime-live-activity-20261111/SYNTHETIC-live-activity-relaunched.png) | 2026-11-11T14:53:08.531000+00:00 | App shows Ready for the next recording and Start recording after restart; no implicit REC restart. | PASS for stated scope |

## Remaining scope

No claim of full WrenchTime parity. Formula expressions, licensed catalog/live test, temporary 11/29-bit protocol restoration, vehicle-context presets, grouped/statistical gauges and full CarPlay eligibility remain separately scoped. Real ELM/vehicle support cannot be established by offline PID decode or synthetic Activity tests.

Dynamic Island configuration compiles, but the observed Simulator Home capture did not independently establish a visible Island. iOS 17/18 runtime, physical-device background behavior, populated sample screen transitions, actual user dismissal and controlled late-update races remain unverified.

Existing GH007 publication/author decision is still pending. Do not rewrite old authors, alter git identity or include unrelated mobile/evidence changes. This slice can be committed locally after final gates; remote synchronization remains unverified until the existing blocker is resolved.

## Reproduction

Use an ASCII-path source snapshot because the canonical path contains non-ASCII spacing. Generate with XcodeGen, build-for-testing, install only on the dedicated synthetic Simulator, seed its fresh data container, then test-without-building. The fixture has two synthetic read-only queries and no connected transport. Use 300-second destination,300/600-second per-test and900-second overall harness timeouts. Disable automatic verbose diagnostic collection for this run because an earlier xcodebuild finalizer hung in Simulator diagnostics after tests ended; assertion results, screenshots and xcresult remain enabled.
