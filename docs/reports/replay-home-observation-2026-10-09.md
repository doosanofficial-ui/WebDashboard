# Replay Home observation and bootstatus evidence

The failed e27155c recording shows a visible transition from native Save to SpringBoard. The later XCTest state attachment contains `4` (runningForeground). These observations are not simultaneous, so they do not establish continuous foreground retention, a stale XCTest response, or a product defect.

The change adds observations only to the Simulator UITest. It preserves the original Home press, the OR's separate state reads and short circuit, the five-second expectation, and its assertion. It does not change the installed physical app, product lifecycle handling, runner deadlines, or native cleanup.

## Original failure and direct visual review

- Source: `e27155c208f66b653c2099e13fdf963e24e22a24`, Native Reliability run [37924141340](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/37924141340), Replay artifact `11613458658`.
- Case: `testNativeExportBackgroundReturnCancelAndReentry`, failed at the background expectation. Activation/cancel/reentry after that assertion did not execute.
- xcresult Home activity: 2026-10-09 11:41:04.014–04.562 UTC. State attachment: 11:41:09.569 UTC, `state after Home: 4`.
- Original movie SHA256: `f0712e020011840b5dc84ef2731d2603ea9e75f9de60f4aa801e25bca55fd943`. Its attachment timestamp is 11:39:11.946 UTC.
- Existing failure movie was decoded locally using Mac AVFoundation. It was not uploaded. The original archive and extracted files remain preserved.

Both the primary and independent read-only reviewer directly opened the three frames below on 2026-10-09. Capture: synthetic iPhone 17 Simulator, iOS 27.0, portrait, 1206×2622, native Save in English. Review scope is the visible foreground screen at each frame, not the whole product UI.

| Frame | Actual media PTS | Direct pixel observation | SHA256 |
| --- | ---: | --- | --- |
| frame-112.png | 111.428333 s | Native Save; On My iPhone, Save, empty folder | `47f664b978bde344b8e4ba1c5799c232f5f463d69a2a697384e8cdcb6654f2c8` |
| frame-113.5.png | 113.495000 s | SpringBoard; Telemetry icon visible | `8bb9cbc29d4087fbc5bca6cb6c537dead11e83fde3eed7dc111a9d2290eb4c3a` |
| frame-115.png | 114.096667 s | Same SpringBoard page | `9f5c24d0fd0582c8d08a4127ca5cb244cc7f49d10385ac30c9dd6549eb7e6d5b` |

File names are requested decode times, not actual sample times. Mapping PTS to UTC by adding the attachment timestamp is an estimate; under that estimate, the last inspected sample precedes the state attachment by about 3.526 seconds. The recording does not justify a claim that SpringBoard remained visible throughout all five seconds. The following test's 31-row dismissal audit is excluded: this failed case did not enable that audit.

## One discrimination goal and minimal instrumentation

Goal: distinguish completed state-query timing/values from the visible Home transition, without weakening the original lifecycle verdict.

`HomeStateObservation` records four monotonic call boundaries and at most 64 recent state-query rows. A query's start is recorded before the original read; an unreturned query has null return time/value in an available snapshot. Completed reads preserve their exact value. Evicted rows are counted. The helper releases its lock before executing the read and performs no native process probe or file write.

The existing post-wait state attachment remains. The trace is attached before optional failure screen capture. A failed wait adds an independent `XCUIScreen.main` screenshot under a named xcresult activity; it does not activate the app. Its capture is after the verdict and can itself be delayed. The unchanged assertion-message read happens later and is outside the trace.

Limits: the trace is in memory until attached. A blocked predicate or existing post-wait state read can prevent attachment; absence does not prove absence of reads. Timing measures XCTest calls, not OS transition time or notification delivery. The new failure-screen branch compiled in the native test, but this passing execution did not exercise that branch.

## TDD and one native execution

