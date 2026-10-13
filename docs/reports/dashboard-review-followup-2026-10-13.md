# Dashboard review follow-up — 2026-10-13

Baseline: `df7af9945037c1d679a9c90611ec23b1309f975e` on canonical `main`.

Snap now uses cell units, avoids saving no-op changes, and records an explicit
whole-page snap as one atomic Undo/Redo command. A stale widget blocks the entire
undo instead of partly overwriting later edits. Setup recording/GPS titles follow
start/stop state, and accessibility translates the title and detail separately.
BLE Stop cancels connected or connecting peripherals retained for inspection,
including after a rescan, and deduplicates cancellation by device identity.

## Verification

- Canonical Core: 271 tests, zero failures (baseline was 268).
- Updated integration candidate Core: 324 tests, zero failures (prior was 321).
- Both source snapshots: generic iOS Simulator build succeeded, signing disabled.
  Builds finished at 16:42:36 UTC (canonical) and 16:45:03 UTC (candidate).
- Exact app method bodies and label expressions ran against synthetic macOS
  fixtures: 15 checks in English and 15 in Korean passed for each source root.
  The original candidate failed 10 English and 12 Korean checks before edits.
  Run `scripts/verify_dashboard_regressions.py <repo-root> <new-output-directory>`.
  The probe tests logic/localization; it does not certify rendering, persistence
  I/O, radio behavior, or real CoreBluetooth callbacks.
- Canonical platform-doc validation passed. Running it against the partial
  candidate copy failed for missing `mobile/README.md`; it is not a complete repo.

## Remaining candidate work

The candidate-only Replay/MARK view now keeps common cursor and MARK navigation
outside the signal-selection condition. It compiled in the candidate build;
no current UI execution or pixel review was performed. Its prerequisite Replay
comparison feature remains outside this independent canonical commit.

Help captures were not regenerated or their receipts edited. Canonical Help has
3 stale source hashes; the candidate still has 5 missing sources and 12 stale
hashes. Candidate `test_help_assets.py` ran 5 tests: 4 passed and
`test_actual_assets_pass` failed with `Incomplete source provenance`.
The previous 80/81 aggregate was not rerun and is not claimed as fresh evidence.
Current-source Hosted, UI, SE, physical-device and Help pixel acceptance remain
unverified; earlier raw UI passes do not transfer to these changed sources.

The local capture-preservation module separately restored root mode and
quarantined new trial links/FIFOs without following them. Its complete 24-test
synthetic suite passed in normal and optimized Python modes. Native writer/cache
quiescence, effective-language restoration and unsupported metadata are still
unverified. The native runner's unconditional block was retained.

All 45 unrelated user files, old 50/52-entry candidate manifests and both prior
built/installed binaries retained their hashes. The owned Simulator dashboard
hash remained unchanged and no measurement database was created. No install,
app/device UI action or native data preparation was performed.
