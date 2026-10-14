# Dashboard GUI follow-up — 2026-10-14

The existing signed application built from `1c71f8e47b43ceebf1d76d203c6c115ed65c832e` was tested on the owned iPhone 17 / iOS 27.0 Simulator after Teams released the shared screen. Repository commit `454fb77` adds tests and documentation only. The application was not rebuilt, reinstalled or relaunched for this GUI follow-up.

## Directly inspected scope

- Default Snap left the existing cell geometry and dashboard file bytes unchanged. The horizontal toolbar required a touch swipe to expose Snap.
- The widget's exposed accessibility **Move right** action moved only its X position from 0 to 1. Snap after this edit did not write again or discard Undo. One Undo restored all original profile values and array order; the visual layout was inspected before, after and on reopening the editor. The Redo button became available, but the Redo action and widget drag/resize gestures were not executed.
- Six Help guides were traversed in English and Korean, fourteen steps per language. All 28 saved guide screens were directly opened with `view_image`. Visible action, expected-result and recovery text was readable. First-step Previous and last-step Next were visibly disabled; forward navigation and return to the guide list worked. The Previous action itself was not exercised.
- The Korean screenshot enlargement sheet opened, exposed the Korean slider and matching step label, and closed normally. Setting its accessibility value moved the thumb without changing the displayed image or Details value; this result was not accepted as successful zoom. Actual touch input produced 3× enlargement and matching Details 3. This distinguishes a setter-only tool result from the working user interaction.
- App language was restored to English, the editor was reopened, and the final screen was the original English Live view with CAN/recording/GPS off, six NO SAMPLE gauges and No GPS fix. All relevant screenshots showed no error or permission dialog.

The viewport was iPhone 17 portrait with normal Dynamic Type. The profile page's Landscape label remained unchanged; it is not evidence of a landscape device test. SE, landscape, large Dynamic Type, actual VoiceOver use, active recording/GPS, native location/Bluetooth callbacks, export and actual Replay remain unverified.

## Preservation and installed version

User files (45), current app inputs (172), candidate inputs (228), original change manifests and the native execution guard are unchanged. All 68 installed bundle files still match the signed package, and strict signature verification succeeds. Launcher SHA256 remains `c6931a1fac330d84e7baaf7c850113a54c561a03dbf4dd6f8e4cac82d6b080f3`; actual implementation dylib SHA256 remains `9fee05c32e112cf9b114b8a457d527321eb356a94ac69a839673e9d6bc25899b`.

Preferences are restored both by value and byte for byte, including the original language and client identity. No measurement database was created. The only app-container file difference is `dashboard.json`: the application's normal JSONEncoder reordered object keys while restoring all values and array order. Canonical sorted serialization matches the original exactly. Its original bytes remain in the private local evidence folder; they were not overwritten into the running app or used to disguise the current hash.

No install, app launch, test runner, DB preparation, permission/security change, physical-device action, model change or credential change was performed. Screen use ended after the final Live return; subsequent work only reads files, uploads the two requested images and records evidence.

## Evidence limits and capture-index repair

Fifty actual image files were saved and directly inspected. Fourteen are CUA window captures, and thirty-six are original-resolution SDK PNGs. The window captures remain private because the surrounding Device Hub contains other device labels. Two unmodified native app PNGs were created in the user's Library and successfully reread; their confirmed IDs are retained in the local upload/readback receipts.

A stale in-memory CUA manifest overwrote SDK entries in the merged index. All original PNGs, per-page AX/ready records and successful SDK capture logs survived. The old writer's loss and read-before-append fix were reproduced in a synthetic temporary directory. The merged index now covers all fifty unchanged image hashes, and both writers preserve independent receipts before merging future entries. No screen was recaptured to conceal this issue.

Thirty-four overwritten SDK entries lack their original exact command-end timestamps. Their provenance explicitly records the interval between the original CUA observation timestamp and the unmodified PNG's filesystem write time. Exact missing times were not invented. The index-overwrite copy, repair record and original inputs remain available locally. This evidence supports the stated visual scope; it does not certify missing historical capture metadata.

The default sandbox's popup metadata query returned `window-metadata-unavailable`. One bounded read-only query outside that sandbox succeeded with no matching Telemetry/SpringBoard error windows. No permission was requested or changed; metadata alone was not treated as pixel verification.

## Help asset acceptance still open

These 28 images show the running **Help guide pages**, which contain existing bundled examples. They are not replacements for the 28 underlying application screenshots in the Help resources. No Help resource image, marker or provenance hash was changed. Main's three stale source hashes and the candidate's five missing inputs/twelve stale hashes remain; the prior full 80/81 aggregate is historical and was not rerun or promoted as a new pass. Actual asset recapture, complete source provenance and final aggregate acceptance still require completion under the preserved-data scope.

Apple's [SwiftUI accessibility guidance](https://developer.apple.com/videos/play/wwdc2024/10073/) supports distinguishing exposed labels/actions from verification with VoiceOver. Existing console/API-contract findings and their [official references](dashboard-noninteractive-followup-2026-10-14.md) remain separate from this native visual record.
