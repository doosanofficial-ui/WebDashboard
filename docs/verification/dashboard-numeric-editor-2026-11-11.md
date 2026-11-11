# Dashboard Numeric Editor Verification

## Identity and Scope

- BASE MAIN SHA: `e5fb11d5f1fd5a52e9a8b494c119621930b1ebba`. Work is serial on canonical `main`; unrelated React Native/mobile changes and earlier evidence remain untouched.
- APP VERSION/BUILD: local candidate `0.22.5 (21)`, Xcode `27.0 (27A266a)`, iPhone 17 / iOS 27.0 Simulator (`24A434`), iPhone-only target family `1`.
- Frozen candidate app code: `Telemetry.debug.dylib` SHA-256 `15cb203e4c76bf059dd3cdb9145005085872a5028581e1edea0b087bd8c04866`. The app executable stayed unchanged across the test-only gesture corrections below. This is not a signed physical-device distribution or a whole-product acceptance.
- PRIVATE RECEIPTS: `~/.local/share/WebDashboard/evidence/numeric-reflow-20261111.tKPujH/`. Raw diagnostic reports, device identifiers, xcresult bundles and process receipts stay local. Source/product snapshots are under the recorded `stage-path.txt`.
- Scope: numeric configuration validation/recovery and maximum-text readability, then previously unattempted software UI checks. No vehicle query, physical iPhone installation, screen-lock test, Android/iPad work, CarPlay entitlement submission or system permission change.

## Change and Reproduction

Malformed range input used to become an empty optional value without correction feedback. The pending validation implementation was retained and checked rather than rewritten. It rejects non-finite/malformed numbers before updating the saved configuration, provides localized feedback and a keyboard Done action, and preserves deliberate blank clearing.

The new reproduction on the old local candidate failed exactly once with `Maximum-text numeric input must use a full row, not an ellipsized four-column cell`. Its actual pixels show both saved numbers as `1...`. The fix uses `AnyLayout` to keep the normal horizontal row but make accessibility-size range inputs full-width labeled vertical rows. This follows Apple's [state-preserving adaptive layout](https://developer.apple.com/documentation/swiftui/anylayout) and [accessibility-size](https://developer.apple.com/documentation/swiftui/dynamictypesize/isaccessibilitysize) APIs, without another UI framework or changes to CAN/GPS/storage contracts.

CHANGED FILES in the requested functional scope: `mobile-ios/App/DashboardEditorView.swift`, `mobile-ios/App/DashboardNumericDraft.swift`, the English/Korean string tables, editor/viewport UI checks, the Core rect-history contract test, `scripts/tests/test_dashboard_numeric_draft.py` and `mobile-ios/project.yml`. Refreshed Help PNG/marker/manifest files and their review record are source-bound evidence. Version increment is for the reproduced functional fix, not for the audit.

## Results

| Boundary | Status | Exact Evidence and Limit |
|---|---|---|
| Old four-column candidate, new readability assertion | FAIL, expected RED | `red/summary.json`: 1 executed, 1 expected failing assertion. Original source and pixels retained. |
| New app `build-for-testing` | PASS | `green-build.process.json`; bounded 900s, exit 0, owned writer group reaped. |
| TelemetryCore | PASS | Original `green-core.log`: 458/458; subsequent `review-followup/core-contract.log`: 459/459 including the added rect-history membership contract. macOS SwiftPM, not physical iPhone. |
| Numeric configuration probes | PASS | `numeric-draft-tests.log`: 6/6; exercises production validation/application code and actual localization tables. |
| Default English and Korean AX5 landscape recovery | PASS | `third/green-editor-regression/summary.json` contains the passed editor testcase (324.840s). Invalid draft rejected, `12.5` saved/reopened, all four localized range labels/full rows checked, original value restored. The other testcase in that batch failed and is not relabeled. |
| English AX5 portrait and viewport recovery | PASS | `fourth/green-editor-regression/summary.json`: 1/1, zero failures/skips. Its test completed successfully; a separate post-test MobileCal report blocked the next group. See `fourth/classified-result.json`. |
| Previously unattempted recorded GPS route prefix | PASS | `remaining/green-replay-route/summary.json`: 1/1. Synthetic recorded route at normal and AX5 text, including backward seeks. No real Core Location acquisition. |
| Language switch and Replay preservation | PASS | `remaining/green-help-runtime/summary.json`: 1/1. |
| English maximum-text all-guides Help | PASS (automated) | `remaining/green-help-max-en/summary.json`: 1/1, zero failures/skips on the same app code. Complete pixel review of all maximum-text captures is not claimed. |
| iPhone SE viewport repeats | PASS 2/2, Simulator only | `final-verification/green-se-viewport/summary.json`, actual iPhone SE (3rd generation), iOS 27.0. Both cases passed; the owned Calendar popup was separately reviewed before next-group admission. The earlier broad process-query timeout remains a separate BLOCKED attempt, not a model compatibility failure. |
| Strict paired label/input visibility | PASS 2/2 | `final-verification/green-label-visibility/summary.json`. Label and field fit together below the presented editor navigation bar and are both hittable. Primary directly opened all eight field-state images across English portrait/Korean landscape. |
| Same-source normal-size Help capture/publication | PASS (scoped) | Two capture cases passed; 28 original PNGs were directly opened, preserved and adopted with actual marker/producer receipts. 57 App input hashes and unchanged capture products validated. See [the complete 28-image review](../evidence/help-capture-review-2026-11-11.md). |
| Numeric/Help source-contract suite | PASS 34/34 | `final-contract-tests.log`: numeric, Help asset, capture-provenance and source-collection tests, with zero failures. Synthetic contract checks, not physical runtime. |
| Resource-updated canonical build | PASS | `canonical-final-build.process.json`: exit 0, 13.576s, owned writer group gone. Temporary selector adapter removed. Built 0.22.5(21) and Help manifest match the current source; app code dylib remains the same hash. |
| Resource-updated canonical Help runtime | PASS 1/1 | `post-resource-runtime/green-bundled-help-runtime/summary.json`, zero failures/skips. Both languages' actual bundled examples, saved language after relaunch and Replay state retention checked. Primary directly opened the resulting English/Korean UI captures. |
| Korean maximum-text Help | NOT TESTED / deferred | Both Korean maximum-text Help selectors are excluded from this local batch. No gate relaxation or substitution with remote `main` results. |
| PHYSICAL DIAGNOSTIC E2E / RAW CAN / CARPLAY runtime | NOT TESTED | No new physical measurement, passive CAN or CarPlay runtime evidence in this task. |

