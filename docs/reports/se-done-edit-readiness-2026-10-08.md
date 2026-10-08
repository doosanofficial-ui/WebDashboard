# SE Done-to-Edit readiness: first native query before polling

The status UI test scheduled a predicate waiter even when Edit was already ready. A focused cost replay showed the first polling delay spending enough of the unchanged five-second dismissal deadline to fail after native `isHittable` returned true. The test now queries immediately and uses the original waiter only when that query is false. The initial query and fallback must both return before the same deadline; late success remains failure.

Only `mobile-ios/UITests/SmallViewportStatusUIRegression.swift` and this report change. Product code, fixture, dismissal gates, capture order and timeout budgets are unchanged.

## Original failures remain distinct

Original source: `33588029220cab38c95199eabbaf83dc40cb33ff`, [Native Reliability attempt 1](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/37711170981). Raw Layout/SE result bundles were copied for analysis and their original bytes verified unchanged.

| Failure | Original assertion and observed evidence | Finding / limit |
| --- | --- | --- |
| Landscape move | `DashboardEditingUITests:100`, Undo disabled after drag; original video frames before/after release show no selected card or draft | Recognition, cancellation or snap-back cause remains unknown. This is not a failed frame assertion. |
| First overlapping resize | `DashboardEditingUITests:79`, stored AX value remains `Position 1, 0; size 2 by 2`; video after the synthesized event shows an orange expanded draft and overlap message | Resize was recognized. AX reports stored rect while pixels can show a draft. Release/cancel/commit order is unrecorded; second drag was never reached. |
| SE Done-to-Edit | `SmallViewportStatusUIRegression:42`, waiter `.timedOut`; sheet absent and Edit visible in a byte-identical screenshot bracket with one AX snapshot | Two disappearance waits and capture precede a delayed first predicate lookup. The remote native AX retry cause remains unproved. |

The SE capture interval is 0.610894 seconds; its immutable snapshot has Edit enabled at `(317,24,38,36)`. That proves observed presence/geometry, not native hittability. Original lookup start `1791423619.035` to retry start `1791423620.322` spans 1.287 seconds; it is not a known successful query-return duration. The earlier activation-point error is a separate unresolved observation.

## Focused RED/GREEN

All local runs use newly created, individually cleaned iPhone SE (3rd generation) Simulators, iOS 27.0 build 24A434, Xcode 27.0 build 27A266a, synthetic fixture only. Source base is 3358802; the modified test SHA256 is `0aa55432e1bf72bb167644dbab8411044c3caefb2cfc0c1d47a744fe69baa6d3`.

| Run | Done-to-capture complete | First native query starts | Native query returns | Result |
| --- | --- | --- | --- | --- |
| Original, monotonic observation | 2.593s | 3.665s | true at 3.778s | 1 passed, 0 failed/skipped |
| Original, synthetic cost replay | 2.937s | 4.015s | true at 5.312s | RED: waiter timed out at 5.315s; 1 actual XCTest failure, Xcode exit65 |
| Fixed, same cost replay | 2.906s | 2.906s | true at 4.203s | GREEN: 1 passed, 0 failed/skipped, including subsequent editor/help checks |
| Fixed, regular native SE gate | No added instrumentation or latency | Normal first query | Required within original deadline | 2 passed, 0 failed/skipped |

The model floors capture cost at 0.610894s and lookup-return cost at 1.287s, adding only the deficit below each floor. The second floor is borrowed from the original lookup-to-retry interval. Both versions use the same model. This establishes scheduling-budget loss under the model; it does not reproduce or explain the remote AX retry itself. The local original run already passed, so a single local GREEN does not establish CI stability.

Focused scripts, staged-source identities, raw logs, result summaries and preserved screenshots are retained in `ui-failure-boundaries-20261008/` in the authorized task workspace. RED remains a retained failure. No failed workflow was rerun and no timeout was raised.

## Direct visual review record

