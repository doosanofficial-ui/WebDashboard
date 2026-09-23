# OBD Ecosystem Research: BT4N / Santa Fe MX5 HEV

Checked: 2026-09-23. Scope: primary project repositories, public first-person issues,
Pelican's scanner/vehicle pages, and the actual LICENSE files. This is a targeted
comparison, not an exhaustive audit of all OBD projects or a physical vehicle test.
No commercial subscription, adapter purchase or third-party ECU command was executed.

## Conclusion

Reuse credible protocol/transport knowledge and verified vehicle data, but do not
select a library on stars alone. **No candidate examined establishes the exact
NANICAR BT4N + domestic MX5 HEV + iOS 27 combination with plentiful verified reviews.**
This user requirement remains a qualification gate, not a box marked complete.

- iOS: evaluate **LTSupportAutomotive** first for real adapter/production-app history,
  and **SwiftOBD2** for its Swift interface. Neither is approved as a runtime dependency yet.
- Windows: **python-OBD** is a serial/COM reference and conditional bridge candidate;
  it does not automatically supply a BLE GATT transport.
- Android: **AndrOBD** provides the strongest relevant community compatibility thread
  in this sample, but Android success cannot certify the iPhone path.
- Vehicle data: **OBDb/Hyundai-Santa-Fe-Hybrid** is directly relevant despite few stars.
  Use reviewed, year-specific definitions and fixtures, not blind import of all OEM PIDs.
- **ELM327-emulator is not an unrestricted open-source dependency**: its LICENSE
  has a NonCommercial condition. Keep it out of this commercial/internal product's
  dependency/test rollout until authorized licensing review establishes permitted use.

## Repository comparison

Stars are exact GitHub REST values at inspection, not rounded search snippets.
[Metadata snapshot](evidence/obd-2026-09-23/github-metadata.json).
Commit dates below refer to the default branch, not the repository's `pushed_at`:
a push to another branch does not establish a new default-branch release.

