# Dashboard noninteractive follow-up — 2026-10-14

The application source remains `1c71f8e47b43ceebf1d76d203c6c115ed65c832e`. This follow-up expands existing console regressions while Teams owns the shared Mac screen. It changes two test files and this report; it does not change application behavior or replace the installed app.

## Changes and verification

- `verify_dashboard_regressions.py` compiles the complete `LocationService` with its CoreLocation import replaced by explicit boundary doubles. It tests permission waiting, Stop before authorization, foreground collection, a single Always upgrade request, late authorization, restart and denied/restricted state. The executable links neither CoreLocation nor CoreBluetooth.
- BLE cancellation is recorded as an array instead of a Set. The old Set concealed duplicate cancellation calls. The probe checks the exact cancellation count, retention until a terminal callback, and cleanup of only the completed inspection. Callback bodies come from production source; callback delivery is simulated.
- The same probe compiles the actual Help data types and image/accessibility expressions. It checks six guide identities, fourteen ordered steps, both languages, all twenty-eight image names and the selected step's accessibility text. These checks do not render or validate screenshot pixels or provenance.
- The existing coordinator harness adds late GPS callback checks: Stop retains the previous fix and track, rejects new recorded positions, permits GPS presentation while recording is off, and prevents acquisition in Replay. UIKit, location, recording and upload boundaries remain doubles.

| Verification | Result | Evidence boundary |
| --- | --- | --- |
| Expanded console probe, English | 74 checks, 0 failures | Actual methods/data with explicit doubles; no native services or SwiftUI rendering |
| Expanded console probe, Korean | 74 checks, 0 failures | Same scope, Korean presentation resources |
| Coordinator harness | 30 checks, 0 failures | Production coordinator methods with boundary doubles |
| Focused TelemetryCore tests | 41 tests, 0 failures | Actual Snap/Undo, recording lifecycle/write/recovery and replay-location code; temporary test databases |
| Deliberately duplicated BLE cancellation | Rejected in both languages | Expected `stop_cancels_duplicate_reference_only_once` failure |
| Deliberately retained GPS start intent after Stop | Rejected in both languages | Expected `gps_stop_cancels_pending_authorization_intent` failure |

The successful runs occurred on 2026-10-14 at 06:11–06:15 UTC. Core used the existing compiled test binary after all 75 Package/Sources/Tests inputs matched current main byte for byte. An initial wider comparison included an Xcode user scheme plist absent from the build snapshot; that noncompiled metadata was recorded and excluded before executing the selected tests. This is a fresh test execution, not a fresh iOS application build. The prior generic Simulator build and 271-test full Core result remain historical evidence.

The mutations exist only in separately identified verification copies. Canonical application source and the Help source hashes/assets are not altered to obtain a pass. Python's probe uses explicit failure checks and contains no `assert` statements.

## Remaining native verification

- Snap/Undo rendering and persisted layout after reopening, active recording/GPS controls and their native asynchronous behavior.
- Real Bluetooth callback delivery, reconnection and peripheral shutdown. Cancellation of this app's local connection does not establish immediate physical link shutdown.
- All twenty-eight current-source Help captures, direct pixel inspection and provenance repair. Existing main Help provenance still has three stale source hashes; candidate has five missing inputs and twelve stale hashes. No replacement capture was produced by this follow-up.
- Korean UI, SE viewport, large Dynamic Type, zoom, navigation focus and VoiceOver. The prior current-main foreground evidence covers only iPhone 17 portrait with normal text and the English Live guide; the app-content accessibility hierarchy was unavailable.

These steps require coordinated GUI ownership. No foreground change, app launch/installation, native runner installation, synthetic user database preparation, permission response, language change or physical-device action was performed. They remain unverified while Teams owns the screen. Native writer/cache quiescence needed for a future data-changing capture workflow is not certified; the previously rejected workflow remains guarded.

## Official API references

- [Apple: cancelPeripheralConnection](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection(_:)): asynchronous cancellation covers active and pending local connections; delegate completion and physical link state are separate concerns.
- [Apple: requestWhenInUseAuthorization](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization()): permission requests are asynchronous and require foreground presentation.
- [Apple: accessibilityLabel](https://developer.apple.com/documentation/swiftui/view/accessibilitylabel(_:)): labels describe content; button traits already convey the control type.
- [Apple WWDC24: Catch up on accessibility in SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10073/): state changes must be accessible, and testing with an accessibility technology is required to assess the experience.

The API Markdown pages were retrieved directly from Apple on 2026-10-14. The installed iPhoneSimulator SDK headers corroborate BLE's nonblocking cancellation contract. Local receipts preserve source digests, generated probes, raw logs, linked libraries, mutation failures and the user-data preservation comparison.
