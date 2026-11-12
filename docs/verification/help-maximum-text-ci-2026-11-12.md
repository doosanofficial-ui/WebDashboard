# Maximum-text Help: exact-SHA CI evidence and limits

## English

At `974df6c5d918f5b7148cd63e46a7e7328f67dfa6`, [English maximum-text job 130856331641](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43118930515/job/130856331641) passed one test with zero failures/skips. Test process 1085.824 seconds, exit 0, no timeout or termination. [Artifact 13908191707](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43118930515/artifacts/13908191707) ZIP SHA256 is `2566429321e783832a77bdea089ef8184921638e4e58cb11dcbe515b6b7013a6`, matching GitHub. All 50 seed source-input hashes match that commit; this is a source receipt, not a separately hashed app binary.

Environment: iPhone 17, iOS 27.0/24A434, Xcode 27A266a, Accessibility XXXL, synthetic offline fixture. It does not establish SE, physical-device, vehicle, BLE, GPS or CarPlay behavior.

An independent reviewer directly opened all 26 original captures. All 14 numbered steps across six guides show the whole numbered image and callout above the fixed footer. Previous/Next labels fit on one line. Twelve first/last-step landscape zoom flows show the slider and Done; successful continuation establishes closure, without a separate post-close image. Middle Live and Sessions steps are not part of the zoom/close coverage.

The implementation reviewer directly opened these core originals:

- `FD5F1533-4CBE-4FFA-8772-4CF63330B974.png`: setup numbered image.
- `44BBE95D-C96F-45B2-A973-D7DD48864241.png`: middle Sessions image and abbreviated navigation title.
- `0091D6E6-F35C-4472-A2F2-C411CB77E3E6.png`: final editor image and disabled Next.
- `B617570F-90B7-4E98-84D2-50AC50F138A6.png`: landscape zoom, truncated label and visible Done.

Residual limits: the landscape “Screenshot zoom” label and Sessions navigation title truncate at maximum text. Enlarged captures show the upper-left clock rather than the numbered target, so zoom panning and target readability are not visually verified. Thumbnail fine text is small; body text and enlarge hints can extend beneath navigation chrome at the image-focused scroll position. Reverse Previous traversal, all body-text scroll positions and middle-step zoom remain unverified. No error or permission dialog is visible in these captures. No local Simulator or desktop UI interaction occurred during artifact review.

## Korean failure, kept separate

The [Korean job 130856331626](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43118930515/job/130856331626) at the same SHA did not pass. [Artifact 13910110538](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/43118930515/artifacts/13910110538) ZIP SHA256 `9626df5784e72ff66c3921e1e46799e1481fc021df481443bc0e9a5442ab0f5f` and all 50 seed source inputs were verified. Build exited 0. The test command began 02:06:45.157548 UTC and reached its unchanged 1200-second deadline at 02:26:45.712862; TERM was sent and the process exited -15. No XCTest assertion failure was recorded before the timeout, and no completed test summary exists.

After Sessions step 1 zoom closed and portrait rotation began, XCTest repeatedly waited 60 seconds for animation completion. Native diagnostics report an idle event loop but `animationsHaveFinished NO`. Controls remained queryable and the test reached Sessions step 2. This establishes animation-quiescence waiting as the immediate mechanism consuming the budget, not the underlying source of the unfinished animation. The English same-SHA flow crossed that boundary without these stalls. This difference does not prove a localization or geometry defect.

Both reviewers directly opened `simulator-bootstrap-screen.png`. Its receipt proves the misleadingly named image was captured after timeout, 02:26:58.055898–02:26:59.200854 UTC. It shows Korean Sessions step 2 text, intact Previous/Next controls and no dialog. The numbered image is still below the viewport. Native frame evidence at 02:26:10.814 gives image `{{131,1972},{140,304.3333}}`, navbar bottom 116 and footer top 681.6667. The image is smaller than the available 565.6667-point viewport; an impossible-fit condition is not established.

The 15 preceding attachment-name log entries are not usable pixel evidence. The incomplete xcresult contains only five text diagnostics, no image payloads; summary/attachment export failed. Therefore the exact onset frame and preceding numbered/zoom states remain uninspected. Raising deadlines, disabling animation synchronization or changing product layout speculatively is not justified. A bounded dismissal/restoration observation before rotation is a possible future diagnostic trial, not a verified repair. The subsequent aggregate failure reflects failed groups and is not another independent app defect.
