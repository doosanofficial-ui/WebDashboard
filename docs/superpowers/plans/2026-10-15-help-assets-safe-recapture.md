# Help asset safe preparation implementation plan

> For agentic workers: execute authorized local steps serially on canonical main. Native steps below are blocked and this document does not authorize them. Use inline execution; no branches or worktrees.

**Goal:** Prepare current-source Help capture inputs and a reviewable preservation contract without touching a Simulator, its app data, or its runner.

**Architecture:** Keep source comparison separate from full image acceptance. Keep file-tree restoration separate from metadata and effective-preference certification. Retain the unconditional native execution barriers until both authorization and independent runtime evidence exist.

**Tech stack:** Python stdlib/unittest, current Swift capture contracts, macOS xattr/ACL observation, ditto on new synthetic temporary files only.

**Spec:** Current user delegation (2026-10-15), repository AGENTS.md sections9.5/10/10.1, and docs/reports/dashboard-help-provenance-followup-2026-10-14.md. This plan records the additional constraints below.

## Fixed scope and identity

- Initial canonical HEAD b41b649796a80e2912f346b3998b10aa51e1b08a on main. Installed code is be88685f1fd8398b6c6cf48521e22365a0e91510; all207 app/build inputs and68 installed files were pinned in the local preparation before.json.
- Only owned destination DDD24F62-C420-4211-B607-D1B03EBF881B, iPhone17/iOS27.0 runtime24A434. No GUI, app-data writes, app launches, runner install/execution, other-device operations, Device Hub reinstall, physical-device work or security changes in this preparation.
- Preserve unrelated45 user files, old candidate228 inputs, Help57 resources, prior capture receipts/manifests, installed68 files and current10 app-data files.
- Do not run or unblock run_help_existing.py. It still pins the old df7af99 candidate and old build artifacts. Do not run verify_offline_replay.py: its normal path creates/boots a disposable Simulator and is not an approved retained-destination executor.
- Never update old image hashes/source receipts merely to make the gate pass. No uploaded or fabricated evidence.

## Review focus

- A source-only audit must never claim full asset verification, even when hashes match and image files do not exist.
- Missing nested CarPlay files, stale files and extra recorded inputs must be reported together without reading extra manifest paths outside the expected input set.
- A file-copy success receipt must not imply ACL/xattr/cache restoration. Unreadable or unsupported metadata must fail closed before a native trial.
- The retained data-root inode and original path absence must survive restoration; trial-only entries remain quarantined rather than silently deleted.
- File equality and a quiet observation interval cannot prove the preferences daemon has flushed its cache or that the relaunched app uses the restored language.

## Task1: Read-only current-source contract

**Files:** scripts/verify_help_assets.py; scripts/tests/test_help_assets.py.

**Interface:** audit_source_provenance(root: Path) -> dict. CLI --audit-source prints JSON, returns1 on source drift and never writes source, image or manifest files. fullAssetVerificationPerformed is always false in this report.

- [x] Add four regressions, observe missing API/CLI failures, then implement the minimum audit.
- [x] Cover simultaneous missing/extra/stale inputs, CRLF normalization, no mutation, all28 targets, and optimized-Python CLI behavior.
- [x] Compare current46 inputs to manifest43. Missing: CarPlayProjection.swift, CarPlayProjectionBridge.swift, CarPlaySceneDelegate.swift. Stale: BLEDiscoveryController.swift, DashboardView.swift, SignalsView.swift, TelemetryModel.swift.
- [x] Run complete applicable Python regressions, docs parity and final preservation comparison; record the known bundled-asset gate failure separately.

The capture contract remains14 steps per language: setup2, live3, signals2, sessions3, replay2, editor2. Current capture tests are in mobile-ios/UITests/LocalizationHelpUITests.swift. Their two capture cases generate28 images with genuine PNG, marker, AX and XCTest receipts. Other Help tests validate persistence/layout and must not inflate captureSummary.passed beyond the two capture cases.

## Task2: Preservation scope and synthetic metadata evidence

**Local working files:** preserved_app_data.py, unchanged test_preserved_app_data.py, and help-safe-preparation-20261015/test_preservation_receipt_scope.py / probe_synthetic_metadata.py.

**Interface:** New preservation receipts declare verificationScope=file-tree-bytes-modes-file-mtimes-only, nativeRestorationCertified=false and explicit uncertified dimensions. Existing status strings remain compatible; consumers must require explicit scope and never treat absent legacy fields as certification.

- [x] Reproduce a receipt that reports RESTORED_VERIFIED while ACL/xattrs differ, using a newly created temporary root, directory and plist only.
- [x] Add a failing receipt-scope regression; add scope fields; verify the regression passes. Native execution barriers remain unchanged.
- [x] Observe ditto --rsrc --extattr --acl preserving metadata in a new synthetic backup copy. This proves the copy stage only, not complete restoration or a native cache boundary.
- [x] Retain normal/optimized results for the existing24 synthetic restoration tests and the new scope regression.

Required before a production metadata backend can be accepted:

