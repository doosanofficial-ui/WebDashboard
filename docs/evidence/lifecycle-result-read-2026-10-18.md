# Lifecycle result-summary extraction diagnosis

Original source: 910fbf1bb16573d14359d52859de2551ef0872b7. Native Recording Lifecycle run 39111415413, job 117628171008, artifact 12130458881. Original artifact SHA-256: a712013d515bb4daacc20f91d23fa99a3b4ac48ac96a2bc6124436fc84ee83f3.

The owned iOS 27 Simulator completed bootstatus in 70.63 seconds. Xcodebuild returned 0 after 92 tests with zero failures. The subsequent `xcrun xcresulttool get test-results summary` call exceeded its original 60-second limit without recorded output. The original CI failure is result-read, not boot or an XCTest assertion failure.

The same original command read a private copy of the saved result in 0.154 seconds on local Xcode 27.0/27A266a and returned 92 passed, zero failed/skipped. The canonical reader with explicit process/output evidence also returned 92/92 in 0.157 seconds under the same 60-second limit. The original 345 files and download ZIP were preserved. No XCTest, App or Simulator was rerun for these reads; the original failed CI outcome remains failed.

The CI recorded load averages 368.9/242.8/116.5 at reader entry and 505.7/303.0/147.4 at failure on a 3-CPU runner. A later neutral command completed in 0.061 seconds and an owned-device query in1.37 seconds, while a service-process query timed out. Load is not CPU utilization or proof of a host cause. The actual reader launch/exit boundary was not measured. Transient tool, store or runner contention remains unproven; the saved bundle is not deterministically unreadable.

## Minimal verification change

The reader keeps the same command,60-second limit, original caller/output-length observation and strict JSON/92-test gate. It uses the already tested owned-phase runner to retain `result-read-command.log` and `result-read-process.json`, and to clean its own process group. No retry, log-count substitution or alternate success verdict is added. Existing evidence paths are rejected before launching. Nonzero exit, timeout and malformed JSON still fail even when log text or partial output looks green.

The Lifecycle boot calls and their original 180-second limit remain unchanged. The two existing synthetic caller fixtures replace the new native reader boundary; all their original assertions are unchanged. The deferred Lifecycle midpoint observer remains deferred. This change improves containment and diagnosis; it does not establish or claim a fix for the original timeout cause.

## Separate bootstrap comparison

The manual-only iOS 27 comparison creates one new owned UUID in each arm. Separate mode keeps boot 60 followed by bootstatus 180; combined mode uses `bootstatus -b -d` with 180 seconds. Both arms use migration verbosity, the same event collector and original owned shutdown/delete policy, and therefore exclude the production len5-only midpoint query. Fresh runner/load differences remain confounders. The experiment installs or launches no App and executes zero UI tests.

The existing 910fbf1 UI31/SE2 run must remain intact. Diagnostic commits use the documented push-only skip instruction to avoid duplicate full UI/Lifecycle execution, then explicitly dispatch only the comparison workflow. These commits are not represented as having passed a new full UI CI run. Source: https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs

App, capture-test and model inputs, user 45 changes, historical evidence and existing Simulator data are unchanged. No Astra review, model/account/security setting change, extra security grant or foreground UI interaction is part of this diagnosis.
