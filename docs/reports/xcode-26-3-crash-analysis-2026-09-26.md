# Xcode 26.3 Crash Analysis

Checked: 2026-09-26. This report analyzes the Xcode crash observed while
working on the iPhone 17 signing/install gate.

## Observed result

- Xcode 26.3 (17C519) exited unexpectedly at approximately 23:38:36.
- Xcode relaunched to the Welcome window. The Telemetry temporary project was
  still listed in Recent Projects; the canonical repository was not modified by
  the crash.
- Crash report:
  ~/Library/Logs/DiagnosticReports/Xcode-2026-09-26-233908.ips

## Crash evidence

The report records:

- Exception: EXC_BREAKPOINT
- Signal: SIGTRAP
- Faulting thread: 13
- Queue: Changes Manager Registry
- No evidence of memory exhaustion or an application process crash
- The faulting stack enters Swift protocol-conformance/KVO machinery and then:
  SourceControlWorkspaceStateManager.init(workspace:)
  SourceControlWindowTitleStatusProvider.init(_:)
  WindowTitleToolbarViewController
  IDEWorkspace._finishLoadingAsynchronously

The workspace being loaded was the generated verification snapshot under:

/private/tmp/telemetry-ios-device-verify.58nYom/source

This is not the canonical repository and is not a durable editable project.

## Root-cause classification

High-confidence classification: an Xcode 26.3 internal crash while its Source
Control/title-status integration asynchronously loads the generated temporary
project. The evidence does not implicate SwiftUI, TelemetryCore, the app
binary, signing, or the iPhone runtime.

The trigger was opening the verification snapshot project in the Xcode GUI
after a shell build. The verification script intentionally stages sources in
an ASCII temporary directory to work around an Xcode response-file issue caused
by the repository's NBSP-containing path. That staging path is suitable for
xcodebuild and simulator artifacts, but it should not be opened as the
developer's project in Xcode.

## Mitigation

- Use mobile-ios/scripts/verify.sh build or xcodebuild from the shell for
  staged verification snapshots.
- Do not open /tmp/telemetry-ios-verify.* or
  /tmp/telemetry-ios-device-verify.* projects in Xcode.
- Edit only the canonical repository path.
- Use Xcode GUI only with a stable project path after generating a project
  there; keep the generated project out of the release commit unless the team
  explicitly adopts it.
- If Xcode crashes again, preserve the newest DiagnosticReports file before
  relaunching and compare the faulting queue/stack against this report.

## Status

- Xcode was relaunched and is currently stable at the Welcome window.
- The physical device build/install investigation remains valid; the crash
  occurred after the device build work while opening the temporary project.
- No destructive recovery, preference reset, project deletion, or source
  rollback was performed.