Primary agent directly opened the screenshots below on 2026-10-08 UTC. SE captures are portrait, 375x667 logical points, maximum accessibility text, app English with Korean system locale. Original Layout captures are video frames from the iPhone17 CI destination at normal text size; landscape frames retain the video track rotation. Screenshots do not prove acquisition, persistent recording or native hit testing.

| Screen/state | Screenshot in task evidence root | Direct pixel findings | Result | Parent core review |
| --- | --- | --- | --- | --- |
| Original SE after Done | [Original capture](/Users/doosansmacbookpro/Documents/Codex/2026-10-02/task-3/ui-failure-boundaries-20261008/se-done-edit-attachments/1B713F38-FED2-4BF8-B7F3-E47AE55EB459.png) | Sheet absent; Edit icon fully visible, no observed covering/clipping | Observed presentation only | NOT REVIEWED |
| Original landscape after event | [Frame40](/Users/doosansmacbookpro/Documents/Codex/2026-10-02/task-3/ui-failure-boundaries-20261008/layout-landscape-decoded-frames/frame-40.0.png) | No selected outline or move preview; Undo grey | Original failure retained | NOT REVIEWED |
| Original resize before event | [Frame89.2](/Users/doosansmacbookpro/Documents/Codex/2026-10-02/task-3/ui-failure-boundaries-20261008/layout-resize-decoded-frames/frame-89.2.png) | Cyan selected outline and visible resize handle | Observed selection | NOT REVIEWED |
| Original resize after event | [Frame93.2](/Users/doosansmacbookpro/Documents/Codex/2026-10-02/task-3/ui-failure-boundaries-20261008/layout-resize-decoded-frames/frame-93.2.png) | Orange expanded draft, overlap message and visible handle | Draft observed; saved commit unproved | NOT REVIEWED |
| Synthetic RED after Done | [RED capture](/Users/doosansmacbookpro/Documents/Codex/2026-10-02/task-3/ui-failure-boundaries-20261008/se-red-latency-replay-evidence/6905E36D-CABD-4C3B-884F-157F15187A41.png) | Sheet absent, whole Edit icon visible despite subsequent timing failure | RED retained | NOT REVIEWED |
| Regular native GREEN after Done | [Native capture](/Users/doosansmacbookpro/Documents/Codex/2026-10-02/task-3/ui-failure-boundaries-20261008/se-green-native/screenshots/DC40086F-F79C-4305-B741-511CC5014D79.png) | Sheet absent; whole Edit icon visible; one AX snapshot in an identical-PNG bracket, interval0.378s | PASS within inspected presentation scope | NOT REVIEWED |
| Regular native GREEN editor/help | [Native help](/Users/doosansmacbookpro/Documents/Codex/2026-10-02/task-3/ui-failure-boundaries-20261008/se-green-native/screenshots/48EA320D-7597-4762-B2B7-69872644BE47.png) | Whole editing-help explanation visible at maximum text; page label wraps; unchanged toolbar title is truncated | Help presentation inspected; no broad layout claim | NOT REVIEWED |

The screenshot bracket is an observation interval around one immutable AX snapshot, not an atomic screenshot/AX event. Original video-frame/activity alignment is approximate and does not establish an exact shared AX instant.

## Completion boundary

- Regular SE native tests: 2/2 pass; synthetic RED1 failure retained and same-model GREEN1 pass.
- Entire Core suite: 268/268 pass; entire Python runner contract suite: 106/106 pass.
- Independent source review: Critical0 / Important0. The report preserves the synthetic-model limitation.
- Remaining product causes: landscape gesture recognition/cancellation and resize release/cancel/commit order; remote AX retry and prior activation-point error.
- User44 files, earlier task inputs except this owned test, original failures, existing Simulator states and Teams services are preserved. No keystore bytes or hidden session/auth stores were read.
- Physical-device installation remains paused. No device installation, deletion, authentication change, provisioning renewal or acquisition trial occurred.
- New exact-SHA automatic push CI is checked separately after normal synchronization; this local record makes no preemptive remote success claim.
