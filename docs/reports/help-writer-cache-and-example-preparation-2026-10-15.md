# Help writer/cache review and safe preparation — 2026-10-15

## Outcome and scope

This follow-up resumes the independent work that was incorrectly treated as blocked by the native capture pause. It is based on main f8ec845c646de10b2baeb5700c88c5479e286249. Native fixture/runner, actual app/container access, app/UI actions, Library upload and physical-device work remain excluded. The existing iOS27 destination and native barriers are retained. No product source or bundled capture/manifest is changed.

The two new scripts separate a read-only Help source plan from host Swift checks using memory-only preferences. The proposed copy correction is stored as an unapplied patch. Neither script can grant native execution or certify the real cache/lifecycle boundary.

## Actual preference code findings

- AppLocalization.swift:27–35: initialOverride changes initialization only; select still writes telemetry.appLanguage. A real-source host probe rejected the assumption that the override isolates later picker writes (two writes). This is not a product defect to fix by suppressing writes: LocalizationHelpUITests.swift:96–130 deliberately verifies that an explicit language selection survives relaunch. The recording controls are not tapped in the two capture selectors; the persistence test is a different acceptance case.
- AppLanguageStore.language is initialized once and shared is process-lived. Restoring backing values does not update that retained object. A fresh unoverridden store is necessary to observe restoration, and an override can mask a wrong restored language. These statements are verified against the actual hash-pinned class prefix; actual Foundation preferences are replaced by module-local memory types.
- TelemetryModel.swift:127–137 also calls UserDefaults.set for clientID during initialization. An originally absent preference domain/clientID cannot be assumed unchanged after app launch. This is a source finding, not a measured native filesystem change; no real data is inspected here.
- The installed iOS27 SDK NSUserDefaults.h documents immediate in-memory changes followed by asynchronous persistent writes. It describes synchronize as waiting for pending updates while discouraging its use. CFPreferences.h describes application synchronization as writing changes and returning success/failure. These contracts do not by themselves establish a protocol that prevents later writers or refreshes AppLanguageStore. Treat that last conclusion as a review inference, not a runtime proof. No synchronization API, defaults command or daemon operation is executed.

Apple's [preference-domain documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html) also explains argument-domain precedence and that the application preference file is managed by the system. A direct file-byte comparison and a test argument cannot substitute for an unoverridden effective-state observation. Current API references: [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults), [synchronize](https://developer.apple.com/documentation/foundation/userdefaults/synchronize()), [CFPreferencesAppSynchronize](https://developer.apple.com/documentation/corefoundation/cfpreferencesappsynchronize(_:)). The current API comments were read from the installed iPhoneSimulator.sdk headers; no web page is treated as a native test result.

## Completed executable checks

Run python3 -B scripts/verify_help_memory_contract.py from the repository. It validates the language-store prefix SHA256 before compiling, writes only a newly created temporary tree, shadows UserDefaults and Locale with memory types, and removes that synthetic tree afterward. It launches host Swift executables, not an app or XCTest runner. Future product-prefix drift fails before process launch.

The actual source prefix passed eleven checks for each of --app-language en and ko. Checks cover normal persistence, initialization-only overrides, later picker writes, retained-store staleness, original absence, locale fallback and an override masking wrong restoration. An adversarial in-memory pending-write queue demonstrates how equality before a queued write can become inequality afterward. That queue is a deliberate model; realCFPreferencesCacheTested and nativeRestorationCertified remain false.

The proposed full AppHelpView source passed Swift syntax parsing. Its real HelpCopy/HelpStep/HelpGuide declarations, plus the actual language-store prefix, compiled and executed with memory preferences: all28 EN/KO target IDs and bilingual instructions match the current guide. Exactly10 setup/live example rows gain context; other guides and all existing action/result/recovery text stay unchanged. Full iOS compilation, rendered layout, navigation and visual acceptance of this proposal are not verified.

## Help capture/provenance preparation

Run python3 -B scripts/verify_help_preparation.py. It reads sources/manifest only and intentionally exits1 on current provenance drift. It reports all28 targets using the fourteen actual capture calls per language, including the actual Signals order2 then1. Literal targets and known local aliases are resolved and checked against the guide. Missing/duplicate captures, wrong/unknown anchors and an unreviewed capture body are rejected. The two capture selectors are listed separately from all four existing Help regression selectors; no acceptance tests are dropped or executed.

The capture body deliberately takes Live examples with recording/GPS off and Setup examples before connection steps. The earlier five observed mismatches are addressed as example-versus-after-action context gaps, not proof of a broken current operation. scripts/fixtures/help-safe-preparation/example-state-note.patch supplies a bilingual note for setup/live only. It has not been applied to AppHelpView and does not change image bytes or hashes. Direct visual acceptance remains required before any product promotion.

Current source audit is unchanged: expected46/recorded43, missing3 (CarPlayProjection, CarPlayProjectionBridge, CarPlaySceneDelegate), stale4 (BLEDiscoveryController, DashboardView, SignalsView, TelemetryModel), extra0. Genuine new screenshots, markers, AX and current-source build/capture receipts are still required to clear the full asset gate. This plan must not relabel old images or unblock the native runner.

## Remaining native boundary

The actual owned writer/cache lifecycle and post-restoration effective language remain unverified. A future authorized method must account for pending writers, original key/domain absence, the shared store lifecycle, other stores and every post-lifecycle path change. No restore/relaunch loop, global daemon manipulation, replacement device or old installation approval is used. Existing fixture/runner and Library refusal/unanswered confirmation remain in force; this report does not request them again.


## Final validation

- New preparation regressions: 13/13 passed in the full normal suite, and 13/13 passed with Python -O, without skips. This includes preserving the actual stdout error details from a failed host check.
- Full Python suite: 291 run, 290 passed, one pre-existing failure in test_help_assets.HelpAssetGateTests.test_bundled_captures_and_provenance_are_complete (Incomplete source provenance), no new failures or skips. The unchanged synthetic metadata regressions remain green.
- Reproducible host command: eleven actual-store memory checks pass separately for EN and KO; proposed Help data28/28 and full candidate syntax parsing pass. Success remains nativeRestorationCertified=false, realCFPreferencesCacheTested=false and nativeUiVerified=false.
- Documentation parity and git diff --check pass; all three added Python files parse. The read-only plan returns1 for unchanged missing3/stale4 source provenance and emits28 targets, capture selectors2 and regression selectors4, without changing source/assets.
- Source preservation: all user45, candidate228, product207 including Help57, three protected stored receipts, the five prior synthetic metadata Python files, legacy helper, native guard and original local UI proposal remain unchanged. Only the eight scoped preparation/test/document paths are new or changed. Actual installed binaries and app data are deliberately not inspected; no native preservation certification is inferred from source hashes.

Local evidence is in help-independent-followup-20261015: language-red.log (unsafe assumption), host-contract.json (memory/source checks), preparation-plan-final.json, optimized-verification.log, repository-regression.log and preservation-source-only.json. The earlier basic sandbox macro-plugin failure was resolved by a scoped host-compiler escalation; no security settings were changed. Native actions and uploads were not retried.
