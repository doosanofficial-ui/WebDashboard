# Dashboard persistence failure isolation

Scope: follow-up to #25. This is a small error-boundary correction, not a Dashboard redesign or complete UI acceptance.

## Plan and reproduced problem
1. Run the current persistence method with a real file-write failure and a later successful write.
2. Keep layout-save errors separate from local measurement storage errors; retain draft edits and add an explicit retry action.
3. Exercise the actual App/Foundation/SQLite path in hosted tests and check all existing CI.

`persistDashboardProfile()` previously assigned a layout-write error to `storageStatus`. That same flag blocks `startLocation` and the cockpit MARK button. Even a later successful layout write did not clear it. The local exact-method probe reproduced four failed assertions out of seven with reduced DashboardProfile serialization but real Foundation file I/O. After the correction, all seven pass. This control-flow probe does not qualify GPS hardware or visual touch behavior.

## Minimal correction
`dashboardSaveError` is distinct from `storageStatus`. It reports unavailable storage, encoding or write failures without altering a real recording failure. Unsaved edits remain in memory; an atomic save retry persists the draft and clears only the dashboard error. The existing editor shows the error and a Retry save button, with accessibility identifiers. Existing profile format, file location and measurement schema remain unchanged.

## Native coverage
Three `DashboardPersistenceHostedTests` run the real App sources and Foundation writes in the disposable Simulator host:
- A blocked layout destination preserves saved bytes and the in-memory draft while two MARK events around the failure reach a real closed SQLite session.
- Retrying after restoring the destination persists exactly the draft and clears the dashboard error.
- A successful layout save does not clear an independent genuine measurement-storage failure.

The combined hosted suite must execute 16 tests, with no skips or failures (seven lifecycle, six adapter-profile, three dashboard-persistence). Full native execution evidence is recorded in the workflow and #25 after it completes. Swift syntax and the local probe passed before integration; these are not standalone proof of UIKit runtime.

## Remaining boundaries
No Bluetooth or location acquisition is started by the tests. Screen-lock, real-device iOS 27, live profile hot-swap, complete widget touch/rotation/save UX, session browsing and timeline replay remain separate. A transient layout-save fault must not be mistaken for a durable measurement write failure; actual measurement failures retain their original safety behavior.
