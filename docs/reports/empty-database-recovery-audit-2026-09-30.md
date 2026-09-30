# Empty-database recovery audit

Parent: `1fe26b85aca68b1331eaa5b952d5fa42e1fb7454`. Scope: the database reopen candidate in #25, not a new storage format or broad corruption repair.

## Plan and root cause
1. Exercise current recovery with zero-byte and schema-empty SQLite fixtures, then compare with legacy/populated/error databases.
2. Treat only an empty SQLite schema as having no interrupted sessions; leave normal recovery, transaction rollback and error propagation intact.
3. Add full-package regressions and verify Core, native hosted App, build and existing CI at the integrated SHA.

`TelemetryModel` invokes `recoverUnfinishedSessions` before a recording constructor can initialize the schema. A process interrupted between file creation/open and schema creation can leave a file with no measurement tables. Recovery previously queried the missing table and threw `storage`, while the recording constructor itself could initialize the same valid empty file. The failing boundary was reproduced directly, not by killing a user's app or touching their data.

## Actual local results
The new eight-case XCTest suite ran against the exact complete production MeasurementRecorder.swift plus real SQLite on Linux Swift 6.2.1. Two cases failed before the patch (zero-byte and header-bearing empty database); all eight passed afterward. Unused CAN/OBD/GPS model types in this focused host are stand-ins; SYSTEM records, schema/migration logic, queries and transactions execute production code. Full macOS package/hosted CI is a separate gate, recorded in #25 after it completes.

Additional regressions cover nonexistent files without file creation, foreign/corrupt/partial schemas retaining their tested failure behavior and contents, legacy mode migration preserving raw rows and completed session boundaries through repeated reopen, and all-session rollback/retry when a later interruption-marker insert fails.

## Compatibility and boundaries
The patch inspects sqlite_master inside the existing transaction. It returns zero only when SQLite reports no schema objects; it does not delete, truncate, repair or replace the file and does not invent a session. Other schemas follow the existing recovery path. No error catch was broadened. Stored metadata, CSV/JSON schema, record order, first end time and legacy mode defaults are unchanged.

The pre-existing duplicate-mode-column migration probe and optional URLSession XPC messages are not suppressed. The legacy reopen tests pass; these log observations are not themselves evidence of data loss. Disk exhaustion, arbitrary corruption recovery, multi-process ownership, physical iOS 27 execution and vehicle endurance remain separate from this targeted boundary test.

## Reproduce
`swift test --package-path mobile-ios/TelemetryCore --filter MeasurementRecoveryTests`

Full checks: `swift test --package-path mobile-ios/TelemetryCore`, both committed coordinator probes, and `python3 scripts/verify_ios_lifecycle.py --result-directory /tmp/recovery-hosted-UNIQUE` on macOS/Xcode.
