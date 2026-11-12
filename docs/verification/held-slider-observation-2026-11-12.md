# Held-slider playback observation: remove an unused diagnostic target

## Original failure and comparison

At `974df6c5d918f5b7148cd63e46a7e7328f67dfa6`, [Replay job 130856331630](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43118930515/job/130856331630) first failed `testPlayingLongSliderDragPreservesCapturedUserTarget` before attempting the held drag. The assertion required playback to advance 2.5 recorded seconds within the existing 10-second XCTest wait. The later 1200-second xcodebuild timeout was a separate failure: 10 tests selected, seven started, five passed, one failed and one interrupted; three never started.

The exact observation attachment reports:

- Baseline `2.9 / 600.0 seconds`, read cost 2.580775 seconds.
- One predicate value `4.9 / 600.0 seconds`, read cost 1.406406 seconds, below the required 5.4.
- Wait duration 10.527758 seconds, result `timedOut`, no omitted or unfinished recorded queries.
- The native result activity then spent 8.074 seconds “Capturing element debug description.” No second predicate read occurred.

The native summary records the assertion at 2026-11-11 23:49:06.452 UTC. The later text-log report is not the original assertion time. The preserved failure JPEG, timestamp 23:49:15.860 UTC, was directly opened by the implementation and independent reviewers. It shows Sessions, 13.4/600 seconds, Pause and 0.5×, with no popup. Playback progressed after the failed wait; this image does not establish when the threshold was crossed.

The [prior successful Replay job 130815235310](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43106642732/job/130815235310), at `79877247ae926eb24f98b8a4560a4a1f6df003ab`, used unchanged Replay/App sources, Xcode 27A266a, iOS runtime 24A434 and iPhone 17. Its baseline was 0.8, followed by 1.6, 2.6 and 4.1 against a 3.3 threshold. The wait completed in 6.193379 seconds. Both false predicates triggered element-debug capture, but those captures permitted later reads. Host load and several AX costs were higher in the failed run; load averages are not proof of causation or a playback defect.

## Evidence recovery

The interrupted xcresult lacks its normal Info.plist. Its original attachment bytes were recovered with the existing Xcode XCResultKit ZSTD decompressor. Native `xcresulttool get object --legacy --version 3 --id` independently decoded the test summary and confirmed the attachment references without a fabricated plist. Original archive and result data were not modified.

- Original archive SHA256: `31c9ac8efcc24e1db0c7861f0bec58efbdb9e779c438ed5676b47834f305cc74` (matches GitHub digest).
- Exact 752-byte `DEMO-held-slider-time-observation` JSON SHA256: `233f5dccf87269ce873d9605ff375385f8eae9ac461487d6f0638c183b56166b`.
- Failure image: `Screenshot_0_BBD9B660-9A2F-4CEF-AAA6-8592D3DF7C60.jpeg`, referenced by the original failure summary, not selected by filename guess.

## Minimal candidate and verification boundary

The predicate closure already reads its captured `position` and ignores the predicate object. Only that expectation's `object: position` becomes `object: nil`, avoiding the unnecessary XCUIElement diagnostic target. No App/Core logic, threshold, timeout, gesture, post-drag assertion, test selector, global CI budget or retry rule changes.

A host regression compiles the actual extracted wait caller and `HomeStateObservation` with deterministic XCTest/AX/clock doubles. It first fails with the old object and passes with nil under the measured diagnostic-cost model. Advancing and exact-threshold values pass; stalled, just-below-threshold and malformed values still fail. The original attachment fields and observed query count remain intact.

This model does not prove real XCTest scheduling, absence of future diagnostic snapshots, late-return semantics, baseline acquisition or actual held dragging. Independent read-only review found no semantic weakening. Fresh exact-SHA remote Simulator CI is required before calling the runtime failure repaired. No local Simulator boot, installation, launch, device control, permission-dialog interaction or Apple report submission occurred during this diagnosis.

Local verification passed 493/493 native contracts with zero failures, errors, skips or deferrals. The signed-disabled generic iOS Simulator build-for-testing passed without a boot/install/launch. The first confined build attempt failed during package resolution with `sandbox_apply: Operation not permitted`; the authorized ordinary build retained that receipt and completed successfully. Platform documentation and whitespace validation also passed. None of these checks replaces the pending remote UI result.
