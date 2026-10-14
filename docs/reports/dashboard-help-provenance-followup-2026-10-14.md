# Help asset provenance and offline regression follow-up

The current Help examples remain blocked for release acceptance. All 28 original PNG/marker pairs match the preserved 2026-10-08 XCTest attachments, exact capture times, language test identifiers, original Simulator UUID and historical direct-pixel review. They can be retained as historical assets. **Zero replacements are certified for the current source.** The initial offline phase did not capture new screens. A later authorized observation captured three current-state supporting screens, without changing any Help image, marker or manifest.

Verification started from canonical main `5cba53d343bd2cdc2400351ce96c4da6e25d7dbf`. The installed application source remains `1c71f8e47b43ceebf1d76d203c6c115ed65c832e`; the intervening commits changed tests and reports. This follow-up changes only the Help verification script, its tests and this report. No application, Core implementation or resource input changed, and the existing candidate was preserved.

During the initial offline phase, the screen was assigned to the independent Teams task and no foreground operation occurred. Existing archive decoding and macOS Core/Foundation tests were offline operations. After `c0ba11d` was synchronized, a new delegation released the screen for existing Simulator observation. There was no app launch/install, native UI runner, Simulator boot/reset, physical-device operation, permission change or app-data preparation in either phase.

## Provenance findings

The original source was main `8ddb12e1b80dd4831911f50a3d4e75517c0a2529` with the recorded localization/capture changes later integrated as `1b493e5`. All 43 hashes in the bundled `screenInputs` match both the original capture-time map and that historical commit. Apple's `xcresulttool` re-decoded the original archive: its complete summary equals the saved summary, with 2 passed, 0 failed, 0 skipped and 0 expected failures. The 28 asset files contain 20 unique PNG byte sequences; repeated images have distinct step markers and are not independent visual events.

The original 124-file capture-time map included App, nested CarPlay, UITests and LifecycleTests, but omitted the Core package and build configuration. The bundled 43-file source manifest also omitted the three nested CarPlay App files, although their historical hashes survive in the capture-time map. This does not establish complete build provenance. No missing capture-time source or binary hash was inferred or filled in.

Main has three stale recorded hashes: `DashboardView.swift`, `BLEDiscoveryController.swift` and `TelemetryModel.swift`. The preserved candidate additionally lacks five top-level App sources and has twelve stale hashes under its existing contract. A recursive App/resource audit finds the same three omitted CarPlay inputs in both roots: main therefore records 43 of 46 required inputs; the candidate records 43 of 51. The candidate verifier itself was not modified.

All original PNG and marker bytes, target IDs, historical AX targets and review paths match their source attachments. Marker coordinates remain historical coordinates; their suitability for current views is unverified. The original underlying screens require actual current-source capture and geometry verification before current acceptance. The 28 Help guide-page images inspected earlier contain these old embedded examples and cannot replace them.

The installed PNG files differ from the original raw PNG hashes because Xcode's recorded `copypng -compress -strip-PNG-text` commands convert them to CgBI PNGs. For every asset, the cached build input matches the original PNG, the exact conversion is logged, and the compiled PNG matches the signed installed package. Raw original-to-installed byte equality is not claimed, and no PNG was edited in this follow-up.

## Independent validator correction

The candidate's earlier guard corrections had not reached canonical main. Main was freshly reproduced accepting stale assets under `python -O`, accepting reordered/duplicate steps and duplicate guide IDs, and ignoring an added nested App source. The main verifier now uses explicit checks that remain active under optimization, validates unique guides and ordered contiguous step numbers, and collects nested App Swift and JSON/string resource inputs. `AppHelpView.swift` retains its separate target-order check, and generated Help assets remain outside their own source map. This collector is the App/resource contract, not a claim of complete binary input coverage.

Tests use clearly marked temporary byte-validation fixtures. Five guard tests pass normally and under optimization; the actual bundled-assets test continues to fail. Image, marker, source and receipt rejection tests first verify a valid fixture and then require the relevant specific failure, so the existing provenance failure cannot mask those checks. Normal and optimized production commands now both reject the incomplete real source manifest; neither prints a release pass.

## Fresh offline verification

