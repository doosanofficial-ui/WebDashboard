# iOS 27 Help capture refresh after Numeric editor layout change

## Exact source and execution

- Source application commit: `4666cc019ca217bb1c5822e1c9d35d0494a96563`, Telemetry `0.22.5 (21)`.
- [Help-only iOS 27 run](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43580545124): Seed succeeded; four UI tests passed, zero failed/skipped. The iPhone 17 Simulator used iOS 27.0 build `24A434` and UUID `C0A48ECE-5B56-4338-BA4E-B3F3B667E33F`.
- [Original UI artifact 14108493898](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43580545124/artifacts/14108493898) contains the 28 PNGs, 28 number-marker files, attachment export, source inventory, final product receipts and XCTest result. The same-run app executable SHA-256 is `4839420d54fa2426dbff670879314255016948e981544fd92ab20b7df5767b1a`; runner `bd1722e9e9144195a848a5ee7195a05b4f39e7e0c09e44faf4d52d17aabba65b`; UI test bundle `271367a5e79e6bfa1ee44e37cfbaf6a7cd4664d2301305177f61ee94d6e26977`.

## Direct visual review and source gate

The implementation reviewer opened every original English and Korean PNG under `mobile-ios/App/Resources/HelpScreenshots` after comparing its bytes, anchor marker, capture receipt, source inventory and unchanged before/after product hashes with the same UI run. All 28 expected guide targets are visible; the editor navigation title reads `Edit` / `편집`, the normal-size Live `Edit` / `편집` button is readable, and no error or permission dialog appears. Some unrelated scroll content passes under the standard navigation or tab chrome; this does not obscure the cited guide targets. Repeated screenshots of one unchanged state have identical image bytes but distinct per-step markers and receipts.

The 60 App source input paths match the recorded inventory, with no missing, extra or stale hash. `scripts/verify_help_assets.py` passed for 28/28 genuine images and their same-run provenance. `python3 -B scripts/verify_native_contracts.py --suite all` passed **502/502**, zero failures/errors/skips/deferred. `scripts/validate_platform_docs.py` and `git diff --check` passed. The capture assets and manifest are refreshed from this actual run; no image or source hash was invented.

These normal-size synthetic guide images do not certify AX5 Numeric inputs, keyboard geometry, a new physical-device run, vehicle acquisition or CarPlay. The separate Numeric layout XCTest and direct AX5 screenshot review remain separate runtime gates.

## Numeric editor change and remaining runtime gate

Source commit `4666cc0` changes the editor title to localized `Edit` / `편집`, gives the selected widget name its own wrapping row, stacks Label/Bind and Signal ID fields with vertical input growth, and exposes an accessible keyboard-toolbar Apply button. Signal ID input and save strip embedded newlines, preserving a single-line identifier while allowing the field to grow for large text. The first invalid Numeric input UI check now keeps the keyboard open, checks that Apply is hittable, and records a keyboard-visible screen before applying. Local Xcode 27 app and UI-test target build succeeded with source-input hashes matching the commit; the pre-capture Core checks passed 472/472. iOS 27 AX5 Numeric pixels and XCTest remain a distinct pending gate. No cause has yet been established for the earlier `Invalid frame dimension` warning.

## Preserved vehicle record, exercised with current source

The read-only 10 October preserved SQLite inspection contains 27 sessions and 9,321 rows. The 2 October 22:27:30 KST session lasted 1,053.021 seconds and has 2,641 rows (781 responses, 781 signals, 1,053 location, 26 system). The production recorder and replay code from source `4666cc0` exported JSON and CSV and built replay timeline/snapshot; every exported row matched SQLite and the original database hash stayed unchanged. Evidence summary: `numeric-layout-followup-20261114/historical-replay-summary.json` in the task workspace. This is an offline reuse of historical data, not a new vehicle or physical-device run.