- Initial regression failed because the observation helper was missing. A second RED run exposed omission of a pending read. Both subsequently passed using the actual Swift/Foundation helper.
- The regression verifies pending nulls, injected-clock read duration, exact returned states, original OR 1/2/2 reads and true/true/false results, and all 72 reads despite retaining only 64 rows with eight omissions. Fixture raw values match the SDK: suspended=2, background=3, foreground=4.
- Full script suite: **196 passed in 20.638 s** on the permitted Mac context. The earlier sandbox run had one `PermissionError` in the unchanged `test_seed_phase` final `killpg`; the same suite passed with appropriate process permissions. Documentation check, diff check, Swift syntax parse, and independent source review passed.
- Teams handed over resources at 13:04 UTC. Protected server PID 44537 and tunnel PID 8391 were confirmed before native work.
- Candidate identity: base e27155c plus the two recorded UITest source hashes; product App/Core and Seed inputs were unchanged. The already qualified e27155c Seed manifest digest matched its original producer log. Xcode 27.0/27A266a, iOS Simulator SDK 27.0, runtime 27.0/24A434.
- One focused `testNativeExportBackgroundReturnCancelAndReentry` execution: **1 passed, 0 failed/skipped**, 50.208 s; xcodebuild exit0. No retry or expectation relaxation.
- Real trace: Home call 0.474875 s; original wait 1.017819 s. First predicate read returned background `3` in 0.000268 s, so the OR's right read was skipped. The original post-wait attachment also returned `3`; omitted rows0.
- Native return-to-CSV screenshot was directly opened: Korean native Save with Save/back/search and CSV filename visible, portrait1206×2622. Screenshot SHA256 `e7793eb15093a70e96cbc12735a73f3750ee97d630a889152d9429ec2476d0ee`. Its lower filename is truncated by the native picker; no product layout change is claimed.
- Shutdown/delete succeeded for the created UUID only. All six owned phase groups were absent, all completion waiters stopped, the created Simulator was removed, and both protected PIDs remained. Native resource window released at 13:13:42 UTC.

This execution validates the instrumentation and unchanged happy path. It does not reproduce or resolve the earlier CI failure. Physical-device UI, vehicle acquisition, and whole-product visual acceptance were not re-run. Parent core-image review remains a separate handoff requirement.

## Bootstatus last observable stage and next observation

| e271 artifact | Phase start UTC | First timeout observation UTC | stdout | Client launch returned |
| --- | --- | --- | ---: | ---: |
| Layout11614781247 | 11:57:52.193014 | 12:00:53.257015 | 0 bytes | 5.811017 s |
| Route11614527004 | 11:52:45.988538 | 11:55:46.252613 | 0 bytes | 12.610744 s |

Both retain the original 180-second timeout. Their last bootstatus stdout stage is **unobserved**, because stdout is empty. The UUID-scoped renderer callbacks precede bootstatus launch: Layout11:57:37.577357, Route11:52:39.529229. Later retained service records include device-identity/activation errors; none identify the bootstatus client's awaited readiness condition. Subscriber readiness is unknown; head/tail retention evicted 5295/5770 events. Renderer callback, a later Home screenshot, and later Booted state cannot substitute for the client's stage.

One missing observation: **before the original deadline, the exact owned bootstatus client's executable and contemporaneous waiting stack**. This would distinguish launch/loader execution from client IPC/readiness waiting; it would not by itself prove a remote service's root cause.

The next safe implementation must supervise a single bounded sampler as a child of an owned launcher, with PID/start-identity and UUID/phase binding, and a retained payload budget. The current collector is a thread whose log child owns a separate group: launching a sampler from that thread does not put it in the log child's group. A native sample added to main progress/completion/TERM, an unmanaged sampler group, or a waitpid lock held during sampling would risk reintroducing the delay e27155c removed.

Before enabling that probe, regressions must hold sampler launch/exit and prove timely phase completion and original180s Timeout/TERM remain independent, late launch is reaped on stop, foreign/reused PID is rejected, and failures remain unknown within the existing2MiB budget. No additional boot probe, timeout increase, broad service dump, or same-CI retry was added in this Home observation change.
