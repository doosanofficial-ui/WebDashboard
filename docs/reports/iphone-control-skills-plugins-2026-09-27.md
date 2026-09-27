# iPhone Control Skills and Plugins Review

Checked: 2026-09-27
Repository baseline: `main` at `f990a64`
Product scope: iPhone/iOS 27 native app, BLE/ELM327, Vehicle CAN, Recording, CarPlay

## Executive Decision

No additional iPhone-control plugin should be installed for the current workflow. The strongest available path is:

```text
Simulator UI:
ios-debugger-agent + XcodeBuildMCP
        |
Physical iPhone:
build_device.sh + verify_device.sh + xcrun devicectl
        |
Physical screen/touch:
Apple Xcode Device Hub or human handoff
```

The current Codex XcodeBuildMCP exposure provides Simulator interaction, but does not expose a physical-device tap/type/screenshot tool in this session. `devicectl` provides reliable physical build/install/launch/process evidence, not arbitrary UI input.

## Available Skills

| Skill | Version/path | Capability | Decision |
| --- | --- | --- | --- |
| `build-ios-apps:ios-debugger-agent` | `build-ios-apps/0.1.2` | Simulator build/run, UI snapshot, tap, type, gesture, screenshot, logs, LLDB | Use for Simulator UI automation |
| `build-ios-apps:ios-simulator-browser` | `build-ios-apps/0.1.2` | Mirrors a running Simulator in the Codex browser | Use only for browser-visible Simulator proof |
| `build-ios-apps:ios-ettrace-performance` | `build-ios-apps/0.1.2` | Simulator ETTrace performance capture | Use for CAN-to-UI latency/performance profiling after runtime flow exists |
| `build-ios-apps:ios-memgraph-leaks` | `build-ios-apps/0.1.2` | Simulator memgraph/leak analysis | Use for endurance/leak investigation, not device touch control |
| `build-ios-apps:ios-app-intents` | `build-ios-apps/0.1.2` | Shortcuts/Siri/system actions | Optional; not a physical device controller |
| `build-ios-apps:swiftui-*` | `build-ios-apps/0.1.2` | SwiftUI implementation, refactor, performance, Liquid Glass | Code/UI work only; not device control |

## Callable Tool Inventory

The current XcodeBuildMCP tool inventory includes `build_run_sim`, `snapshot_ui`, `tap`, `type_text`, `gesture`, `screenshot`, `wait_for_ui`, `test_sim`, log/debug tools, and Simulator lifecycle tools. It does not expose `build_device`, `install_device`, physical-device screenshot, or physical-device UI tap/type operations in this session.

The repository physical path is explicit and working:

- `mobile-ios/scripts/build_device.sh`: XcodeGen, signed iPhone build.
- `mobile-ios/scripts/verify_device.sh`: `devicectl` install, launch, and process evidence.
- `scripts/ios-bt4n-preflight.sh`: SDK/device/BT4N preflight.

The repository UI automation target is `mobile-ios/UITests/TelemetryUITests.swift`. It is suitable for Simulator/XCUITest flows, but a green build or test runner is not physical iPhone interaction evidence.

## Plugin Directory Search

Plugin searches for `iOS device automation`, `Xcode Simulator`, `Appium`, `Maestro`, and `XCUITest` returned no dedicated iPhone-control connector. `Remote Desktop Commander` was the only adjacent result; it is not installed and its description targets an authorized computer's filesystem/terminal, not a native iPhone control channel. Installing it would add a remote-computer transport but would not solve physical iPhone UI automation in this workflow.

The local binaries `appium`, `maestro`, `ios-deploy`, `idb`, `pymobiledevice3`, and `idevice_id` are not installed. `xcodebuild` and `xcrun` are available.

## Capability Matrix

| Operation | Simulator | Physical iPhone | Current result |
| --- | --- | --- | --- |
| Build | XcodeBuildMCP / `xcodebuild` | `build_device.sh` / `xcodebuild` | PASS |
| Install | XcodeBuildMCP / `simctl` | `verify_device.sh` / `devicectl` | PASS |
| Launch | XcodeBuildMCP / `simctl` | `verify_device.sh` / `devicectl` | PASS |
| Screenshot | XcodeBuildMCP / `simctl` | Xcode Device Hub only in current supported path | Simulator PASS; physical unavailable through current MCP |
| Tap/type/gesture | XcodeBuildMCP / XCUITest | Xcode Device Hub or human | Simulator available; physical handoff required |
| UI assertions | `TelemetryUITests.swift` / XCUIAutomation | XCUITest may run on a device, but runner/device service must be healthy | Current physical runner is not proven |
| GPS permission/location | Simulator controls or XCUITest | Human permission + Core Location | Physical NOT TESTED |
| BLE GATT/ELM327 | Mock/fixture only | iPhone + BT4N hardware | PHYSICAL HARDWARE REQUIRED |
| Vehicle CAN | Mock/demo only | Vehicle + ELM327 | PHYSICAL HARDWARE REQUIRED |

## Official Apple Boundary

Apple documents Simulator and physical devices as separate run destinations and states that Simulator does not reproduce all physical hardware behavior:

- [Running apps on simulated or physical devices](https://developer.apple.com/documentation/Xcode/running-your-app-on-simulated-or-physical-devices)
- [Interacting with apps in Device Hub](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-the-ios-or-ipados-simulator)
- [XCTest and XCUIAutomation](https://developer.apple.com/documentation/XCUIAutomation)
- [XCTest](https://developer.apple.com/documentation/xctest)
- [Apple development process](https://developer.apple.com/documentation/technologyoverviews/development-process)

Apple Device Hub is the official Mac-side route for viewing and interacting with a physical device screen. The current Codex XcodeBuildMCP configuration has not exposed that physical Device Hub interaction surface, so this project must keep physical touch actions as a human handoff until that capability is enabled.

## Recommendation For This Project

1. Keep `ios-debugger-agent` + XcodeBuildMCP for Simulator regression and UI proof.
2. Keep the existing `devicectl` scripts for physical build/install/launch proof.
3. Use Xcode Device Hub manually for physical GPS/REC taps and screen-lock testing.
4. Do not install Remote Desktop Commander, Appium, Maestro, or another plugin solely for this gate; none is currently connected or required for the verified paths.
5. Do not claim physical GPS, BT4N, raw CAN, or CarPlay runtime success from Simulator tooling.
