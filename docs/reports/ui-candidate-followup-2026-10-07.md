# UI candidate follow-up and early SE boot evidence

This record covers three presentation fixes and a bounded observation change on canonical `main`. Baseline: `2e27ad472f75cb35eb53032e47b7f166cf2fd3ea`. The commit containing this record publishes the measured source inputs below. The retained baseline failures remain failures; later successful tests do not change their receipts.

English maximum-text Help previously wrapped “Previous” over two lines and measured 139.33pt versus “Next” 77.33pt. The labels now retain their natural size, and a vertical fallback fits them when a horizontal row cannot. The SE editor page title previously clipped internally despite a large button frame. A wrapping Menu label now shows the selected title while retaining the same inner Picker binding and tags. At accessibility text sizes, recording/GPS information previously became disabled native Menu actions. It now opens a read-only Sheet with the same model values and an explicit Done button. Recording actions and persistence logic are unchanged.

## Source and capture provenance

All local captures use synthetic offline fixtures on newly created, individually owned Simulators, Xcode27.0 build27A266a / iOS27.0 build24A434. Vehicle data and physical-device captures are excluded. Captures span measured implementation stages: Help and the original native Menu were captured before the later Sheet change; final SE/Replay captures include all five current UI inputs. Each embedded figure contains its capture-stage source hashes, UUID, observation time, PNG SHA256 and direct inspection record. The later guide capture helper change is separate from the retained candidate captures: its content nav+8 / Tabbar-8 assertion prevents numbered targets from being hidden by floating chrome, while actual navigation-bar descendants such as Undo remain valid inside the toolbar.

| Source | SHA256 |
| --- | --- |
| `mobile-ios/App/AppHelpView.swift` | `982585c9ddcaffe654258bd10b9a0a9571ac319017d86a91edb1d6595fd4e1cf` |
| `mobile-ios/App/DashboardEditorView.swift` | `ba2f508691702b02c944d553ebe4956dcce83c65d3ffcb79dd10ff4096afce0f` |
| `mobile-ios/App/LiveCockpitView.swift` | `092d3a2331c8352a1bd82a002523a5992cc74a54a5d3f006a658be08a10851d0` |
| `mobile-ios/UITests/LocalizationHelpUITests.swift` | `a195771de8f7a46cd57aa292390674140ba9326834844aba03acccd360361b17` |
| `mobile-ios/UITests/SmallViewportStatusUIRegression.swift` | `e5e65d591c2a5d67c2e2abeda09ad82bab977eb1762ef0bdd767a14c5fe838f9` |

## Directly inspected core screens

