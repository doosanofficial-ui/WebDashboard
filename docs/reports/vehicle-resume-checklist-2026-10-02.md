# Next vehicle connection checklist

## Hold boundary

Vehicle/adapter connection and power are UNKNOWN after the user left the car on
2026-10-02. Additional physical tests are on USER-REQUESTED HOLD. Do not scan,
connect, poll a PID/DID, start passive monitoring, or start a vehicle endurance
test merely because the iPhone is connected to the Mac. Previously queued
questions about the live cluster/Car Scanner are deferred, not required now.

The last verified recordings ended normally; this does not assert current
device/radio/vehicle state. Preserve all original DB/CSV/JSON/xcresult records.

## Preserved baseline

- Physical build: 0.22.3 (19), source `910a8a7`; iPhone 17 / iOS 27.0.
- OBDII candidate: observed service FFF0, write FFF2, notify FFF1. Private
  peripheral ID/profile/GATT evidence is retained outside Git. This is an
  observed profile, not a guessed UUID or complete adapter capability claim.
- 17:46-17:47 capture: SOC 48.5%, raw 97 x 0.5, 14 diagnostic responses /
  14 signals / 49 GPS / 19 system events.
- 18:05-18:06 capture: SOC 46.5 -> 46.0%, raw 93 -> 92; same row counts.
- Mode01 bitmap B63FA813 supports RPM/vehicle speed but not coolant PID05.
  RPM replies were `[0,0]`; cluster photos show ~1,200 rpm without an aligned
  photo timestamp. The discrepancy is unresolved, not a decoder scaling fix.
- Preserved physical snapshot: 25 closed sessions / 6,586 rows; existing
  6,394 rows were retained. Full GPS/unmasked exports remain private.

## Fresh handoff, P0

- [ ] Re-confirm safely parked/P condition, vehicle awake state, iPhone 17
  availability, scanner plugged into the vehicle and actually powered.
- [ ] Stop other OBD-app connections; use Car Scanner and our app sequentially.
- [ ] Check the installed source/version/build and whether there is an active
  recording before any reinstall/relaunch. Back up newer data first.
- [ ] Install/launch the current verified build only after device-state check;
  user performs trust/unlock/Face ID prompts. Build/Install/Launch are separate.
- [ ] Confirm the observed peripheral/profile still identifies the intended
  scanner. If observation changed, inspect GATT again; do not reuse guessed IDs.

## Diagnostic checks, P1

- [ ] Capture Mode01 support bitmap once; disable unsupported coolant polling.
  Do not perform an ECU/PID/DID sweep to fill missing fields.
- [ ] Align cluster RPM with actual receive time; record ECU response CAN ID,
  service/PID, raw payload, independent `(A * 256 + B) / 4`, units and displayed
  cluster rounding. If still zero while the cluster is ~1,200, investigate the
  response/ECU/adapter path; never force a UI value to match the photo.
- [ ] Alternate Car Scanner HV battery SOC and our `22 0101`, with value/unit,
  condition/time and agreed tolerance. Do not compare 12V SOC/voltage instead.
- [ ] Re-confirm HV SOC response `7E4 -> 7EC`, source version, payload offset 4,
  raw byte/2. Record negative/malformed/no-data replies, not fake zero.
- [ ] Bind the same real signal to Numeric + Gauge + Bar/LED and save/reload
  the profile. Offline fixture UI is not physical widget validation.

## Complete session checks, P1

- [ ] Ten-minute real diagnostic + real GPS recording with app transition,
  reconnect, MARK, orderly Stop, native CSV/JSON file save and reload.
- [ ] Verify original -> decoded -> DB -> CSV -> Replay by sample ID/timestamps,
  source and quality. Replay must not start acquisition or append measurements.
- [ ] Measure actual per-query acquisition rate, success/timeout/error count,
  recorder loss and receive-to-UI latency independently. Prior SOC intervals
  were ~10 s, NOT 1 Hz or 10 Hz. Do not equate UI target rate with acquisition.
- [ ] Once stable, perform the one-hour physical endurance run once; memory,
  CPU, battery/thermal, disk growth, BLE continuity and GPS continuity. No
  screen-lock trial is required in the active scope.

## Separate gates

- [ ] Passive raw CAN: AT H1/CAF0/CSM1/MA capabilities and actual frame evidence,
  one configurable CAN ID/signal first. Do not combine AT MA with diagnostic
  queries or assume CAN FD support for ELM327.
- [ ] CarPlay category/entitlement/template/simulator/head-unit gates separately.
  iPhone compile and diagnostic SOC success do not approve CarPlay runtime.

Current physical resume gates: BLOCKED (USER-REQUESTED HOLD), not hardware PASS.
iPad/Android and screen lock remain OUT OF SCOPE; Vector/CANoe/CANape are optional
future paths. Software tasks can proceed without releasing the physical hold.

## Remaining offline tasks

- [ ] Continuous playback/seek and recorded graph/track timelines; current
  Replay restores an explicitly labelled final snapshot only.
- [ ] Larger-session streaming/pagination; current UI lists latest 100 sessions
  and snapshots/export reject over 200,000 rows rather than truncate.
- [ ] Persist profile/config/authorization/quality context for exact future
  reproduction; do not invent fields absent from existing physical records.
- [ ] Expand editor interaction, Dynamic Type and landscape UI coverage. The
  three-widget fixture check does not qualify every widget/editor operation.
