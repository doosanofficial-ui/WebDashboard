import Foundation
import XCTest
@testable import TelemetryCore

final class OBDQuerySchedulerTests: XCTestCase {
    // Catches polling a standard PID after its same-target bitmap excludes it.
    // Supported RPM/speed and the manufacturer DID must still reach the wire.
    func testValidBitmapSkipsUnsupportedPIDAcrossPollingCycles() async throws {
        let queries = try SantaFeMX5HybridQueryCatalog.initialQueries().map(fastQuery)
        let checkpoint = expectation(description: "second manufacturer request")
        let transport = ScriptedDiagnosticTransport(
            replies: standardReplies,
            hold: "220101\r", occurrence: 2, checkpoint: checkpoint
        )
        let session = OBDQuerySession(transport: transport)
        let scheduler = OBDQueryScheduler(session: session)
        let initialSupport = await scheduler.support(for: queries[2])
        XCTAssertEqual(initialSupport, .unknown)
        let stream = try await scheduler.start(queries: queries)
        let received = DiagnosticOutcomeLog()
        let consumer = Task {
            for await outcome in stream { await received.append(outcome) }
        }

        await fulfillment(of: [checkpoint], timeout: 2)
        var observedSupport: [OBDQuerySupport] = []
        for query in queries { observedSupport.append(await scheduler.support(for: query)) }
        await scheduler.stop()
        await consumer.value
        let stoppedWrites = await transport.writes()
        await transport.releaseHeldReply()
        let finalWrites = await transport.writes()
        let outcomes = await received.outcomes()
        let stoppedSupport = await scheduler.support(for: queries[2])

        XCTAssertEqual(observedSupport, [.unknown, .supported, .unsupported, .supported, .unknown])
        XCTAssertEqual(stoppedSupport, .unknown)
        XCTAssertEqual(stoppedWrites.filter { $0 == "0105\r" }.count, 0)
        XCTAssertEqual(stoppedWrites.filter { $0 == "010C\r" }.count, 2)
        XCTAssertEqual(stoppedWrites.filter { $0 == "010D\r" }.count, 2)
        XCTAssertEqual(stoppedWrites.filter { $0 == "220101\r" }.count, 2)
        XCTAssertEqual(finalWrites, stoppedWrites, "Stop must prevent later requests")
        XCTAssertTrue(outcomes.contains { outcome in
            guard case .success(let result) = outcome else { return false }
            return result.queryID == "obd-mode01-rpm" && result.signals.first?.value == 2_000
        })
        XCTAssertTrue(outcomes.contains { outcome in
            guard case .success(let result) = outcome else { return false }
            return result.queryID == "obd-mode01-speed" && result.signals.first?.value == 72
        })
        XCTAssertTrue(outcomes.contains { outcome in
            guard case .success(let result) = outcome else { return false }
            return result.queryID == "santafe-mx5-hev-hv-soc" && result.signals.first?.value == 50
        })
        XCTAssertFalse(outcomes.contains { outcome in
            guard case .success(let result) = outcome else { return false }
            return result.queryID == "obd-mode01-coolant"
        }, "An unsupported PID must not invent a measurement")
        XCTAssertFalse(outcomes.contains { outcome in
            guard case .failure(let queryID, _) = outcome else { return false }
            return queryID == "obd-mode01-coolant"
        }, "A bitmap-skipped PID must not invent a diagnostic failure")
    }

    // Catches treating an all-zero bitmap as absent, which would keep polling
    // known-unsupported standard PIDs or incorrectly suppress the unrelated DID.
    func testZeroBitmapSkipsStandardPIDsAndKeepsManufacturerQuery() async throws {
        var replies = standardReplies
        replies["0100\r"] = "7E8 06 41 00 00 00 00 00\r>"
        let run = try await pollingRun(replies: replies)

        XCTAssertEqual(run.writes.filter { $0 == "010C\r" }.count, 0)
        XCTAssertEqual(run.writes.filter { $0 == "0105\r" }.count, 0)
        XCTAssertEqual(run.writes.filter { $0 == "010D\r" }.count, 0)
        XCTAssertEqual(run.writes.filter { $0 == "220101\r" }.count, 1)
        XCTAssertEqual(run.support["obd-mode01-coolant"], .unsupported)
    }

    // Catches applying a future bitmap retroactively or reordering an imported
    // profile: the first coolant request is unknown and must reach the adapter.
    func testQueriesBeforeBitmapRunUntilEvidenceIsObserved() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let queries = [original[2], original[0], original[1], original[3], original[4]]
        let run = try await pollingRun(queries: queries, occurrence: 2)

