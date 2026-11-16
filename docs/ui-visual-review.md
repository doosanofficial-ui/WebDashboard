# UI visual review record

UI verification requires direct inspection of actual screenshot pixels. Automated tests and generated captures are separate evidence. Copy the record below for the active task; replace placeholders with observed facts and stable artifact links.

## Scope and provenance

- Task and acceptance criteria:
- Source commit / build identity:
- Capture date, platform/device/runtime, viewport, orientation, text size and language:
- Capture source (existing CI artifact, permitted live capture or user-provided image):
- Automated functional evidence and result:
- Visual scope and required screens/states:
- Physical-device scope and availability:

## Screens and states

Add a row for each required screen/state and each screenshot used as visual evidence. Directly open every referenced screenshot; do not mark an unopened capture passed.

| Screen/state | Screenshot link | Capture provenance/environment | Directly opened by / review time | Pixel inspection findings | Visual result | Parent core review |
| --- | --- | --- | --- | --- | --- | --- |
| <required screen and state> | <stable link> | <commit/build and capture environment> | <reviewer/time or NOT OPENED> | <content/state, legibility, clipping/overlap, controls/navigation> | <PASS / FAIL / UNVERIFIED> | <reviewer/time or NOT REVIEWED> |

Include viewport, orientation, text-size or language variants when relevant to the change. A contact sheet can help navigation but does not replace opening evidence at a readable scale. Preserve original captures and identify any redacted shareable copies.

## Unverified items

Report these separately even if automated tests passed:

| Category | Screen/state or scope | Evidence / reason | Next required check |
| --- | --- | --- | --- |
| Unopened screenshot | <scope or NONE> | <path/reason> | <direct inspection> |
| Blocked/inaccessible capture | <scope or NONE> | <observed access/capture limitation> | <permitted recovery> |
| Physical-device UI not inspected | <scope or NONE> | <device absence, installation hold or other observed boundary> | <separately permitted device review> |

## Completion boundary

- Automated functional result:
- Directly inspected visual result:
- Physical-device result:
- Parent/primary agent's direct core screenshot review:
- Remaining defects and unverified scope:
- User-facing completion claim supported by the evidence:

Screenshots establish visible presentation at capture time. They do not by themselves prove BLE/GPS acquisition, durable recording, background/reconnection behavior or preservation of existing data. Do not clear those separate gates or resume a paused install through a visual-review result.

The preceding sections are the reusable template. Scoped completed reviews follow.

## 2026-11-16 Core Guide Capture Refresh

- Capture source: `e4d76a0e7ce142f72e08f24edfb592838048ebce`, app `0.22.5(21)`.
- Existing CI: [Native Reliability 43733307103](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43733307103), artifact `offline-replay-help-e4d76a0e7ce142f72e08f24edfb592838048ebce` (14173259515).
- Environment: iPhone 17 Simulator, iOS 27.0 (24A434), Xcode 27.0 (27A266a), portrait 1206x2622, synthetic offline fixture. These are normal guide captures, not maximum-text, landscape or physical-device evidence.
- The primary agent directly opened all 28 original EN/KO PNGs individually. A source-only checksum update, old review, contact sheet or worker summary was not substituted for inspection.
- The full four-case Help group passed. Both named screenshot-capture tests passed and produced the 28 images/anchors. The manifest's two-case capture summary is distinct from the four-case group result.
- The existing same-run verifier checked all 60 source inputs, capture test digest, original image/anchor bytes and unchanged app/XCTest/runner product receipts. Exact capture timestamps and digests are preserved in [the manifest](../mobile-ios/App/Resources/HelpScreenshots/manifest.json).
- Review result: **PASS for cited target visibility and evidence provenance only**. This is not whole-product UI acceptance or proof a disabled control works.

