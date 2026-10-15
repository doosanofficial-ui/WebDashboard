# Help asset safe preparation — 2026-10-15

The new `python3 -B scripts/verify_help_assets.py --audit-source` command reports missing, extra and stale source inputs together, plus the exact28 capture targets. It reads source and the existing manifest without modifying either. Its JSON explicitly says `fullAssetVerificationPerformed: false`; matching source hashes alone cannot certify image bytes, markers or a native capture run. The default full asset gate and its acceptance checks are unchanged.

Current app/build inputs207 remain byte-identical to installed be88685f1fd8398b6c6cf48521e22365a0e91510. Initial repository HEAD was b41b649796a80e2912f346b3998b10aa51e1b08a. The manifest has43 of46 required source inputs: CarPlayProjection.swift, CarPlayProjectionBridge.swift and CarPlaySceneDelegate.swift are missing. BLEDiscoveryController.swift, DashboardView.swift, SignalsView.swift and TelemetryModel.swift have stale hashes. All57 bundled Help resources remain unchanged. No source/hash-only update was used to repair the asset gate.

## Independent verification

- Four new source-audit regressions failed before implementation and pass afterward. They cover missing/extra/stale inputs together, no writes, all28 ordered targets, CRLF normalization and optimized-Python CLI behavior.
- Complete repository Python suite:232 tests,231 passed and the existing `test_bundled_captures_and_provenance_are_complete` failed with `Incomplete source provenance`. This is not a green full gate.
- Platform documentation validation and changed-Python AST parsing passed.
- No iOS product source changed, so no new app build, installation, UI test or pixel acceptance is claimed in this preparation.

## Preservation evidence and limits

Only new temporary synthetic files were mutated. The existing local `preserved_app_data.py` restores file bytes/modes/file mtimes and originally absent paths, but a real macOS metadata probe found that its backup/restore loses ACLs and extended attributes. The data-root inode survives, so a trial root xattr also survives incorrectly. The synthetic plist bytes and language return to their original values while the broader metadata contract fails.

New local receipts now explicitly declare `verificationScope: file-tree-bytes-modes-file-mtimes-only`, `nativeRestorationCertified: false`, and uncertified ACL, extended-attribute, external-store and effective-preference-cache dimensions. A new regression failed before these fields existed and passed after the minimal receipt change. The existing24 synthetic preservation/barrier tests plus the new scope test pass in both normal and optimized Python. Original execution guards remain unconditional and retain SHA256 `4e2aef19a95b7cd97a16521e56ff3d456854aae9aac25a06ea65751206471c7c`.

An independent `ditto --rsrc --extattr --acl` copy preserved ACL/xattr metadata for the new synthetic root, directory and file. This is evidence for a candidate backup-copy stage only. Full restoration, exact root attributes, interrupted metadata restoration, actual app/preferences-cache quiescence and effective language after a native lifecycle remain uncertified. The complete metadata probe intentionally returns2 rather than presenting a file-only restoration as native readiness.

Local evidence is retained in the Codex task's `help-safe-preparation-20261015/`: source-audit red/green logs, repository-python-regression.log, synthetic-verification.json, synthetic-metadata-final.stdout.log, receipt-scope tests, exact before/after hashes and proposal files. These local helper files are separate from repository product code. A first ACL API observation attempt failed without producing metadata qualification; its source/log remain retained. The completed probe uses an independent ordered ACL observation rather than interpreting that API failure as an empty ACL.

## Interpretation of the existing examples

The capture code deliberately photographs Live controls with recording/GPS OFF, and photographs Setup controls without importing or connecting an adapter. The earlier five observed state/text mismatches are a missing-context issue in these locator examples, not evidence that the current recording, GPS or adapter implementation failed.

The local `help-example-state-note.proposed.patch` adds bilingual context only for Live and Setup. Its wording matches those capture paths. It does not claim that all Replay/Signals examples precede every action. It is not applied to product source, compiled, installed or visually verified: Teams owns the shared screen, and adopting it would create a different app source/build than be88685. The previous GUI28/28 result remains limited to its stored, directly opened historical-example presentation captures; no new GUI evidence or asset replacement is claimed.

## Remaining gate

[The preparation plan](../superpowers/plans/2026-10-15-help-assets-safe-recapture.md) separates local preparation from any future native action. Actual app-data replacement/DB creation, owned app lifecycle operations, runner first-install/testing and restoration remain outside the currently permitted execution. The old df7af99/old-runner workflow is not retargeted or retried. A safe owned preferences-writer boundary and complete metadata-preserving restoration must be demonstrated in addition to obtaining the narrowly scoped approval. No global preferences-service termination, device reset/boot, permission expansion or physical-device workaround is proposed.