        XCTAssertEqual(run.writes.filter { $0 == "0105\r" }.count, 1)
        XCTAssertEqual(run.writes.first { !$0.hasPrefix("AT ") }, "0105\r")
        XCTAssertEqual(run.writes.filter { $0 == "010C\r" }.count, 2)
    }

    // Catches mistaking absence, NO DATA, a negative response, or a non-four-byte
    // bitmap for authoritative exclusion. These fixtures are not vehicle data.
    func testUnknownBitmapConservativelyKeepsStandardQueries() async throws {
        let cases: [String?] = [
            nil,
            "NO DATA\r>",
            "7E8 03 7F 01 12\r>",
            "7E8 05 41 00 B6 3F A8\r>",
            "7E8 07 41 00 B6 3F A8 13 00\r>"
        ]
        for bitmap in cases {
            var replies = standardReplies
            replies["0100\r"] = bitmap
            var queries = try SantaFeMX5HybridQueryCatalog.initialQueries()
            if bitmap == nil { queries.removeFirst() }
            let run = try await pollingRun(queries: queries, replies: replies)

            XCTAssertEqual(run.writes.filter { $0 == "0105\r" }.count, 1, "bitmap: \(String(describing: bitmap))")
            XCTAssertEqual(run.writes.filter { $0 == "010C\r" }.count, 1)
            XCTAssertEqual(run.writes.filter { $0 == "010D\r" }.count, 1)
            XCTAssertEqual(run.support["obd-mode01-coolant"], .unknown)
        }
    }

    // Catches stale negative capability surviving an unsuccessful bitmap refresh.
    func testInvalidBitmapRefreshRestoresUnknownPolling() async throws {
        for invalid in ["NO DATA\r>", "7E8 05 41 00 B6 3F A8\r>", "7E8 07 41 00 B6 3F A8 13 00\r>"] {
            let run = try await pollingRun(
                occurrence: 2, subsequentReplies: ["0100\r": invalid]
            )
            XCTAssertEqual(run.writes.filter { $0 == "0105\r" }.count, 1, "refresh: \(invalid)")
            XCTAssertEqual(run.writes.filter { $0 == "010D\r" }.count, 2)
            XCTAssertEqual(run.support["obd-mode01-coolant"], .unknown)
        }
    }

    // Catches reusing evidence from another request address, response address,
    // or 11/29-bit CAN format merely because its PID matches.
    func testBitmapEvidenceIsScopedToExactDiagnosticTarget() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let coolant = original[2]
        let queries = try [
            fastQuery(original[0]), fastQuery(coolant),
            revisedQuery(coolant, id: "other-request", requestCANID: 0x7E0),
            revisedQuery(coolant, id: "other-response", responseCANID: 0x7E9),
            revisedQuery(coolant, id: "extended", isExtended: true),
            fastQuery(original[4])
        ]
        var replies = standardReplies
        replies["7DF/7E9/0105\r"] = "7E9 03 41 05 50\r>"
        replies["000007DF/000007E8/0105\r"] = "000007E8 03 41 05 50\r>"
        let run = try await pollingRun(queries: queries, replies: replies)

        XCTAssertEqual(run.writes.filter { $0 == "0105\r" }.count, 3)
        let successfulIDs = run.outcomes.compactMap { outcome -> String? in
            guard case .success(let result) = outcome else { return nil }
            return result.queryID
        }
        XCTAssertTrue(successfulIDs.contains("other-request"))
        XCTAssertTrue(successfulIDs.contains("other-response"))
        XCTAssertTrue(successfulIDs.contains("extended"))
        XCTAssertFalse(successfulIDs.contains("obd-mode01-coolant"))
        XCTAssertEqual(run.support["obd-mode01-coolant"], .unsupported)
        XCTAssertEqual(run.support["other-request"], .unknown)
        XCTAssertEqual(run.support["other-response"], .unknown)
        XCTAssertEqual(run.support["extended"], .unknown)
    }

    // Catches filtering a manufacturer DID merely because its numeric command
    // fits in one byte and matches an unsupported standard PID on the same ECU.
    func testManufacturerDIDSharingPIDNumberIsAlwaysPolled() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let manufacturer = try revisedQuery(
            original[2], id: "manufacturer-0005", command: "0005", service: .service22
        )
        var replies = standardReplies
        replies["220005\r"] = "7E8 04 62 00 05 50\r>"
        let run = try await pollingRun(
            queries: [original[0], manufacturer, original[4]], replies: replies
        )

        XCTAssertEqual(run.writes.filter { $0 == "220005\r" }.count, 1)
        XCTAssertEqual(run.support["manufacturer-0005"], .unknown)
        XCTAssertTrue(run.outcomes.contains { outcome in
            guard case .success(let result) = outcome else { return false }
            return result.queryID == "manufacturer-0005" && result.signals.first?.value == 40
        })
    }

    // Catches extrapolating higher-PID support from a continuation bit alone.
    func testUnobservedPageKeepsHigherPIDUnknown() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        for mask in ["00 00 00 00", "00 00 00 01"] {
            let higherPID = try revisedQuery(original[2], id: "pid21", command: "21")
            var replies = standardReplies
            replies["0100\r"] = "7E8 06 41 00 \(mask)\r>"
            replies["0121\r"] = "7E8 03 41 21 50\r>"
            let run = try await pollingRun(
                queries: [original[0], higherPID, original[4]], replies: replies
            )
            XCTAssertEqual(run.writes.filter { $0 == "0121\r" }.count, 1)
            XCTAssertEqual(run.writes.filter { $0 == "0120\r" }.count, 0)
            XCTAssertEqual(run.support["pid21"], .unknown)
        }
    }

    // Catches shifting bits relative to PID00 instead of a directly received page.
    // The E0 page also guards against UInt8 overflow near PIDFF.
    func testDirectPagesExcludeOnlyTheirCoveredStandardPIDs() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        for (page, included, excluded, mask) in [
            ("20", "21", "3F", "80 00 00 00"),
            ("E0", "FF", "E1", "00 00 00 02")
        ] {
            let bitmap = try revisedQuery(original[0], id: "page\(page)", command: page)
            let supported = try revisedQuery(original[2], id: "included", command: included)
            let unsupported = try revisedQuery(original[2], id: "excluded", command: excluded)
            var replies = standardReplies
            replies["01\(page)\r"] = "7E8 06 41 \(page) \(mask)\r>"
            replies["01\(included)\r"] = "7E8 03 41 \(included) 50\r>"
            replies["01\(excluded)\r"] = "7E8 03 41 \(excluded) 50\r>"
            let run = try await pollingRun(
                queries: [bitmap, supported, unsupported, original[4]], replies: replies
            )
            XCTAssertEqual(run.writes.filter { $0 == "01\(included)\r" }.count, 1)
            XCTAssertEqual(run.writes.filter { $0 == "01\(excluded)\r" }.count, 0)
            XCTAssertEqual(run.support["included"], .supported)
            XCTAssertEqual(run.support["excluded"], .unsupported)
        }
    }

    // Catches start returning an initialization reader error before its owned
    // close/drain finishes, exposing an incompletely cleaned-up failed session.
    func testInitializationReaderFailureWaitsForCleanupBeforeStartThrows() async throws {
        let initializationEntered = expectation(description: "initial AT H1 awaits reply")
        let closeEntered = expectation(description: "reader failure is closing the transport")
        let transport = ScriptedDiagnosticTransport(
            hold: "AT H1\r", checkpoint: initializationEntered,
            closeGateEntered: closeEntered
        )
        let session = OBDQuerySession(transport: transport)
        let startReturned = CompletionSignal()
        let starting = Task { () -> OBDQuerySessionError? in
            let startError: OBDQuerySessionError?
            do {
                try await session.start()
                startError = nil
            } catch let failure as OBDQuerySessionError {
                startError = failure
            } catch is CancellationError {
                startError = .disconnected
            } catch {
                startError = .transport
            }
            await startReturned.signal()
            return startError
        }

        await fulfillment(of: [initializationEntered], timeout: 2)
        await transport.pushIncoming(Data([0x00]))
        await fulfillment(of: [closeEntered], timeout: 2)
        let returnedBeforeCleanup = await startReturned.wait(timeoutNanoseconds: 2_000_000_000)
        // Always release the cleanup gate, including when the assertion fails.
        await transport.releaseClose()
        let returnedAfterCleanup = await startReturned.wait(timeoutNanoseconds: 2_000_000_000)

        XCTAssertFalse(returnedBeforeCleanup, "start must await the failed initialization's close/drain")
        XCTAssertTrue(returnedAfterCleanup, "start must finish after cleanup")
        guard returnedAfterCleanup else { starting.cancel(); return }
        let error = await starting.value
        let state = await session.state
        let writes = await transport.writes()
        await session.stop()

        XCTAssertEqual(error, .transport)
        XCTAssertEqual(state, .error)
        XCTAssertEqual(writes, ["AT H1\r"], "Reader failure must prevent further initialization writes")
    }

    // Catches initialization resuming after Stop and issuing adapter/query writes.
    func testStopDuringConnectGatePreventsInitializationWrites() async throws {
        let query = try fastQuery(SantaFeMX5HybridQueryCatalog.baselineQueries()[0])
        let connectEntered = expectation(description: "connect is gated")
        let transport = ScriptedDiagnosticTransport(connectGate: connectEntered)
        let scheduler = OBDQueryScheduler(session: OBDQuerySession(transport: transport))
        let starting = Task { () -> OBDQuerySessionError? in
            do {
                _ = try await scheduler.start(queries: [query])
                return nil
            } catch let error as OBDQuerySessionError {
                return error
            } catch is CancellationError {
                return .disconnected
            } catch {
                return .transport
            }
        }

        await fulfillment(of: [connectEntered], timeout: 2)
        await scheduler.stop()
        let writesAtStop = await transport.writes()
        // Current session startup may outlive Stop; a safe implementation will
        // already have cancelled this gate, making this release a no-op.
        await transport.releaseConnect()
        let startError = await starting.value
        let writesAfterConnectReturns = await transport.writes()

        XCTAssertNotNil(startError)
        XCTAssertTrue(writesAtStop.isEmpty)
        XCTAssertTrue(writesAfterConnectReturns.isEmpty, "Initialization must not write after Stop")
    }

    // Catches a late write error from a stopped run failing the new run's waiter.
    func testStoppedWriteErrorCannotFailSameSchedulerRestart() async throws {
        let query = try revisedQuery(
            SantaFeMX5HybridQueryCatalog.baselineQueries()[0], timeout: 0.1
        )
        let firstWriteEntered = expectation(description: "first bitmap write is gated")
        let secondWriteEntered = expectation(description: "restarted bitmap write is silent")
        let transport = ScriptedDiagnosticTransport(
            silentCommands: [query.requestString],
            gatedWrite: query.requestString,
            gatedWriteOccurrence: 1,
            writeGateEntered: firstWriteEntered,
            laterWriteEntered: secondWriteEntered
        )
        let scheduler = OBDQueryScheduler(session: OBDQuerySession(transport: transport))
        let firstStream = try await scheduler.start(queries: [query])
        let firstConsumer = Task { for await _ in firstStream {} }

        await fulfillment(of: [firstWriteEntered], timeout: 2)
        await scheduler.stop()
        await firstConsumer.value

        let secondStream = try await scheduler.start(queries: [query])
        let secondOutcomes = DiagnosticOutcomeLog()
        let secondFinished = expectation(description: "restarted stream finishes")
        let secondConsumer = Task {
            for await outcome in secondStream { await secondOutcomes.append(outcome) }
            secondFinished.fulfill()
        }
        await fulfillment(of: [secondWriteEntered], timeout: 2)
        await transport.failGatedWrite()
        await fulfillment(of: [secondFinished], timeout: 2)
        await secondConsumer.value
        let outcomes = await secondOutcomes.outcomes()
        let writes = await transport.writes()
        await scheduler.stop()

        XCTAssertEqual(writes.filter { $0 == query.requestString }.count, 2)
        XCTAssertTrue(outcomes.contains { outcome in
            guard case .failure(let queryID, let error) = outcome else { return false }
            return queryID == query.id && error == .timeout
        }, "A write error from the stopped run must not fail the restarted query")
        XCTAssertFalse(outcomes.contains { outcome in
            guard case .failure(_, let error) = outcome else { return false }
            return error == .transport
        })
    }

    // Catches an older stop finishing late and disconnecting or clearing the new run.
    func testConcurrentStopAndRestartDoNotLetOldCloseCorruptNewStream() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let firstQueries = try [fastQuery(original[0]), fastQuery(original[2]), fastQuery(original[4])]
        let restartQuery = try revisedQuery(original[2], pollInterval: 1, timeout: 1)
        let pendingQuery = expectation(description: "old manufacturer request waits for a response")
        let closeEntered = expectation(description: "first stop is gated in close")
        let transport = ScriptedDiagnosticTransport(
            replies: standardReplies,
            hold: "220101\r",
            occurrence: 1,
            checkpoint: pendingQuery,
            closeGateEntered: closeEntered
        )
        let scheduler = OBDQueryScheduler(session: OBDQuerySession(transport: transport))
        let oldStream = try await scheduler.start(queries: firstQueries)
        let oldConsumer = Task { for await _ in oldStream {} }

        await fulfillment(of: [pendingQuery], timeout: 2)
        let priorSupport = await scheduler.support(for: restartQuery)
        XCTAssertEqual(priorSupport, .unsupported)
        let firstStop = Task { await scheduler.stop() }
        await fulfillment(of: [closeEntered], timeout: 2)
        let secondStopReturned = CompletionSignal()
        let secondStop = Task {
            await scheduler.stop()
            await secondStopReturned.signal()
        }
        // This handshake makes the start request follow Stop B if it returns
        // while Stop A still owns the blocked close. If B waits for A, continue
        // with the overlapping-start path and release the gate below.
        _ = await secondStopReturned.wait(
            timeoutNanoseconds: 2_000_000_000
        )

        let restartReturned = CompletionSignal()
        let restartAttempt = Task { () -> Result<AsyncStream<OBDQueryOutcome>, OBDQuerySessionError> in
            let result: Result<AsyncStream<OBDQueryOutcome>, OBDQuerySessionError>
            do {
                result = .success(try await scheduler.start(queries: [restartQuery]))
            } catch let error as OBDQuerySessionError {
                result = .failure(error)
            } catch {
                result = .failure(.transport)
            }
            await restartReturned.signal()
            return result
        }
        let restartCompletedBeforeCloseRelease = await restartReturned.wait(
            timeoutNanoseconds: 2_000_000_000
        )

        await transport.releaseHeldReply()
        await transport.releaseClose()
        await firstStop.value
        await secondStop.value
        let restartResult = await restartAttempt.value
        await oldConsumer.value

        let newStream: AsyncStream<OBDQueryOutcome>
        switch restartResult {
        case .success(let stream) where restartCompletedBeforeCloseRelease:
            let unexpectedConsumer = Task { for await _ in stream {} }
            await scheduler.stop()
            await unexpectedConsumer.value
            XCTFail("Start during Stop A's close must be rejected or wait for close completion")
            return
        case .success(let stream):
            newStream = stream
        case .failure(.invalidState) where restartCompletedBeforeCloseRelease:
            newStream = try await scheduler.start(queries: [restartQuery])
        case .failure(let error):
            await scheduler.stop()
            XCTFail("Restart must survive completion of the earlier Stop: \(error)")
            return
        }
        let supportAfterStop = await scheduler.support(for: restartQuery)
        XCTAssertEqual(supportAfterStop, .unknown)
        let newOutcomes = DiagnosticOutcomeLog()
        let restartResponse = expectation(description: "restarted query succeeds")
        let outcomeWatcher = Task {
            for await outcome in newStream {
                await newOutcomes.append(outcome)
                if case .success(let result) = outcome, result.queryID == restartQuery.id {
                    restartResponse.fulfill()
                }
            }
        }
        await fulfillment(of: [restartResponse], timeout: 2)
        await scheduler.stop()
        await oldConsumer.value
        await outcomeWatcher.value
        let outcomes = await newOutcomes.outcomes()
        let writes = await transport.writes()

        XCTAssertTrue(writes.contains(restartQuery.requestString))
        XCTAssertTrue(outcomes.contains { outcome in
            guard case .success(let result) = outcome else { return false }
            return result.queryID == restartQuery.id
        }, "The old close must not cancel the new stream")
    }

    // Catches a query immediately following the first result instead of waiting
    // through its configured polling interval, where Stop must remain effective.
    func testStopDuringPollingIntervalPreventsNextConfiguredRequest() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let first = try revisedQuery(original[2], pollInterval: 1, timeout: 1)
        let second = try fastQuery(original[1])
        let firstResponse = expectation(description: "first configured query succeeds")
        let transport = ScriptedDiagnosticTransport(replies: standardReplies)
        let scheduler = OBDQueryScheduler(session: OBDQuerySession(transport: transport))
        let stream = try await scheduler.start(queries: [first, second])
        let consumer = Task {
            for await outcome in stream {
                if case .success(let result) = outcome, result.queryID == first.id {
                    firstResponse.fulfill()
                }
            }
        }

        await fulfillment(of: [firstResponse], timeout: 2)
        await scheduler.stop()
        await consumer.value
        let writes = await transport.writes()

        XCTAssertEqual(writes.filter { $0 == first.requestString }.count, 1)
        XCTAssertEqual(writes.filter { $0 == second.requestString }.count, 0)
    }

    // Catches stopping after a recoverable bitmap outcome or continuing after a fatal one.
    func testFatalBitmapFailuresStillTerminateTheScheduler() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let bitmap = try revisedQuery(original[0], timeout: 0.1)
        let coolant = try fastQuery(original[2])
        let cases: [(name: String, reply: String?, failsWrite: Bool, error: OBDQuerySessionError)] = [
            ("timeout", nil, false, .timeout),
            ("transport", nil, true, .transport),
            ("buffer full", "BUFFER FULL\r>", false, .bufferFull),
            ("parser", "7E8 03 42 00 00\r>", false, .response(.serviceMismatch))
        ]

        for testCase in cases {
            let finished = expectation(description: "\(testCase.name) ends the stream")
            var replies = standardReplies
            if let reply = testCase.reply { replies[bitmap.requestString] = reply }
            let transport = ScriptedDiagnosticTransport(
                replies: replies,
                silentCommands: testCase.reply == nil && !testCase.failsWrite ? [bitmap.requestString] : [],
                failingCommands: testCase.failsWrite ? [bitmap.requestString] : []
            )
            let scheduler = OBDQueryScheduler(session: OBDQuerySession(transport: transport))
            let stream = try await scheduler.start(queries: [bitmap, coolant])
            let outcomes = DiagnosticOutcomeLog()
            let consumer = Task {
                for await outcome in stream { await outcomes.append(outcome) }
                finished.fulfill()
            }

            await fulfillment(of: [finished], timeout: 2)
            await scheduler.stop()
            await consumer.value
            let writes = await transport.writes()
            let recordedOutcomes = await outcomes.outcomes()

            XCTAssertFalse(writes.contains(coolant.requestString), "\(testCase.name) must remain fatal")
            XCTAssertTrue(recordedOutcomes.contains { outcome in
                guard case .failure(let queryID, let error) = outcome else { return false }
                return queryID == bitmap.id && error == testCase.error
            }, "Unexpected failure for \(testCase.name): \(recordedOutcomes)")
        }
    }

    // Catches skipping an explicitly configured PID 20 bitmap when PID 00 says
    // its continuation bit is clear, or deriving PID 21 support from that bit.
    func testConfiguredPID20BitmapRefreshesWithoutAutomaticDiscovery() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let page00 = try fastQuery(original[0])
        let page20 = try revisedQuery(original[0], id: "configured-page-20", command: "20")
        let pid21 = try revisedQuery(original[2], id: "pid-21", command: "21")
        let pid3F = try revisedQuery(original[2], id: "pid-3f", command: "3F")
        var replies = standardReplies
        replies["0100\r"] = "7E8 06 41 00 00 00 00 00\r>"
        replies["0120\r"] = "7E8 06 41 20 80 00 00 00\r>"
        replies["0121\r"] = "7E8 03 41 21 50\r>"
        replies["013F\r"] = "7E8 03 41 3F 50\r>"
        let run = try await pollingRun(
            queries: [page00, page20, pid21, pid3F, original[4]],
            replies: replies,
            occurrence: 2
        )

        XCTAssertEqual(run.writes.filter { $0 == "0100\r" }.count, 2)
        XCTAssertEqual(run.writes.filter { $0 == "0120\r" }.count, 2)
        XCTAssertEqual(run.writes.filter { $0 == "0121\r" }.count, 2)
        XCTAssertEqual(run.writes.filter { $0 == "013F\r" }.count, 0)
        XCTAssertEqual(run.support["pid-21"], .supported)
        XCTAssertEqual(run.support["pid-3f"], .unsupported)
    }

    // Catches inferring capability from user-facing signal labels/decoding
    // instead of the four raw bytes in the parsed positive response.
    func testBitmapSupportUsesResponsePayloadNotSignalLabels() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let unrelatedLabel = try OBDSignalDefinition(
            id: "display-only-value",
            name: "Arbitrary custom display label",
            startBit: 0,
            bitLength: 8,
            byteOrder: .intel,
            isSigned: false,
            factor: 1,
            offset: 0,
            minimum: 0,
            maximum: 255,
            unit: "display",
            timeout: 1
        )
        let bitmap = try revisedQuery(
            original[0], name: "Custom profile field", signals: [unrelatedLabel]
        )
        let run = try await pollingRun(
            queries: [bitmap, original[2], original[4]], occurrence: 2
        )

        XCTAssertEqual(run.writes.filter { $0 == "0105\r" }.count, 0)
        XCTAssertEqual(run.support["obd-mode01-coolant"], .unsupported)
    }

    // Catches changes to existing serialized query shape or configured order.
    func testConfiguredProfileOrderSurvivesCodableRoundTrip() throws {
        let queries = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let encoded = try JSONEncoder().encode(queries)
        let restored = try JSONDecoder().decode([OBDQueryDefinition].self, from: encoded)

        XCTAssertEqual(restored.map(\.id), [
            "obd-mode01-supported-00", "obd-mode01-rpm", "obd-mode01-coolant",
            "obd-mode01-speed", "santafe-mx5-hev-hv-soc"
        ])
        XCTAssertEqual(restored, queries)
    }

    private func pollingRun(
        queries: [OBDQueryDefinition]? = nil,
        replies: [String: String]? = nil,
        occurrence: Int = 1,
        subsequentReplies: [String: String] = [:]
    ) async throws -> (writes: [String], outcomes: [OBDQueryOutcome], support: [String: OBDQuerySupport]) {
        let definitions = try (queries ?? SantaFeMX5HybridQueryCatalog.initialQueries()).map(fastQuery)
        let checkpoint = expectation(description: "manufacturer request \(occurrence)")
        let transport = ScriptedDiagnosticTransport(
            replies: replies ?? standardReplies, hold: "220101\r", occurrence: occurrence,
            checkpoint: checkpoint, subsequentReplies: subsequentReplies
        )
        let scheduler = OBDQueryScheduler(session: OBDQuerySession(transport: transport))
        let stream = try await scheduler.start(queries: definitions)
        let received = DiagnosticOutcomeLog()
        let consumer = Task {
            for await outcome in stream { await received.append(outcome) }
        }
        await fulfillment(of: [checkpoint], timeout: 2)
        var support: [String: OBDQuerySupport] = [:]
        for query in definitions { support[query.id] = await scheduler.support(for: query) }
        await scheduler.stop()
        await consumer.value
        return (await transport.writes(), await received.outcomes(), support)
    }

    private var standardReplies: [String: String] {
        [
            // The independently checked historical mask excludes 05 and includes 0C/0D.
            "0100\r": "7E8 08 06 41 00 B6 3F A8 13 00\r>",
            "010C\r": "7E8 04 41 0C 1F 40\r>",
            "0105\r": "7E8 03 41 05 50\r>",
            "010D\r": "7E8 03 41 0D 48\r>",
            "220101\r": "7EC 08 62 01 01 00 00 00 00 64\r>"
        ]
    }

    private func fastQuery(_ query: OBDQueryDefinition) throws -> OBDQueryDefinition {
        try revisedQuery(query)
    }

    private func revisedQuery(_ query: OBDQueryDefinition, id: String? = nil,
                              name: String? = nil, command: String? = nil, service: OBDService? = nil,
                              requestCANID: UInt32? = nil, responseCANID: UInt32? = nil,
                              isExtended: Bool? = nil, pollInterval: Double = 0.000_001,
                              timeout: Double = 1, signals: [OBDSignalDefinition]? = nil) throws -> OBDQueryDefinition {
        try OBDQueryDefinition(
            id: id ?? query.id, name: name ?? query.name,
            requestCANID: requestCANID ?? query.requestCANID, responseCANID: responseCANID ?? query.responseCANID,
            isExtended: isExtended ?? query.isExtended, service: service ?? query.service, command: command ?? query.command,
            pollInterval: pollInterval, timeout: timeout, flowControl: query.flowControl,
            sourceRepository: query.sourceRepository, sourcePath: query.sourcePath,
            sourceCommit: query.sourceCommit, signals: signals ?? query.signals
        )
    }
}

