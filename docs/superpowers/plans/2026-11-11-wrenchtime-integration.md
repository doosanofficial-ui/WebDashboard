# WrenchTime behavior integration plan

**Goal:** Independently bring useful public WrenchTime interaction patterns into the native iOS telemetry app, preserving raw CAN, offline records and explicit acquisition.
**Architecture:** Reuse validated TelemetryCore definitions, persisted adapter profiles, Dashboard and Replay. Author code independently from public workflows; no extracted binaries/assets. No guessed CarPlay capability.
**Tech stack:** SwiftUI, TelemetryCore, Xcode 27 / iOS 27 Simulator.

## Scope and decisions
The user's execution instruction and repository standing authorization request implementation without approval checkpoints. Work is serial on canonical main. Existing unrelated mobile and evidence files remain untouched; GH007 author rewriting remains blocked pending the separate decision.

1. Map official Live/Signals/CarPlay/Live Activity behavior to existing features and list missing pieces.
2. First independently releasable slice: an app-local custom PID authoring sheet with strict typed read-only 01/21/22 definitions, explicit ECU IDs, scale/offset decoding, offline response preview, add-only atomic profile save and stale-profile detection. It extends diagnostic profiles only; it must not silently switch a passive CAN profile into polling. No import network, live vehicle query or permission request on screen entry/preview/save. Existing explicit selection must be reviewed after the profile revision changes.
3. Add tests for invalid/blank numeric fields, command/header injection, unsupported writes, duplicate IDs, profile drift, raw-profile rejection, wrong ECU/no-data response, and scaled preview. Run full core tests, iOS build, platform docs and dedicated synthetic Simulator UI checks. Directly inspect screenshots separately from automated results.
4. Continue remaining product slices from the matrix, with separate validation: per-context display configuration and presets, min/max/average and grouped tiles, and ActivityKit lifecycle. Full CarPlay gauge/template integration remains gated on an approved category entitlement, not vendor implementation speculation.

## Initial acceptance
- New Custom PID from Signals has identity, request, decoding and offline preview sections.
- Input validation fails visibly and never substitutes zero for invalid text.
- Cancel writes nothing; successful Save appends to the exact opened diagnostic profile, preserves original queries/transport/signals and persists before publication.
- Editing/Save is blocked during recording, replay or diagnostic acquisition. No collection starts implicitly.
- A copied response preview is explicitly local/sample data, never vehicle support evidence.

## Ledger
- Initial baseline: 4d782c2 on main. Xcode 27.0 (27A266a), iOS 27 simulators available. Existing simulator windows and PosterBoard dialog reserved/preserved.
- [x] Public behavior matrix
- [x] Custom PID core RED → GREEN
- [x] UI integration and safety boundary
- [x] Full tests/build, dedicated UI evidence, independent review
- [x] Verified custom PID slice committed locally as 2f0635f
- [ ] Remote synchronization; do not alter blocked prior commit author

Custom PID validation: 466 core + 4 UI passed; see [review record](../../verification/wrenchtime-custom-pid-2026-11-11.md). Next ActivityKit work is separate and not part of this acceptance.

## Second slice: local REC-linked Live Activity

1. Keep ActivityKit independent of acquisition and durable recording. Default off; explicit selected signals, no push token/server/App Group or background-mode expansion.
2. Build a pure bounded projection and generation gate, then connect only recorder start success, stop/failure, scene transitions and received samples. End orphaned activities on launch; dismissal cannot recreate the same session. Terminal intent invalidates pending updates before disk close.
3. Add an embedded WidgetKit extension with iOS 17 Lock Screen/Dynamic Island support and an iOS 18 availability-gated supplemental small family. Treat actual CarPlay appearance and iOS 17 runtime separately from iOS 27 compilation.
4. Verify core tests, target/embedding, dedicated synthetic opt-in/REC/relaunch UI, actual system surface pixels and regression of the first slice. Record physical-device and entitlement limitations. Commit only verified portions.

Core projection RED → GREEN is complete (6 focused, full suite 472 passed). Final Activity suite: 3 passed; first-slice PID regression: 4 passed. All 11 final captures were directly inspected; see [Activity verification](../../verification/wrenchtime-live-activity-2026-11-11.md). OS stale rendering is delayed, not a hard 15-second deadline. Snapshot time and the disclosure reflect that observed limit. Parent direct UI review and remote synchronization remain separate gates.

## Next bounded slice

Add current displayed-recorded-sample minimum/maximum/sample-average to the existing RecordedSignalHistoryView, reusing MeasurementReplay.SignalHistory and ReplayController.recordedHistory. Preserve its 60-second/600-point/cursor limits; label truncated scope. Do not merge mixed units/sources or invent zeros for unavailable values. Define historical quality inclusion explicitly and test backward seek/session isolation. Vehicle-context presets should later link existing VehicleContext IDs to DashboardProfile with legacy dashboard.json and undo preservation, not introduce another vehicle model.
