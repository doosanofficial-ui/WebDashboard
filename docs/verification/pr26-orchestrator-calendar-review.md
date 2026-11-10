# PR26 admission and Calendar history: orchestrator review

## Decision

**BLOCK full PR26 merge; SELECTIVE scheduler follow-up only after its remaining
contracts are specified.** No production code, acquisition setting, app version,
user data or security permission was changed by this review. PR priority was
handled before the Calendar sidecar; no new native GUI/Simulator/device run was
started.

Fixed comparison:

- main: `49c30e2f006b416290dbc9383522dd8bf0d29fe8`.
- PR26 head: `d0299145e3cd06f6c29f9824760d875acea49058`.
- PR26 base: `7a62642b1af9879b6052b6faa6e1ac403fdc5b43`.
- Source PR: <https://github.com/doosanofficial-ui/WebDashboard/pull/26>.
- Admission observation: Draft, MERGEABLE, UNSTABLE; layout in progress and Help
  groups queued. A pending matrix is not a failure or an all-green result.

## Delegation and parent reconciliation

Two independent read-only reviews were dispatched through the dedicated
spawn/close lifecycle. Neither received a writable worktree or report path.

| Reviewer | Model actually requested | Deliverable | Final state |
|---|---|---|---|
| Terra | gpt-6.1-terra | PR product-code risks and minimum safe subset | Nonempty final received, reconciled, closed |
| Luna | gpt-6-luna | Original Calendar/Simulator crash correlation | Nonempty final received, reconciled, closed |

The provider exposes no gpt-6.1-luna override; this limitation was disclosed.
Parent performed admission checks, the three-way merge experiment, original-log
checks, direct historical screenshot inspection and the bounded software tests.
Agent statuses alone were not used as completion evidence.

## PR findings

1. **Acquisition timing changes need their own admission gate.** The due-time
   planner removes cross-query sleeps and initially makes every configured slot
   due. This can increase aggregate command traffic relative to main's serial
   sleep loop. Each query also configures header/filter commands. Existing
   per-query intervals are not an adapter-wide or ECU-wide pacing contract.
   Do not assume a clone's sustained throughput from planner tests.
2. **A planner deadline is not transport preemption.** The original planner test
   `testSlowTireQueryDoesNotBlockNextSpeedSample` manipulates completed deadlines;
   it does not hold a real query open. The parent added an audit-only Mock
   transport probe: while the slow response is held for 80 ms, no fast request
   is written. That expectation passes and establishes the serialized boundary,
   not a latency guarantee or a vehicle failure.
3. **Do not treat preparation as mounted product features.** The candidate adds
   broad appearance/fuel/place/navigation/policy preparation beyond the narrow
   scheduler change. The PR itself keeps these unqualified. For example,
   RecordingTriggerPolicy.invalidate clears inactivity/armedAt while an existing
   recording state may remain; ownership/reconnect/disarm behavior needs its own
   specified tests before any live mounting. This is not a reproduced bug in
   the current main recorder.
4. **Preserve main's newer regression evidence.** Comparing the PR head tree
   directly with main makes recent UI assertions appear absent. The parent
   corrected the integration interpretation: a genuine three-way merge dry run
   has no conflict and retains the two latest main UI test files unchanged.
   Replacing main wholesale with the PR tree would be unsafe; ordinary merging
   does not inherently delete those assertions.

### Parent software verification

| Check | Result | Boundary |
|---|---|---|
| Three-way `git merge-tree --write-tree` | PASS, no conflict | Fixed main/head only; not product acceptance |
| Latest main UI files in merge tree | Byte-equivalent to main | UIClarityUITests and DashboardEditingUITests |
| PR OBDPollingScheduleTests | 9 passed | Deterministic planner; no adapter |
| PR OBDQuerySchedulerTests | 24 passed | Mock transport; no ECU/vehicle |
| Parent held-response probe | 1 passed | Explicitly confirms no fast-query preemption |

The audit snapshot was made with `git archive`, not a branch/worktree or a
canonical source rewrite. The parent probe initially rejected its invalid
pollInterval=5/timeout=2 fixture with invalidTiming. After setting timeout=5,
the intended transport experiment executed. That first failure is retained as
a test-fixture error, not attributed to the candidate.

### Minimum follow-up acceptance

