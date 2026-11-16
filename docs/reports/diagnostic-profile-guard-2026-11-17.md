# Diagnostic Profile Mutation Guard

## Reproduced Behavior And Fix

Two previously pending hosted tests were actually executed against main `cb0a7eff7e784f3d8cf310518d7a7a07a3d640b8`. They failed with eight assertions: while the synthetic diagnostic acquiring flag was true, both production mutation entry points returned true and changed the published profile, timeout dictionary and persisted bytes.

`importAdapterProfile` and `replaceAdapterProfileSignals` now share a synchronous MainActor admission check before decoding/construction, atomic IO or publication. Active diagnostic acquisition rejects the change with a localized status. Once stopped, a valid update still succeeds. The guard does not change query commands, transport ownership, decoder math, CAN/GPS timestamps or recording behavior. Other acquisition-mode editing policies are not newly qualified by these tests.

The original two tests now also verify post-stop retry, timeout application and decoded persisted signal readback. The previously pending rate/controller regression and all 96 declarations were compiled and executed, not merely counted.

## Actual Verification

| Gate | Result | Evidence Scope |
| --- | --- | --- |
| Before-fix profile guards | FAIL 2 tests / 8 assertions | Real hosted Model APIs, synthetic acquiring state |
| Fixed focused guards | PASS 2/2 | Rejection preserves profile/timeouts/file; stop then retry succeeds |
| Final complete hosted suite | PASS 96/96 | Actual result JSON:0 failed,0 skipped,0 expected failures; 2026-11-17 01:50:41 KST |
| Hosted-runner contract tests | PASS 32/32 | Expected count and partial/failure/cleanup reporting |
| Combined production replay-rate UI | PASS 1/1 | 134.914s; 01:58:21 KST; profile guard and prior rate fix together |
| Core package and rate evidence verifier | PASS 474/474 and9/9 | Same unchanged Core tree; separate fresh executions recorded in REP-02 report |
| Independent static reviews | No actionable findings | Two explicit gpt-6.1-sol reviewers, Standards/Spec, fresh read-only context; final results reconciled and agents closed |
| Physical device / vehicle / CarPlay | NOT TESTED | No promotion from hosted or Simulator evidence |

App 0.22.5(21) remains a development build, not a new packaged release. Test source hashes and inspected synthetic screenshots are in [capture.json](../evidence/profile-guard-2026-11-17/capture.json). Raw result bundles and private diagnostic receipts are retained locally.

## Corrected Verification Conditions

Initial optimized manual invocations were not equivalent to the repository runner and were rejected as qualification:

- Without the existing export-audit source transform/compilation condition, only93 of96 declared cases ran. The missing three were conditional export-audit tests. No96-case success is inferred from those runs.
- A Korean-started host rendered valid zero as `유효`; English OCR expectations failed even though pixels showed the correct value/quality. `-testLanguage en` alone did not give the prepared host the explicit app override. The test-only lifecycle scheme now passes `--app-language`, `en`; actual generated scheme XML and runfile arguments were checked. Normal production/system language behavior was not changed.
- In a wrapped graph count, Vision's full-image reading order interleaved the trailing time range between `Recorded samples:` and visible `2`. The existing assertion now recognizes the leading count column separately while retaining the exact count, full footer and following-card checks. No font, count value or production layout was changed to obtain green.
- The final run matches the repository's staged export fixture and compilation condition, explicit host arguments and actual96-case summary. Skips and missing cases remain failures in the verifier.

XcodeGen documents test-action [command-line arguments](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#common-build-action-options). The installed `xcodebuild.xctestrun(5)` manual identifies `CommandLineArguments` as test-host arguments. Generated arguments, not an assumed UI setting, were verified.

## Separate Calendar Event

A new MobileCal problem report appeared during the cold host setup. Its window pixels and original crash were correlated: background `com.apple.mobilecal`, FRONTBOARD `0x8BADF00D`, 30-second process-launch watchdog, coalition matching only the newly owned Simulator. This was not a Telemetry exception or the earlier helper SIGTERM. The two profile assertions actually executed after that event and exposed the independent Model bug.

No system app/framework was removed or renamed. The dialog was not approved/dismissed, no security/permission setting changed, and no other task's process was terminated. Subsequent tests used the same owned hydrated device; no new MobileCal report appeared during the warm sequence. Private crash keys and broad desktop inventory were not added to the repository.

## Remaining Gates

This is synthetic software qualification, not actual BLE/ELM/vehicle acquisition. Required physical evidence, background/endurance, real recording/export/replay, app registration and CarPlay approval/head-unit gates remain separate. The full feature denominator is still UNDER_MAPPING.

Help capture source lineage changed with these application sources/resources and remains an explicit later release gate; no blind fingerprint rewrite or recycled screenshot was used. Existing source-media and remote email-privacy blockers are not reported as resolved. No release ZIP, upload, new CI dispatch or force push occurred.
