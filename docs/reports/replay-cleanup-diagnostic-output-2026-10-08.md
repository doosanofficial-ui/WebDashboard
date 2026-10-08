# Replay cleanup: protect owned delete from diagnostic output failure

When recording aggregate cleanup evidence fails, the Replay runner marks cleanup unsuccessful and prints an optional warning. A broken or closed stderr can raise from that warning before the loop reaches delete. The warning is now protected, so both commands for the run's created UUID are attempted while the original failure and unsuccessful cleanup result remain intact.

The change is limited to `scripts/verify_offline_replay.py`, its synthetic regression tests and this report. No product UI, app lifecycle, fixture, workflow, timeout, authentication, provisioning or device installation changes are included.

## Failure classification at 047d6af

Original [Native Reliability attempt 1](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/37718352093), source `047d6afcd0caa32ca9bd722f4964bd8850d22d34`, remains preserved.

| Observed failure | Boundary | Evidence and unresolved cause |
| --- | --- | --- |
| Selected-card test | XCTest app lifecycle control, before product assertions | First launch and Live capture completed. `openEditor` line9 calls `app.launch` a second time; termination of pid14026 failed. Layout executed14:13PASS/1FAIL/0SKIP. Termination cause and the effect of removing the duplicate launch remain unproved. |
| Replay bootstrap | Runner invokes CoreSimulator before XCTest | `bootstatus`180s timed out; observed phase189.052s. Shutdown and delete each60s timed out. Ten tests never started. |
| SE bootstrap | Runner invokes CoreSimulator before XCTest | `bootstatus`180s timed out; observed phase192.939s. Shutdown and delete each60s timed out. Two tests never started. |
| Korean maximum-text bootstrap | Runner invokes CoreSimulator before XCTest | `bootstatus`180s timed out; observed phase182.981s. Shutdown60s timed out; delete returned0. One test never started. |

The observed elapsed phase can include post-timeout stopping and diagnostics; it is not a changed command budget. All three original CI tracebacks retain the primary `bootstatus` `TimeoutExpired`. Their cleanup receipts show both shutdown and delete attempted. High host load, process-observation timeouts and delayed process launch are observations, not proof of the CoreSimulator failure cause.

The prior Hosted defect skipped delete when shutdown raised. Its corrected finally block attempts each operation, retains the first cleanup error and protects warning output. The current Replay CI failures already attempted delete and are different from that prior skip. The new regression covers Replay's separate unprotected warning path; it does not reproduce or solve the original remote bootstrap, shutdown or app-termination failures. Hosted89/89 success on iPhone11 is not a matched reproduction of the failing iPhone17/SE runs.

## Focused RED/GREEN

The two new tests inject a180s primary boot timeout, a60s shutdown timeout, an aggregate receipt `OSError`, and respectively stderr `BrokenPipeError` or closed-stream `ValueError`. Device commands are mocked; no actual Simulator or XCTest runs.

- RED: both tests fail because owned delete is skipped. The original boot exception object and collector-finalization call are already retained.
- GREEN: both cases attempt owned delete, preserve that same boot exception and finalize the collector. Aggregate recording failure still marks cleanup unsuccessful; optional warning loss cannot create a successful gate.
- Focused cleanup suite:7/7PASS. Full Python runner contract suite:108/108PASS. Platform documentation validator:PASS.

Shutdown/delete budgets remain60s, bootstatus180s, app build600s and UI tests1200s. No old workflow is rerun and no timeout is increased. Exact-SHA automatic push CI is checked after normal integration; these local results do not preemptively claim remote success.

## Direct visual inspection

The primary agent opened the actual first-launch screenshot from the preserved047d6af selected-card test: [Live idle capture](/Users/doosansmacbookpro/Documents/Codex/2026-10-02/task-3/ci-runner-boundaries-20261008/selected-card-047-attachments/1FEC6549-C388-42B5-A3E1-6DC5AAA8A35C.png).

Capture provenance: iPhone17 Simulator, iOS27.0(24A434), Xcode27.0(27A266a), English app, default text size, portrait1206x2622 pixels. Device UUID `74E8779D-BF8F-497D-833D-9D1198690DB1`; attachment timestamp1791427344.255. The exporter read a separate analysis copy and original bundle bytes were verified unchanged.

The Live screen, whole Edit control and synthetic no-sample cards are visible; no observed obstruction of Edit or top navigation. This is presentation before the second launch. No editor configuration assertion was reached, no new candidate UI was captured, and the screenshot proves no vehicle/GPS acquisition. Parent screenshot review remains NOT REVIEWED. Earlier SE visual evidence is preserved separately.

## Preservation and remaining limits

User44 files, earlier source/evidence, other Simulator states and Teams services are preserved. No keystore bytes or hidden session/authentication stores are read. Physical-device installation remains paused.

Remaining failures require evidence about CoreSimulator bootstrap/cleanup and XCTest app termination. Original landscape/resize gesture causes and remote native AX retry causes also remain unproved, even though the original three selectors passed in the047d6af iPhone17 shard. Automated tests, directly inspected pixels and physical-device acceptance remain separate.