1. Inventory root, every directory and regular file: bytes, namespace/absence, modes, file mtimes, ordered ACL entries with stable principal identity, and complete xattr names/bytes. Compare missing attributes as well as values. Preserve security-related attributes; do not clear them as a workaround. Reject unreadable metadata, original links/special files and unsupported external stores before mutation.
2. Copy to a new private backup on the same filesystem; verify bytes plus metadata independently before any trial. Existing retained-data-before is historical evidence, not this transaction's backup.
3. Create and verify a restoration stage first. Journal each move; quarantine trial entries. Keep the original root inode and explicitly restore its attributes/ACL, including removal of trial-only attributes within the approved synthetic trial. Copying children alone does not restore root metadata.
4. Compare the complete restored inventory and the backup again. Interrupted/timeout/cancelled restoration must retain original, stage and trial evidence and emit RECOVERY_REQUIRED. Extend tests for root/directory/file ACL+xattrs, trial-only attributes, partial restore, disk-full and abrupt exit before changing native eligibility.

The existing module is not a certified metadata backend. Its file-tree tests and receipt scope are useful local evidence only. This preparation does not replace its copy strategy with an unverified native implementation.

## Task3: Native writer/cache and effective-language method — blocked

No executable quiescence implementation exists. A callback returning true, terminating Telemetry alone, or seeing stable hashes is insufficient. Do not invent or kill a cfprefsd/launchctl PID, stop a global service, reset/boot the Simulator, or widen permissions to produce a green receipt.

Before any proposed native action is reviewable, identify a documented synchronization/lifecycle boundary limited to the owned destination and preference domain. Verify that boundary independently on synthetic test data after explicit native approval. Required evidence includes original persistent-domain values, pending-writer handling, failure propagation and a bounded proof that stale queued preferences cannot overwrite restored files. If this cannot be established, stop before backup/trial mutation.

After a certified restoration, effective-language acceptance must launch the owned app without --app-language, AppleLanguages or locale overrides and read the actual AppLanguageStore/UI choice against the saved original. Check the persistent domain and file inventory again after the native lifecycle. Account for every changed path; never hide cache drift, substitute plist bytes for effective state, or loop restore/relaunch until hashes happen to match. Any unexplained drift leaves restoration unverified and all evidence retained. No native phase of this method is executed here.

## Task4: Future capture, only after separate approval and technical gates

1. Re-pin current main/app207-input inventory and signed installed68 files. Preserve be88685 linkage if product source remains identical. If the proposed UI wording is adopted, it becomes a different app source/build and requires its own permitted build/install/visual acceptance; do not label that app be88685.
2. Qualify a fresh host Seed from scripts/verify_replay_seed.py and scripts/tests/offline_replay_seed.swift against current inputs/commit/toolchain. Do not relabel the old df7af99 producer manifest. Generate only a new local synthetic fixture until native approval exists.
3. Prepare a matching current-source UITests runner and hash its host/test bundle. The old prebuilt runner is reference evidence only. Review the exact first installation of local.webdashboard.Telemetry.UITests.xctrunner, app termination/relaunches, language/orientation effects, fixed dashboard replacement, absent-DB creation/sidecars, backup/restore, and runner retention/removal policy together. No target reinstall is implied.
4. After approved writer/cache and metadata gates, make a new full transactional backup; replace dashboard.json and create the synthetic DB only when the original DB/sidecars remain absent. An unexpected DB aborts preparation rather than overwriting it.
5. Execute the four named help selectors from scripts/verify_offline_replay.py TEST_GROUPS["help"] serially on the exact retained destination. Keep help-max-en and help-max-ko as separate layout acceptance cases. Export genuine attachments from the current run; derive28 image/marker/AX receipts and complete current46-source provenance. Directly open every image and inspect errors, target visibility and state.
6. Finish restoration and effective-state acceptance before promoting new images/manifest. Run the unchanged full asset gate and applicable regressions. Retain old assets and all original receipts. A parent reviewer must directly open core images before user-facing completion claims.

## Wording review and integration

The existing capture code deliberately records Live controls with recording/GPS OFF and Setup controls before importing a profile. These are locator examples, not evidence of a failed current operation or completed action. The local help-example-state-note.proposed.patch adds language-specific context only to live/setup; it does not assert every Replay/Signals screen is pre-action. It is not applied, compiled or visually accepted while Teams owns the screen.

The source audit, its regressions and the independently verified synthetic metadata follow-up below are eligible for repository integration. Preserve the product UI proposal as unverified. Record synthetic file tests, source-gate failures, native gaps and prior GUI28/28 as separate evidence classes.


## Task2 follow-up: isolated synthetic metadata transaction

The 2026-10-15 follow-up adds scripts/darwin_file_metadata.py, scripts/synthetic_data_preservation.py and their three test files. The old local preserved_app_data.py and unconditional native barriers remain frozen. This module accepts only its newly created marked temporary workspace; it does not add a native CLI or establish a writer/cache boundary.

- [x] Reproduce metadata loss with independent ls/xattr assertions against the old copy2 path.
- [x] Preserve and compare ordered ACLs, exact binary/empty/absent xattrs, root/entry permissions, ownership/flags and nanosecond directory/file/root mtimes; retain the root inode.
- [x] Verify backup and full staging before moving trial entries, preserve trial root metadata and reject metadata mismatch without a success receipt.
- [x] Exercise failure/interrupt/recovery paths with disposable files; no actual app/data access.
- [ ] Certify actual writer/cache synchronization, external stores and effective preference restoration: still blocked; not attempted by this change.

See [synthetic metadata verification](../../reports/help-synthetic-metadata-preservation-2026-10-15.md) for the contract, synthetic evidence and explicit limits. Filesystem regression success cannot authorize runner installation, app lifecycle actions, UI/capture or Library upload. The product wording proposal remains unverified and unapplied.
