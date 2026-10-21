# Help captures: current Demo source and isolated Simulator run

- Source base: `9f26130b171ee59cd2de061fe8cb70bc94a47c6c` on canonical main, plus the existing DemoAdapterController frame-format correction. Capture source inputs include its exact new hash; this is not a claim that the base commit alone contains the correction.
- Capture: 2026-10-21 15:15:46–15:19:05 UTC (2026-10-22 00:15:46–00:19:05 KST); existing iPhone 17, iOS 27.0/24A434, Xcode 27.0/27A266a; portrait/default large Dynamic Type; English and Korean.
- Simulator UUID: `DDD24F62-C420-4211-B607-D1B03EBF881B`; no device created. Isolated application `local.webdashboard.Telemetry.HelpCapture20261021`, runner `.UITests.xctrunner`; original product was not updated.
- Run ID: `7F4D39B6-6A81-47B9-ADED-B57851842B05`; source receipt SHA-256: `753c2549842c43b80fec76ada5fc67c5ee7a30edbb2c816c92b020f8e7e4264b`; final products SHA-256: `8312e16a56fc593a9df303ab6208b1d5f9b49c2585f5956eed786981b15c6959`.
- Prepared products were copied unchanged. Existing canonical prepare_run/test_command/finish_run and final verifier bound the actual xctestrun, app/runner/xctest digests, source 46-input inventory, capture-test hash and exported attachment bytes to this one execution.
- Automated: exactly two capture tests passed; no failure/skip/expected failure. Fresh original 28 PNGs and marker bytes were copied directly from this run. No verification criteria or test source changed.
- Local original xcresult/products/receipts are retained in `webdashboard-help-capture-execution-9f26130b-20261021-standard`. Its exact actual-command path remains in the local record; the bundled manifest omits that machine-specific absolute path only. Required provenance fields and digests are unchanged.

## Direct pixel review

Each of the following 28 original PNGs was opened individually using view_image by the executing agent on 2026-10-21T15:24:56.629405+00:00. Target controls were visible and legible; no error/permission dialogs appeared in these saved pixels. These images do not establish that the macOS Simulator window was frontmost.