| Scope | Actual result | Limit |
| --- | --- | --- |
| Canonical Python script suite | 227/228 passed; 1 failure, 0 errors/skips | Only failure: actual Help provenance; native command execution blocked |
| Preserved candidate's related aggregate | 80/81 passed; 1 failure, 0 errors/skips | Fresh rerun; only failure: actual Help provenance; synthetic contracts are not UI passes |
| Canonical Core | 271/271 passed, 0 failures | Existing compiled bundle; all 75 Package/Sources/Tests inputs matched current source; `--skip-build` |
| Original candidate Core | 323/324 passed; 1 failure | All 86 compiled inputs matched; failure in the redaction test's source JSON byte comparison |
| Candidate plus proposed **test-only** correction, temporary copy | 324/324 passed, 0 failures | Original candidate untouched; this is not its acceptance result |
| Actual immutable-value JSON diagnostic | 512 encodings; 4 unsorted byte representations, 1 sorted representation | All decoded values equal; changed array order, payload text and timestamp remain detectable |
| Platform documentation and scoped diff checks | Passed | No new iOS build or native UI/hosted run |

The candidate Core failure is a false failure from comparing two independently unsorted `JSONEncoder` outputs of an immutable `MeasurementExport`. The exact production value declarations and failing four-row fixture reproduce different byte ordering without invoking the exporter or any data store. Canonicalizing object keys in the test retains comparison of all scalar/string values and array order; independent changed-order/payload/time controls still differ. The original JSON/CSV privacy checks remain present and passed in the temporary test correction.

The verified proposal is preserved separately as `candidate-test-only-json-ordering.patch`. Its feature and test are not present in canonical main, so the patch was not copied into the original candidate or committed as an incomplete feature integration. The original candidate's 323/324 failure remains recorded. This follow-up makes no new native BLE/GPS/recording, VoiceOver, SE, large-text or physical-device claim.

Preservation checks cover all 45 user files, 172 canonical application inputs, 228 candidate inputs (including the previously recorded six controlled changes), the two prior candidate manifests, the unchanged native execution guard, all 57 Help resource files, all 68 signed installed bundle files and the ten existing app-data files. The already restored dashboard values and original English preferences remain preserved; no measurement database was created. The earlier GUI restoration's object-key byte-order difference is not relabeled as a new data change.

**Final acceptance is incomplete:** current-source underlying Help captures, complete capture-time provenance and successful actual asset gates remain outstanding. The original candidate's test correction also remains a separate verified proposal. No source hash was refreshed merely to make the gate pass.

## Authorized unchanged-data screen observation after c0ba11d

The running signed main `1c71f8e` on the same owned iPhone17/iOS27 Simulator was observed at 09:00–09:06 UTC. Three raw SDK PNGs (1206×2622) were captured from the current Sessions, Setup and final Live screens and directly opened. Each capture has an immutable command/time/hash/build receipt and a CUA AX excerpt explicitly labeled as an excerpt. These are supporting observations, not new synthetic Help resources. No native alert popup was seen; the visible Sessions warning is retained as a blocker.

Sessions shows recording off, “Saved sessions unavailable; measurement data was not modified” and disabled Open Replay. Setup shows adapter NOT CONFIGURED and English selected. No measurement database existed before or after observation. The saved-session status matches the current read-only archive error path; no data-loss diagnosis is inferred. Current data therefore cannot reproduce loaded/recording/GPS/saved-Replay examples under a navigation-only scope. The installed main bundle also lacks the unintegrated candidate changes, so its screenshots cannot certify that candidate's source provenance.

Only the Sessions and Setup tabs were opened before returning to the original English Live dashboard with CAN/recording/GPS off. No recording, GPS, adapter, import, export or permission action was executed. Post-observation byte checks again matched the 45 user files, 172 recorded canonical inputs, 228 candidate inputs, prior manifests/native guard, 57 Help resources, 68 signed installed files and ten app-data files; dashboard values and English preferences remained restored. No source hash or capture contract was changed to admit these three images as the missing 28 assets.

The older automatic approval review rejected the workflow that prepared app data and added a native test runner. This observation did not retry it, and the unchanged execution guard still blocks it. Complete candidate recapture requires an explicitly scoped capture workflow for the actual intended application source and the necessary synthetic state, followed by all 28 direct reviews and real asset gates. Existing screen access alone does not provide that workflow.
