# Status UI screenshots and accessibility state

Base: `01f72e487f350af69d63ec1cee1b5dc41fc5a5ec` on canonical `main`.
Change: `mobile-ios/UITests/SmallViewportStatusUIRegression.swift` only, plus this evidence record. App and Done implementation, runtime budgets, UI selectors and CI partitions are unchanged.

## Confirmed test defect

The old maximum-text test captured an expanded-help screenshot, then an AX attachment, then queried two element frames later. A local PASS therefore did not establish that the captured help text was unobscured.

A test-only diagnostic reproduced that timing mismatch on iPhone17/iOS27.0 build24A434, Xcode27.0 build27A266a. Within a0.494s PNG-before → one immutable AX snapshot → PNG-after interval, the first image concealed “last edit.” behind the first card and the second showed it. The intermediate snapshot already had explanation.maxY618.333/card.minY618.887, satisfying the former inequality. A subsequent0.458s bracket had byte-identical PNGs, the whole sentence visible, and a6pt gap. This is a confirmed evidence-timing defect; persistent settled occlusion was not reproduced.

The added same-state assertion failed against the changing bracket: one real UI test executed, one expected failure, zero skips. Original xcresult bytes, its analysis-copy summary, PNGs and per-capture uptime receipts were retained. This RED failure is distinct from the original remote activation-point failure.

## Corrected verification

- After Done, wait for the actual Done and status-scroll elements to disappear before the original Edit hittability query and tap. State checks, diagnostic capture and waiter share the original5s deadline; late returned capture or hittability is rejected.
- For expanded help, use the existing5s interval to admit a PNG-before → single AX snapshot → PNG-after bracket with identical nonempty PNG bytes. Retain every changing attempt rather than treating it as visual PASS.
- Read the unique real explanation and editor card from that same snapshot; require finite, nonempty frames and compare those immutable frames. A stable overlapping bracket fails immediately and is never retried.
- Keep original selector, actual hittability/tap, Editor arrival, page-label sizing and no-layout-edit checks. Snapshot errors, missing/duplicate nodes and missing evidence cannot become PASS.

## Validation and provenance

Final UITest SHA256: `8f511cc1add6ae0a749b7c55e514cbc20db5b54b265f5a98137f861e46d1861f`.

- Independent read-only review: Critical0/Important0. Fixed review finding: a timeout0 waiter could otherwise admit a success after its shared deadline.
- Final iPhone17/iOS27.0 named regression:1PASS/0FAIL/0SKIP; owned Simulator shutdown/delete success. Directly opened all6 coherent PNGs; stable help shows the whole sentence and6pt gap.
- Final iPhoneSE3/iOS27.0 named regression: 1PASS/0FAIL/0SKIP; owned Simulator shutdown/delete success. Directly opened all6 coherent PNGs; whole expanded explanation is visible and the immutable AX gap is6pt.
- Whole runner suite:95 tests passed in10.748s. Platform documentation validation passed.
- User mobile files44 and App source inputs60 matched their preserved hashes; keystore bytes were not read. Only newly created own Simulator UUIDs were used; no physical installation or Teams operation.

Local evidence directory: `layout-coherent-evidence-20261007/` in the delegated workspace. It preserves original/instrumented/RED sources, per-trial source hashes, environment/command/summary/cleanup, exact failure bundle manifest, capture receipts and raw PNGs. These are synthetic fixture captures, not vehicle or hardware validation. The local runs re-execute one named selector across devices; they are not31 unique acceptance tests.

## Remaining limits

The original remote Layout activation-point error has not been reproduced locally, including before this final test correction. The new modal condition is a state precondition and diagnostic guard, not proof of that remote root cause. Original remote failure remains preserved; the new committed SHA must be assessed from its own automatic CI results. Help bootstrap failure remains a separate unresolved issue; no failed CI rerun or timeout extension was requested.

Public screenshot and snapshot APIs are not atomic. Matching PNGs conservatively bracket the observed state but cannot guarantee there was no intervening transient. Snapshot calls have no timeout argument; returned evidence is checked against the deadline, without claiming a native call can be forcibly bounded at5s. A whole-image mismatch caused by a clock tick is evidence instability, not proof of product overlap. Nonfinite AX numbers may fail JSON serialization before attachment; such errors are never accepted as PASS. Other unopened screenshots and physical UI remain unverified.