| Capture | Target | Direct pixel finding |
| --- | --- | --- |
| [Help-editor-en-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-editor-en-1.png) | `resize-dashboard-widget-fixture-0` | Selected fixture card has cyan outline and wholly visible resize handle. |
| [Help-editor-en-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-editor-en-2.png) | `undo-dashboard-layout` | Undo/redo controls wholly visible in editor navigation bar; disabled with fresh empty history. |
| [Help-editor-ko-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-editor-ko-1.png) | `resize-dashboard-widget-fixture-0` | Selected fixture card has cyan outline and wholly visible resize handle. |
| [Help-editor-ko-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-editor-ko-2.png) | `undo-dashboard-layout` | Undo/redo controls wholly visible in editor navigation bar; disabled with fresh empty history. |
| [Help-live-en-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-en-1.png) | `toggle-recording` | REC/start-recording control fully visible; Recording off/기록 꺼짐 shown. |
| [Help-live-en-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-en-2.png) | `toggle-gps` | GPS control fully visible beside REC; GPS off/꺼짐 shown. |
| [Help-live-en-3](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-en-3.png) | `mark-event` | MARK flag control fully visible; no mark shown. |
| [Help-live-ko-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-ko-1.png) | `toggle-recording` | REC/start-recording control fully visible; Recording off/기록 꺼짐 shown. |
| [Help-live-ko-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-ko-2.png) | `toggle-gps` | GPS control fully visible beside REC; GPS off/꺼짐 shown. |
| [Help-live-ko-3](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-ko-3.png) | `mark-event` | MARK flag control fully visible; no mark shown. |
| [Help-replay-en-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-replay-en-1.png) | `session-replay-play` | Play control visible at 0.0 / 5.0 seconds; DEMO Replay and acquisition/recording off stated. |
| [Help-replay-en-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-replay-en-2.png) | `replay-time-slider` | Recorded-time slider, speed, start/end controls visible; 8 original rows stated. |
| [Help-replay-ko-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-replay-ko-1.png) | `session-replay-play` | Play control visible at 0.0 / 5.0 seconds; DEMO Replay and acquisition/recording off stated. |
| [Help-replay-ko-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-replay-ko-2.png) | `replay-time-slider` | Recorded-time slider, speed, start/end controls visible; 8 original rows stated. |
| [Help-sessions-en-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-en-1.png) | `saved-session-picker` | Saved-session selector displays dated synthetic DEMO session; GPS not collecting. |
| [Help-sessions-en-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-en-2.png) | `sessions-export-json` | JSON/CSV export controls visible; screen explicitly reports no export generated. Export was not performed. |
| [Help-sessions-en-3](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-en-3.png) | `replay-saved-session` | Open Replay control wholly visible beside Refresh for the saved synthetic session. |
| [Help-sessions-ko-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-ko-1.png) | `saved-session-picker` | Saved-session selector displays dated synthetic DEMO session; GPS not collecting. |
| [Help-sessions-ko-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-ko-2.png) | `sessions-export-json` | JSON/CSV export controls visible; screen explicitly reports no export generated. Export was not performed. |
| [Help-sessions-ko-3](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-ko-3.png) | `replay-saved-session` | Open Replay control wholly visible beside Refresh for the saved synthetic session. |
| [Help-setup-en-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-setup-en-1.png) | `import-adapter-profile` | JSON import button wholly visible; adapter profile not configured; system-settings control was not tapped. |
| [Help-setup-en-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-setup-en-2.png) | `start-live-adapter` | Developer/diagnostics expanded; live-adapter start control visible and disabled without a profile. |
| [Help-setup-ko-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-setup-ko-1.png) | `import-adapter-profile` | JSON import button wholly visible; adapter profile not configured; system-settings control was not tapped. |
| [Help-setup-ko-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-setup-ko-2.png) | `start-live-adapter` | Developer/diagnostics expanded; live-adapter start control visible and disabled without a profile. |
| [Help-signals-en-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-signals-en-1.png) | `raw-can-content` | Read-only replay diagnostic payload visible; recorded signal 53.0 percent and freshness unknown stated. |
| [Help-signals-en-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-signals-en-2.png) | `signals-stale-filter` | Stale-filter control visible; REPLAY/DEMO status distinguishes recorded values from live acquisition. |
| [Help-signals-ko-1](../../mobile-ios/App/Resources/HelpScreenshots/Help-signals-ko-1.png) | `raw-can-content` | Read-only replay diagnostic payload visible; recorded signal 53.0 percent and freshness unknown stated. |
| [Help-signals-ko-2](../../mobile-ios/App/Resources/HelpScreenshots/Help-signals-ko-2.png) | `signals-stale-filter` | Stale-filter control visible; REPLAY/DEMO status distinguishes recorded values from live acquisition. |

## Preservation and separate verification boundaries

- Original product: installed 67 files and the existing 10 data files, including Dashboard and preferences, retained byte-for-byte; original bundle/data container paths did not change.
- OS effect: one original-app SplashBoard snapshot was added (`F3E3BFFE-58C4-44B1-8F32-33CBFA58C790@3x.ktx`); total original data files became 11. No original file was changed or removed, and no snapshot was deleted to force a count of 10.
- Normal isolated test installation moved the isolated app/runner bundle paths and the isolated data container from `CB77CF2C-6FBD-4DC7-94DA-DF3812B949A1` to `FD624FC1-CFE2-4341-8A6A-B8CA6B0F3170`. The synthetic Dashboard, SQLite and SHM bytes and all six closed DEMO sessions/26 rows remained identical.
- Simulator catalog remained the same 68 devices; global test-tool defaults remained unset. No new credentials, persistent access, OS permission/security changes, physical-device transition or original-app reinstall occurred.
- Native Simulator screenshot during the test was separately opened and showed the synthetic Live fixture with recording/GPS off. Mac foreground/unobscured execution remains UNVERIFIED; the Mac permission window was untouched. Original-app PID/running-state retention was not newly verified.
- Only the two capture methods ran. They select a seeded DEMO session, open Replay, seek start/end, view recorded Signals, stop Replay and finish with recording/GPS off. They do not establish a new recording/save/relaunch/reopen/export-completion journey.
- New Help overlay rendering, guide navigation/reentry/language boundaries, zoom/full-image scroll, maximum text, landscape, physical-device, hardware BLE/GPS and CarPlay acceptance remain separate. Prior results are not expanded into new passes.
- Editor tool rows scroll horizontally and non-target content can extend behind navigation/tab glass; this review certifies the visible captured targets only. Fixture-specific English names in Korean screenshots are synthetic data.
- The failed UseDestinationArtifacts Simulator hypothesis and its zero-test result remain in the separate local noinstall evidence packet; the unsupported option was not retried.
- Parent/primary direct core-image review is a separate responsibility; this executing-agent record does not claim that review on the parent’s behalf.

