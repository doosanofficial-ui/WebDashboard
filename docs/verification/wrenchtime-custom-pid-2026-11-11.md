# WrenchTime custom PID slice: verification record

## Scope and provenance

- Goal: independently implement local, read-only custom PID authoring, offline decode, safe append/persistence and cancel behavior. No WrenchTime code/assets extracted.
- Baseline: `4d782c2` on canonical main, plus the six exact Swift sources/tests hashed in [source-sha256.json](evidence/wrenchtime-custom-pid-20261111/source-sha256.json). The tested snapshot and canonical versions matched byte for byte.
- Xcode 27.0 (27A266a); iPhone 17, iOS 27.0 (24A434); dedicated Simulator `CF44E21B-06DF-4AD4-8356-9381B6DB982D`; portrait 402×874 points / 1206×2622 pixels; English default text and Korean accessibility XXXL.
- Captures are unmodified synthetic app screenshots taken by XCTest from the foreground test app. The operator's existing Simulators and PosterBoard dialog were preserved. No physical device, radio, vehicle, GPS permission or network connection was used.
- Synthetic diagnostic profile uses a loopback address, never connected. Profile save after relaunch retained its existing query and appended one custom query. Preview data did not create measurement rows or become live values.

## Automated verification

- Core RED: new draft type absent. GREEN: 7 focused cases, then full core **466 passed, 0 failed** (`core-final.log`, local work artifact).
- Core tests include strict numeric/hex validation, read-only 01/21/22, real zero, no-data/wrong ECU/wrong PID, oversized sample, duplicate IDs, optimistic profile drift, Wi-Fi/BLE profile preservation and passive-CAN rejection.
- UI RED: missing New Custom PID action; later explicit keyboard visibility regression failed before FocusState fix.
- Final build-for-testing and test-without-building: **4 passed, 0 failed, 0 skipped**, [result summary](evidence/wrenchtime-custom-pid-20261111/ui-four-final-summary.json). Includes exact wrong-ECU input assertion, visible 60 C, cancellation, persistence/relaunch and Korean XXXL.
- Prior 3-case result did not establish an exact wrong-ECU UI case: its input helper appended text. The malformed-input screenshot is preserved as PRIOR evidence, not wrong-ECU proof. The final four-case suite uses an independent fresh draft for wrong ECU. A Korean system edit-menu label also required the test helper to match the observed language. Neither test-helper issue was a product decode failure.
- `git diff --check` and `python3 scripts/validate_platform_docs.py`: passed. Native iOS only changed; Android/RN changes predated this task and were not touched or staged.
- Independent read-only review caught a SwiftUI profile-snapshot lifetime issue; fixed by capturing openedProfile in init-seeded State. Storage publishes only after atomic save. Duplicate/stale selection stays fail-closed until explicit review.

## Direct visual inspection

All seven final captures below were opened directly at readable scale. No unexpected system prompt or app error dialog remained in them. The deliberately triggered validation alert was acknowledged inside the app, not a system permission dialog.

| State | Screenshot | Capture UTC | Direct review | Pixel findings | Result | Parent review |
| --- | --- | --- | --- | --- | --- | --- |
| cancel-reset | [SYNTHETIC-custom-pid-cancel-reset.png](evidence/wrenchtime-custom-pid-20261111/SYNTHETIC-custom-pid-cancel-reset.png) | 2026-11-11T13:46:10.995000+00:00 | Primary implementation worker, 2026-11-11 | Reopened draft is blank and Save is disabled. Cancel/Validate remain reachable. | PASS | Pending parent direct review |
| empty | [SYNTHETIC-custom-pid-empty.png](evidence/wrenchtime-custom-pid-20261111/SYNTHETIC-custom-pid-empty.png) | 2026-11-11T13:46:02.423000+00:00 | Primary implementation worker, 2026-11-11 | Blank fields, disabled Save, local/read-only scope and explicit diagnostic-profile selection warning are legible. | PASS | Pending parent direct review |
| ko-largest-identity | [SYNTHETIC-custom-pid-ko-largest-identity.png](evidence/wrenchtime-custom-pid-20261111/SYNTHETIC-custom-pid-ko-largest-identity.png) | 2026-11-11T13:46:34.531000+00:00 | Primary implementation worker, 2026-11-11 | Full-width Korean identity fields reachable by scroll; no label/input side-by-side squeezing. | PASS | Pending parent direct review |
| ko-largest-top | [SYNTHETIC-custom-pid-ko-largest-top.png](evidence/wrenchtime-custom-pid-20261111/SYNTHETIC-custom-pid-ko-largest-top.png) | 2026-11-11T13:46:27.227000+00:00 | Primary implementation worker, 2026-11-11 | Korean accessibility XXXL text wraps vertically; title and Cancel/Validate/Save remain visible. Long content scrolls. | PASS | Pending parent direct review |
| persisted-no-live-value | [SYNTHETIC-custom-pid-persisted-no-live-value.png](evidence/wrenchtime-custom-pid-20261111/SYNTHETIC-custom-pid-persisted-no-live-value.png) | 2026-11-11T13:47:45.476000+00:00 | Primary implementation worker, 2026-11-11 | Relaunched Signals shows synthetic saved signal, read-only query metadata, and NO SAMPLE/dash rather than preview leaking into live data. | PASS | Pending parent direct review |
| preview-60C | [SYNTHETIC-custom-pid-preview-60C.png](evidence/wrenchtime-custom-pid-20261111/SYNTHETIC-custom-pid-preview-60C.png) | 2026-11-11T13:47:20.943000+00:00 | Primary implementation worker, 2026-11-11 | Exact 7E8 03 41 05 64 sample and SAMPLE · 60 C visible; keyboard dismissed, value inside screen. | PASS | Pending parent direct review |
| invalid-ECU-no-value | [SYNTHETIC-custom-pid-invalid-ECU-no-value.png](evidence/wrenchtime-custom-pid-20261111/SYNTHETIC-custom-pid-invalid-ECU-no-value.png) | 2026-11-11T13:48:33.213000+00:00 | Primary implementation worker, 2026-11-11 | Exact 7E9 03 41 05 64 input visible, no decoded value after error acknowledgment. | PASS | Pending parent direct review |

## Completion boundary

- Supported claim: this offline Custom PID slice builds and passes the stated core/UI checks; the seven listed portrait states were directly inspected.
- Parent must directly open the preview, saved-catalog and largest-Korean core captures before telling the user UI verification is complete.
- Unverified: physical iPhone, landscape, real ELM/vehicle support, live PID test, catalog scan/formulas and temporary 11/29-bit protocol restoration. None are implied by offline decode or Simulator results.
- Full CarPlay category/entitlement and Live Activity runtime are separate work. No capability was guessed or enabled in this slice.
- Existing GH007 publication/author decision remains pending. Do not rewrite that prior commit or change author/security settings. This slice may be committed locally; remote synchronization is not yet verified.

## Reproduction

Generate the Xcode project in an ASCII-path source snapshot, build for the dedicated Simulator, install that final app, seed only its container with a synthetic diagnostic profile, then run `TelemetryUITests/CustomPIDUITests` with `test-without-building`. Building/reinstalling after seeding can replace the app container and is not valid persistence evidence. Use 300-second destination and 300/600-second test timeouts. No global Simulator cleanup is required.