| Repository | Stars | License observed | Last default-branch commit | Suitable role / decision |
|---|---:|---|---|---|
| [AndrOBD](https://github.com/fr3ts0n/AndrOBD) | 2,098 | GPL-3.0 | 2026-09-22 | Android reference app; no iOS substitution |
| [python-OBD](https://github.com/brendan-w/python-OBD) | 1,313 | GPL-2.0 | 2025-04-07 | Windows serial candidate; licensing and BLE boundary review |
| [ELMduino](https://github.com/PowerBroker2/ELMduino) | 936 | MIT | 2025-05-20 | Embedded scheduling/protocol reference; not an iOS SDK |
| [ELM327-emulator](https://github.com/Ircama/ELM327-emulator) | 677 | CC BY-NC-SA 4.0 in LICENSE | 2026-09-17 | Source-available test reference; adoption held |
| [LTSupportAutomotive](https://github.com/mickeyl/LTSupportAutomotive) | 254 | MIT | 2023-06-14 | iOS/macOS BLE/stream evaluation candidate; also inspect SPM branch |
| [obd2-swift-lib](https://github.com/lemberg/obd2-swift-lib) | 163 | MIT | 2017-11-02 | Legacy reference only; no default adoption |
| [SwiftOBD2](https://github.com/kkonteh97/SwiftOBD2) | 159 | MIT | 2025-10-21 | Modern Swift candidate; reconnect regression gate required |
| [Hyundai-Santa-Fe-Hybrid](https://github.com/OBDb/Hyundai-Santa-Fe-Hybrid) | 3 | CC BY-SA 4.0 | 2026-09-23 | Vehicle definitions and fixtures; runtime library not provided |

License labels classify the source, not permission to ignore attribution, share-alike
or copyleft obligations. Review the intended distribution and modified files before
copying/bundling. GitHub marks the emulator license `NOASSERTION`; inspection of
[the actual LICENSE](https://github.com/Ircama/ELM327-emulator/blob/dd3b1d2b19368875830ea8c86cea070040c26caf/LICENSE)
revealed the NC condition. Do not treat “public GitHub” as unrestricted commercial use.

Search coverage also included high-star ELM327 results such as resource directories,
Renault-oriented ddt4all, and embedded gauges. Lists of links, ECU coding tools and
unrelated hardware are not substitutes for a tested iOS read-only transport.

## What “real operation” evidence actually exists

### AndrOBD: specific reports, mixed outcomes

[Issue 187](https://github.com/fr3ts0n/AndrOBD/issues/187) contains 13 comments from 8 accounts at inspection,
covering named vehicles, adapters and OS versions. This is not 13 independent successes.
Examples include positive OBDLink MX/Android 11 reports, Hyundai i10/i30 reports,
and failed or intermittent connections. A 2026 Vgate iCar Pro BT4.0 report distinguishes
Classic and BLE performance. A separate 2026 hybrid/USB report says no information
was displayed. These are first-person community reports, not our reproduced tests.
The published [V2.7.10 release](https://github.com/fr3ts0n/AndrOBD/releases/tag/V2.7.10)
is dated 2026-07-06.

### python-OBD: actual transport matters

[Issue 149](https://github.com/brendan-w/python-OBD/issues/149) records Bluetooth stalls
on a Raspberry Pi, a wired adapter operating for over 30 minutes, and recovery after
changing the host. It is useful failure/recovery evidence, not a BT4N endorsement.
The [implementation](https://github.com/brendan-w/python-OBD/blob/a378bdd81d58c67d08050e4244173a9a7dbda73d/obd/elm327.py)
uses serial ports. A dual-mode sticker does not mean Windows will expose a suitable COM
port. Its [v0.7.3 release](https://github.com/brendan-w/python-OBD/releases/tag/v0.7.3)
is dated 2025-04-07. Do not adopt README timeout workarounds as a blanket throughput guarantee.

### ELMduino: useful scheduler model, no rate safety guarantee

The [README](https://github.com/PowerBroker2/ELMduino) documents nonblocking, one-PID-at-a-time
operation. However [issue 286](https://github.com/PowerBroker2/ELMduino/issues/286)
reports vehicle warning lights/idle disturbance with a cheap Wi-Fi adapter; replies
state the library does not itself enforce a query-rate cap. This report is not an
independently established root cause or a universal OBD Hz limit. Retain our bounded
rate and stop-on-fault requirements. [Issue 291](https://github.com/PowerBroker2/ELMduino/issues/291)
also distinguishes Bluetooth connection failures from ELM initialization. Embedded
success must not be extrapolated to iOS Core Bluetooth.

### iOS candidates: working reports do not remove open defects

[LTSupportAutomotive](https://github.com/mickeyl/LTSupportAutomotive) documents maintainer-tested
BLE/MFi/Wi-Fi/USB adapters, two applications using it and a BLE-to-stream bridge.
It is in bugfix-only mode; public UDS support is not its stated path. These are
maintainer claims, not a large independent review cohort. Its
[LELink initialization report](https://github.com/mickeyl/LTSupportAutomotive/issues/40)
and [MX+ report](https://github.com/mickeyl/LTSupportAutomotive/issues/52) are required
reading before choosing its transport. No listed BT4N test was found.
The [SPM branch](https://github.com/mickeyl/LTSupportAutomotive/commit/909c42a803e74d7e941add4ba31201948a117259)
has a 2024-03-31 head, distinct from master. An open
[PID 06 decoding report](https://github.com/mickeyl/LTSupportAutomotive/issues/48)
also belongs in candidate regression tests. Older apps named by its author do not
establish current iOS 27 compatibility; current App Store review counts for those
apps were not verified during this inspection.

SwiftOBD2 has two user confirmations after a header-selection change in
[issue 18](https://github.com/kkonteh97/SwiftOBD2/issues/18), including a BMW test context.
But [issue 41](https://github.com/kkonteh97/SwiftOBD2/issues/41) remains open at inspection,
reporting accumulated state and reconnect failures in an iOS production app.
Treat it as a reported defect to reproduce at the pinned candidate commit, not proof
every current build is broken. README quick-start values and promised demos are not
physical test evidence. Its `value ?? 0` display example must not be adopted in this
project's unknown-value path.

The older lemberg library has an unresolved
[BLE integration question](https://github.com/lemberg/obd2-swift-lib/issues/14) describing
the need for an external transport, and a [Swift 5 compatibility report](https://github.com/lemberg/obd2-swift-lib/issues/22).
Its larger star count than SwiftOBD2 does not make it the safer modern iOS choice.

## Pelican: useful product evidence, not a reusable scanner implementation

The supplied [scanning page](https://pelican.clutch.engineering/scanning/) names tested
adapters and publishes ELMCheck command/PID rates. For example it reports up to 34/s
for Vgate iCar Pro BT4.0 and 17/s for Veepeak BLE. These are that publisher's benchmark
results, not our vehicle-specific rates, and not 10Hz for every PID. BT4N is not named
in its tested list; a generic ELM327 entry must not be treated as the same hardware.
The page has affiliate links and a paid boundary for scanning beyond five minutes.

We verified a public PID data source, not an open-source release of the Pelican app:
its [extended PID guide](https://pelican.clutch.engineering/scanning/extended-pids/)
links OBDb and identifies CC BY-SA 4.0 data licensing.

[ELMCheck's US App Store page](https://apps.apple.com/us/app/elmcheck/id6479630442)
showed 5.0 from **one rating** when inspected. That is not “many verified reviews”.
The vendor describes broad ELM command tests; do not automatically run its entire
test suite against the user's vehicle before reviewing command side effects.
Any purchase/subscription is a separate user decision. Basic identification and
our allowlisted Mode 01 reads are the initial on-vehicle scope.

## Santa Fe data: more useful than stars, still needs validation

[Pelican's Santa Fe Hybrid page](https://pelican.clutch.engineering/cars/hyundai/santa-fe-hybrid/)
shows 8 drivers and 11,483 miles. This is a publisher aggregate, not independent
test logs proving a particular Korean MX5 model year, BT4N unit or iOS 27 build.

The linked OBDb repository at
[31a2292](https://github.com/OBDb/Hyundai-Santa-Fe-Hybrid/tree/31a22927796e146f4e7e6d71477d8dd78afccca7/tests/test_cases)
contains test files grouped under 2021, 2022, 2023, 2024 and 2025.
Counts are 45/1/48/13/39 files, including command-support files: **not numbers of
drivers, independent reviews or successful vehicles**. The model-generation file
overlaps 2023, reinforcing the need for exact year/region/profile validation.

Important unresolved reports at inspection:

- [2025 tire pressure mismatch, issue 21](https://github.com/OBDb/Hyundai-Santa-Fe-Hybrid/issues/21):
  front-left reads while other corners are missing/wrong.
- [2021 state-of-health zero, issue 13](https://github.com/OBDb/Hyundai-Santa-Fe-Hybrid/issues/13):
  zero is questioned rather than accepted as a healthy measurement.
- [SOH/energy mapping, issue 7](https://github.com/OBDb/Hyundai-Santa-Fe-Hybrid/issues/7):
  offsets/meaning are disputed.

Do not import these suspect definitions as verified. Do not assume a corrected
fixture or closed issue proves all generations. Our first Mode 01 scope stays
separate from OEM Mode 22 definitions and multi-frame transport.

## Adoption gates and next actions

1. Preserve source, version, license and public reports independently from our tests.
   Higher stars rank discovery candidates; they cannot override missing hardware evidence.
2. For a production transport, seek several independent, reproducible reports naming
   adapter, vehicle, OS and version. Where absent, mark evidence insufficient instead
   of quietly lowering the user's requirement or counting comments as successes.
3. Compare LTSupportAutomotive and SwiftOBD2 at pinned commits in an isolated evaluation,
   with our read-only allowlist, unknown/zero semantics and reconnect cases. Do not
   integrate an entire diagnostics API or its DTC-clearing functions.
4. Test BT4N discovery on iPhone 17/iOS 27; record actual GATT properties and allowed
   responses. Validate supported PIDs on the stationary MX5 HEV before live graphs.
5. Only then qualify vehicle-specific data and 30-minute background collection.
   External reports remain supplementary; they do not replace our physical evidence.

The initial in-house codec is a small, tested boundary and comparison fixture, not
an assertion that a new scanner stack is more mature than these projects. No reviewed
third-party runtime has been installed or declared compatible in this checkpoint.