| Individually Opened Captures | Inspected Content And Limitations |
| --- | --- |
| Help-editor-en-1, Help-editor-en-2, Help-editor-ko-1, Help-editor-ko-2 | Selected card, resize handle and top undo controls visible. No-sample state is explicit. Undo is disabled with empty history. Horizontal toolbar overflow remains; drag/resize/undo behavior is not proved by stills. |
| Help-live-en-1, Help-live-en-2, Help-live-en-3, Help-live-ko-1, Help-live-ko-2, Help-live-ko-3 | Record, GPS and MARK targets visible. CAN/recording/GPS off and missing samples are explicit. No vehicle, GPS fix or MARK persistence is inferred. |
| Help-replay-en-1, Help-replay-en-2, Help-replay-ko-1, Help-replay-ko-2 | Quick Play and time slider visible. DEMO Replay and acquisition off are explicit. Duplicate Stop Replay, DEBUG Dynamic Type text and scroll-under content remain open. The separate active-rate UI failure is not waived. |
| Help-sessions-en-1, Help-sessions-en-2, Help-sessions-en-3, Help-sessions-ko-1, Help-sessions-ko-2, Help-sessions-ko-3 | Saved-session picker, JSON export and Open Replay targets visible. Epoch-zero dates identify synthetic fixtures. Export delivery and session persistence require separate tests. |
| Help-setup-en-1, Help-setup-en-2, Help-setup-ko-1, Help-setup-ko-2 | Import and Start Live targets visible; no configured adapter and disabled actions are explicit. No permission prompt or error dialog is visible in these frames. This does not establish authorization or actual BLE discovery. |
| Help-signals-en-1, Help-signals-en-2, Help-signals-ko-1, Help-signals-ko-2 | Recorded diagnostic response, 53.0-percent fixture and unknown recorded freshness visible. STALE is the source-confirmed filter button, not a row-quality assertion. Its badge-like appearance is potentially ambiguous. Diagnostic bytes are not represented as passive raw CAN. |

All listed original PNG/JSON pairs reside in `mobile-ios/App/Resources/HelpScreenshots`. No retouching, invented marker position or changed source fingerprint was used to disguise a historical capture. Other Replay, maximum-text, landscape and physical scopes are not marked visually verified by this entry. Existing data, layouts, app version and acquisition behavior were not changed by this evidence refresh.

## REP-02 Actual Input Regression - 2026-11-17

Environment: owned iPhone17/iOS27.0 Simulator, Xcode27.0/27A266a, App0.22.5(21), synthetic fixture, device foreground via actual XCTest. The Mac foreground was not taken from another task. Source base6ec1376 plus `SessionsView.swift` SHA256 `dfd843b1db2fbb66494749eb92187e42e34f02ff74ddb4d0c0488feb11791eab`, with the existing export-audit fixture transform; no diagnostic rate hooks in the fixed runs.

| Directly Opened Image | Inspected State / Limits |
| --- | --- |
| [before-rate-stays-half](evidence/replay-rate-2026-11-17/before-rate-stays-half.png) | Actual failure video frame:0.5x remains selected during playback after the2x attempt; later frame also remained0.5x. Not a frozen position or a passing fast-rate selection. |
| [after-rate-two](evidence/replay-rate-2026-11-17/after-rate-two.png) | Actual third fixed-run attachment, active2x selected at21.0/600s, Pause visible, DEMO/acquisition off. Labels/control are readable. Header partly under navigation in this scrolled state; no whole-layout perfection claim. |
| [after-auto-end](evidence/replay-rate-2026-11-17/after-auto-end.png) | Actual fixed-run automatic5.0/5.0 end; Play disabled,2x retained, End reached text visible. Footer overlays scroll-under copy, not evaluated as whole-product layout acceptance. |
| [large-portrait](evidence/replay-rate-2026-11-17/large-portrait.png) | Accessibility5 audit, vertical controls and native segmented labels visible; zero-range0.0/0.0 fixture means playback is disabled. Huge text requires scrolling; this is not proof of populated large-text playback. |
| [large-landscape](evidence/replay-rate-2026-11-17/large-landscape.png) | Following landscape control frame directly opened, Go visible. Zero-range fixture and scroll-under caption remain explicit; no physical-device or all-viewport claim. |

Original capture metadata/digests: [capture.json](evidence/replay-rate-2026-11-17/capture.json). No raster retouching, cropping or invented values. Failure frames were extracted from the actual recording using AVAssetImageGenerator and retain requested/actual frame timestamps in private receipts.

Automated functional evidence is separate: original playback3/3, active slider1/1, large/landscape1/1 and Core474/474 passed. One separate Go-result attachment was black/unusable and is UNVERIFIED, not a visual PASS; three other generated menu states were not directly inspected. Shared Simulator pixels showed an active recording and remain private; that recording/device was not interrupted. Physical iPhone and vehicle UI were not inspected in this work.

Parent review: Standards and Spec checked against the single-control fix and captured verifier. Binding closures intentionally are not compared; model identity plus visible inputs prevent stale-owner reuse. The verifier preserves real wrong-value failures even when the Controller accepts them, rejects incomplete or uncorrelated captures and keeps checks active under Python-O. This was primary review, not an unperformed external-agent approval. Remaining source-media qualification and full-product gates are listed in [the report](reports/replay-rate-fix-2026-11-17.md).
