# First-failure observations for the existing CI runners — 2026-10-08

## Change and preserved predicates

Add optional evidence to the existing Hosted and offline UI runners after the original first failure. This is an observation change, not a fix or reclassification of the retained bootstatus/result-reader failures. Product sources, test selectors, Xcode/runtime selection, original logs and result bundles are unchanged.

The UI waiter records its first failed completion observation and an in-process resource sample; main records when it receives that failure before requesting the existing owned-group stop. A returned child status and the post-stop status remain separate. Kernel exit time is explicitly unknown. Existing phase deadlines and the condition requiring completion to be observed within the original deadline remain intact. The new group-cleanup option defaults off; only the optional diagnostic worker enables it.

Hosted calls remain the same `output`/`subprocess.run` operations with their original kwargs: boot60, bootstatus180, xcodebuild900, summary60, shutdown/delete60 seconds. Shutdown's unchecked nonzero policy and delete's checked policy are preserved. Thin optional receipts record caller-boundary duration and known returned child code. A subprocess timeout does not reveal a kernel exit timestamp; log-output/cleanup time is not attributed to the summary reader. The original exception object still propagates after shutdown, delete and private-workspace cleanup.

## Bounded first-failure evidence

`first-failure-observation.json` is created exclusively once and retains the original failure, phase, created Simulator UUID if known, failure-observation time, caller-received time, resource-sample time and sanitized pre-phase selected Xcode evidence. A later cleanup failure cannot overwrite it. Missing/malformed phase receipts use a guarded fallback. Observation/snapshot/write/worker errors cannot replace the original result or skip owned cleanup. A cleanup-only error is observed before subsequent cleanup but external diagnosis waits until both shutdown and delete have been attempted.

Only on GitHub CI, one newly owned diagnostic worker receives an additional **20-second phase budget**. Its probes share the worker deadline and each receives at most3seconds: neutral Python launch, state of the created UUID, numeric memory-page counters, allowlisted simulator-service presence counts, selected xcresulttool system path, and bounded numeric iostat rows. A noisy probe is stopped after2MiB+1byte has been read; raw stdout, process arguments/environment, other devices/names and exception text are not persisted by this new observer. Probe children inherit the worker's newly owned process group.

The worker's normal exit also requests owned-group cleanup, covering a child that exits while leaving a descendant. Final group absence is claimed only when an actual `killpg(owned_pid,0)` probe returns ProcessLookupError; signal attempts or leader reaping alone are insufficient. Group present, denied probe or missing receipt stays unresolved/unknown and cannot make diagnostic status successful. Diagnostic status never changes the original verification result.

20seconds is the extra phase budget, **not a hard total wall-time guarantee**. Existing stop/reap grace, observation overhead or delayed process launch/scheduling can add elapsed time; requested/returned launch and final worker receipts preserve those intervals. Probe process creation cannot itself be given a guaranteed kernel deadline. Host resources are guest/runner observations: load is not CPU utilization, service presence is not service health or physical measurement activity, and the first iostat report may be cumulative since boot. They do not identify a physical-host cause.

The existing2MiB initial boot stream and its artifacts are unchanged. Failure-time diagnosis was chosen instead of rotating/replacing that original stream. Pre-phase Xcode default/DEVELOPER_DIR selection and diagnosis-time tool resolution are separately labeled; unavailable or non-system paths remain unknown.

## Regression evidence

- Original checkpoint RED:11missing-observation failures and1existing successful-path pass.
- Additional genuine RED: resource-snapshot failure blocking the operation; malformed phase receipt losing the first observation; normal worker exit leaving an inherited TERM-ignoring descendant without cleanup.
- Final full Python runner contracts: **127PASS** (existing108 plus19new observation regressions), both normal and GitHub-CI environment fixtures.
- Regressions cover original timely success/nonzero/timeout predicates and exception identity; Hosted kwargs and summary60; first-failure immutability/one diagnostic budget; resource/write/observer faults; owned late spawn/timeout/TERM-ignoring descendant/normal leader exit; overflow stop/reap; unrelated UUID/private-field exclusion; and original shutdown/delete/workspace/collector cleanup.
- Tests execute only newly owned Python fixtures or replace native command boundaries. No local Xcode/Simulator/physical-device operation is acceptance evidence for this change.
- `python3 scripts/validate_platform_docs.py` and `git diff --check` pass.
- Read-only independent review found the normal diagnostic leader-exit descendant gap; its RED regression and diagnostic-only cleanup option resolve that finding.

Prior raw evidence remains preserved. This report is pre-push validation; the new commit's first CI attempt must be recorded separately. No previous failed workflow is rerun, no system/security setting is changed, and no physical installation is performed.

## Service executable allowlist follow-up

The selected local Xcode's CoreSimulator framework XPC Info.plist identifies the executable as `com.apple.CoreSimulator.CoreSimulatorService`. The initial bare-name allowlist omitted this real basename. A genuine RED fixture now reproduces that omission; the observer maps this one exact executable name to the existing CoreSimulatorService count, still retaining no path/arguments or unrelated process data. The comm-only ps probe requests full width so long executable paths do not truncate the basename; it does not request arguments. Full CI-environment runner contracts after this bounded correction: **128/128PASS**. The first pushed commit's127-test CI remains separate evidence; it is allowed to finish before the correction is pushed.

## First observed remote failure (ae338e0, attempt1)

[Layout job113152205579](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/37728485087/job/113152205579) failed before UI execution: the original bootstatus180-second timeout remains the job failure. The waiter observed failure at phase180.259s; resource sample was6.435s later and main received it11.019s later. The resource sample reports guest3CPU and load432.23/210.46/93.45, not CPU utilization or physical-host identity. These intervals include observation/scheduling and cannot isolate pure function time or a root cause.

Pre-phase Xcode was27.0/27A266a. Child status before stop and kernel exit time are unknown; after the original stop the child returned-15. One optional diagnostic worker also timed out with its original20-second phase budget, actual phase25.266s including stop/recording costs. Its direct child returned-15 and the final owned-group probe confirmed absence. No probe record was produced: service and additional memory/disk observations remain unknown, not absent. The original shutdown60-second failure still led to a successful delete45.796s; the first boot failure was not overwritten or converted to success. Original initial boot stream and all downloaded logs/ZIPs were retained with hashes.

On the same SHA, Hosted89 passed; its separately observed summary reader took3.635s under the unchanged60-second budget. This distinguishes the successful reader from the failing bootstrap without establishing why the runner slowed. Final workflow/shard counts and the corrected commit's first CI are recorded in the task evidence separately.

The initial SE and maximum-English-text shard failures likewise retained bootstatus180 timeout. Their diagnostic worker elapsed times were24.808s and20.833s respectively, with final owned-group absence confirmed. SE and maximum-English-text Simulator shutdown/delete succeeded. For English, the worker-entry observation was15.130s after diagnosis was requested; the neutral child completed in1.912s and the owned UUID read timed out in2.984s using the remaining2.947s probe budget. Missing service/memory/disk probes remain unknown. No physical-host identity or kernel exit timestamp was inferred.
