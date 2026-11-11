# WrenchTime Integration Help Capture Review: 2026-11-12

## Scope and provenance

- Source commit: `d7f81d34b89e616d07cc64ec304d927c3f42f2e4`. All 60 App source inputs match exactly; no App or capture-test source adapter.
- Capture: iPhone 17 / iOS 27.0 (24A434), Xcode 27.0 (27A266a), app 0.22.5 (21), portrait, normal Dynamic Type, English/Korean, synthetic offline fixture. Captured November 12 KST (November 11 UTC).
- Run ID: `9F8FC502-2F92-4156-9A40-360DDABDEC22`; application bundle SHA-256 `0e95df104a23e147afbd7c3eb7b58b64d760b4f2e2bce5eb1514754e9d58e69d`.
- Automated result: 2 capture tests passed, 0 failures/skips. Producer-issued PNG/marker/source/product/XCTest receipts validated. Same products before and after capture; no relabeling of previous captures.
- Implementation reviewer directly opened all 28 original PNGs at readable scale before adopting them. Review finished: 2026-11-11T21:43:42.582906+00:00. Parent core review remains a separate gate.
- Previous resource files and full original capture results are preserved locally. A MobileCal system crash report from the owned Simulator was correlated with its original log; the error window was left untouched, and no report was sent by the agent. This is distinct from the successful Telemetry capture assertions.

## Direct pixel review

