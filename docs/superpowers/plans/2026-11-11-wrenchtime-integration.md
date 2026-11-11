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
- [ ] Authorized commit/push after verified gates; do not alter blocked prior commit author

Custom PID validation: 466 core + 4 UI passed; see [review record](../../verification/wrenchtime-custom-pid-2026-11-11.md). Next ActivityKit work is separate and not part of this acceptance.
