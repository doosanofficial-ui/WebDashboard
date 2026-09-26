# CarPlay Open-Source Benchmark

Checked: 2026-09-26. This is a source and metadata survey for architecture
selection. GitHub stars and README claims are discovery signals, not proof of
vehicle compatibility, App Review approval, or production reliability.

## Scope and method

The survey covered public repositories discoverable through GitHub repository
search for Swift, React Native, Expo, and CarPlay, then inspected the repository
README, scene/entitlement code, license metadata, and recent source activity.
The snapshot was taken on 2026-09-26. Repositories that bypass Apple security,
require jailbreaks, spoof entitlements, or target prohibited media projection
were excluded from implementation benchmarking.

## Candidates

| Repository | Stars / forks | License | What was verified in source | Decision |
| --- | ---: | --- | --- | --- |
| [birkir/react-native-carplay](https://github.com/birkir/react-native-carplay) | 807 / 134 | MIT | React Native wrapper, iOS Scenes, typed template objects, example app, imperative root/push/pop API, explicit note that templates are not continuously declarative | Reference only; do not add to the native app |
| [dpearson2699/swift-ios-skills](https://github.com/dpearson2699/swift-ios-skills/tree/main/skills/carplay) | 1,144 / 59 | No SPDX license in API metadata | CarPlay skill covering category entitlements, scene manifest, template limits, dashboard/instrument-cluster boundaries, and simulator workflow | Reference guidance only; not a runtime dependency |
| [googlemaps/react-native-navigation-sdk](https://github.com/googlemaps/react-native-navigation-sdk) | 226 / 38 | Apache-2.0 | Vendor SDK wrapper documents Apple CarPlay/Android Auto navigation support | Not suitable for generic CAN telemetry; adds Google navigation/API obligations |
| [aws-samples/aws-serverless-fullstack-swift-apple-carplay-example](https://github.com/aws-samples/aws-serverless-fullstack-swift-apple-carplay-example) | 134 / 12 | MIT-0 | Swift CarPlay sample with location, cloud data, and a simulator runbook | Architecture reference only; AWS backend is unnecessary for local telemetry |
| [Iternio-Planning-AB/react-native-auto-play](https://github.com/Iternio-Planning-AB/react-native-auto-play) | 65 / 21 | MIT | Typed cross-platform template lifecycle, scene render-state events, safe-area handling, and warnings about template identity/cleanup | Reference for lifecycle/error handling; current app stays native |
| [hansemannn/iOS12-CarPlay-Example](https://github.com/hansemannn/iOS12-CarPlay-Example) | 53 / 14 | MIT | Small native CarPlay example | Useful baseline, but old OS/API surface |
| [bradford-tech/expo-carplay](https://github.com/bradford-tech/expo-carplay) | 0 / 1 | MIT | Active navigation-focused Expo module; config plugin writes scene manifest and entitlement; README says additional templates are incomplete | Not mature enough and wrong runtime stack |
| [shinyorg/kmlrecorder](https://github.com/shinyorg/kmlrecorder) | 2 / 0 | MIT | GPS recorder with actual `CarPlaySceneDelegate`, grid Start/Stop template, map variant, refresh timer, and Driving Task/Maps entitlement setup | Closest product-domain reference; port patterns, not code/dependency |
| [kevinvperry/Autohop](https://github.com/kevinvperry/Autohop) | 1 / 1 | MIT | Documents an approved CarPlay Audio entitlement and generated XcodeGen entitlement wiring | Useful approval/release evidence; Audio category is not applicable |
| [paulw11/CPHelloWorld](https://github.com/paulw11/CPHelloWorld) | 5 / 1 | Not declared | Minimal native sample for scene/template wiring | Smoke-test baseline only |

The counts above came from the GitHub REST repository metadata at the check
time. `pushed_at` and the repository source were inspected separately because a
recent issue/README update does not prove a recent runtime implementation.

## Patterns worth adopting

### 1. Keep the CarPlay boundary native and template-driven

The strongest common pattern is a native `CPTemplateApplicationSceneDelegate`
that owns the `CPInterfaceController`, constructs the root template on connect,
updates only supported template data, and releases scene-owned state on
disconnect. This matches the current Swift boundary in:

- `mobile-ios/App/CarPlay/CarPlaySceneDelegate.swift`
- `mobile-ios/App/CarPlay/CarPlayProjectionBridge.swift`

The bridge should remain a projection of typed state. It must not expose the
SwiftUI dashboard, raw 10 Hz frame stream, or arbitrary layout editor to
CarPlay.

### 2. Use a scene-owned session, not a global template cache

The Iternio and Expo examples make template identity, lifecycle, and disconnect
cleanup explicit. The app should treat a CarPlay connection as a short-lived
scene session and invalidate stale handlers/templates after disconnect. This is
particularly important before adding reconnect or multiple head-unit tests.

### 3. Keep entitlement and scene manifest changes behind the approval gate

The Expo plugin and KML Recorder show the mechanical shape of adding the scene
manifest and entitlement, but they do so only for a category they are eligible
to use. This project is a telemetry/measurement app, so it must not copy a Maps,
Audio, or Driving Task key merely because a repository uses it. The exact Apple
assigned capability remains the source of truth.

### 4. Treat CarPlay as glanceable state, not a second dashboard

The open-source libraries converge on fixed system templates. The most relevant
safe surface for this product is a compact status list or information template:
adapter state, recording state, profile, elapsed time, and one or two primary
values. High-frequency gauges, raw CAN, graph scrolling, and editing belong on
the phone/iPad screen.

## Patterns explicitly rejected

- [pavunato/carsurf](https://github.com/pavunato/carsurf), CarBridge-style
  projects, CarPlayUnleashed, CarTube, and similar projects are not valid
  product dependencies. They bypass or spoof platform admission, rely on
  jailbreak/private behavior, or target arbitrary app/media projection.
- GPL-licensed CarPlay samples are not adopted into this internal/commercial
  codebase without a separate legal review.
- A high star count is not treated as a verified report that a NANICAR BT4N,
  Santa Fe MX5 HEV, iPhone 17/iOS 27, and this app work together.

## Current frontend audit

The existing `mobile-ios/App/DashboardView.swift` is functional but visually
generic and expensive to evolve:

- One 535-line view owns navigation, 100 ms refresh, dashboard layout, every
  widget renderer, charts, GPS, MARK, and connection settings.
- Repeated system-grouped backgrounds and 16 pt rounded cards flatten the visual
  hierarchy; the primary driving value is not visually dominant.
- The root `TimelineView` invalidates the entire scroll hierarchy every 100 ms,
  including settings-like content and all cards.
- Typography and color are mostly inline modifiers instead of a small set of
  cockpit tokens, so the design cannot be tuned consistently for night driving,
  warning states, or iPad landscape.
- The current profile editor is valuable and should be retained, but the live
  screen should render the same profile through a more deliberate responsive
  cockpit shell.

## Recommended implementation

Do not add a CarPlay React Native/Expo dependency. Keep the native SwiftUI app
and implement the following bounded redesign:

1. Add `TelemetryTheme.swift` with semantic tokens for cockpit background,
   surface, elevated surface, cyan telemetry accent, valid green, warning amber,
   critical red, and monospaced measurement typography.
2. Split the live screen into focused views: connection strip, primary metric,
   wheel-speed rail, dynamics chart cards, GPS/location card, session action bar,
   and profile widget canvas. Each view receives only the model data it reads.
3. Use an adaptive two-column iPhone landscape/iPad layout and a single-column
   iPhone portrait layout. Preserve existing profile page selection and editor
   entry points.
4. Make `MARK` a persistent high-contrast action in the session bar, not a
   low-priority card at the bottom of a long scroll.
5. Give charts a dark, high-contrast plotting surface, current-value labels,
   fixed 60-second domain, and visible stale state. Keep the data cadence and
   recorder unchanged.
6. Keep CarPlay status-only and system-template based. Reuse the same typed
   projection state but do not reuse the SwiftUI visual components.

No external UI library is needed. This preserves licensing, reduces build risk,
and makes the visual refresh testable in the existing iOS simulator.

## Acceptance criteria for the redesign

- The app builds with the current Xcode 26.3/iOS 26.2 simulator SDK.
- Core tests remain green and the existing demo adapter/recorder flow is intact.
- Direct simulator smoke shows a clear live/STALE status, dominant primary value,
  wheel/dynamics/GPS grouping, and a reachable MARK action without scrolling
  through the entire page.
- Portrait and landscape/iPad layouts do not clip the primary controls.
- 10 Hz telemetry updates do not require rebuilding settings/editor content.
- Accessibility labels and identifiers for connect, start GPS, MARK, editor, and
  stale/valid state remain available.
- No CarPlay entitlement key is invented or added before Apple approval.
