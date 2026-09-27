# CarPlay/iPhone Automotive UI Pattern Research

Checked: 2026-09-27. This is a research and design proposal only; no product
code is changed by this report.

## Method And Limits

The App Store does not expose reliable public download counts. The App Store
sample below therefore uses US storefront chart position and rating count as an
adoption proxy. Those values are a snapshot, not a global download ranking.
GitHub stars measure developer interest, not production quality or safety.

The benchmark separates three surfaces:

1. Popular CarPlay/navigation apps, which show glanceable interaction patterns.
2. OBD/telemetry apps, which show dashboard and trip patterns.
3. Open-source repositories, which show architecture and testability patterns.

## App Store Benchmarks

| Proxy order | App | Evidence snapshot | CarPlay/UI pattern | Relevance |
| --- | --- | --- | --- | --- |
| 1 | Google Maps | 7.3M ratings, Navigation chart #1 | Map, top action bar, add-stop flow, incident reports | Use map plus one primary action, not a dense control wall |
| 2 | Waze | 3.2M ratings, Navigation chart #3 | Split map/instructions, report action, search, categories, limited CarPlay surface | Strong model for state-dependent actions and split-screen hierarchy |
| 3 | PlugShare | 143K ratings, Navigation chart #44 | Map plus filters, station detail, reliability score, planned trips | Direct pattern for signal filters, source quality and route context |
| 4 | Apple Maps | 63K ratings; system baseline | Favorites, frequent destinations, incident reporting, CarPlay map | Use system-like navigation chrome and predictable map actions |
| 5 | Sygic | 57K ratings, Navigation chart #145 | Offline map, speed alerts, camera/route context, CarPlay | Supports an offline/stale-first design for weak connectivity |
| 6 | MapQuest | 29K ratings, Navigation chart #18 | Route alternatives, multipoint stops, layers, speedometer, incident reporting | Use a small set of contextual tools instead of permanent buttons |
| 7 | Car Scanner ELM OBD2 | 33K ratings | User-built dashboards, custom PIDs, gauges and charts | Closest phone-side reference for configurable telemetry pages |
| 8 | OBD Fusion | 19K ratings, Travel chart #4 | Custom dashboards, resizable gauges, graph rows/columns, map playback | Strong editor and logging reference; its CarPlay surface is list-only and explicitly does not show real-time gauges |
| 9 | A Better Routeplanner | 6.6K ratings, Navigation chart #122 | Vehicle profile, trip plan, charge stops, driving mode, continuous replanning | Use profile-aware sessions and a planned-versus-live view |
| 10 | HERE WeGo | 1.6K ratings, Navigation chart #183 | Offline regions, collections/shortcuts, route waypoints, CarPlay navigation | Use explicit offline readiness and saved profiles |
| 11 | Fuelio | 155 ratings | Simple fuel/cost log, charts, vehicle profiles, CarPlay fuel/station lookup | Use a low-friction session/history surface rather than burying exports in Settings |
| 12 | RevDash | Rating overview unavailable | Four CarPlay tabs: Vehicle, Diagnostics, Telemetry, Trips; locked-phone reconnect automation; trip auto-finalization | Best recent structural reference for this project, although adoption is not yet proven |

### App Store Sources