The [same Library review report](https://chatgpt.com/api/library/files/libfile_618900d5356081919fd960623331262b/download) preserves original PNG1–34 and adds original, unmodified core images35–40. `/root` opened every cited PNG directly. The parent reported direct inspection of version17 images21–33; the newly added core images await its inspection.

| Screen/state | Core image | Capture and direct review | Findings/result | Parent new core review |
| --- | --- | --- | --- | --- |
| Help before | 35 / `8B3A7B8F-E57F-4A2A-9DDC-2A85D5036D5F.png` | iPhone17, en AX5 portrait; `/root`,20:46UTC | FAIL: Previous wraps and is139.33pt tall | Pending |
| Help after | 36 / `53F0BD18-368A-4AED-8A0B-4E634EECA917.png` | iPhone17, en AX5 portrait; `/root`,20:58UTC | PASS for first-page labels: single line, equal77.33pt, first Previous intentionally disabled | Pending |
| Status native Menu before | 37 / `3A0484F6-ABB0-45DB-8C22-23FF4E11ECFA.png` | SE3, en AX5 portrait; `/root`,20:58UTC | FAIL readability: gray disabled informational actions; not all rows simultaneously visible | Pending |
| Status Sheet after | 38 / `55700A88-A2F2-4AE2-B699-240721C17A15.png` | SE3, en AX5 portrait; `/root`,21:20UTC | PASS for four normal staticText rows, fully readable, explicit Done; long navbar title still ellipsized | Pending |
| Editor selected page after | 39 / `5F18462A-D6FC-479E-8BC2-20C45DB28EE7.png` | SE3, en AX5 portrait; `/root`,21:20UTC | PASS: both selected-title lines visible at125.5pt;1pt allowance covers fractional UIKit metric estimate | Pending |
| Replay after keyboard Go | 40 / `C6FCEB9A-1C0D-4EAA-B949-C7514EB31B8A.png` | iPhone17, en AX5 portrait; `/root`,21:20UTC | PASS: actual2.0/5.0 recorded seconds after restoring offscreen analysis into view | Pending |

The full companion preserves24 directly inspected before/after PNGs, including two original RED captures and two after-Go frames with unverified upper black capture regions. Extra diagnostic attachments not individually opened are excluded from visual PASS claims.

## Functional verification and limits

The narrow English Help height regression passed. Final temporary diagnostics passed SE2/2 and Replay1/1, with zero failures or skips. Own Simulator cleanup and Dashboard profile/exact-byte preservation passed for both groups. The earlier same-page Picker selection/Undo regression also passed and did not change the stored profile. The original fractional-height FAIL remains recorded; the tolerance changes only the measurement proxy, not the product font or padding.

Replay application source was not changed. A Lazy stack can omit offscreen analysis from the accessibility tree; bringing it into view confirmed the actual2.0/5.0 result after tapping Go. Go is visible above the keyboard and in landscape. The separate keyboard Return fallback was not executed. Two immediate/5-second after-Go captures have an unexplained black upper region and remain UNVERIFIED; later analysis and landscape pixels are clear.

The Sheet audit ran while presented and retained one contrast issue with no attributable element. The long inline navigation title still ellipsizes. The landscape Replay audit reported zero issues only for its visible state. These observations do not establish complete accessibility conformance. The already completed12-state baseline Help candidate diagnosis was not repeated; language/orientation-wide post-fix evidence is separate automatic CI evidence.

Bundled guide capture refresh and complete script-contract results are recorded in the source manifest and publication evidence. The source guard initially rejected stale bundled guide provenance after the UI changes; the original two failing contract receipts are retained. New capture imports preserve actual PNG bytes and marker positions. The first refreshed two language suites passed functional assertions, but direct inspection found four Setup targets partially under the Tab bar (805/809pt versus791pt). Those captures and AX failures are retained. A bounded capture-helper correction requires the whole target to clear navigation and Tab chrome before capturing; later guide receipts are separate. The first content-only correction incorrectly treated Undo as body content and failed both tests; its repeated swipes changed only that newly created synthetic Dashboard, so that attempt also failed preservation. Those actual failures and source inputs remain retained. The final helper identifies navigation descendants explicitly and does not need those swipes. No user or physical-device Dashboard was touched.

The final corrected capture ran both English and Korean guide tests successfully, with zero failures or skips, on own iPhone17 UUID `84FFF0E8-5D46-4837-B095-CE730786A692`. Dashboard profile and exact-byte preservation and Simulator/collector cleanup passed. `/root` directly opened all28 selected PNGs: every numbered target is visible, including the four formerly obscured Setup buttons. This is a target-specific portrait/default-text guide check. Scrolled/offscreen content, the existing Korean Replay “End” and Sessions “NOT COLLECTING” text, and whole-app localization remain outside this PASS scope.

## SE bootstrap observation

`scripts/owned_simulator_boot_log.py` requests a UUID-filtered stream before boot without waiting for subscriber readiness. It bounds input at240seconds/2MiB, validates UUID membership again in parsed event messages, and closes its own pipe before terminating and reaping its own process group. It records unresolved cleanup explicitly. The runner preserves primary boot errors even if Simulator or observer cleanup also fails. Existing boot60 / bootstatus180 / App build600 / UI1200 / Simulator cleanup60 budgets are unchanged.

The actual local SE bootstrap observation used own UUID `765191D5-5D0B-44B3-8F73-E06C2618856E`: boot and bootstatus passed, bootstatus28.502/180seconds, and Simulator/collector cleanup passed. The saved NDJSON contains1,231 valid own-UUID events and no foreign/invalid events. The2MiB input limit was reached about5.29seconds after request, so later boot log coverage is UNVERIFIED. This improves early evidence collection; it does not prove the root cause or stability of the separate remote SE boot failure. The remote SE two-test result must be assessed separately from the31-test aggregate and this local bootstrap.

## Completion boundary

- Automated local candidate results cover the stated narrow paths; direct visual results cover the individually opened original PNGs.
- Parent inspection of the new core35–40 remains pending. Entire UI, complete accessibility and physical-device acceptance are not claimed.
- Unrelated user file44 byte hashes remain unchanged; keystore bytes were excluded from access.
- No connected iPhone install, deletion, authentication, provisioning renewal, vehicle control, foreign Simulator operation or CI rerun was performed. The physical install pause and unknown vehicle10-minute trial completion remain in effect.
- Native remote SE stability and provider/guest root cause remain separate evidence gates. The new collector's input cap means absence of a later event does not prove that the later phase did not occur.