| Screen/state | Screenshot | Observations | Result | Parent core review |
|---|---|---|---|---|
| `Help-editor-en-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-editor-en-1.png) | Selected fixture card/resize handle, undo/done and collapsed configuration visible. Non-target action row can scroll horizontally. | PASS, scoped | Pending |
| `Help-editor-en-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-editor-en-2.png) | Selected fixture card/resize handle, undo/done and collapsed configuration visible. Non-target action row can scroll horizontally. | PASS, scoped | Pending |
| `Help-editor-ko-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-editor-ko-1.png) | Selected fixture card/resize handle, undo/done and collapsed configuration visible. Non-target action row can scroll horizontally. | PASS, scoped | Pending |
| `Help-editor-ko-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-editor-ko-2.png) | Selected fixture card/resize handle, undo/done and collapsed configuration visible. Non-target action row can scroll horizontally. | PASS, scoped | Pending |
| `Help-live-en-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-en-1.png) | Recording/MARK/GPS locators visible. No Sample distinct from zero; acquisition, recording and GPS off. | PASS, scoped | Pending |
| `Help-live-en-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-en-2.png) | Recording/MARK/GPS locators visible. No Sample distinct from zero; acquisition, recording and GPS off. | PASS, scoped | Pending |
| `Help-live-en-3` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-en-3.png) | Recording/MARK/GPS locators visible. No Sample distinct from zero; acquisition, recording and GPS off. | PASS, scoped | Pending |
| `Help-live-ko-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-ko-1.png) | Recording/MARK/GPS locators visible. No Sample distinct from zero; acquisition, recording and GPS off. | PASS, scoped | Pending |
| `Help-live-ko-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-ko-2.png) | Recording/MARK/GPS locators visible. No Sample distinct from zero; acquisition, recording and GPS off. | PASS, scoped | Pending |
| `Help-live-ko-3` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-live-ko-3.png) | Recording/MARK/GPS locators visible. No Sample distinct from zero; acquisition, recording and GPS off. | PASS, scoped | Pending |
| `Help-replay-en-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-replay-en-1.png) | Synthetic recording at 0/5 seconds, no current-window sample or complete playback/seek controls visible. Not an empty-recording or live-acquisition assertion. | PASS, scoped | Pending |
| `Help-replay-en-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-replay-en-2.png) | Synthetic recording at 0/5 seconds, no current-window sample or complete playback/seek controls visible. Not an empty-recording or live-acquisition assertion. | PASS, scoped | Pending |
| `Help-replay-ko-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-replay-ko-1.png) | Synthetic recording at 0/5 seconds, no current-window sample or complete playback/seek controls visible. Not an empty-recording or live-acquisition assertion. | PASS, scoped | Pending |
| `Help-replay-ko-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-replay-ko-2.png) | Synthetic recording at 0/5 seconds, no current-window sample or complete playback/seek controls visible. Not an empty-recording or live-acquisition assertion. | PASS, scoped | Pending |
| `Help-sessions-en-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-en-1.png) | Recording/MARK or JSON/CSV controls visible at target scroll position; selected synthetic closed session. No export/save success claimed. | PASS, scoped | Pending |
| `Help-sessions-en-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-en-2.png) | Recording/MARK or JSON/CSV controls visible at target scroll position; selected synthetic closed session. No export/save success claimed. | PASS, scoped | Pending |
| `Help-sessions-en-3` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-en-3.png) | Recording/MARK or JSON/CSV controls visible at target scroll position; selected synthetic closed session. No export/save success claimed. | PASS, scoped | Pending |
| `Help-sessions-ko-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-ko-1.png) | Recording/MARK or JSON/CSV controls visible at target scroll position; selected synthetic closed session. No export/save success claimed. | PASS, scoped | Pending |
| `Help-sessions-ko-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-ko-2.png) | Recording/MARK or JSON/CSV controls visible at target scroll position; selected synthetic closed session. No export/save success claimed. | PASS, scoped | Pending |
| `Help-sessions-ko-3` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-sessions-ko-3.png) | Recording/MARK or JSON/CSV controls visible at target scroll position; selected synthetic closed session. No export/save success claimed. | PASS, scoped | Pending |
| `Help-setup-en-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-setup-en-1.png) | Location settings/profile import and collapsed/expanded developer controls readable; Live Activity off. No profile/hardware success claimed. | PASS, scoped | Pending |
| `Help-setup-en-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-setup-en-2.png) | Location settings/profile import and collapsed/expanded developer controls readable; Live Activity off. No profile/hardware success claimed. | PASS, scoped | Pending |
| `Help-setup-ko-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-setup-ko-1.png) | Location settings/profile import and collapsed/expanded developer controls readable; Live Activity off. No profile/hardware success claimed. | PASS, scoped | Pending |
| `Help-setup-ko-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-setup-ko-2.png) | Location settings/profile import and collapsed/expanded developer controls readable; Live Activity off. No profile/hardware success claimed. | PASS, scoped | Pending |
| `Help-signals-en-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-signals-en-1.png) | DEMO Replay 53.0 percent, freshness unknown, read-only diagnostic HEX and receive-time caveat readable. | PASS, scoped | Pending |
| `Help-signals-en-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-signals-en-2.png) | DEMO Replay 53.0 percent, freshness unknown, read-only diagnostic HEX and receive-time caveat readable. | PASS, scoped | Pending |
| `Help-signals-ko-1` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-signals-ko-1.png) | DEMO Replay 53.0 percent, freshness unknown, read-only diagnostic HEX and receive-time caveat readable. | PASS, scoped | Pending |
| `Help-signals-ko-2` | [PNG](../../mobile-ios/App/Resources/HelpScreenshots/Help-signals-ko-2.png) | DEMO Replay 53.0 percent, freshness unknown, read-only diagnostic HEX and receive-time caveat readable. | PASS, scoped | Pending |

## Boundaries

- No unopened image among these 28. Targets are legible, without a Telemetry error/permission overlay in captured pixels. Some non-target body content passes under navigation/tab chrome at the chosen scroll position; this review does not assert that all content is visible simultaneously.
- Parent must directly open the core evidence before a user-facing UI-completion statement. This worker result alone does not close that gate.
- The 28 screenshots are help examples, not full user-flow, BLE/GPS, durable-recording, physical iPhone, CarPlay entitlement/head-unit or vehicle acceptance.
- Maximum text size, other devices/orientations, full button inventory and resource-updated bundle runtime remain separate, unverified checkpoints. No new Simulator test was launched after the instruction to leave system popups untouched.
