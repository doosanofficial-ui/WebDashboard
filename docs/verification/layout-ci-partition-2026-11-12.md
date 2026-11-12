# Bounded layout CI partition

## Observed failure

At source `d7f81d34b89e616d07cc64ec304d927c3f42f2e4`, the [layout job](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43045084687/job/130608522196) reached its existing 1800-second xcodebuild command deadline. [Original artifact](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43045084687/artifacts/13874070294).

The retained test log contains 14 case starts, 13 successful case endings, no logged assertion failures, and an incomplete final `testSyntheticDemoNeverClaimsLiveVehicleAcquisition`. The last case was still producing progress when the command was terminated. The incomplete xcresult has no Info.plist, so its summary and image exports cannot be treated as complete evidence. No product defect or selector failure was established from this run.

Two successful cases contain the numeric-input recovery flows added to the existing UI tests: selected-card configuration (XCTest-reported 579.353 seconds) and small-viewport editor reachability (384.967 seconds). Those reported durations explain why a scheduling partition is reasonable, but are not a guaranteed future runtime or a reconstruction of total command wall time.

## Minimal scheduling change

- Move those two unchanged tests to `layout-numeric`; the other 12 remain in `layout`.
- Both groups retain the existing 1800-second test-command limit. No timeout, retry policy, assertion, skip allowance or success criterion was relaxed.
- All seven groups remain serial (`max-parallel: 1`, `fail-fast: false`) and consume the exact-current-SHA Seed. The existing per-layout workflow allocation applies to each layout shard.
- The complete aggregate still requires exactly 31 unique tests, now across seven disjoint groups. It requires the new artifact and rejects a missing, skipped, duplicate, mismatched, timed-out or failed group.
- The selected workflow still covers the same 21 unique tests; help-only still selects four. SE still independently repeats its original two tests and does not add to the 31-test aggregate.
- App, Core, UI test bodies, Help capture sources and bundled resources are unchanged by this partition.

## Verification boundary

The partition regression first failed in four expected places against the old six-group configuration. After the change, the focused group contracts passed 12/12, runner-budget handoff contracts 8/8 and SE contracts 3/3. These are host-side contracts with native boundaries replaced, not real XCTest results. Independent read-only review found no blocking omission or weakened failure gate.

The complete host-side native-contract suite passed 491/491 with zero failures, errors or skips and nothing deferred. Platform documentation and whitespace checks passed. Exact-SHA CI results remain pending. Real shard runtime, completion of the previously interrupted final case, XCTest summaries and direct screenshot review remain required. Prior individual successes do not imply that the new aggregate has passed. No local Simulator was created, booted or controlled for this change, and existing system popups were left untouched.

## Exact-SHA partition result

At `974df6c5d918f5b7148cd63e46a7e7328f67dfa6`, the [12-case Layout group](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43118930515/job/130856331622) and [two-case Numeric group](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43118930515/job/130856331634) both passed, with zero failures/skips. Numeric test durations were 737.454 and 384.615 seconds; its xcodebuild process finished in 1184.902 seconds, below the unchanged 1800-second deadline, with exit 0 and no timeout or termination.

Numeric [artifact 13905961410](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43118930515/artifacts/13905961410) ZIP SHA256 `42fdac6c70838f9fb2c6b43fdb643b9cbb2c459e748e22d65e6ed896e7d653d0` matches GitHub. An independent reviewer directly inspected all 29 PNGs; the implementation reviewer directly opened these five core originals:

- `913B0CE9-EDD6-4906-B576-A2C538DD0E61.png`: English invalid numeric feedback.
- `95D9FD0B-4ABE-403D-9A30-879C3D70ABB8.png`: Korean maximum-text landscape corrected flow, Apply visible.
- `25F4E6C7-6044-4E52-97D4-548551D362FD.png`: English maximum-text portrait persisted minimum 12.5.
- `6AD26B2D-4274-4301-A758-CDA9DF5EB4BA.png`: restored minimum 0.0.
- `DF862324-98C9-4F5D-9942-A2F738DA357D.png`: Live maximum-text Edit label still wraps “Edi”/“t”.

Captures span 2026-11-12 00:52–01:10 UTC on iPhone 17/iOS 27.0 Simulator (24A434), not an SE or physical device despite legacy attachment names. Numeric labels/values are readable across scrolling, and invalid input recovery/persistence/restoration were exercised. Keyboard-raised state is not pictured; keyboard-Done log entries cannot certify its visual layout. The editor title and name/signal fields truncate at maximum text, and Apply is partly/below the viewport in some invalid-feedback captures. Two “Invalid frame dimension (negative or non-finite)” runtime warnings remain, with cause not established. This is targeted recovery/partition evidence, not whole-UI polish or full-suite success; the separate Replay failure remains.

The two numeric runtime warnings correlate with the first minimum-field focus in each test, before invalid text is entered. They have `<unknown>:0`, no source URL and no stack trace. The maximum-text case omits the editor canvas yet also warns, so attributing the warnings to canvas geometry alone is unsupported. Exact cause needs a bounded focus-transition reproduction with runtime-warning stack evidence; the existing logs do not identify a frame expression.