- [Google Maps App Store](https://apps.apple.com/us/app/google-maps/id585027354) and [Google Maps CarPlay help](https://support.google.com/maps/answer/9432062?hl=en)
- [Waze App Store](https://apps.apple.com/us/app/waze-navigation-live-traffic/id323229106) and [Waze CarPlay help](https://support.google.com/waze/answer/9123774?hl=en)
- [PlugShare App Store](https://apps.apple.com/us/app/plugshare-charging-stations/id421788217)
- [Apple Maps App Store](https://apps.apple.com/us/app/apple-maps/id915056765)
- [Sygic App Store](https://apps.apple.com/us/app/sygic-gps-navigation-maps/id585193266)
- [MapQuest App Store](https://apps.apple.com/us/app/mapquest-gps-navigation-maps/id316126557)
- [Car Scanner ELM OBD2 App Store](https://apps.apple.com/us/app/car-scanner-elm-obd2/id1259933623)
- [OBD Fusion App Store](https://apps.apple.com/us/app/obd-fusion/id650684932)
- [A Better Routeplanner App Store](https://apps.apple.com/us/app/a-better-routeplanner-abrp/id1490860521)
- [HERE WeGo App Store](https://apps.apple.com/us/app/here-wego-maps-navigation/id955837609)
- [Fuelio App Store](https://apps.apple.com/us/app/fuelio-mpg-mileage-tracker/id1487753318)
- [RevDash App Store](https://apps.apple.com/us/app/revdash/id6764164749)

## Open Source Benchmarks

| Repository | Stars snapshot | What is useful | What must not be copied blindly |
| --- | ---: | --- | --- |
| [flutter_carplay](https://github.com/oguzhnatly/flutter_carplay) | 318 | Dedicated plugin boundary between mobile UI and CarPlay scene | Flutter/plugin architecture is not a substitute for Apple entitlement approval |
| [carplay-cast](https://github.com/EthanArbuckle/carplay-cast) | 460 | Shows how much demand exists for richer CarPlay surfaces | Jailbreak/tweak approach is not App Store-compliant and is excluded from this project |
| [iOS-OBD-Example-App](https://github.com/HellaVentures/iOS-OBD-Example-App) | 80 | Wi-Fi ELM327 stream setup, protocol-specific parsing and test simulator assumptions | Old boilerplate, external API dependency, no evidence of production endurance |
| [Pelican sidecar](https://github.com/ClutchEngineering/sidecar.clutch.engineering) | 15 | Active automotive assistant content, privacy-oriented product framing and route/report concepts | Small public star count is not proof of adoption; inspect current product evidence before reuse |
| [carsurf](https://github.com/pavunato/carsurf) | 26 | Documents CarPlay pipeline experimentation | Bypass/tweak model is not a valid implementation path for this app |
| [Swift-UDS](https://github.com/geoffnix/Swift-UDS) | 11 | Hardware-agnostic protocol boundary and Swift Package structure | Repository explicitly warns that it is not battle-tested; do not use it as vehicle-safety evidence |
| [elmulator](https://github.com/qadanm/elmulator) | 2 | Scriptable BLE/TCP ELM327 emulator and CI scenarios | Low stars, so use as a test technique, not as an adoption benchmark |
| [NavOSS](https://github.com/yassinsolim/NavOSS) | 1 | Privacy-first navigation, MapLibre/Valhalla separation, documented CarPlay entitlement/release gates | Technical beta and low adoption; architecture reference only |

The open-source sample confirms an important boundary: popular CarPlay
repositories often demonstrate framework experiments or entitlement bypasses,
while the production-safe path remains Apple-managed templates and approved
capabilities.

## Common UI Patterns

### 1. State First

The strongest apps put connection, route/session, stale state and the next
available action above secondary metrics. For this project the first viewport
should always answer:

- Is the adapter/server connected?
- Is the CAN/GPS data fresh?
- Is recording active?
- What is the single most important signal now?

### 2. One Primary Action Per State

Navigation apps expose `Go`, `Add stop`, `Report` or `Stop` only when the action
is valid. The telemetry equivalent should expose `Connect`, `Start GPS`, `REC`,
`MARK` or `STOP` as a state machine, not as six equally prominent buttons.

### 3. Split Context, Not Split Attention

Waze and Google Maps use a large map with a compact instruction/action region.
OBD apps use a large primary gauge with a small set of secondary gauges. The
project should not render every configured widget at equal visual weight.

### 4. Customization On The Phone, Glanceability In The Car

Car Scanner and OBD Fusion make phone-side dashboards configurable. OBD Fusion
also explicitly limits its CarPlay surface and does not show its real-time
gauge pages there. This supports keeping the editor and dense charts on iPhone,
while exposing only approved, glanceable status on CarPlay.

### 5. Profiles And Sessions

ABRP, Fuelio and RevDash make vehicle/profile/session history first-class. The
telemetry app should make `Vehicle profile`, `Signal set`, `Recording session`
and `Trip replay` visible objects, not hidden files in Settings.

### 6. Recovery Is A Feature

RevDash highlights locked-phone reconnect and automatic trip finalization. HERE
WeGo highlights offline maps. For this project, stale data, reconnecting, an
interrupted SQLite session and pending upload count must be normal visible
states rather than silent errors.

### 7. Filters And Quality Signals

PlugShare exposes connector, speed, provider and amenities filters plus a
reliability score. The equivalent telemetry controls are signal groups, CAN ID,
source adapter, quality (`VALID/STALE/INVALID/DISCONNECTED`) and recording
health.

## Proposed Direction

### Option A: Cockpit + State Rail (Recommended)

Keep the current dark cockpit but restructure its hierarchy:

```text
┌ Connection / RTT / drops / GPS / REC state ┐
├ Primary signal: large value + unit + quality ┤
├ Four quick metrics: FL / FR / RL / RR       ┤
├ Dynamics: yaw + ay charts                    ┤
├ GPS/map card                                  ┤
└ MARK             REC/STOP             GPS     ┘
```

Phone tabs:

- `Live`: primary signal, four quick metrics, two charts, GPS, fixed action rail
- `Signals`: searchable signal catalog, CAN ID/raw frame, quality and timeout
- `Sessions`: REC history, interrupted-session recovery, export and replay
- `Setup`: server, adapter profile, BLE observation and permissions

The dashboard editor remains available from `Live`, but `Demo adapter` moves to
a developer/diagnostics section. Presets become `Drive`, `Dynamics`, `CAN Debug`
and `GPS Track` so operators do not start with an empty grid.

### Option B: Four-Tab Telematics

Use the RevDash-style structure directly: `Vehicle`, `Diagnostics`, `Telemetry`,
`Trips`. This is easier to explain to operators but hides the most important
connection/recording state behind tab changes. It is a good second-stage
information architecture, not the best first screen for a test engineer.

### Option C: CarPlay-First Status

Optimize only the status projection now and defer most phone UI changes. This
minimizes implementation risk but does not address the current phone dashboard
density, editor discoverability or session workflow. It is not recommended.

## Recommended Implementation Scope After Approval

### P0 Phone UI

- Replace the current equal-weight top stack with the state rail and primary signal hierarchy.
- Add a three-step first-run flow: `Connect → Start GPS → REC`.
- Keep `MARK` and `REC/STOP` in a fixed, large bottom action rail.
- Show `RTT`, `DROP`, `BAD`, GPS age and upload queue in one compact status component.
- Add preset dashboard profiles and move developer/demo controls out of the main path.
- Keep stale/disconnected values visible but never render them as valid numbers.

### P1 Session And Editor UX

- Add a `Sessions` tab with duration, frame count, GPS fix count, drop count, interruption state and export.
- Add signal search/filter by CAN ID, source, unit and quality.
- Add a dashboard inspector preview that shows the selected widget at phone and CarPlay-safe sizes.

### CarPlay Gate

Apple’s current documentation requires a category-specific managed entitlement;
the system renders prebuilt templates rather than arbitrary custom UI. Until
the correct entitlement is approved, do not add a guessed entitlement or claim
CarPlay app support.

After approval, the proposal is a status-only CarPlay surface:

- `Status`: adapter, recording, GPS and stale state
- `Session`: start/stop state, elapsed time, pending upload count
- `Alerts`: only high-priority configured conditions

Use the approved general-purpose template allowed by the category, likely a
list/information flow, and keep dense gauges/charts on iPhone. This follows
Apple’s guidance to provide high-value information in a clean layout that is
easy to scan from the driver’s seat.

## Approval Request

Recommended choice: **Option A, Cockpit + State Rail**, followed by the P0 phone
UI scope. No CarPlay entitlement or external dependency is added in that phase.

Approval boundary: reply `Option A 승인` to authorize the next design/implementation
step. Until then, this report is the proposed direction only.

## Primary References

- [Apple CarPlay HIG](https://developer.apple.com/design/human-interface-guidelines/carplay)
- [Apple CarPlay entitlement request](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [Apple CPTemplate](https://developer.apple.com/documentation/carplay/cptemplate)
- [Apple CPListTemplate](https://developer.apple.com/documentation/carplay/cplisttemplate)
- [Apple CPGridTemplate](https://developer.apple.com/documentation/carplay/cpgridtemplate)
- [Apple CPInformationTemplate](https://developer.apple.com/documentation/carplay/cpinformationtemplate)
- [Apple CarPlay developer portal](https://developer.apple.com/carplay/)