The original 24 successful candidate cases and the CSV/JSON three-row source comparison remain in the earlier candidate evidence directory unchanged. They are not presented as a full pass of this different product or as physical acquisition.

## Direct Pixel Review

Primary agent review: 2026-11-11 KST. The following are owned-Simulator synthetic captures, directly opened during verification. Exact source copies are unmodified; the Korean landscape preview is an explicit `sips -Z 1800` inspection derivative, with its original retained alongside it. No vehicle/private diagnostic screen is published.

| Screen/State | Reviewed Artifact | Findings |
|---|---|---|
| RED, English AX5 portrait | [Before](evidence/dashboard-numeric-editor-20261111/before-en-ax5.png) | Min/max both ellipsize as `1...`; functional accessibility values alone did not catch this. |
| New app, English default invalid draft | [Feedback](evidence/dashboard-numeric-editor-20261111/invalid-en-default.png) | `1..2`, field-specific correction text and Apply visible; no success/persistence falsely indicated. |
| New app, English AX5 portrait minimum | [12.5](evidence/dashboard-numeric-editor-20261111/after-en-ax5-minimum.png) | Persistent Min label and full `12.5`, without the old four-column truncation. |
| New app, English AX5 portrait maximum | [100.0](evidence/dashboard-numeric-editor-20261111/after-en-ax5-maximum.png) | Max label and `100.0` visible. This does not certify every editor control in every scroll position. |
| New app, English AX5 after restart/restoration | [0.0](evidence/dashboard-numeric-editor-20261111/restored-en-ax5.png) | Saved original value `0.0` shown again, not the rejected draft. |
| New app, Korean AX5 landscape range | [Inspection preview](evidence/dashboard-numeric-editor-20261111/after-ko-ax5-landscape-preview.png), [retained source](evidence/dashboard-numeric-editor-20261111/after-ko-ax5-landscape-source.png) | `최소`/`최대`, `12.5`/`100.0` readable in separate rows. |

Actual iPhone UI, the whole app/button inventory and unopened capture variants remain unverified. Desktop focus was not taken from the user's work; these are direct owned-Simulator/window captures, not Mac-frontmost or physical-device execution evidence.

The strict follow-up's eight directly inspected pairs are retained separately: [EN min](evidence/dashboard-numeric-editor-20261111/paired-en-minimum.png), [EN max](evidence/dashboard-numeric-editor-20261111/paired-en-maximum.png), [EN warning](evidence/dashboard-numeric-editor-20261111/paired-en-warning.png), [EN critical](evidence/dashboard-numeric-editor-20261111/paired-en-critical.png), [KO min](evidence/dashboard-numeric-editor-20261111/paired-ko-minimum.png), [KO max](evidence/dashboard-numeric-editor-20261111/paired-ko-maximum.png), [KO warning](evidence/dashboard-numeric-editor-20261111/paired-ko-warning.png), [KO critical](evidence/dashboard-numeric-editor-20261111/paired-ko-critical.png). These show fixture configuration values, not vehicle measurements. Optional empty thresholds remain blank, not zero.

