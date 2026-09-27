# SwiftUI Cockpit Dashboard Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the generic native dashboard shell with an adaptive, glanceable cockpit UI while preserving the existing CAN/GPS/recording and dashboard-profile contracts.

**Architecture:** Keep `TelemetryModel`, `TelemetryCore`, Charts, and the status-only CarPlay bridge unchanged. Extract the SwiftUI live screen into small views with a shared visual token layer, and limit the 100 ms timeline dependency to the live telemetry subtree instead of the entire navigation/settings shell.

**Tech Stack:** SwiftUI, Swift Charts, Observation, iOS 17 deployment target, existing XcodeGen project.

**Spec:** `docs/reports/carplay-open-source-benchmark-2026-09-26.md`

## Global Constraints

- Do not add a React Native/Expo CarPlay dependency.
- Do not invent or add a CarPlay entitlement before Apple approval.
- Preserve existing dashboard profile pages, editor entry, MARK, GPS, adapter, and accessibility identifiers.
- Preserve 10 Hz telemetry data and 60-second chart buffers.
- Do not modify unrelated user-owned changes under `mobile/`.
- Use semantic colors and Dynamic Type-compatible system font styles; avoid Liquid Glass-specific APIs.

## Review Focus

- Stale/disconnected CAN data must remain visually distinct from valid data.
- A missing GPS fix must not render as a valid zero coordinate.
- MARK and Start/Stop GPS must remain reachable in portrait and landscape layouts.
- A saved dashboard profile with custom pages/widgets must still render and open the editor.
- 10 Hz updates must not rebuild the Connection settings form on every tick.

### Task 1: Lock the UI contract and theme primitives

**Files:**
- Create: `mobile-ios/App/TelemetryTheme.swift`
- Modify: `mobile-ios/UITests/TelemetryUITests.swift`

**Interfaces:**
- Produces `TelemetryTheme` colors, spacing, radii, and `TelemetryStatusBadge` style used by later views.
- Preserves identifiers `mark-event`, `edit-dashboard`, `local-recording-status`, `start-adapter-demo`, `server-url`, and `connect-server`.

- [ ] **Step 1: Add UI smoke assertions for the new cockpit anchors**

  Assert that `live-status-strip`, `primary-metric`, `session-mark`, and
  `location-card` exist after launch while retaining the current tests.

- [ ] **Step 2: Run the targeted UI test and record the expected failure**

  Run the existing simulator test command with the active simulator. Expected:
  the new identifiers are absent before implementation.

- [ ] **Step 3: Implement theme primitives**

  Add semantic dark/navy surfaces, cyan telemetry accent, valid/warning/critical
  colors, four-point spacing constants, and reusable status badge modifiers.

- [ ] **Step 4: Build the app target**

  Run `mobile-ios/scripts/verify.sh build`. Expected: compile success.

### Task 2: Extract the live cockpit screen

**Files:**
- Modify: `mobile-ios/App/DashboardView.swift`
- Create: `mobile-ios/App/LiveCockpitView.swift`
- Create: `mobile-ios/App/TelemetryMetricCard.swift`
- Create: `mobile-ios/App/TelemetryChartCard.swift`

**Interfaces:**
- Consumes `TelemetryModel`, `DashboardProfile`, `CanPoint`, and existing widget render helpers.
- Produces `LiveCockpitView(model:)`, `TelemetryMetricCard`, and `TelemetryChartCard` without changing model APIs.

- [ ] **Step 1: Move live-only composition behind `LiveCockpitView`**

  Keep the 100 ms `TimelineView` around the live telemetry subtree only; make
  the root tab/navigation shell stable.

- [ ] **Step 2: Implement the visual hierarchy**

  Add a live connection strip, primary wheel-speed metric, wheel-speed rail,
  dynamics charts, GPS card, session action bar, profile page selector, and
  profile canvas. MARK remains a high-contrast button with identifier
  `session-mark` and compatibility identifier `mark-event`.

- [ ] **Step 3: Implement adaptive layout**

  Use `horizontalSizeClass` and `ViewThatFits`/lazy grids so portrait uses a
  readable single-column flow while landscape/iPad uses two columns. Do not
  alter stored widget rectangles or editor behavior.

- [ ] **Step 4: Run Core tests and app build**

  Run `swift test --package-path mobile-ios/TelemetryCore` and
  `mobile-ios/scripts/verify.sh build`. Expected: all Core tests pass and the
  app compiles.

### Task 3: Restyle widget and settings surfaces

**Files:**
- Modify: `mobile-ios/App/DashboardView.swift`
- Modify: `mobile-ios/App/DashboardEditorView.swift`

**Interfaces:**
- Consumes the theme primitives from Task 1.
- Preserves existing editor identifiers and all dashboard page/widget operations.

- [ ] **Step 1: Apply shared surfaces and state colors**

  Replace repeated inline card styling with theme-backed surfaces, retain
  warning/critical/stale semantics, and improve chart legends/value labels.

- [ ] **Step 2: Restyle editor without changing persistence**

  Keep grid editing, page add/delete, duplicate/delete, snap, orientation, and
  drag/resize behavior while applying the same cockpit visual language.

- [ ] **Step 3: Run direct simulator smoke**

  Install/launch on the booted iPhone 17 Pro iOS 26.2 simulator, inspect
  accessibility text and screenshot, and verify no clipping in portrait and
  landscape orientations.

### Task 4: Final verification and evidence

**Files:**
- Create: `docs/reports/swiftui-cockpit-redesign-2026-09-26.md`
- Modify: `docs/reports/commercial-readiness-2026-09-26.md`

- [ ] **Step 1: Run repository parity checks**

  Run platform docs validation, Core tests, app build, and the available UI
  smoke. Record exact results and known XCTest runner limitations.

- [ ] **Step 2: Review the diff for scope and identifiers**

  Confirm only native SwiftUI files, tests, plan/evidence docs are changed; do
  not stage unrelated `mobile/` changes.

- [ ] **Step 3: Commit and push the redesign**

  Use a feature commit that does not increment the application version because
  this is a UI change under the current unreleased development version.