- Keep the full PR Draft until its exact-head mandatory CI is complete.
- Isolate the scheduler/planner/tests from unrelated preparation features.
- Define initial burst, sustained aggregate pacing, per-query desired cadence
  and the non-preemptible slow/timeout boundary; never imply 10 Hz acquisition.
- Retain Stop/no-late-write, duplicate-slot, unsupported-bitmap refresh,
  fatal/nonfatal error and reconnect coverage.
- Obtain physical adapter-load/continuity evidence separately before treating
  new scheduling behavior as hardware-qualified. No such test was run here.

## Calendar / Simulator history

Six original retired reports with basenames
`MobileCal-2026-11-06-{032433,034706,065204,080719,083200,084142}.ips`
were inspected. All name MobileCal, parent launchd_sim, responsible
SimulatorTrampoline, EXC_CRASH/SIGKILL and FRONTBOARD termination 0x8badf00d.
Four are process-launch watchdog events; two are scene-create events. These
are Calendar application-process terminations inside Simulator, not evidence
of a Telemetry crash or a crash of the entire Simulator service.

Official interpretation: [Apple: Addressing watchdog terminations](https://developer.apple.com/documentation/xcode/addressing-watchdog-terminations).
That documentation establishes the watchdog signature and responsiveness
boundary, not the cause of this machine's individual stalls.

An older original timing analysis under the private October 11 diagnosis
folder binds `ui-help-runtime-d` to a specific Simulator coalition and a
30-second MobileCal process-launch watchdog. It records zero native cases
started/completed and FAILED_INFRASTRUCTURE_CRASH. It explicitly does not
establish dtuhidd/root cause or permission shortage.

Parent corrections to the sidecar interpretation:

- `runtime-guard-first-run.log` is a regression-test log, not a screenshot or
  proof that an actual popup was dismissed during that native run.
- The two historical popup PNGs show a **different October 11 incident**:
  the visible report says 17:33:21 +0900, MobileCal, scene-create watchdog and
  a 10-second allowance. Do not merge this with run-d's 19:42 incident.
- The November 6 events have not been joined to a same-incident Telemetry
  assertion/layout failure. Calendar causing the app defect remains UNPROVEN.

## Direct historical visual inspection

Both images were opened by the parent with view_image; they remain private in
the original local evidence directory because system/device identifiers are
visible. No new screen activation, capture, permission prompt or dismissal was
performed.

| Screen/state | Local evidence | Identity / observed pixels | Result |
|---|---|---|---|
| Expanded MobileCal Problem Reporter | mobilecal-runtime-diagnosis/current-mobilecal-popup-original-private.png | MobileCal unexpectedly terminated; Apple mobilecal identity, launchd_sim/SimulatorTrampoline and watchdog details visible | Historical popup verified only |
| Same historical popup, button-bounds follow-up | mobilecal-runtime-diagnosis/popup-button-bounds-followup/current-reporter-original-private.png | Same visible report content and Confirm control; separate image bytes retained | Historical popup verified only |

Capture source is the existing private October 11 evidence, not current main
or a current foreground runtime check. Source build shown in the popup is
MobileCal 1.0 (1), not Telemetry 0.22.4. Other UI/screens, current physical
device UI and current screen pixels remain UNVERIFIED in this task.

A new bounded metadata guard including MobileCal/Calendar/Korean Calendar,
SpringBoard and Telemetry found no matching on-screen error window. It returned
screenVerified=false. This does not prove normal app readiness or a fixed crash.
agent-desktop availability/permissions were checked according to its shipped
desktop/platform guides; no GUI action or privilege expansion was needed.

## Next discriminating observation, not blind retries

During the next separately authorized native run, retain exact run/Simulator
identity, start/end, original crash incident/time/coalition, XCTest counters and
the actual foreground screenshot. A matching popup pauses readiness for pixel
and original-log review. Do not erase Simulator data, kill Calendar, dismiss a
system prompt or increase a timeout merely to obtain green. Keep popup
obstruction, infrastructure watchdog, app assertion, CI budget and physical
runtime as separate gates.

## Preservation and scope

User-confirmed stopped numeric-editor work, its translation files/test, existing
RN changes and stash were preserved. Their hashes matched before/after this
review. No feature integration, release version increment, app package/upload,
Simulator/phone installation or vehicle connection occurred. Existing main
49c30e2 and PR d029914 were not replaced by historical baselines.
