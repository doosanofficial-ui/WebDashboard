# WrenchTime integration publication and CI repair

## Published implementation

The numeric editor, offline Custom PID editor and opt-in recording Live Activity were published at `d7f81d34b89e616d07cc64ec304d927c3f42f2e4`. The GitHub private-email rejection was resolved by changing only author/committer email and dependent commit parent references for three unpublished commits. Trees, messages, names and timestamps were retained. GitHub attributed the published commits to the existing authenticated account. A complete local bundle and uncommitted-file backup were verified before a normal fast-forward push; no force push, global Git setting or new credential was used.

## Independent CI failures

1. [Native Reliability](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43045084687) rejected stale Help source provenance. The earlier manifest had 57 of 60 required inputs. New Custom PID/Live Activity files and modified screens required new captures, not changed hashes on old PNGs.
2. The same run's diagnostic recording source harness failed to compile because the actual REC/Stop methods now invoke an ActivityKit presentation boundary not represented in the macOS storage harness.
3. [Native Recording Lifecycle](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43045084790), [artifact](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43045084790/artifacts/13867381545), failed before any tests executed. `RecordingActivityController.swift` could not find `RecordingActivityAttributes`: the lifecycle host still included only `App`, while production included `App` and `ActivityShared`.
4. The Reliability layout group separately exceeded the original 1800-second XCTest command budget. It is not resolved by these compile/provenance fixes and remains a separate diagnosis. The aggregate correctly failed.

The prior SHA's smoke, native-app, native-seed, replay, replay-route, help, help-max-en, help-max-ko and SE viewport jobs succeeded. These are results for that exact prior SHA, not a green claim for the repair or the whole app.

## Scoped repairs

- Adopted 28 newly generated, directly opened English/Korean Help PNGs and their original marker/same-run product/source receipts. All 60 source inputs match the published implementation exactly. Old resource bytes and original captures were retained locally. [Pixel review and limits](../evidence/help-wrenchtime-capture-review-2026-11-12.md).
- Added a typed, presentation-only spy to the diagnostic recording harness. Production REC/Stop bodies remain verbatim. The actual SQLite, queue, diagnostic-failure, JSON/CSV and reopen checks remain unchanged. New assertions cover exactly one presentation begin with the durable session ID and synchronous end before durable close.
- Added `ActivityShared` to the lifecycle test host and a production/host source-parity regression. No new extension embedding, entitlement or permission was added to the host.
- Independent read-only review found no blocking defect in these fixes. The double does not certify ActivityKit rendering or production snapshot generation.

## Verification

| Check | Actual result | Boundary |
|---|---|---|
| Help producer XCTest | 2 passed, 0 failed, 0 skipped | Owned iPhone 17 / iOS 27 Simulator; synthetic examples |
| Direct Help pixel review | All 28 original PNGs opened | Normal text, portrait, English/Korean; parent core review separate |
| Help provenance gate | Passed | PNG/marker hashes, all 60 App inputs and same-run product receipts |
| Diagnostic generator regression | RED 1/6, then GREEN 6/6 | Generation contract; no UI |
| Actual Swift diagnostic harness | Record 60/60, separate-process reopen 59/59 | Actual App/Core storage paths, presentation/adapter doubles; no device/network |
| Lifecycle source-parity regression | RED missing ActivityShared; GREEN 32/32 | No count/skip/timeout policy relaxation |
| Lifecycle generic Simulator build-for-testing | Passed, Xcode 27.0 (27A266a), 48 seconds, exit 0 | No boot, install, launch or XCTest runtime |
| Complete native contracts | 489 passed, 0 failures/errors/skips; nothing deferred | Full `--suite all` |
| GPS/client integrity and service worker | 28/28 and 8/8 passed | Existing Node contracts |
| Platform documentation and scaffold checks | Passed | iOS-focused scope; scaffold is not Android acceptance |
| Whitespace check | Passed | Scoped diff |

The scaffold check was first invoked with an incorrect script path and failed before execution. It was rerun at the workflow's actual `mobile/scripts/validate-mobile-scaffold.js` path and passed.

## Preserved state and remaining gates

- 65 unrelated local files were checked against the protection hashes; they are not included in the repair commit. Existing `mobile/` changes, Android content and unrelated readiness evidence remain intact.
- Existing Simulator windows and system report popups were left untouched after the preservation instruction. No Apple report was sent by the agent. The compile-only verification did not interact with those windows.
- The new lifecycle host has not executed its 92 XCTest cases locally. Fresh exact-SHA CI must establish its runtime result.
- The resource-updated product bundle has not received a new local runtime smoke. Earlier successful capture tests establish capture provenance, not that later bundled resource build's runtime.
- Parent direct core-image review, physical iPhone/BLE/GPS/vehicle validation, full CarPlay head-unit/entitlement coverage and complete WrenchTime behavior parity remain separate requirements.
- The separate layout timeout and its exact cause remain open. No timeout was raised and no unchanged CI job was manually rerun to hide the failure.
