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