private actor DiagnosticOutcomeLog {
    private var recorded: [OBDQueryOutcome] = []
    func append(_ outcome: OBDQueryOutcome) { recorded.append(outcome) }
    func outcomes() -> [OBDQueryOutcome] { recorded }
}

private actor CompletionSignal {
    private var completed = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    func signal() {
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        waiter?.resume(returning: true)
        waiter = nil
    }

    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        if completed { return true }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self.resolveTimeout()
            }
        }
    }

    private func resolveTimeout() {
        guard let waiter else { return }
        self.waiter = nil
        timeoutTask = nil
        waiter.resume(returning: false)
    }
}

/// Replaces only the external adapter. Production session setup, address
/// selection, prompt parsing, response validation, decoding, and scheduling run.
/// A held request creates a bounded handshake without using sleeps as an oracle.
private actor ScriptedDiagnosticTransport: CANTransport {
    private var stream: AsyncThrowingStream<Data, Error>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let replies: [String: String]
    private let heldCommand: String?
    private let heldOccurrence: Int
    private let subsequentReplies: [String: String]
    private let checkpoint: XCTestExpectation?
    private let silentCommands: Set<String>
    private let failingCommands: Set<String>
    private let gatedWrite: String?
    private let gatedWriteOccurrence: Int
    private let writeGateEntered: XCTestExpectation?
    private let laterWriteEntered: XCTestExpectation?
    private let connectGate: XCTestExpectation?
    private let connectCheckpoints: [XCTestExpectation?]
    private let closeGateEntered: XCTestExpectation?
    private var connectGateContinuation: CheckedContinuation<Void, Error>?
    private var closeGateContinuation: CheckedContinuation<Void, Never>?
    private var writeGateContinuation: CheckedContinuation<Void, Error>?
    private var heldReply: (continuation: AsyncThrowingStream<Data, Error>.Continuation, data: Data)?
    private var connectCount = 0
    private var didWaitForClose = false
    private var connected = false
    private var recorded: [String] = []
    private var requestHeader = ""
    private var responseHeader = ""

    init(
        replies: [String: String] = [:], hold: String? = nil, occurrence: Int = 1,
        checkpoint: XCTestExpectation? = nil, subsequentReplies: [String: String] = [:],
        silentCommands: Set<String> = [], failingCommands: Set<String> = [],
        gatedWrite: String? = nil, gatedWriteOccurrence: Int = 1,
        writeGateEntered: XCTestExpectation? = nil, laterWriteEntered: XCTestExpectation? = nil,
        connectGate: XCTestExpectation? = nil, connectCheckpoints: [XCTestExpectation?] = [],
        closeGateEntered: XCTestExpectation? = nil
    ) {
        self.replies = replies
        heldCommand = hold
        heldOccurrence = occurrence
        self.checkpoint = checkpoint
        self.subsequentReplies = subsequentReplies
        self.silentCommands = silentCommands
        self.failingCommands = failingCommands
        self.gatedWrite = gatedWrite
        self.gatedWriteOccurrence = gatedWriteOccurrence
        self.writeGateEntered = writeGateEntered
        self.laterWriteEntered = laterWriteEntered
        self.connectGate = connectGate
        self.connectCheckpoints = connectCheckpoints
        self.closeGateEntered = closeGateEntered
    }

    func incoming() async -> AsyncThrowingStream<Data, Error> {
        if let stream { return stream }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        return pair.stream
    }

    func connect() async throws {
        connectCount += 1
        if connectCount <= connectCheckpoints.count {
            connectCheckpoints[connectCount - 1]?.fulfill()
        }
        if let connectGate {
            connectGate.fulfill()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { connectGateContinuation = $0 }
            } onCancel: {
                Task { await self.cancelConnectGate() }
            }
        }
        connected = true
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func close() async {
        if !didWaitForClose, let closeGateEntered {
            didWaitForClose = true
            closeGateEntered.fulfill()
            await withCheckedContinuation { closeGateContinuation = $0 }
        }
        connected = false
        continuation?.finish()
    }

    func write(_ data: Data) async throws {
        let command = String(decoding: data, as: UTF8.self)
        recorded.append(command)
        guard connected else { throw CANTransportError.notConnected }
        let commandCount = recorded.filter { $0 == command }.count
        if let gatedWrite, command == gatedWrite, commandCount == gatedWriteOccurrence {
            writeGateEntered?.fulfill()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { writeGateContinuation = $0 }
            } onCancel: {
                Task { await self.cancelWriteGate() }
            }
        }
        if let laterWriteEntered, let gatedWrite, command == gatedWrite, commandCount > gatedWriteOccurrence {
            laterWriteEntered.fulfill()
        }
        if failingCommands.contains(command) { throw CANTransportError.writeFailed }
        if silentCommands.contains(command) { return }
        if command.hasPrefix("AT SH ") { requestHeader = String(command.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if command.hasPrefix("AT CRA ") { responseHeader = String(command.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let scopedReply = replies["\(requestHeader)/\(responseHeader)/\(command)"]
        let laterReply = commandCount > 1 ? subsequentReplies[command] : nil
        let reply = command.hasPrefix("AT ") ? "OK\r>" : laterReply ?? scopedReply ?? replies[command] ?? "NO DATA\r>"
        if command == heldCommand && commandCount == heldOccurrence {
            if let continuation { heldReply = (continuation, Data(reply.utf8)) }
            checkpoint?.fulfill()
        } else {
            continuation?.yield(Data(reply.utf8))
        }
    }

    func releaseHeldReply() {
        if let heldReply { heldReply.continuation.yield(heldReply.data) }
        heldReply = nil
    }

    func pushIncoming(_ data: Data) {
        continuation?.yield(data)
    }

    func releaseConnect() {
        connectGateContinuation?.resume()
        connectGateContinuation = nil
    }

    private func cancelConnectGate() {
        connectGateContinuation?.resume(throwing: CancellationError())
        connectGateContinuation = nil
    }

    func releaseClose() {
        closeGateContinuation?.resume()
        closeGateContinuation = nil
    }

    func failGatedWrite() {
        writeGateContinuation?.resume(throwing: CANTransportError.writeFailed)
        writeGateContinuation = nil
    }

    private func cancelWriteGate() {
        writeGateContinuation?.resume(throwing: CancellationError())
        writeGateContinuation = nil
    }

    func writes() -> [String] { recorded }
}
