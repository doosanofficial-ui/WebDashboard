# Signals freshness clock — 2026-10-14

Fresh CAN samples could appear `STALE` when they arrived between the Signals view's 0.5-second Timeline ticks. The view evaluated them using the older scheduled tick date, while the freshness contract correctly rejects a timestamp later than its evaluation time. Live and Demo now evaluate at the current render clock. Replay keeps its selected recorded timestamp. Per-signal receive times, timeout rules, future-timestamp rejection and sample values are unchanged.

Apple documents TimelineView's context as the scheduled update date, rather than the arrival time of reactive data ([TimelineView](https://developer.apple.com/documentation/swiftui/timelineview)). The periodic invalidation remains in place so inactive signals still expire.

## Source verification

- The added Foundation-only source harness compiles the actual caller expression, actual freshness/frame-age/filter methods and complete display helper against explicit clock/model boundaries. It neither renders SwiftUI nor calls native services.
- Baseline `b7107be1d0476b3fd77e5e8db85d942c96738e9c`: 16 assertions, 7 behavioral failures. Fixed source: 16/16. Final generated harness inputs match the completed GREEN inputs byte-for-byte; layout experiments changed no tested inputs, so that run was reused.
- Existing coordinator source harness: 46/46. Dashboard/location/BLE presentation boundaries: 74/74 English and 74/74 Korean. Host Core tests: 271/271. Unchanged source hashes permit reuse after the final UI scope reduction.
- Final generic iOS Simulator Debug build succeeded at 2026-10-14 13:25:13 UTC. Its copied 207-file source inventory matched canonical source throughout the build.
- Python unit/contract fixtures: 227/228, zero errors/skips; the existing bundled Help provenance gate still fails. This change does not clear Help or native recording gates.

Run the focused source regression with a new output directory:

```sh
python3 -B scripts/verify_signals_presentation.py . /tmp/signals-presentation-check
```

## Runtime and visual review

- Build identity: `signals-clock-final-373d80e8a2f7c1e6`; source manifest SHA256 `373d80e8a2f7c1e6ad853fa75e6ab97e4708127001f10403323e4976c6dd684a`. Commit linkage is recorded separately after checking every source blob; immutable capture receipts preserve this pre-commit known-build identity.
- Same owned iPhone 17 Simulator `DDD24F62-C420-4211-B607-D1B03EBF881B`, iOS27.0 runtime24A434. English, portrait1206×2622, existing text size retained, dark theme. Final launch PID11238.
- Installed loader SHA256 `db103f8e899efb7d8885d54e5b6326a48bf5831077528619d7de444451b021fb`; implementation dylib SHA256 `300095e9d7854aa6bd20641ee31738bdb778fefef186354a6aa61773225b4340`. All68 installed files match the signed package; strict signature verification passed.
- Core PNGs and complete receipts are in the local task artifact directory `demo-signal-ui-fix-20261014`. SDK originals and supporting foreground CUA originals were each directly opened by the delegated primary agent. CUA timestamps below are observation completion; SDK times come from bounded capture receipts. The parent has not yet performed its required direct core review.

| Screen/state | Local original | UTC capture/observation | Pixel findings | Result | Parent core review |
| --- | --- | --- | --- | --- | --- |
| Final Demo active | final-demo-valid.png | 13:37:25.738974 | Finite Demo signal VALID; frame age1ms; CAN synthetic active; recording/GPS off. Footer initial underlap excluded from this pass. | PASS for freshness | NOT REVIEWED |
| Fresh signal under STALE filter | cua-window-final-stale-filter.png | 13:38:18.406 | 0items, No confirmed stale signals, Show all signals; synthetic data continues. | PASS | NOT REVIEWED |
| Stop after Demo | final-stop-live.png | 13:40:06.079810 | LIVE/disconnected; values cleared; no profile; CAN/recording/GPS off. | PASS | NOT REVIEWED |
| Final default LIVE | cua-window-final-restored-live.png | 13:41:01.577 | English LIVE; original dashboard; no sample/GPS fix; Developer collapsed. | PASS | NOT REVIEWED |

The exact target window was raised before each launch. Reviewed foreground originals show no visible error/permission popup. The app AX subtree was unavailable, so these are pixel observations rather than native AX assertions. Runtime-log absence is not treated as crash clearance.

## Footer investigation and completion boundary

Demo with Developer controls expanded places the second explanatory line behind the native floating tab bar at the initial scroll position. Apple permits scrolling content behind floating controls, while readable content must remain accessible ([scroll views](https://developer.apple.com/design/human-interface-guidelines/scroll-views), [layout](https://developer.apple.com/design/human-interface-guidelines/layout)). Expected behavior is that a normal scroll to the end reveals the full explanation above the bar.

The follow-up on the unchanged installed `be88685` app confirmed that behavior. A current official runtime snapshot identified the actual Simulator scroll view. Two ordinary upward swipes, using fresh `withinElementRef` values `e19` then `e22`, moved content to the bottom; the second swipe did not move its static positions farther. The full two-line explanation and lower card padding were visible above the tab bar, with separation between the card and bar. The raw SDK PNG `footer-scroll-review-20261014/scroll-end.png` was captured at 2026-10-14 14:26:00.306610 UTC, SHA256 `36fd9e8be1ae09215f2b362973e73b1eb8a1e5d18c57d6ef937f3646492d6ade`, and directly opened along with the saved foreground CUA originals before/after scrolling. Portrait1206×2622, English and existing text size remain the inspected scope. Parent direct review of this new core image is pending.

CUA's element-based page-scroll call completed without moving the visible content. An earlier stale window activation returned `Computer Use is not active ... first call get_app_state`; the official fresh app-state binding resolved that state error. The supported native swipe actions both returned `SUCCEEDED` with no action error. Their automatic post-action snapshot refresh reported `SNAPSHOT_CAPTURE_FAILED` because it did not settle within2500ms; references were refreshed through `snapshot_ui` before reuse, and the actual moved screen was separately captured and inspected. No repeated settling wait or raw-input workaround was used.

There is no reproduced persistent footer overlap at the actual scroll end in this scope, so no layout patch is warranted. Earlier content-margin/outer-scroll-view experiments remain excluded from the source. This follow-up performed no build, test, app install/launch, fixture preparation, runner installation action, security setting or persistent-access change. Demo was stopped and the original English LIVE screen was restored at 14:32:30.733 UTC. Original10 data-file bytes, user45 files, candidate228 inputs, Help57 resources and prior manifests/guard were rechecked unchanged.

Physical-device UI, landscape/larger text/Korean native Signals variants, acquisition, durable recording, Replay UI and CarPlay are unverified by this work. Fixed app fixture DB preparation, a new native XCTest runner, security changes, other devices, and physical installation remain excluded.

## Preservation and Library delivery

Final read-only checks preserved all45 unrelated user files, candidate228 inputs, Help57 resources and prior manifests/guard. Only the final Signals source changed in application inputs; the prior committed coordinator change remains intact. All original10 data-file byte contents, critical dashboard/preferences bytes, dashboard array order and critical mode/mtime survived SDK relocation. Language remains `en`; no measurement DB exists. Three scoped app updates and launches retained all prior packages/data. Recording/GPS starts, runner installs, fixture writes and physical/security actions were zero.

The requested two previously reviewed b7107be screenshots were uploaded successfully through supported Library upload and kept their original bytes. Their confirmed identities are in local `library-deliverables.json`: Demo `libfile_d6aeaaa4e44c8191ac5b294416fc53cd`; Stop/LIVE `libfile_5165fc562fc881919730984705ab73f3`. These identify the earlier b7107be screenshots, not the final clock fix.
