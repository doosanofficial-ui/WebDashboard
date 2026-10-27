# P2 Help source capture review — 2026-10-26

Reviewed UTC: 2026-10-26T19:41:07.526820+00:00. All 28 original XCTest PNGs were directly opened. Every numbered target, expected English/Korean label and synthetic state was readable and unobscured; no popup was observed. Review covers the numbered target and surrounding state within the existing scroll context.

Exactly two source-guide tests passed, failed/skipped/expected-failure 0, on iPhone17 Simulator DDD24F62-C420-4211-B607-D1B03EBF881B, iOS 27.0 (24A434), from 2026-10-26T19:29:01.505000+00:00 through 2026-10-26T19:32:07.942000+00:00.

Source: exact baseline 6b9ea6c439287172a0a19ac8202ae1190381b4e7 plus separately sealed ten-file P2 overlay f7a39a1397915ae8a5b7492271f845ac1cf690696ccccd4eb1633e9da8df7a14. No new committed SHA is claimed. Canonical 46 Help inputs and the capture-test hash match unchanged built products. Products SHA256: 315f0e4493aedf8815b3813a86e6c242e0a171d96b7b1517258c9ce82252166c. Source receipt SHA256: 4fb82c23a5157b66dedd1db9671898b39566c1151e7f09146eaeceaffafd1f28. Same-run ID: 62AA770C-C75F-455E-99FD-119547AAC372.

Xcode27.0/27A266a build-for-testing app/runner/xctest and xctestrun remained exact. The staged project changes two isolated bundle IDs; XcodeGen also emits two usage-description strings already specified by candidate project.yml. A separate receipt binds candidate/staged/product Info.plist hashes and values. Permission key sets/background modes are unchanged; these generated files are outside the canonical 46 Help inputs.

Only the new P2Help20261026 app and UITest runner were installed. Original app67/data11, existing HelpCapture app67 and five persistent files remained exact. One new OS-generated SplashBoard snapshot was added in the existing HelpCapture container; protected persistent files had no changes/removals and no restoration/deletion was performed. Full private Mac screens were directly inspected locally before, during and after execution; they are excluded from repository assets and external upload.

Synthetic fixture only; portrait/default Dynamic Type large. Replay at Start has zero visible samples before its first recorded timestamp; Signals at End shows recorded SOC53.0 with historical freshness unknown. Recording, GPS, BLE and vehicle acquisition were not started. No fresh Help-overlay, maximum-text, landscape, physical-device or live-radio result is claimed. The original captureCertified=false and visualReviewRequired=true contract fields are retained; direct inspection is recorded separately.

| Original screenshot | Numbered target | PNG SHA256 |
| --- | --- | --- |
| Help-editor-en-1 | resize-dashboard-widget-fixture-0 | `696e7581e78c7c90a63b7221cdda87d58a83f6ac979f51dabd85d3ea23206ce1` |
| Help-editor-en-2 | undo-dashboard-layout | `696e7581e78c7c90a63b7221cdda87d58a83f6ac979f51dabd85d3ea23206ce1` |
| Help-editor-ko-1 | resize-dashboard-widget-fixture-0 | `c01d6d1a5e7f1515be000414118796162770b83f65cbe3c5f85e803d3119db21` |
| Help-editor-ko-2 | undo-dashboard-layout | `c01d6d1a5e7f1515be000414118796162770b83f65cbe3c5f85e803d3119db21` |
| Help-live-en-1 | toggle-recording | `37a264caa6d2db36531df3ab96865de4da9884f2ba4e5c93af37233c31931024` |
| Help-live-en-2 | toggle-gps | `37a264caa6d2db36531df3ab96865de4da9884f2ba4e5c93af37233c31931024` |
| Help-live-en-3 | mark-event | `37a264caa6d2db36531df3ab96865de4da9884f2ba4e5c93af37233c31931024` |
| Help-live-ko-1 | toggle-recording | `dd126d24eb959d5b3e22566c75297fdeb109b31a6acb4b0fb61b4d8874da41b4` |
| Help-live-ko-2 | toggle-gps | `dd126d24eb959d5b3e22566c75297fdeb109b31a6acb4b0fb61b4d8874da41b4` |
| Help-live-ko-3 | mark-event | `dd126d24eb959d5b3e22566c75297fdeb109b31a6acb4b0fb61b4d8874da41b4` |
| Help-replay-en-1 | session-replay-play | `5a1bd93e39a0f3059760a4c8ed08a116285a6af05bc3cd95286b8324ff5bf21a` |
| Help-replay-en-2 | replay-time-slider | `f29c0678004225fedba40e49606ea3c6dfb496968a4bda750f5e2b766e676016` |
| Help-replay-ko-1 | session-replay-play | `54f5616d35877ddaa13986d9b6a507264ef02a4e0d457637e3cba815de01f686` |
| Help-replay-ko-2 | replay-time-slider | `042be473cc59f8cece5c3578b1689a24b4a9f0b6cfad943fc4589d25551743e6` |
| Help-sessions-en-1 | saved-session-picker | `307b6ca78b2b4910823b3045a78a034b0d1e1aa33c4b096d715340ec135192b0` |
| Help-sessions-en-2 | sessions-export-json | `1029381c0cf42d88e92f927b41301588d58a1d5306ac70bcf4e740f936d59724` |
| Help-sessions-en-3 | replay-saved-session | `2fd5cc30a514ba7eb9839e9ecabb9aeec68484f548c8bc9c64330ca8b8b12e52` |
| Help-sessions-ko-1 | saved-session-picker | `3182c4cd9f1488cfd3721f974f87b0a94ecf8994d1c378687cb5d99980e4356e` |
| Help-sessions-ko-2 | sessions-export-json | `c4e1b8f79814cd2187d00e6a8c3d3ddca0e7dfcbe826488f9bdb1e655ecb6910` |
| Help-sessions-ko-3 | replay-saved-session | `af0a8faa05763e857c89e7d645306ca5da57364227601c3230d5ddd2ff2c5c9e` |
| Help-setup-en-1 | import-adapter-profile | `f49b5adef83e7534d2caa0e9d9ecf656e4cd554f2b9c0d26100a8900d775b5d8` |
| Help-setup-en-2 | start-live-adapter | `8ca299428a71264c10f331779e3c287b1a8b3f6e27a5b2dc4e0991d4c853072c` |
| Help-setup-ko-1 | import-adapter-profile | `3862365971093f45e48f6d670a66a07812cb009961a88fb824f89ff49ac48f2e` |
| Help-setup-ko-2 | start-live-adapter | `4b632380a68dcf3e57e5ce78be9df62f224ea4365f721923a49886b4d76dc029` |
| Help-signals-en-1 | raw-can-content | `c6fb6567728983c7317284e5ebae3930704d5378d46beea4f9b731af3bcd01fc` |
| Help-signals-en-2 | signals-stale-filter | `c6fb6567728983c7317284e5ebae3930704d5378d46beea4f9b731af3bcd01fc` |
| Help-signals-ko-1 | raw-can-content | `8637b9311aab265fc87ce717c51b7b1d69153f59f7156cd48a2c602d03592c2d` |
| Help-signals-ko-2 | signals-stale-filter | `8637b9311aab265fc87ce717c51b7b1d69153f59f7156cd48a2c602d03592c2d` |
