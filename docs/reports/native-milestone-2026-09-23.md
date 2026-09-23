# Native iOS Milestone - 2026-09-23

Status: **implementation and local verification in progress; not a commercial release**.
The full objective remains the internal Windows/iOS product, real background telemetry,
Naver map/roadview, real CAN integration, CarPlay and the platform release gates.

## Verified progress

- SwiftUI app target added: six gauges, two bounded 60-second Charts views, CAN reconnect,
  location status, explicit GPS start/stop, durable MARK and connection/credential settings.
- GPS capture uses the original Core Location timestamp. Unknown optional measurements
  remain unknown. Location capture and SQLite persistence are independent of the render loop.
- File-backed background URLSession uploads v2 batches. Valid ACKs are applied to the
  outbox; wrong-client or unrelated ACKs cannot delete records. Temporary failures back off.
- Known safe server failure codes reach the UI. Arbitrary server error text is not reflected.
- Server v2 ingestion validates/authenticates the actual HTTP request, commits SQLite before
  returning ACK, deduplicates replay and rolls back conflicting/invalid batches.
- Existing v1 CAN stream and MARK CSV continue to pass the actual ASGI lifespan smoke test.

## Evidence

| Check | Result | Scope |
|---|---|---|
| Server unittest suite | 21 PASS | Journal + HTTP response bodies + real app lifespan/10 CAN frames/MARK |
| GPS/map regression suite | 23 PASS | Web/RN normalization, JSON uplink body, callback permission API, missing BG bridge, unknown heading rendering and literal map annotations |
| Service-worker regression suite | 8 PASS | Live API bypass, same-origin static scope, fresh online assets, offline shell, safe cache failures and cache ownership |
| Native Core XCTest | 15 PASS | Timestamp/unknown values, restart, partial ACK, queue capacity, safe error decoding, OS retry registration and configuration races |
| Legacy RN Jest | 16 PASS | Current changed code tested against the intended commit's original package/lock files |
| Reproducible native simulator build | PASS | Xcode 26.3, Debug, iOS Simulator SDK 26.2 |
| Device architecture build | PASS | generic iOS ARM64, unsigned; **not installed on iPhone** |
| App installation and launch | PASS on simulator | iPhone 17 simulator / iOS 26.2 |
| HTTPS URL validation | Observed through UI | Entered http://example.invalid, Connect showed HTTPS requirement |
| MARK persistence | Observed through UI and SQLite | Original record survived app replacement/relaunch; latest reviewed build's button press increased stored MARK count to 3 |
| XCUITest automatic screen suite | NOT PASSED | Runner suspended before test execution; no test assertions completed |
| Real iPhone 30-minute lock test | NOT RUN | Physical phone unavailable on 2026-09-23; valid development signing identities: 0 |
| Hosted CI | PASS at bb66e7a | Windows/Linux contract jobs, macOS Core, and all three existing smoke jobs |

The simulator screen check used macOS accessibility controls and captured only the
simulator. Screenshot: [HTTPS refusal](evidence/native-2026-09-23/https-required.png).
Native source hashes at the build checkpoint: [manifest](evidence/native-2026-09-23/source-sha256.txt).
A subsequent source change requires fresh relevant verification; this report is not a
blanket approval for future versions.

## Review corrections

A bounded read-only review found two P1 lifecycle issues: an in-process sleep could
lose a retry when iOS suspends the app, and a background-only relaunch did not restore
the upload configuration. Both were corrected before commit:

- BackgroundDelivery now registers the replacement background upload before the
  completion callback returns; the OS receives earliestBeginDate for backoff.
- The model restores the saved endpoint and Keychain credential before attaching the
  background session, then reconciles existing work and pending records.
- A failing regression also exposed premature completion during concurrent transfer
  preparation; callers now await that preparation before releasing background work.
- Another failing regression exposed submission to an outdated destination/credential
  during reconfiguration; a revision guard discards outdated preparation.
- The safe failure code remains visible when a retry is registered.

These are actual Core code-path tests with an OS scheduler test double. They do not
prove iOS scheduling deadlines or replace physical-device background validation.
The reviewer returned a non-empty result and was closed; no delegated worktree or
report file was created.

Local artifacts retained for this checkpoint:

- /tmp/telemetry-ios-verify.ULagRp/core-tests.log
- /tmp/telemetry-ios-verify.ULagRp/app-build.log
- /tmp/telemetry-ios-verify.ULagRp/result.xcresult
- /tmp/telemetry-ios-verify.ULagRp/device-build.log
- /tmp/webdashboard-tests.CYmkcl/server-tests-final.log
- /tmp/webdashboard-tests.CYmkcl/gps-tests-final.log
- /tmp/webdashboard-tests.CYmkcl/sw-green.log

PWA cache revision v6 delivers the reproduced GPS/heading fixes and stops caching
live API responses or third-party maps. It uses network-first static assets, retains
the offline app shell, and does not return HTML as a missing JavaScript module.
Map note content is constructed as an HTMLElement using textContent, a supported
[NAVER InfoWindow content type](https://navermaps.github.io/maps.js.ncp/docs/naver.maps.InfoWindow.html).
The application/package release version has not been raised by this cache revision.

The successful compiler log has the platform warning that App Intents metadata
extraction is skipped because this target does not implement App Intents.
Actor-isolation conformance warnings in the app were fixed with main-queue delegate
ownership and checked protocol conformance.

## Environment repairs

- Xcode 26.3 was found under the migrated Desktop folder. The earlier inspection of
  /Applications alone was insufficient; it did not establish that Xcode was absent.
  /Applications/Xcode.app now links to that existing installation.
- The original IDE path Documents/VScodePrj/WebDashboard now links to the actual
  migrated repository. Both paths address the same source, not separate checkouts.
- XcodeGen 2.44.1's installed binary lacked its setting presets. Its SHA-256 matched
  the official 2.44.1 release binary; matching resource files were restored.
- Xcode response files split the NBSP-containing source path. verify.sh stages an
  identical input snapshot into an ASCII temporary path and records source hashes.
- Native UI test startup was attempted unsigned, with simulator ad-hoc signing, and
  via the Xcode path alias. The runner still suspended before executing assertions.
  Testmanager diagnostics included an XPC listener permission error. The exact
  startup cause remains unresolved. These attempts were stopped, not marked PASS.

## Git recovery

Implementation commit: b15dc6eb3c7eaab58a3e7178aed534265f393fba.
Cross-platform fixture correction: bb66e7a (SQLite inspection connections now close
before temporary-file cleanup). The first Windows run failed with WinError 32 in
test cleanup; the rerun passed without weakening assertions or skipping Windows.

Draft review: https://github.com/doosanofficial-ui/WebDashboard/pull/23.
Verified hosted run: https://github.com/doosanofficial-ui/WebDashboard/actions/runs/35858070621.
Existing smoke: https://github.com/doosanofficial-ui/WebDashboard/actions/runs/35858070755.
This is a source checkpoint; main has not been merged and no release has been published.

Authenticated GitHub account: doosanofficial-ui. Verified target:
https://github.com/doosanofficial-ui/WebDashboard (public, main).

Remote base: 1f8a650f4d2c8da53289a29255ff97b63fde957f.
The Git blob hashes of docs/PRD.md, client/index.html and server/can_source/dummy.py
matched the local files before recovery.

The original .git had cloud-only/dataless HEAD/index and could not be read. It was
renamed to .git-cloud-recovery-20260923, **not deleted**. The two cloud-only smoke
workflow files were also preserved inside that recovery directory before their
verified remote versions were restored. Their unavailable local contents may still
contain differences and require reconciliation if iCloud can recover them.

A fresh copy of verified remote Git metadata now drives the same working source
on branch codex/native-telemetry-productization. Original source files were not reset
or overwritten during metadata recovery. The recovery directory is locally excluded
from Git. The temporary recovery clone was removed after its metadata was integrated.
The new metadata has one worktree and no stash; this does not assert that unreadable
original metadata contained no additional history. Old local main/Copilot refs remain
in the recovery directory for later investigation.

## Remaining requirements

- Physical iPhone signing/install and real screen-lock/reconnect logs.
- Native map/roadview integration and CarPlay eligibility/templates.
- Automatic pairing, v1 endpoint hardening, Windows installer and real Vector adapter.
- End-to-end background upload recovery under app suspension/reboot/network loss.
- Merge review, dependency remediation, performance/battery tests and release evidence.
- Preserved cloud Git/CI history reconciliation.

Version remains 0.1.0 while these release gates are incomplete. Simulator development
builds are not a published package or a completed release.
