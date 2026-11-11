# WrenchTime public-behavior integration

Observed 2026-11-11. Source code, IPA internals, private APIs and artwork were not extracted. This is an independent implementation plan based on public product behavior, not a claim to reproduce vendor internals. Current baseline: native SwiftUI Telemetry on WebDashboard main, 4d782c2.

## Public behaviors and our existing capabilities

| Surface | Officially documented behavior | Existing Telemetry mapping | Gap / next validated slice |
| --- | --- | --- | --- |
| iPhone Live | Custom instrument pages, number/gauge/trend cards, warning bands | Dashboard pages, grid editor, thresholds, graphs, stale states already implemented | Vehicle-context display presets and grouped cards; avoid replacing existing editable layouts |
| Signals | Vehicle-specific standard/custom PIDs, service 01/21/22, scale/offset, preview before saving | Validated OBD query engine, explicit collection selection, support/availability evidence | App-local authoring and offline response preview first; formulas/catalog licensing separately |
| CarPlay | Per-vehicle tile ordering, gauge/graph/text; current/min/max/avg; display redraw and polling separated | Status projection and template bridge already present | Exact permitted entitlement/template remains unverified; no guessed capability or arbitrary canvas |
| Recorded trips | Recorded channels on scrubbable route replay | Durable SQLite sessions, exports, recorded cursor, signal comparison and energy estimates | Session labeling and summary convenience; automated trip detection is not substituted for explicit REC |
| Live Activity | Trip-linked configured metrics, ending summary and CarPlay small presentation | No ActivityKit extension in current project | Add extension/lifecycle separately; update pacing and background limitations must be tested |

Sources: [Live dashboard](https://wrenchtimeapp.com/car-dashboard-app-iphone/), [custom PID tutorial](https://wrenchtimeapp.com/tutorials/add-custom-obd2-pids/), [CarPlay](https://wrenchtimeapp.com/carplay-obd2-app/), [CarPlay setup](https://wrenchtimeapp.com/tutorials/set-up-carplay/), [trips](https://wrenchtimeapp.com/automatic-mileage-tracker/), [Live Activity](https://wrenchtimeapp.com/car-live-activity-iphone/).

These are vendor documentation claims, not measured runtime results. Public page content and search cache disagree about the default CarPlay redraw rate (2 versus 4 Hz); no fixed frequency is treated as an acceptance target. Redraw cadence is never an OBD sample-rate guarantee.

## Apple boundary

A full CarPlay app requires category eligibility, approved entitlement and the category's supported templates. WrenchTime's exact implementation is not public evidence of our app's permission. [Apple CarPlay](https://developer.apple.com/carplay/).

Apple documents that iOS 26 Live Activities can appear in CarPlay without a full CarPlay app, using the small activity family or compact fallback; the CarPlay presentation is non-interactive. This is a separately implementable path, not permission for continuous background acquisition. [WWDC25](https://developer.apple.com/videos/play/wwdc2025/216/), [ActivityKit lifecycle](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

## First slice: local custom PID

New definitions extend an existing diagnostic adapter profile without changing endpoint, transport, existing queries or raw definitions. Authoring, offline preview and Save never connect or query. Only typed read-only services are available. Numeric parsing rejects invalid/nonfinite input, blank required fields and malformed optional bounds. Headers and identifier text cannot inject ELM commands.

The editor is add-only to avoid flattening imported multi-signal definitions or their provenance. An existing passive CAN profile cannot silently become a polling profile. Save requires the same profile snapshot used when opening the sheet and an idle, non-recording, non-Replay state. Saved collection selections become stale after a profile revision and require explicit review. Dashboard bindings and recorded decoded samples reuse the existing engine; the offline sample preview never enters measurement history or support evidence.

## Remaining scope, not completed

- Formula expressions and independent per-surface inclusion controls.
- Verified, licensed catalog ingestion with origin/version and parked live test workflow.
- Vehicle-specific dashboard/CarPlay presets, grouped cards and session extrema.
- ActivityKit extension, authorization and start/update/end/recovery tests.
- Full CarPlay gauge rendering after entitlement/template verification.
- Physical adapter, actual vehicle and head-unit validation. Existing held vehicle tests remain held.

## Next slice: ActivityKit delivery path

Implement local-only, opt-in, REC-linked status and two finite optional metrics. No push server, token registration, App Group or guessed full CarPlay entitlement is required for this design. Add a Widget Extension (iOS 17 minimum), shared ActivityAttributes, `NSSupportsLiveActivities` in the app plist, and embedded extension. Start with `Activity.request(attributes:content:pushType: nil)` only after foreground REC succeeds; serially update/end and reconcile orphaned activities against authoritative session storage on relaunch. A failed activity request must not stop recording.

Gate `ActivityFamily`, `activityFamily` and `supplementalActivityFamilies([.small])` with iOS 18 availability. CarPlay Live Activity presentation begins in iOS 26 and is non-interactive. Keep an iOS 17 Lock Screen/Dynamic Island configuration fallback. Set a stale date and hide stale numeric values; a stale date does not end an activity or authorize background execution. User dismissal must not trigger recreation. Four-kilobyte payload and eight-hour lifetime limits apply. These are implementation requirements for a future slice, not completed code or runtime evidence.

Exact API boundary was checked against Apple's current documentation and installed Xcode 27/iPhoneOS 27 SDK Swift interfaces. Sources: [request](https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:)), [end](https://developer.apple.com/documentation/activitykit/activity/end(_:dismissalpolicy:)), [authorization](https://developer.apple.com/documentation/ActivityKit/ActivityAuthorizationInfo), [custom activity views](https://developer.apple.com/documentation/ActivityKit/creating-custom-views-for-live-activities), [extension setup](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension).

## Additional comparison: temporary adapter configuration

The [Custom PID tutorial](https://wrenchtimeapp.com/tutorials/add-custom-obd2-pids/) describes raw response plus decoded-value testing, no-response/decoding-error feedback, and cancellable catalog scans. The [6.5.1 changelog](https://wrenchtimeapp.com/en-gb/changelog/#6.5.1) describes temporary 11/29-bit adapter protocol switching and restoration, with grouped reads. These are vendor descriptions, not independently measured internals.

Our new authoring/preview flow is offline and does not change ELM state. Existing `OBDQuerySession` configures `AT SH` and `AT CRA` per query and closes/cancels on stop or transport recovery; it does not currently implement a temporary `AT SP` switch and restoration snapshot. Existing mock tests cover success, NO DATA, timeout, pending stop and stale-session restart isolation. Dedicated mixed-address protocol restoration tests were not found. This is a feature/verification boundary, not evidence of a vehicle defect. A future live-test/scan slice must separately verify restoration after success, cancellation, failure and disconnect before claiming parity.
