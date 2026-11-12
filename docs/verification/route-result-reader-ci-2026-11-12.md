# Route CI: native success, result-reader failure

## Original failure remains failed

At `99342c7b8fc2f70385dfc27bafdcb35cbb042ffb`, [job 130939525568](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43144339439/job/130939525568) failed. This is separate from the same commit's successful ten-test Replay group.

[Artifact 13913715017](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43144339439/artifacts/13913715017) ZIP SHA256 is `2fa9398deec93346d4cdbb19f27e860e922d81a4451444b4fb704c7fc7d03700`, independently matched to downloaded bytes. All 50 seed source-input hashes match the commit. That receipt covers the seed inputs, not a separately hashed app binary.

- `testRecordedGPSRouteContainsOnlySelectedTimePrefix` passed in 345.595 seconds. Native XCTest reports one executed test and zero failures.
- `test-process.json` records xcodebuild exit 0, 417.016 seconds, no timeout, TERM or KILL. It finished at 03:36:10.115406 UTC.
- The first failure is `result-read`, observed at 03:37:13.517732 UTC. `xcresulttool get test-results summary` exceeded the original 60-second `check_output` deadline.
- Summary parsing, attachment export, counter validation and successful group-completion publication were not reached.
- The subsequent diagnostic worker also timed out. Simulator shutdown exceeded its 60-second limit; delete succeeded. The original reader failure remained primary.
- The failure screenshot was not captured because the diagnostic deadline had elapsed. No absence-of-dialog claim can be made about that failure boundary.

The same unchanged downloaded XCResult was read locally with a 60-second bound in 0.363 seconds. It returned Passed, one total/passed test, zero failed/skipped/expected failures. Original attachments exported in 0.315 seconds. This establishes readability after transfer, not the historical cause of CI's wait. Recovery does not change the failed job or substitute for its missing completion receipt.

The original reader's PID, launch/completion boundaries, output size and partial output were not retained. A still-running command and an exited leader whose descendant retained the capture pipe cannot be distinguished. Runner load averages and other timed-out operations are observations, not proof of host CPU saturation or a diagnosed platform fault.

## Direct visual review

The implementation reviewer directly opened all ten original PNG attachments from this one test. Environment: iPhone 17 Simulator, iOS 27.0/24A434, Xcode 27A266a, synthetic offline GPS fixture, English, normal Large and Accessibility XXXL text. The captures span 03:31:10.077–03:36:01.335 UTC.

Normal-size route captures:

- `D0D10FD7-9573-4BE3-8FF2-32D955562BFD.png`: end, two plotted points joined by a line; latest recorded fix unplottable.
- `75A84F47-0B6F-4437-8033-07187073D8A4.png`: backward to 2.5 seconds, one point and one recorded fix.
- `8DEE06A6-444D-45E2-B68C-7101BAF0FBD7.png`: start, zero fixes and no-plottable-fixes explanation.
- `278C1437-B191-448F-B7F9-58284FFA9E7F.png`: visible end status above the fixed replay controls.
- `EFCAB1C6-AA35-48B2-A67D-F8F130D14425.png`: Sessions text-size audit.

Maximum-size originals are `A66CD1F6-50E5-4491-9FB7-E2F366EF4184.png`, `8C5760FA-8E51-4CB6-8FF2-37F1517B04C4.png`, `ABCD05FC-086D-4B79-8330-1E51F759644C.png`, `07A2D11B-84F7-497D-87FC-99E1A619B9F5.png`, and `DE9FC4BB-E41C-4505-8F35-7288588A5133.png`. They show the corresponding two/one/zero-point states and readable end-status text after scrolling. The fixed replay controls remain visible. Long body text extends outside individual capture viewports, so these images do not establish every scroll position or whole-screen simultaneous fit. No dialog appears in these test captures; they precede the result-reader timeout.

No local Simulator boot, install, launch, foreground change or prompt interaction was performed for this review. These are not physical-device, real-route, live GPS or CarPlay results.

## Bounded reader hardening candidate

Only Replay's summary command is moved to the existing owned, file-backed phase mechanism. It now preserves `result-read-command.log` and `result-read-process.json`, refuses existing evidence, and requires confirmed disappearance of its owned process group before parsing bytes. Timeout and nonzero-exit exceptions propagate even if partial output contains passing counters. Existing exact-count, original-failure and final-completion checks remain.

The numeric command budget remains 60 seconds; lifecycle's 180-second constant is not reused. Timing semantics are intentionally different: the former communicate timeout started after Popen and waited for pipe EOF; the owned deadline starts before resource recording and launch, waits for the leader, then performs bounded inherited-process cleanup and a one-second group confirmation. Cleanup is additional to the command budget. This is reader hardening and better evidence, not behavior-identical instrumentation or a proven fix for the historical failure.

Seven actual-caller tests first failed against the original reader (nine assertion failures, zero errors), then passed with the candidate. They cover retained success/nonzero output, an inherited descendant, virtual completion beyond 60 seconds, uncertain cleanup, preserved evidence and malformed JSON. Main-level tests additionally verify that reader timeout/nonzero failure blocks public success and remains primary when workspace cleanup also fails. Existing integration fixtures were updated at their mocked native-command boundary; acceptance assertions were not removed. The complete native contract suite then passed 502/502 in 73.999 seconds, with zero failures, errors, skips or deferred cases; platform documentation validation also passed. An independent read-only review found no acceptance weakening.

A read of the unchanged downloaded route bundle through the candidate completed locally in 0.146 seconds with exit 0 and confirmed group disappearance. That is a result-reader check only. A new exact-commit CI trial remains required; no unchanged failed job was rerun or promoted. A fresh complete contract recheck passed 502/502 in 77.862 seconds, again with zero failures, errors, skips or deferred cases.

## Completed baseline CI

The original 99342c7 workflow finished without cancellation while this candidate was prepared. Smoke and Native Recording Lifecycle succeeded. Replay 10, Layout 12, numeric editing 2, basic Help 4, maximum-text English Help 1, and maximum-text Korean Help 1 completed successfully. The Korean Help test and App tree are unchanged from the prior timeout; this one successful execution does not diagnose or repair that earlier failure.

The separate iPhone SE viewport job failed independently: one test passed and the Status test rejected an initial hittability read that returned after its original five-second deadline. Native test execution exited 65 after 574.679 seconds, without a process timeout. The summary-reader candidate does not change that test, its deadline, or app behavior, and does not claim to resolve it. The original route job and aggregate remain failed.
