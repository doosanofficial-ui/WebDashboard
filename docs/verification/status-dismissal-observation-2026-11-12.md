# Status dismissal: separate UI readiness from diagnostic collection

## New failure, distinct from the layout group timeout

At `79877247ae926eb24f98b8a4560a4a1f6df003ab`, [layout job 130815235338](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43106642732/job/130815235338) executed all 12 selected tests: 11 passed and one failed. The xcodebuild phase exited 65 after 995.932 seconds, with `timedOut=false`. This is not the previous 1800-second group timeout. [Original artifact 13898079944](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43106642732/artifacts/13898079944).

The first assertion was `SmallViewportStatusUIRegression.swift:38`: “Dismissal capture exceeded the original 5-second deadline.” Both Done and status-scroll nonexistence checks had completed. The subsequent screenshot/immutable-AX-snapshot/screenshot collection consumed 2.042410 seconds. The remaining budget was then zero, so the test stopped before its first Edit hittability query. The help-expanded frame assertions were not reached.

This run used iPhone 17, iOS 27.0 (24A434), Xcode 27.0 (27A266a), portrait, maximum accessibility text and English UI. “SE” in a capture name does not change the actual device into an SE.

## Direct observation

The implementation reviewer and independent reviewer opened the original before-Done image and both after-Done bracket images:

- `A520E84A-23FB-4E30-95F1-CE8C97400C7C.png`: status sheet, Done, Recording off/GPS off/No mark visible.
- `1C63BE10-59E6-4DB8-982D-B25CA1BD8E0E.png` and `F9B1E4F0-94A0-4F4E-A155-3AB22A0AF2A6.png`: sheet absent, Live screen and top Edit icon visible, no error popup. The two PNGs are identical.
- AX interval receipt `FE26E627-02A8-44A3-9528-B9D1FC1E3FFD.json` contains enabled Edit at `[344.333, 66, 37.667, 36]`. Enabled and visible are not evidence of hittability within five seconds.

The large secondary Edit label wraps as “Edi / t” at this maximum size. That is a separate presentation observation, not the cause of this assertion. The screenshots and original artifact remain unchanged. No local app or Simulator was launched for this review.

## Minimal correction

The same original five-second deadline now covers Done/scroll disappearance, the first immediate Edit hittability query, any required remaining-time polling, and the query return-time verdict. Late or unsuccessful UI observations still fail. The code logs the observed readiness time and unchanged deadline.

Only after that verdict is fixed does the test collect the same two screenshots and immutable AX snapshot. The capture name now says `after-done-after-hit-query`. Diagnostics cannot delay the first query or turn a failed/late UI result into success. Their bytes and interval remain actual evidence of the later observed state, not retroactive proof of earlier hittability. The coherent help-expanded snapshot and its separate five-second deadline are unchanged. No App/Core source, product behavior, assertion inventory, CI command budget or retry policy changed.

## Verification and limits

A new host regression compiles and executes the actual extracted caller with deterministic clock and AX/XCTest doubles. It first failed against the old order. It then passed with 2.8 seconds of disappearance observation, 0.4 seconds of successful Edit query and 2.042410 seconds of subsequent diagnostic cost. Late disappearance, late hittability, never-ready Edit and still-presented status remain failing cases.

The fake assertions collect failures rather than aborting execution, so this harness proves failure classification and ordering, not XCTest's `continueAfterFailure=false` unwinding, native polling or real device timing. An independent read-only review found no weakened deadline or failure-overwrite path. Fresh exact-SHA CI must still verify actual Edit readiness and the later help-frame assertions. Earlier captures do not certify this new runtime path.

Local full native contracts passed 492/492 with no failures, errors, skips or deferrals. Xcode 27 generic Simulator build-for-testing passed without boot/install/launch. Existing Help 60-input/same-run evidence, platform documentation and whitespace gates passed. These checks do not substitute for the pending actual UI run.