## Integration boundary

This promotion replaces the 28 PNGs, their exact marker JSON and the manifest with this actual run. It does not change AppHelpView, the capture tests, validators or the original installed app. Full asset/native-contract and applicable Demo/Core/app-build validation are recorded separately before integration; this capture record alone is not an all-project/CI pass.

## Integration validation

- Unchanged full Help asset verifier passed against the actual promoted bytes and current 46-input provenance.
- Complete native contract suite: 394/394 passed, zero failures/errors/skips, no deferred tests. This closes the previously failing bundled-current-Help provenance item.
- Complete TelemetryCore XCTest suite: 271/271 passed, zero failures.
- Actual Demo producer regression: 301 callbacks reached all nine independent initial/carry/period expectations; 16 synthetic rows saved/reopened/replayed; ten synthetic sentinels unchanged. This is host evidence, not a new app recording UI pass.
- Coordinator source harness: 46 assertions; profile-import flow: 12 assertions; BLE selection flow: six assertions; all passed. Their documented substituted-boundary limits remain.
- Platform documentation parity and generic iOS Simulator application build with the new resources passed. Builds were isolated in an owned temporary workspace; no additional Simulator/UI execution occurred.
- Xcode copypng optimizes PNG containers into CgBI, so packaged PNG file hashes differ from raw capture bytes. All 28 normalized rendered pixel buffers match; all 29 marker/manifest JSON files match byte-for-byte. The source/raw capture hash contract was not changed.
- Independent read-only review found no critical/important code or provenance issue. A temporary suggestion that Korean Replay lacked its row count was withdrawn after original-resolution PNG and exported AX both showed `원본 8행`; the accurate original review wording is retained. No localization defect or product fix was introduced from that misreading.
- Remote synchronization and CI results are checked after the scoped commit; this record does not predeclare CI or deferred native UI/physical-device gates passed.

## Follow-up: bounded host liveness

The first synchronized commit's native-core CI passed all 271 Core tests but the new Demo harness failed its total 40-second wait. Matching Demo/Core hashes and a separate instrumented host run showed healthy monitoring and 297 callbacks in 40 seconds under an explicitly backgrounded, newly owned test process. A scoped latencyCritical-only experiment also failed and was not adopted. This does not prove the original GitHub process had the same scheduler policy.

The test incorrectly treated 300 relative minimum-100ms sleeps as a real-time throughput guarantee; [Swift's sleep contract](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/TaskSleep.swift) allows each suspension to take longer. No product requirement mandates 301 callbacks within 40 seconds. The harness now completes on at least 301 actual callbacks, uses a monotonic 40-second **no-progress** watchdog refreshed only by actual frames, and retains the driver's existing 150-second total build/run cap. This explicitly corrects the test's liveness model; no source-provenance, pixel, value, count or persistence expectation is reduced. Sequence 1 onward must now be consecutive as well. Callback/state timing diagnostics remain available for any later failure.

The same backgrounded host experiment passed with 301 consecutive callbacks in 44.4 seconds, all nine independent fixtures, 16 saved/reopened/replayed rows and ten unchanged synthetic sentinels; build/run completed in 61.4 seconds under the unchanged 150-second cap. Only test code changed; the production Demo/App source, capture source inventory and actual 28-image receipts remain unchanged. No activity flags, process-priority overrides of existing processes, global preferences or new Simulator actions were introduced. Full applicable gates are rechecked before synchronization.

Remote hosted-lifecycle and Replay UI results remain separate from these Help/callback assertions. In the first remote lifecycle run, one unchanged long-title presentation method failed two OCR assertions amid image-provider/PNG finalization errors. A valid but blank JPEG and a valid title-bearing PNG were both directly opened; not all output images were missing or corrupt. The test and card source are identical to the base commit and do not invoke Demo. That evidence does not establish a baseline reproduction or a complete product/UI pass.
