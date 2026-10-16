# Help provenance implementation for Astra review — 2026-10-16

Status: implemented and locally checked; uncommitted on canonical `main` at `016434c3980e719060ce7ec8148b5ea24ebbb992`. Integration is held for the parent's separate Astra review. The scope was source changes, historical evidence and fresh synthetic fixtures. No installed app or Simulator data container was opened or changed in this implementation.

## Source inventory correction

The historical generator used a non-recursive Swift glob and omitted three CarPlay files. The bundled manifest now records 46 of 46 required inputs, with no missing or extra entries. Only the three omitted entries were added. All 43 previously recorded hashes, all 28 screenshot receipts, capture counters/times, source base and historical modified-source declarations remain unchanged.

The additions match the original 124-file capture-time snapshot byte for byte. Its exact copy is [the stored source evidence](../evidence/help-capture-source-inputs-2026-10-09.json), SHA-256 `bc76c6fe5669c13d2b348ab2aa4aa8b4ecc275ef159e940da29e13b447b7c45c`, with capture base `8ddb12e1b80dd4831911f50a3d4e75517c0a2529`. `sourceInventoryAmendment` records the proof and explicitly does not certify current sources. The original historical snapshot and generator were preserved.

The real stale inputs remain BLEDiscoveryController, DashboardView, SignalsView and TelemetryModel. Their recorded hashes were not refreshed. The complete Help gate continues to reject the old captures.

`verify_help_assets.py` owns the recursive collection rule. `collect_help_source_inputs.py` uses it both for the repository and physically staged App sources, with the existing CRLF normalization. Dedicated `--group help` / `--only-test help-capture` production in `verify_offline_replay.py` now checks matching repository/staged source and capture-test hashes before Simulator bootstrap, then checks source/commit stability after the XCTest summary. These source-only receipts explicitly set `captureCertified=false`; capture/marker/PNG receipts are still required separately. The capture tool itself was not executed here.

## Independent preparation gates

`verify_native_contracts.py` requires exactly one canonical complete bundled-Help gate. Seed and SE preparation defer only that test, retaining every rejection test, other contract and import failure. Their reports explicitly set `fullValidationPerformed=false` and `fullValidationPassed=false`. Unknown stages or missing/duplicate final gates fail closed.

The workflow runs the complete suite in an independent `native-contracts` job and keeps the existing direct full Help checks. Seed qualification, trusted digest admission, the original 240-second budget, six disjoint UI groups/31 tests and the two SE repeat tests are unchanged. No workflow was pushed, rerun or qualified remotely.

## Preference restoration preparation

`verify_preference_restoration.py` defines a pure synthetic acceptance contract: explicit original/restored/post-lifecycle full persistent-domain snapshots and presence, writer acknowledgements and zero pending writes at both barriers, exact phase order, a fresh effective-language observation without language launch overrides, and unchanged file inventory. Canonical plist encoding preserves type and domain-absence distinctions.

The Swift memory harness supplies observations from the actual AppLanguageStore source prefix using module-local memory doubles. Fresh-restored and originally-absent cases are accepted; retained-store, queued-writer and override-masking cases are rejected in both languages. A separate Darwin test performs a real restoration of a newly created synthetic plist, then releases a deliberately late synthetic writer and detects the resulting drift.

This does not implement the actual owned-domain writer/cache adapter. All reports retain `nativeRestorationCertified=false`, `nativeExecutionAllowed=false` and `realWriterCacheBoundaryVerified=false`. Actual UserDefaults/CFPreferences/cfprefsd and native lifecycle behavior remain unverified.

## Final local verification

| Check | Result |
| --- | --- |
| Optimized Python focused contracts | 31/31 passed |
| Complete contracts, `--suite all` | 309 run; 308 passed; 1 expected stale-Help failure; 0 errors/skips |
| Seed preparation, `--suite seed` | 308/308 passed; final Help gate explicitly deferred |
| SE preparation, `--suite se` | 308/308 passed; final Help gate explicitly deferred |
| Host Swift memory checks | EN 11/11 and KO 11/11; each language's five restoration scenarios classified as expected |
| Python AST sanity, platform docs, `git diff --check` | passed |

The complete-suite failure is `test_help_assets.HelpAssetGateTests.test_bundled_captures_and_provenance_are_complete`: `Guided screen changed; regenerate actual screenshots: mobile-ios/App/DashboardView.swift`. The source audit independently lists all four stale files. The native-command/container guard was enabled for Python regression tests. Synthetic mock output in those logs is not evidence of a Simulator run.

Machine reports and full logs are retained in `/Users/doosansmacbookpro/Documents/Codex/2026-10-13/task-4/help-provenance-implementation-after-astra/`: `final-checks-results.json`, `all-final.log`, `seed-final.log`, `se-final.log`, `focused-final-optimized.log`, `host-restoration-contract-final.json`, `preservation-final.json`, `final-status.json` and `implementation.diff`.

## Preservation and remaining execution boundary

User files 45/45, the prior candidate's 228/228 inputs, three protected receipts, the native hard-stop guard and frozen legacy helper are preserved. Current application build inputs are unchanged for 206 of 207 files; the sole authorized change is the Help manifest. All 56 PNG/marker files are unchanged. Product Swift, AppHelpView and its pending proposal patch are unchanged. No new capture, GUI review, Library upload, Seed executable run, actual SQLite generation, native runner installation, physical-device action or installed-app verification occurred.

The previous automatic approval review rejected `python3 -B run_help_existing.py` before process creation because it would replace owned app data, generate SQLite and first-install/run a UITests runner without clear authorization for those side effects. That command remains hard-blocked and was not retried.

After a real owned-domain writer/cache adapter is implemented and independently qualified, a future execution request must explicitly cover only owned iOS 27 Simulator `DDD24F62-C420-4211-B607-D1B03EBF881B`: verified original file/preference backup and quiescence; temporary replacement of dashboard data and creation of absent-only synthetic measurement SQLite; persistent EN/KO language changes with original-domain restoration and fresh unoverridden lifecycle checks on success/failure; first installation and execution of `local.webdashboard.Telemetry.UITests.xctrunner`; and a clear runner-retention/removal policy. This is remaining approval scope, not permission obtained by this implementation. The target app does not need an installation merely to run these source-only checks.

Fresh current-source screenshots (28), direct inspection of every capture and error popup, final complete Help success and two newly verified Library IDs remain outstanding. This implementation must not be presented as their completion.
