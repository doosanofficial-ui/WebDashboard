# Help provenance — Astra boundary follow-up

Verified locally on 2026-10-16 UTC against canonical `main` at `016434c3980e719060ce7ec8148b5ea24ebbb992`. This follows `/Users/doosansmacbookpro/Documents/Codex/2026-10-17/task-2/astra-review-evidence/review.md` and its boundary results. The prior reviewed 16-file baseline was preserved by exact hash before this follow-up. Five existing files changed, and this report was added; the combined uncommitted change has 17 files. Commit/push remain held for a new Astra review.

## Review corrections

| Finding | Files and resulting behavior |
| --- | --- |
| P2 — preparation depended on the actual bundled stale count/CLI failure | `scripts/tests/test_help_preparation.py` now explicitly builds a clean temporary source inventory. Drift tests deliberately change one fixture source; clean and stale CLI checks assert their respective outcomes. A newly added nested source must be detected as missing. No test depends on the actual assets having exactly four stale entries, and clean source preparation still never certifies PNGs/native execution. |
| P2 — default UI Help capture bypassed source collection | `scripts/verify_offline_replay.py` resolves the final XCTest selectors before bootstrap. Method, class and module selectors determine whether Help captures are included. Every such selection runs the same before/after source checks and disables export source instrumentation. The default full UI selection remains 31 tests using untransformed App sources; grouped replay and the focused export test retain diagnostics. The existing literal Help selector declaration stays compatible with the source-only plan parser. |
| P3 — binary plist encoding treated object aliasing as value data | `scripts/verify_preference_restoration.py` now normalizes values recursively with explicit plist type tags. It ignores dictionary insertion order and container sharing, preserves array order and domain presence, distinguishes boolean/integer/real values, and rejects invalid/cyclic containers. Byte-for-byte plist serialization is no longer the domain equality test. |

The other modified files, `scripts/tests/test_help_source_collection.py` and `scripts/tests/test_preference_restoration_contract.py`, exercise these boundaries. Producer tests cover default, dedicated, mixed-group and non-capture selections, including a group named Help that selects no capture. Wrong staged input stops before the first mocked Simulator boundary; valid source input produces a source-only receipt before that boundary. Capture selections do not instrument App sources, while non-capture export selections retain their instrumentation. Plist tests accept shared-versus-independent equivalent containers in both directions and reject nested type, array-order, date/data/value, missing-key and extra-key drift.

## New verification

The original Astra probes were reproduced before the fixes and rerun afterward using only temporary/memory fixtures and mocked native boundaries. Both formerly clean-fixture failures and the added-source case now pass. Default and dedicated capture paths both call `begin_capture` once and reject wrong staged sources with zero mocked Simulator calls. Equivalent plist values now pass the synthetic contract; native certification remains false.

| Check | Result |
| --- | --- |
| Focused Python, normal / `-O` | 39/39 passed in each mode |
| Complete suite | 317 run; 316 passed; 1 expected stale-Help failure; 0 errors/skips |
| Seed / SE preparation | 316/316 passed in each mode; exactly the complete bundled Help test deferred |
| Actual complete Help CLI under `-O` | exit 1 with the expected stale DashboardView rejection |
| Host Swift memory contracts | EN 11/11 and KO 11/11; each language's two positive and three negative restoration scenarios classified as expected |
| Python AST, tracked/new whitespace, platform docs | passed |

The remaining full-suite failure is `test_help_assets.HelpAssetGateTests.test_bundled_captures_and_provenance_are_complete`: `Guided screen changed; regenerate actual screenshots: mobile-ios/App/DashboardView.swift`. The manifest remains 46/46 with zero missing/extra inputs, and still records stale BLEDiscoveryController, DashboardView, SignalsView and TelemetryModel hashes. No old screenshot was relabeled current.

Full evidence is in `/Users/doosansmacbookpro/Documents/Codex/2026-10-13/task-4/astra-review-boundary-fixes-20261017/`: `boundary-results-before.json`, `boundary-results-after.json`, `checks-results.json`, `host-restoration-contract-final.json`, `optimized-final-help-gate-result.json`, `preservation-final.json`, `final-status.json`, incremental `review-fixes.diff` and combined `implementation.diff`. Native-command/container guards were enabled for Python regressions. Mock Seed output in logs does not represent a Seed/SQLite/Simulator run.

## Preserved and unverified scope

User files 45, prior candidate inputs 228, protected receipts, the native hard-stop guard and frozen legacy helper remain unchanged. All 57 current Help resources, including the already reviewed manifest amendment, are unchanged by this follow-up. All current product Swift and mobile-ios build inputs are unchanged by these boundary fixes. The prior metadata correction remains the sole build-input difference from the original 207-input baseline.

No actual Simulator data or preference domain was opened or changed; no install, native test execution, new screenshot, direct native UI inspection, Library upload or remote CI run occurred. The prior automatic-review rejection of data replacement/SQLite generation/first UITests runner installation remains respected and was not retried. The actual owned-domain writer/cache adapter, host/test bundle identity qualification, fresh 28-screen capture and direct popup/pixel inspection, final complete Help success and two new Library IDs remain unverified/outstanding. The source receipts still explicitly set `captureCertified=false`; all native restoration/execution/UI certification flags remain false.