Additional directly inspected states: [SE AX5 saved minimum](evidence/dashboard-numeric-editor-20261111/se-ax5-minimum.png), [SE landscape canvas end](evidence/dashboard-numeric-editor-20261111/se-ax5-landscape-canvas.png), [resource-updated Korean Help](evidence/dashboard-numeric-editor-20261111/help-runtime-ko.png) and [resource-updated English Help](evidence/dashboard-numeric-editor-20261111/help-runtime-en.png). The normal Help image is partially visible at this scroll position; this smoke is not the deferred Korean whole-image maximum-text gate. Source-byte hashes and scope are in [the inspection manifest](evidence/dashboard-numeric-editor-20261111/inspection-manifest.json).

## Failures Kept Separate

1. The first new-app batch had a Korean landscape seek failure: the 73pt field fit the 312pt available height, but full-page swipes overshot it. The test now uses measured, bounded drags while preserving full-frame/hittability assertions.
2. The next batch passed Korean landscape but failed reaching Apply in English portrait. Its recorded drag began at y=857 near the home-gesture region and repeated without scrolling. Moving the start to the viewport's interior quartile fixed that test; no further app-code change was needed.
3. One admission check returned `window-metadata-unavailable`, not a new crash. The private runner initially mislabeled this; the original JSON is retained, the user-facing statement was corrected, and five tests now check actual-body error preservation plus fail-closed fallback classification. A fresh verified `agent-desktop` window read is an observation fallback, not app-readiness or prompt approval.
4. A later real MobileCal popup was separately matched to its owned Simulator and original `.ips`. It is not a failed Telemetry XCTest. New group admission pauses until direct inspection and a non-sending ordinary window close; no Send to Apple control is used. Existing unrelated PosterBoard windows are preserved.

## Independent Review Disposition

An independent read-only Terra reviewer returned two findings, then was closed. The proposed Undo/Redo removal scenario was checked against `DashboardLayoutHistory.swift`, the model entry points, and an isolated synthetic UI trial. The trial stopped because structural deletion is not undoable. More decisively, history commands store/apply rectangles only, never whole widget arrays. The new `testRectUndoAndRedoNeverRemoveWidgetsAddedAfterTheCommand` passes in the full 459-test Core suite. No unnecessary production selection observer or new structural Undo feature was added; the unsupported trial and its exact source remain private, not in the canonical tests.

The second finding was accepted: `verifyReadableRanges` previously required only label existence/text. Its follow-up checks full paired label/field bounds and hittability using the actual presented editor navigation bar and passed in both languages. Narrow staged selector adapters call those same canonical helpers; they do not substitute App code or inject values into the telemetry store. Their source digest is recorded separately. Complete recovery remains wired into the canonical editor/viewport tests. The adapters were removed before the resource-updated canonical build.

## MobileCal Remaining Risk

The 11:33:27 report records background `scene-create`, `FRONTBOARD 0x8badf00d`, a 10.00s allowance, total system CPU 93.920s and application CPU 0.453s. This resembles the earlier 10:07:49 event (12.72s, 127.330s total / 0.834s application). Apple's [watchdog guidance](https://developer.apple.com/documentation/xcode/addressing-watchdog-terminations) explains that low application CPU is a hint of waiting for system resources; the termination backtrace alone need not identify the time-consuming cause. The specific competing service/process is not established.

Owned boot logs show Calendar daemon activation and background fetch without explicit Calendar calls in the app. Later owned reports also show UIKit pasteboard notification/cache queues. These observations do not establish that clipboard permissions or a particular user application caused the wait; no clipboard data was read or cleared. A separate control run recorded `runningboard 0x2182baad` and CalendarWidgetExtension watchdog events; these are not silently classified as the same `0x8badf00d` event. An unrelated metadata-query timeout is not another Calendar crash.

Mitigation is serial reuse of the initialized owned worker, plus a maximum 300s pause for primary inspection when admission is blocked. No watchdog limit, Calendar setting, global daemon, permission, existing Simulator, VPN or remote connection is changed. This is not a claim that the Apple runtime issue is fixed.

## Next Actions

- NEXT AUTOMATIC ACTION: final whitelisted diff/contract review, commit/push qualified changes on main, then read back the actual remote SHA/check status. All owned verification devices were deleted with no cleanup error. Earlier failed/blocked receipts remain unchanged. No whole-product or physical release is declared.
- NEXT HUMAN ACTION: none for these local software checks. A future stationary vehicle/iPhone connection is still required for current physical diagnostic E2E; it is not part of this Mac-only run.
