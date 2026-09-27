# CarPlay Simulator and Account Gates

Checked: 2026-09-26. Branch: `codex/native-telemetry-productization`.
This is an execution checkpoint, not proof of CarPlay entitlement approval or
physical-vehicle support.

## Observed on this Mac

- Xcode 26.3 (`17C519`)
- iOS Simulator SDK 26.2
- Booted simulator: iPhone 17 Pro, iOS 26.2,
  `5BDA4708-2F38-4018-A3A9-023C7DC661A2`
- Physical target: iPhone 17 (`iPhone18,3`), iOS 27.0
- The installed Xcode has no iOS 27 SDK. The iOS 27 device support files are
  present, but that is not equivalent to an iOS 27 SDK or build result.

## CarPlay simulator result

The CarPlay external display is available in the installed Simulator:

1. Boot an available iOS simulator.
2. Open `I/O` in the Simulator menu.
3. Select `External Displays`.
4. Select `CarPlay`.

The CarPlay window opened and displayed the default CarPlay home screen. This
proves only that the host can launch the external display. Apple documents that
the app needs the applicable CarPlay entitlements before it can appear in the
CarPlay simulator. The simulator does not replace vehicle/aftermarket testing
and does not cover every lock-screen, Siri, audio, or vehicle integration path.

Official reference: [Using the CarPlay Simulator](https://developer.apple.com/documentation/carplay/using-the-carplay-simulator).

## Current app boundary

The repository contains a compile-gated, status-only projection:

- `mobile-ios/App/CarPlay/CarPlaySceneDelegate.swift`
- `mobile-ios/App/CarPlay/CarPlayProjectionBridge.swift`
- `mobile-ios/App/CarPlay/CarPlayProjection.swift`
- `mobile-ios/TelemetryCore/Sources/TelemetryCore/CarPlayProjection.swift`

The target currently does **not** contain a fabricated `com.apple.developer.carplay-*`
entitlement or a CarPlay scene manifest. Therefore:

- A successful iPhone build proves Swift compilation only.
- The default CarPlay home screen proves the simulator display only.
- CarPlay app launch/rendering remains `NOT RUN` until Apple assigns an applicable
  entitlement and the approved scene configuration is added.
- The iPhone dashboard and data logger remain usable without CarPlay approval.

The first CarPlay surface remains a glanceable status list: adapter state,
recording state, active profile, elapsed session, and a small number of primary
values. High-frequency gauges, raw CAN hex, editing, and arbitrary layouts stay
on the iPhone/iPad UI unless Apple explicitly permits a different category and
template set.

## Account and license gates

| Gate | Needed for | Owner/action | Status |
| --- | --- | --- | --- |
| Apple Account signed into Xcode | Local simulator work and account discovery | User signs in to Xcode Settings > Apple Accounts | Pending account browser handoff |
| Xcode and SDK license acceptance | Local Xcode build tooling | Accept Xcode license on the Mac if prompted | Verify on this host |
| Apple Developer Program membership | Physical-device provisioning, TestFlight, Ad Hoc, and team signing | Account Holder enrolls/renews; paid terms must be accepted by the user | Unverified |
| Registered App ID | Stable signing identity for the Telemetry target | Account Holder or Certificates/Identifiers role registers the final bundle ID | Not verified |
| CarPlay managed capability request | CarPlay app entitlement | Account Holder submits the category-appropriate request | Not submitted |
| Entitlement approval and App ID enablement | Signed CarPlay build and simulator app appearance | Apple review, then team enables the granted capability | Not granted |
| Development certificate/device profile | Install on the physical iPhone 17 | Xcode automatic signing or team member with signing access | Blocked: no valid signing identity observed |

Apple's managed-capability process requires the Account Holder for an
organization. The documented path is:

1. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list).
2. Open the final App ID.
3. Open `Capability Requests`.
4. Select the capability that Apple exposes for the app's eligible category.
5. Submit the request and retain the request status/read-back.
6. After approval, enable the capability on the App ID and configure the Xcode
   target using the entitlement Apple assigned.

Official references:

- [Requesting CarPlay Entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [Capability Requests](https://developer.apple.com/help/account/capabilities/capability-requests)
- [Running on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
- [Apple Developer Program enrollment](https://developer.apple.com/programs/enroll/)

## Application execution plan

The agent can inspect the logged-in team, existing App IDs, available capability
request entries, and request status. The user must perform or confirm:

- Apple Account password, passkey, MFA, or biometric steps.
- Paid Developer Program enrollment or renewal and acceptance of paid terms.
- Any final legal/eligibility declaration or final capability-request submit
  action shown by Apple's portal.

After the account handoff is complete, the next evidence must include the team
identifier, the final App ID, the capability request status, and any Apple
response. Secrets, session cookies, private keys, and device codes must not be
recorded in the repository.

## Exit criteria for this gate

- [x] CarPlay external display opens on the current simulator host.
- [x] The app remains buildable without a guessed entitlement.
- [ ] Apple Developer team and membership status verified.
- [ ] Final App ID registered and matched to the production bundle identifier.
- [ ] Eligible CarPlay category confirmed by Apple documentation/portal.
- [ ] CarPlay capability request submitted by Account Holder.
- [ ] Capability approved and enabled on the App ID.
- [ ] Approved scene manifest and entitlement added to the target.
- [ ] App appears in the CarPlay simulator with status-only UI.
- [ ] Physical iPhone 17/iOS 27 signed install and CarPlay vehicle/head-unit test.
