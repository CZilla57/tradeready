import Foundation

private final class MemoryWidgetActionQueue: NativeWidgetActionQueueBacking {
    var value: String?
    var ignoresWrites = false

    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { value }
    func write(_ value: String?) {
        if !ignoresWrites { self.value = value }
    }
}

@main
struct WidgetActionReplayTests {
    static func main() throws {
        // Line-buffered, so every FAIL line survives a later fatalError.
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0
        // Task 11.05 (§4.5): replay drops every action not stamped hash(O), so
        // every fixture action carries the tag for the planning binding.
        let tag = NativeWidgetOwnerTag.make(binding: String(repeating: "a", count: 64))
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }
        func rejects(_ raw: String, _ expected: NativeWidgetActionBatchError, _ label: String) {
            do {
                _ = try NativeWidgetActionBatchPlanner.prepare(
                    rawValue: raw,
                    verifiedAccountBinding: String(repeating: "a", count: 64)
                )
                expect(false, label)
            } catch let error as NativeWidgetActionBatchError {
                expect(error == expected, label)
            } catch { expect(false, label) }
        }
        /// Phase 12 12.00b.2-C (L130): the batch prepares; exactly the entry
        /// at `index` is set aside with `expected`, and `applied` still apply.
        func setsAside(
            _ raw: String, _ expected: NativeWidgetActionBatchError, _ label: String,
            index: Int = 0, applied: [String] = []
        ) {
            do {
                let batch = try NativeWidgetActionBatchPlanner.prepare(
                    rawValue: raw,
                    verifiedAccountBinding: String(repeating: "a", count: 64)
                )
                expect(batch.rejected.map(\.index) == [index] && batch.rejected.first?.error == expected
                       && batch.actions.map(\.id) == applied, label)
            } catch { expect(false, "\(label) (threw \(error))") }
        }

        let raw = """
        [{"ownerTag":"\(tag)","id":"start-1","type":"timer_start","at":"2026-08-03T09:00:00.000Z","jobId":"j1","future":true},
         {"ownerTag":"\(tag)","id":"stop-1","type":"timer_stop","at":"2026-08-03T11:00:00Z","jobId":"j1"},
         {"ownerTag":"\(tag)","id":"trip-1","type":"trip_log","at":"2026-08-03T11:05:00Z","date":"2026-08-03","odometerStart":100,"odometerEnd":115},
         {"ownerTag":"\(tag)","id":"expense-1","type":"expense_log","at":"2026-08-03T11:10:00Z","date":"2026-08-03","amount":42.5,"category":"materials","description":"Lumber"},
         {"ownerTag":"\(tag)","id":"future-1","type":"future_action","at":"2026-08-03T12:00:00Z","payload":{"keep":"exact"}}]
        """
        let batch = try NativeWidgetActionBatchPlanner.prepare(
            rawValue: raw,
            verifiedAccountBinding: String(repeating: "a", count: 64)
        )
        expect(batch.sourceBytes == Data(raw.utf8), "exact queue source bytes are retained")
        expect(batch.actions.count == 5, "known and future actions remain ordered")
        expect(batch.actions.map(\.kind) == [.timerStart, .timerStop, .tripLog, .expenseLog, .unknown("future_action")],
               "action kinds are classified without discarding future types")
        expect(batch.actions[0].fields["future"] == .bool(true), "additive known-action fields are preserved")
        expect(batch.actions[4].fields["payload"] == .object(["keep": .string("exact")]),
               "future action payload is preserved losslessly")
        expect(batch.sourceDigest.count == 64 && batch.actions.allSatisfy { $0.digest.count == 64 },
               "source and action digests are deterministic SHA-256 values")
        let retry = try NativeWidgetActionBatchPlanner.prepare(
            rawValue: raw,
            verifiedAccountBinding: String(repeating: "a", count: 64)
        )
        expect(batch == retry, "preparing the same claimed bytes is deterministic")
        let binding = String(repeating: "a", count: 64)

        let sourceSnapshot = try Canonical.SnapshotCodec.decode(Data(#"""
        {
          "schemaVersion":1,
          "payload":{
            "jobs":[{
              "id":"j1","customerId":"c1","customerName":"Customer","title":"Job",
              "description":"Work","status":"scheduled","scheduledDate":null,
              "scheduledStartTime":null,"scheduledEndTime":null,"address":"",
              "estimateTotal":0,"laborHours":0,"laborRate":0,"materials":[],
              "materialMarkup":0,"overhead":0,"margin":0,"notes":"",
              "invoiceId":null,"createdAt":"2026-08-01T00:00:00Z","timeSessions":[],
              "futureJobField":{"keep":true}
            }],
            "futurePayloadField":"keep"
          }
        }
        """#.utf8))
        let knownRaw = #"""
        [
          {"ownerTag":"\#(tag)","id":"start-atomic","type":"timer_start","at":"2026-08-03T09:00:00Z","jobId":"j1"},
          {"ownerTag":"\#(tag)","id":"stop-atomic","type":"timer_stop","at":"2026-08-03T08:00:00Z","jobId":"j1"},
          {"ownerTag":"\#(tag)","id":"trip-atomic","type":"trip_log","at":"2026-08-03T11:00:00Z","date":"2026-08-03","odometerStart":120,"odometerEnd":115},
          {"ownerTag":"\#(tag)","id":"expense-atomic","type":"expense_log","at":"2026-08-03T12:00:00Z","date":"2026-08-03","amount":25,"category":"future-category","description":""}
        ]
        """#
        let knownBatch = try NativeWidgetActionBatchPlanner.prepare(
            rawValue: knownRaw, verifiedAccountBinding: binding
        )
        let replayed = try NativeWidgetActionReplayer.apply(knownBatch, to: sourceSnapshot)
        let replayedJob = replayed.snapshot.payload.jobs!.first!
        expect(replayed.changedActionCount == 4 && replayed.canAcknowledge,
               "all known action families apply in one replay plan")
        expect(replayedJob.status == "in_progress"
               && replayedJob.timeSessions?.count == 1
               && replayedJob.timeSessions?.first?.end == "2026-08-03T09:00:00Z",
               "timer replay advances scheduled work and clamps an early stop")
        expect(replayedJob.preservation.unknownFields["futureJobField"] == .object(["keep": .bool(true)])
               && replayed.snapshot.payload.unknownFields["futurePayloadField"] == .string("keep"),
               "replay preserves additive job and snapshot fields")
        expect(replayed.snapshot.payload.trips?.first?.id == "t_siri_trip-atomic"
               && replayed.snapshot.payload.trips?.first?.miles == 0,
               "trip replay uses the RN identifier and nonnegative mileage rule")
        expect(replayed.snapshot.payload.expenses?.first?.id == "e_siri_expense-atomic"
               && replayed.snapshot.payload.expenses?.first?.category == "other"
               && replayed.snapshot.payload.expenses?.first?.description == "Logged via Siri",
               "expense replay matches RN category and description fallbacks")
        let replayedAgain = try NativeWidgetActionReplayer.apply(knownBatch, to: replayed.snapshot)
        expect(replayedAgain.changedActionCount == 0 && replayedAgain.ignoredActionCount == 4,
               "deterministic IDs and session markers make post-commit retry idempotent")

        let transportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-widget-claim-tests-\(UUID().uuidString)", isDirectory: true)
        let claims = transportRoot.appendingPathComponent("claims", isDirectory: true)
        let lock = transportRoot.appendingPathComponent("app-group/.tradeready-widget-actions.lock")
        let queue = MemoryWidgetActionQueue(raw)
        let transport = NativeWidgetActionClaimTransport(
            queue: queue,
            claimDirectory: claims,
            lockFile: lock
        )
        defer { try? FileManager.default.removeItem(at: transportRoot) }
        let firstClaim = try transport.claim(verifiedAccountBinding: binding)
        expect(firstClaim?.sourceBytes == Data(raw.utf8),
               "claim WAL preserves the exact shared queue bytes")
        expect(queue.value == nil, "queue clears only after the durable claim is published")
        let initialClaimFiles = try FileManager.default.contentsOfDirectory(atPath: claims.path)
        expect(initialClaimFiles.count == 1,
               "one account-bound write-ahead claim is durable")

        let appended = #"{"ownerTag":"\#(tag)","id":"later-1","type":"timer_stop","at":"2026-08-03T13:00:00Z"}"#
        queue.value = String(raw.dropLast()) + "," + appended + "]"
        let recovered = try transport.claim(verifiedAccountBinding: binding)
        expect(recovered == firstClaim, "an unacknowledged claim is recovered before new input")
        if let retained = queue.value,
           let retainedBatch = try? NativeWidgetActionBatchPlanner.prepare(
               rawValue: retained, verifiedAccountBinding: binding
           ) {
            expect(retainedBatch.actions.map(\.id) == ["later-1"],
                   "recovery removes only the claimed prefix and retains concurrent appends")
        } else {
            expect(false, "retained suffix remains a valid action queue")
        }

        try transport.acknowledge(firstClaim!)
        let claimFilesAfterAcknowledgement = try FileManager.default.contentsOfDirectory(atPath: claims.path)
        expect(claimFilesAfterAcknowledgement.isEmpty,
               "acknowledgement removes exactly the replayed WAL")
        let secondClaim = try transport.claim(verifiedAccountBinding: binding)
        expect(secondClaim?.sourceBytes != firstClaim?.sourceBytes && queue.value == nil,
               "retained extension input becomes the next ordered claim")
        try transport.acknowledge(secondClaim!)

        queue.value = raw
        let corruptible = try transport.claim(verifiedAccountBinding: binding)!
        let claimFile = try FileManager.default.contentsOfDirectory(
            at: claims, includingPropertiesForKeys: nil
        ).first!
        try Data("corrupt".utf8).write(to: claimFile, options: .atomic)
        do {
            _ = try transport.claim(verifiedAccountBinding: binding)
            expect(false, "a corrupt WAL must fail closed")
        } catch NativeWidgetActionClaimError.invalidClaim {
            expect(queue.value == nil && corruptible.sourceBytes == Data(raw.utf8),
                   "corrupt WAL never fabricates or exposes queue content")
        }

        let failedRoot = transportRoot.appendingPathComponent("failed-clear", isDirectory: true)
        let failedQueue = MemoryWidgetActionQueue(raw)
        failedQueue.ignoresWrites = true
        let failedTransport = NativeWidgetActionClaimTransport(
            queue: failedQueue,
            claimDirectory: failedRoot.appendingPathComponent("claims", isDirectory: true),
            lockFile: failedRoot.appendingPathComponent("group/\(WidgetAppGroup.lockFileName)")
        )
        do {
            _ = try failedTransport.claim(verifiedAccountBinding: binding)
            expect(false, "an unverified shared-queue clear must fail")
        } catch NativeWidgetActionClaimError.verificationFailed {
            expect(failedQueue.value == raw,
                   "failed shared-queue clear retains producer bytes")
            expect((try? FileManager.default.contentsOfDirectory(
                atPath: failedRoot.appendingPathComponent("claims").path
            ).count) == 1, "failed clear retains the recoverable WAL")
        }

        let commitRoot = transportRoot.appendingPathComponent("atomic-commit", isDirectory: true)
        let commitQueue = MemoryWidgetActionQueue(knownRaw)
        let commitTransport = NativeWidgetActionClaimTransport(
            queue: commitQueue,
            claimDirectory: commitRoot.appendingPathComponent("claims", isDirectory: true),
            lockFile: commitRoot.appendingPathComponent("group/\(WidgetAppGroup.lockFileName)")
        )
        let commitRepository = Canonical.SnapshotRepository(
            primaryURL: commitRoot.appendingPathComponent("store.json")
        )
        // Final review C1: the coordinator hands every written record to the
        // enqueue hook after the canonical save and before acknowledgement.
        let commitClaims = commitRoot.appendingPathComponent("claims")
        var enqueueCalls: [(keys: [String], savedAtCall: Bool, claimAtCall: Bool)] = []
        var failNextEnqueue = true
        let recordingCoordinator = NativeWidgetActionReplayCoordinator(
            transport: commitTransport,
            repository: commitRepository,
            enqueueWrittenRecords: { records, committedSnapshot in
                enqueueCalls.append((
                    records.map { "\($0.table)/\($0.recordID)" },
                    (try? commitRepository.load()?.snapshot.payload.trips?.count) == 1
                        && committedSnapshot.payload.expenses?.count == 1,
                    ((try? FileManager.default.contentsOfDirectory(atPath: commitClaims.path))?.count ?? 0) == 1
                ))
                if failNextEnqueue {
                    failNextEnqueue = false
                    throw NativeWidgetActionReplayEnqueueError.missingRecord
                }
            }
        )
        let writtenKeys = ["jobs/j1", "trips/t_siri_trip-atomic", "expenses/e_siri_expense-atomic"]
        expect(replayed.writtenRecords.map { "\($0.table)/\($0.recordID)" } == writtenKeys,
               "C1: the replay result names every written record once, in first-touch order")
        expect(replayedAgain.writtenRecords.map { "\($0.table)/\($0.recordID)" } == writtenKeys,
               "C1: an already-applied retry still names the records it wrote earlier")
        do {
            _ = try recordingCoordinator.replayNext(snapshot: sourceSnapshot, verifiedAccountBinding: binding)
            expect(false, "C1: an enqueue failure fails the replay")
        } catch NativeWidgetActionReplayEnqueueError.missingRecord {
            expect(enqueueCalls.count == 1 && enqueueCalls[0].keys == writtenKeys,
                   "C1: the enqueue hook received every written record")
            expect(enqueueCalls[0].savedAtCall, "C1: the enqueue runs after the canonical save")
            expect(enqueueCalls[0].claimAtCall, "C1: the enqueue runs before the claim is acknowledged")
            expect(((try? FileManager.default.contentsOfDirectory(atPath: commitClaims.path))?.count ?? 0) == 1,
                   "C1: an enqueue failure leaves the claim unacknowledged")
        }
        let committed = try recordingCoordinator
            .replayNext(snapshot: try commitRepository.load()!.snapshot, verifiedAccountBinding: binding)
        expect(enqueueCalls.count == 2 && enqueueCalls[1].keys == writtenKeys,
               "C1: the retry re-queues the records the failed attempt wrote (queue dedup makes it idempotent)")
        if case let .committed(committedSnapshot, changed, ignored, ownerDropped, setAside) = committed {
            expect(changed == 0 && ignored == 4 && ownerDropped == 0 && setAside == 0 && committedSnapshot.payload.trips?.count == 1,
                   "coordinator commits the complete multi-family result (the retry finds it already applied)")
        } else { expect(false, "known batch reaches the committed state") }
        let persistedCommit = try commitRepository.load()
        expect(persistedCommit?.snapshot.payload.expenses?.count == 1,
               "all replay families publish in one canonical snapshot")
        let persistedRetry = try NativeWidgetActionReplayer.apply(
            knownBatch, to: persistedCommit!.snapshot
        )
        expect(persistedRetry.changedActionCount == 0 && persistedRetry.ignoredActionCount == 4,
               "idempotency markers survive canonical encoding and repository reload")
        let remainingCommitClaims = try FileManager.default.contentsOfDirectory(
            atPath: commitRoot.appendingPathComponent("claims").path
        )
        expect(commitQueue.value == nil && remainingCommitClaims.isEmpty,
               "successful canonical publication is followed by exact acknowledgement")

        let futureRoot = transportRoot.appendingPathComponent("future-action", isDirectory: true)
        let futureQueue = MemoryWidgetActionQueue(
            #"[{"ownerTag":"\#(tag)","id":"future-only","type":"newer_action","at":"2026-08-03T13:00:00Z","payload":{"keep":true}}]"#
        )
        let futureTransport = NativeWidgetActionClaimTransport(
            queue: futureQueue,
            claimDirectory: futureRoot.appendingPathComponent("claims", isDirectory: true),
            lockFile: futureRoot.appendingPathComponent("group/\(WidgetAppGroup.lockFileName)")
        )
        let futureRepository = Canonical.SnapshotRepository(
            primaryURL: futureRoot.appendingPathComponent("store.json")
        )
        var futureEnqueues = 0
        let retained = try NativeWidgetActionReplayCoordinator(
            transport: futureTransport,
            repository: futureRepository,
            enqueueWrittenRecords: { _, _ in futureEnqueues += 1 }
        ).replayNext(snapshot: sourceSnapshot, verifiedAccountBinding: binding)
        expect(futureEnqueues == 0, "C1: a retained (unsupported) batch enqueues nothing")
        if case .retainedUnsupported(actionCount: 1) = retained {
            let futureClaimCount = try FileManager.default.contentsOfDirectory(
                atPath: futureRoot.appendingPathComponent("claims").path
            ).count
            let futureStoredSnapshot = try futureRepository.load()
            expect(futureQueue.value == nil && futureClaimCount == 1 && futureStoredSnapshot == nil,
                   "future action bytes remain in an unacknowledged durable claim")
        } else { expect(false, "future action batch remains deferred as one unit") }

        // Final review C1: a batch that commits nothing enqueues nothing.
        let noopRoot = transportRoot.appendingPathComponent("noop", isDirectory: true)
        let noopQueue = MemoryWidgetActionQueue(#"""
        [{"ownerTag":"\#(tag)","id":"ghost","type":"timer_start","at":"2026-08-03T09:00:00Z","jobId":"missing"},
         {"ownerTag":"\#(tag)","id":"idle","type":"timer_stop","at":"2026-08-03T09:00:00Z"}]
        """#)
        var noopEnqueues = 0
        let noop = try NativeWidgetActionReplayCoordinator(
            transport: NativeWidgetActionClaimTransport(
                queue: noopQueue,
                claimDirectory: noopRoot.appendingPathComponent("claims", isDirectory: true),
                lockFile: noopRoot.appendingPathComponent("group/\(WidgetAppGroup.lockFileName)")
            ),
            repository: Canonical.SnapshotRepository(primaryURL: noopRoot.appendingPathComponent("store.json")),
            enqueueWrittenRecords: { _, _ in noopEnqueues += 1 }
        ).replayNext(snapshot: sourceSnapshot, verifiedAccountBinding: binding)
        if case let .committed(_, changed, ignored, _, setAside) = noop {
            expect(changed == 0 && ignored == 2 && setAside == 0 && noopEnqueues == 0 && noopQueue.value == nil,
                   "C1: a batch that commits nothing enqueues nothing and is acknowledged")
        } else { expect(false, "C1: the no-op batch commits") }

        do {
            _ = try NativeWidgetActionBatchPlanner.prepare(rawValue: raw, verifiedAccountBinding: "not-a-binding")
            expect(false, "invalid account binding is rejected before replay planning")
        } catch NativeWidgetActionBatchError.invalidAccountBinding {}

        rejects("{}", .malformedQueue, "non-array queue is rejected")
        // Phase 12 12.00b.2-C (L130): a bad owner-matched entry no longer
        // fails the batch. It is recorded on the batch, set aside at
        // acknowledgement, and every other entry still applies.
        setsAside("[{\"ownerTag\":\"\(tag)\",\"id\":\"\",\"type\":\"timer_stop\",\"at\":\"2026-08-03T11:00:00Z\"}]",
                  .malformedAction(index: 0), "empty identifiers are set aside")
        setsAside("[{\"ownerTag\":\"\(tag)\",\"id\":\"a\",\"type\":\"timer_stop\",\"at\":\"not-a-date\"}]",
                  .malformedAction(index: 0), "invalid action instants are set aside")
        setsAside("[{\"ownerTag\":\"\(tag)\",\"id\":\"a\",\"type\":\"timer_start\",\"at\":\"2026-08-03T11:00:00Z\"}]",
                  .invalidAction(index: 0, field: "jobId"), "timer start requires a job")
        setsAside("[{\"ownerTag\":\"\(tag)\",\"id\":\"a\",\"type\":\"timer_stop\",\"at\":\"2026-08-03T11:00:00Z\"},{\"ownerTag\":\"\(tag)\",\"id\":\"a\",\"type\":\"expense_log\",\"at\":\"2026-08-03T11:00:00Z\",\"date\":\"2026-08-03\",\"amount\":1}]",
                  .duplicateActionID("a"), "a different entry reusing an id across action types is set aside", index: 1, applied: ["a"])
        setsAside("[{\"ownerTag\":\"\(tag)\",\"id\":\"t\",\"type\":\"trip_log\",\"at\":\"2026-08-03T11:00:00Z\",\"date\":\"2026-02-30\",\"odometerStart\":0,\"odometerEnd\":1}]",
                  .invalidAction(index: 0, field: "date"), "impossible local dates are set aside")
        setsAside("[{\"ownerTag\":\"\(tag)\",\"id\":\"e\",\"type\":\"expense_log\",\"at\":\"2026-08-03T11:00:00Z\",\"date\":\"2026-08-03\",\"amount\":1000001}]",
                  .invalidAction(index: 0, field: "amount"), "expense cap is enforced")
        setsAside("[{\"ownerTag\":\"\(tag)\",\"id\":\"t\",\"type\":\"trip_log\",\"at\":\"2026-08-03T11:00:00Z\",\"date\":\"2026-08-03\",\"odometerStart\":-1,\"odometerEnd\":1}]",
                  .invalidAction(index: 0, field: "odometerStart"), "negative odometers are set aside")
        rejects("[" + Array(repeating: "{\"ownerTag\":\"\(tag)\",\"id\":\"x\",\"type\":\"timer_stop\",\"at\":\"2026-08-03T11:00:00Z\"}", count: 513).joined(separator: ",") + "]",
                .tooManyActions, "one batch still never holds more than 512 entries (the transport claims a 512-entry prefix)")

        testPartialQuarantine(
            tag: tag, binding: binding, sourceSnapshot: sourceSnapshot, root: transportRoot, expect: expect
        )
        testClaimQuarantine(
            tag: tag, binding: binding, sourceSnapshot: sourceSnapshot, root: transportRoot, expect: expect
        )

        if failures == 0 { print("PASS: native widget-action batch planner tests") }
        else { fatalError("\(failures) widget-action batch planner test(s) failed") }
    }
}

// MARK: - Phase 12 12.00b.2-C: replay sets aside only the bad entries (L130)
// and the claims it cannot use (L131)

private typealias Expect = (@autoclosure () -> Bool, String) -> Void

/// One owner's replay on a throwaway claims directory and store.
private struct ReplayHarness {
    let queue: MemoryWidgetActionQueue
    let claims: URL
    let transport: NativeWidgetActionClaimTransport
    let repository: Canonical.SnapshotRepository

    init(_ root: URL, _ label: String, _ raw: String?) {
        let directory = root.appendingPathComponent(label, isDirectory: true)
        queue = MemoryWidgetActionQueue(raw)
        claims = directory.appendingPathComponent("claims", isDirectory: true)
        transport = NativeWidgetActionClaimTransport(
            queue: queue, claimDirectory: claims,
            lockFile: directory.appendingPathComponent("group/\(WidgetAppGroup.lockFileName)")
        )
        repository = Canonical.SnapshotRepository(primaryURL: directory.appendingPathComponent("store.json"))
    }

    func coordinator(enqueue: @escaping NativeWidgetActionReplayCoordinator.EnqueueWrittenRecords = { _, _ in })
        -> NativeWidgetActionReplayCoordinator {
        NativeWidgetActionReplayCoordinator(transport: transport, repository: repository, enqueueWrittenRecords: enqueue)
    }

    /// One `replayNext` against the last committed snapshot (as AppStore does).
    func replay(_ binding: String, base: Canonical.Snapshot) throws -> NativeWidgetActionReplayCommitResult {
        try coordinator().replayNext(snapshot: saved ?? base, verifiedAccountBinding: binding)
    }

    var saved: Canonical.Snapshot? { (try? repository.load())?.snapshot }

    func files(_ prefix: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: claims, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func records(_ binding: String) -> [NativeWidgetActionQuarantine] {
        (try? transport.quarantinedQueues(accountBinding: binding)) ?? []
    }
}

private func counts(_ result: NativeWidgetActionReplayCommitResult)
    -> (changed: Int, ignored: Int, ownerDropped: Int, setAside: Int)? {
    if case let .committed(_, changed, ignored, ownerDropped, setAside) = result {
        return (changed, ignored, ownerDropped, setAside)
    }
    return nil
}

private func quarantineReason(_ result: NativeWidgetActionReplayCommitResult) -> NativeWidgetActionQuarantineReason? {
    if case let .quarantined(reason) = result { return reason }
    return nil
}

private func expenseEntry(_ tag: String, _ id: String, amount: String = "5") -> String {
    #"{"ownerTag":"\#(tag)","id":"\#(id)","type":"expense_log","at":"2026-08-03T11:10:00Z","date":"2026-08-03","amount":\#(amount),"category":"fuel"}"#
}

private func entryIDs(_ raw: String?) -> [String] {
    guard let raw, let values = try? JSONDecoder().decode([Canonical.JSONValue].self, from: Data(raw.utf8)) else { return [] }
    return values.compactMap { value -> String? in
        guard case let .object(fields) = value, case let .string(id)? = fields["id"] else { return nil }
        return id
    }
}

private func testPartialQuarantine(
    tag: String, binding: String, sourceSnapshot: Canonical.Snapshot, root: URL, expect: Expect
) {
    /// Runs one section; a throw is recorded as a failure so the
    /// sections after it still run.
    func section(_ label: String, _ body: () throws -> Void) {
        do { try body() } catch { expect(false, "\(label): threw \(error)") }
    }

    let foreignTag = NativeWidgetOwnerTag.make(binding: String(repeating: "b", count: 64))

    section("testPartialQuarantine 1") {
        // 1. One malformed and one invalid entry among valid ones (with the
        //    writer's own spacing, and a foreign entry that is also malformed).
        let startOK = #"{"ownerTag":"\#(tag)","id":"start-m","type":"timer_start","at":"2026-08-03T09:00:00Z","jobId":"j1"}"#
        let badEmptyID = #"{ "type" : "timer_stop",  "ownerTag":"\#(tag)", "id":"", "at":"2026-08-03T11:00:00Z" }"#
        let tripOK = #"{"ownerTag":"\#(tag)","id":"trip-m","type":"trip_log","at":"2026-08-03T11:05:00Z","date":"2026-08-03","odometerStart":100,"odometerEnd":115}"#
        let foreignBad = #"{"ownerTag":"\#(foreignTag)","id":"","type":"timer_stop","at":"x"}"#
        let badAmount = #"{"ownerTag":"\#(tag)","id":"expense-big","type":"expense_log","at":"2026-08-03T11:10:00Z","date":"2026-08-03","amount":2000000}"#
        let expenseOK = expenseEntry(tag, "expense-m", amount: "42.5")
        let mixedRaw = "[\n  " + [startOK, badEmptyID, tripOK, foreignBad, badAmount, expenseOK].joined(separator: ",\n  ") + "\n]"

        let mixedBatch = try NativeWidgetActionBatchPlanner.prepare(rawValue: mixedRaw, verifiedAccountBinding: binding)
        expect(mixedBatch.actions.map(\.id) == ["start-m", "trip-m", "expense-m"],
               "L130: every valid entry of a batch with bad entries is kept for replay, in order")
        expect(mixedBatch.rejected.map(\.index) == [1, 4]
               && mixedBatch.rejected.map(\.error) == [.malformedAction(index: 1), .invalidAction(index: 4, field: "amount")],
               "L130: exactly the malformed and the invalid entry are set aside, with their reasons")
        expect(mixedBatch.ownerDroppedCount == 1,
               "L130: a foreign entry is still owner-dropped before validation (§4.5), never set aside for this owner")

        let mixed = ReplayHarness(root, "partial-mixed", mixedRaw)
        let mixedRun = try mixed.replay(binding, base: sourceSnapshot)
        let mixedCounts = counts(mixedRun)
        expect(mixedCounts?.changed == 3 && mixedCounts?.ignored == 0 && mixedCounts?.ownerDropped == 1 && mixedCounts?.setAside == 2,
               "L130: the batch commits its 3 valid actions and reports 2 set aside (got \(String(describing: mixedRun)))")
        let mixedSaved = mixed.saved
        expect(mixedSaved?.payload.jobs?.first?.timeSessions?.count == 1
               && mixedSaved?.payload.trips?.map(\.id) == ["t_siri_trip-m"]
               && mixedSaved?.payload.expenses?.map(\.id) == ["e_siri_expense-m"],
               "L130: the clock-in, the trip and the valid expense are saved; the invalid expense is not")
        expect(mixed.queue.value == nil && mixed.files("claim-").isEmpty,
               "L130: the queue is cleared and the claim acknowledged")
        let mixedRecords = mixed.records(binding)
        let expectedSetAside = Data(("[" + badEmptyID + "," + badAmount + "]").utf8)
        expect(mixedRecords.count == 1, "L130: one quarantine record holds the set-aside entries (got \(mixedRecords.count))")
        expect(mixedRecords.first?.sourceBytes == expectedSetAside,
               "L130: the record keeps the exact raw bytes of the set-aside entries, and only theirs")
        expect(mixedRecords.first?.entryReasons == [.malformedAction, .invalidAction]
               && mixedRecords.first?.reason == .malformedAction && mixedRecords.first?.accountBinding == binding,
               "L130: the record names each entry's reason and is owner-scoped")
        expect(mixedRecords.first?.sourceByteCount == expectedSetAside.count,
               "L130: the record's byte count is the set-aside bytes'")
        if case .nothingPending = try mixed.replay(binding, base: sourceSnapshot) {} else {
            expect(false, "L130: nothing is left pending after the partial commit")
        }
        mixed.queue.value = "[" + expenseEntry(tag, "after-m") + "]"
        let afterMixed = counts(try mixed.replay(binding, base: sourceSnapshot))
        expect(afterMixed?.changed == 1 && afterMixed?.setAside == 0 && mixed.records(binding).count == 1,
               "L130: replay continues: a later action applies and nothing more is set aside")

    }
    section("testPartialQuarantine 2") {
        // 2. Duplicate ids: the first applies; an identical repeat (the writer's
        //    idempotent re-append, even with other key order and spacing) is
        //    skipped; a different entry under the same id is set aside.
        let dupFirst = expenseEntry(tag, "dup", amount: "5")
        let dupSame = #"{ "amount": 5, "category":"fuel", "date":"2026-08-03", "at":"2026-08-03T11:10:00Z", "type":"expense_log", "id":"dup", "ownerTag":"\#(tag)" }"#
        let dupDiffer = expenseEntry(tag, "dup", amount: "7")
        let dupTrip = #"{"ownerTag":"\#(tag)","id":"trip-d","type":"trip_log","at":"2026-08-03T11:05:00Z","date":"2026-08-03","odometerStart":1,"odometerEnd":2}"#
        let dupRaw = "[" + [dupFirst, dupSame, dupDiffer, dupTrip].joined(separator: ",") + "]"
        let dupBatch = try NativeWidgetActionBatchPlanner.prepare(rawValue: dupRaw, verifiedAccountBinding: binding)
        expect(dupBatch.actions.map(\.id) == ["dup", "trip-d"], "L130 dup: the first entry of an id applies")
        expect(dupBatch.rejected.map(\.index) == [2] && dupBatch.rejected.first?.error == .duplicateActionID("dup"),
               "L130 dup: an identical repeat is skipped; only the different entry is set aside")
        let dup = ReplayHarness(root, "partial-dup", dupRaw)
        let dupCounts = counts(try dup.replay(binding, base: sourceSnapshot))
        expect(dupCounts?.changed == 2 && dupCounts?.setAside == 1, "L130 dup: 2 applied, 1 set aside")
        expect(dup.saved?.payload.expenses?.map(\.amount) == [Decimal(5)],
               "L130 dup: the expense is recorded once, with the first entry's amount")
        expect(dup.records(binding).first?.sourceBytes == Data(("[" + dupDiffer + "]").utf8)
               && dup.records(binding).first?.entryReasons == [.duplicateActionID],
               "L130 dup: the conflicting entry's exact bytes are kept")
        // A rejected entry does not take its id: a later valid entry with it applies.
        let reuseRaw = "[" + expenseEntry(tag, "reuse", amount: "2000000") + "," + expenseEntry(tag, "reuse", amount: "9") + "]"
        let reuse = try NativeWidgetActionBatchPlanner.prepare(rawValue: reuseRaw, verifiedAccountBinding: binding)
        expect(reuse.actions.map(\.id) == ["reuse"] && reuse.actions.first?.fields["amount"] == .number(9)
               && reuse.rejected.map(\.index) == [0],
               "L130 dup: an id first used by a set-aside entry still applies from its valid entry")
        // A foreign entry reusing an owned id is owner-dropped, never a duplicate.
        let foreignDup = try NativeWidgetActionBatchPlanner.prepare(
            rawValue: "[" + expenseEntry(tag, "o1") + "," + expenseEntry(foreignTag, "o1", amount: "8") + "]",
            verifiedAccountBinding: binding
        )
        expect(foreignDup.actions.map(\.id) == ["o1"] && foreignDup.rejected.isEmpty && foreignDup.ownerDroppedCount == 1,
               "L130 dup: owner gating still runs first (§4.5)")

    }
    section("testPartialQuarantine 3") {
        // 3. Oversize: a bounded prefix per claim, the rest stays queued.
        let entries600 = (0..<600).map { expenseEntry(tag, "e\($0)", amount: "1") }
        let raw600 = "[ " + entries600.joined(separator: ", ") + " ]"
        let prefix600 = try NativeWidgetActionBatchPlanner.claimablePrefix(of: raw600)
        expect(prefix600 == "[" + entries600.prefix(512).joined(separator: ",") + "]",
               "L130 oversize: a claim takes the first 512 entries with their exact bytes")
        let small = "[" + expenseEntry(tag, "s1") + " ]"
        let smallPrefix = try NativeWidgetActionBatchPlanner.claimablePrefix(of: small)
        expect(smallPrefix == small,
               "L130 oversize: a queue of at most 512 entries is claimed byte for byte")
        let big = ReplayHarness(root, "partial-oversize", raw600)
        let firstPass = counts(try big.replay(binding, base: sourceSnapshot))
        expect(firstPass?.changed == 512 && firstPass?.setAside == 0,
               "L130 oversize: the first claim applies 512 actions (got \(String(describing: firstPass)))")
        expect(entryIDs(big.queue.value) == (512..<600).map { "e\($0)" },
               "L130 oversize: the other 88 stay queued, in order, for the next claim")
        expect(big.records(binding).isEmpty && big.files("claim-").isEmpty,
               "L130 oversize: nothing is quarantined and the claim is acknowledged")
        let secondPass = counts(try big.replay(binding, base: sourceSnapshot))
        expect(secondPass?.changed == 88 && big.queue.value == nil,
               "L130 oversize: the next claim applies the remaining 88")
        expect(big.saved?.payload.expenses?.map(\.id) == (0..<600).map { "e_siri_e\($0)" },
               "L130 oversize: all 600 apply exactly once, in order")
        // A bad entry past the first claim is set aside by the claim it lands in.
        var withBad = (0..<520).map { expenseEntry(tag, "b\($0)", amount: "1") }
        withBad[515] = expenseEntry(tag, "b515", amount: "-1")
        let bigBad = ReplayHarness(root, "partial-oversize-bad", "[" + withBad.joined(separator: ",") + "]")
        let bad1 = counts(try bigBad.replay(binding, base: sourceSnapshot))
        let bad2 = counts(try bigBad.replay(binding, base: sourceSnapshot))
        expect(bad1?.changed == 512 && bad1?.setAside == 0 && bad2?.changed == 7 && bad2?.setAside == 1,
               "L130 oversize: 512, then 7 applied and the 1 bad entry set aside")
        expect(bigBad.records(binding).first?.sourceBytes == Data(("[" + withBad[515] + "]").utf8),
               "L130 oversize: the entries left queued keep their exact bytes, so a later set-aside keeps them too")
        // A crash between the prefix claim and the queue trim recovers the same claim.
        let crash = ReplayHarness(root, "partial-oversize-crash", raw600)
        crash.queue.ignoresWrites = true
        do {
            _ = try crash.transport.claim(verifiedAccountBinding: binding)
            expect(false, "L130 oversize: an unverified queue trim fails the claim")
        } catch NativeWidgetActionClaimError.verificationFailed {}
        crash.queue.ignoresWrites = false
        expect(crash.files("claim-").count == 1 && entryIDs(crash.queue.value).count == 600,
               "sanity: the prefix claim is durable and the queue untouched")
        let recovered = counts(try crash.replay(binding, base: sourceSnapshot))
        expect(recovered?.changed == 512 && entryIDs(crash.queue.value) == (512..<600).map { "e\($0)" },
               "L130 oversize: the recovered claim trims exactly its prefix and applies once")

    }
    section("testPartialQuarantine 4") {
        // 4. Unparseable bytes: the whole queue is still set aside, bytes kept.
        for (label, raw) in [("not JSON", "{not json"), ("not a list", #"{"id":"x"}"#)] {
            let whole = ReplayHarness(root, "partial-whole-\(label.count)", raw)
            let wholeRun = try whole.replay(binding, base: sourceSnapshot)
            expect(quarantineReason(wholeRun) == .malformedQueue,
                   "L130 \(label): the whole queue is quarantined")
            expect(whole.records(binding).first?.sourceBytes == Data(raw.utf8) && whole.records(binding).first?.entryReasons == nil
                   && whole.queue.value == nil, "L130 \(label): its exact bytes are kept")
            whole.queue.value = "[" + expenseEntry(tag, "after-whole") + "]"
            let wholeNext = try whole.replay(binding, base: sourceSnapshot)
            expect(counts(wholeNext)?.changed == 1, "L130 \(label): replay continues")
        }

    }
    section("testPartialQuarantine 5") {
        // 5. At most once across an interrupted acknowledgement. (a) The enqueue
        //    fails: the claim, bad entry included, stays; nothing is set aside yet.
        let ackRaw = "[" + [expenseEntry(tag, "ack-1"), expenseEntry(tag, "ack-bad", amount: "0"), expenseEntry(tag, "ack-2")]
            .joined(separator: ",") + "]"
        let ack = ReplayHarness(root, "partial-ack", ackRaw)
        var failEnqueue = true
        do {
            _ = try ack.coordinator(enqueue: { _, _ in
                if failEnqueue { failEnqueue = false; throw NativeWidgetActionReplayEnqueueError.missingRecord }
            }).replayNext(snapshot: sourceSnapshot, verifiedAccountBinding: binding)
            expect(false, "sanity: the failed enqueue fails the replay")
        } catch NativeWidgetActionReplayEnqueueError.missingRecord {}
        expect(ack.files("claim-").count == 1 && ack.records(binding).isEmpty,
               "L130 at-most-once: before acknowledgement the bad entry is still in the claim, not yet set aside")
        guard let claimFile = ack.files("claim-").first else { return }
        let claimBytes = try Data(contentsOf: claimFile)
        let ackRetry = counts(try ack.replay(binding, base: sourceSnapshot))
        expect(ackRetry?.changed == 0 && ackRetry?.ignored == 2 && ackRetry?.setAside == 1,
               "L130 at-most-once: the retry finds both valid actions already applied and sets the bad one aside")
        // (b) A crash after the record is written but before the claim is removed.
        try claimBytes.write(to: claimFile)
        let recordName = ack.files("quarantine-").map(\.lastPathComponent)
        let ackAgain = counts(try ack.replay(binding, base: sourceSnapshot))
        expect(ackAgain?.changed == 0 && ackAgain?.ignored == 2 && ackAgain?.setAside == 1,
               "L130 at-most-once: a claim left behind after its record is applied as a no-op")
        expect(ack.files("quarantine-").map(\.lastPathComponent) == recordName && recordName.count == 1,
               "L130 at-most-once: the same record is rewritten, not duplicated")
        expect(ack.saved?.payload.expenses?.map(\.id) == ["e_siri_ack-1", "e_siri_ack-2"] && ack.files("claim-").isEmpty,
               "L130 at-most-once: each valid action is recorded once and the claim is gone")

    }
    section("testPartialQuarantine 6") {
        // 6. The raw-entry splitter on awkward but valid JSON.
        let awkward = #"[ {"a":"x,]}\"y","b":[1,{"c":"]"}]} ,-1.5e3,"s\\",null , true,[[]],{} ]"#
        let pieces = NativeWidgetActionBatchPlanner.rawEntries(of: Data(awkward.utf8)).map { $0.map { String(decoding: $0, as: UTF8.self) } }
        expect(pieces == [#"{"a":"x,]}\"y","b":[1,{"c":"]"}]}"#, "-1.5e3", #""s\\""#, "null", "true", "[[]]", "{}"],
               "L130: each entry's exact bytes are recovered from the list (got \(String(describing: pieces)))")
        expect(NativeWidgetActionBatchPlanner.rawEntries(of: Data("[]".utf8)) == [], "L130: an empty list has no entries")
    }
}

private func testClaimQuarantine(
    tag: String, binding: String, sourceSnapshot: Canonical.Snapshot, root: URL, expect: Expect
) {
    /// Runs one section; a throw is recorded as a failure so the
    /// sections after it still run.
    func section(_ label: String, _ body: () throws -> Void) {
        do { try body() } catch { expect(false, "\(label): threw \(error)") }
    }

    section("testClaimQuarantine 1") {
        // 1. An invalid (corrupt) claim is set aside with its exact bytes, and
        //    replay continues with the queue behind it.
        let invalid = ReplayHarness(root, "claim-invalid", "[" + expenseEntry(tag, "inv-1") + "]")
        _ = try invalid.transport.claim(verifiedAccountBinding: binding)
        guard let invalidFile = invalid.files("claim-").first else { return expect(false, "sanity: a claim to corrupt") }
        try Data("corrupt".utf8).write(to: invalidFile)
        invalid.queue.value = "[" + expenseEntry(tag, "inv-next") + "]"
        let invalidRun = try invalid.replay(binding, base: sourceSnapshot)
        expect(quarantineReason(invalidRun) == .invalidClaim,
               "L131: an invalid claim is quarantined instead of retried forever (got \(String(describing: invalidRun)))")
        expect(invalid.files("claim-").isEmpty, "L131: the invalid claim file is removed")
        let invalidRecords = invalid.records(binding)
        expect(invalidRecords.count == 1 && invalidRecords.first?.reason == .invalidClaim
               && invalidRecords.first?.sourceBytes == Data("corrupt".utf8) && invalidRecords.first?.accountBinding == binding,
               "L131: its exact bytes are kept in an owner-scoped quarantine record")
        expect(invalid.saved == nil && entryIDs(invalid.queue.value) == ["inv-next"],
               "L131: setting the claim aside applies nothing and leaves the queue untouched")
        let invalidNext = counts(try invalid.replay(binding, base: sourceSnapshot))
        expect(invalidNext?.changed == 1 && invalid.saved?.payload.expenses?.map(\.id) == ["e_siri_inv-next"],
               "L131: replay continues with the next claim")

    }
    section("testClaimQuarantine 2") {
        // 2. A claim file that cannot be read is never removed (nothing to keep).
        let unreadable = ReplayHarness(root, "claim-unreadable", "[" + expenseEntry(tag, "u-1") + "]")
        let unreadablePath = unreadable.claims.appendingPathComponent("claim-\(binding)-\(String(repeating: "0", count: 64)).json")
        try FileManager.default.createDirectory(at: unreadablePath, withIntermediateDirectories: true)
        do {
            _ = try unreadable.replay(binding, base: sourceSnapshot)
            expect(false, "L131: an unreadable claim fails this pass")
        } catch NativeWidgetActionClaimError.unavailable {
            expect(FileManager.default.fileExists(atPath: unreadablePath.path) && unreadable.records(binding).isEmpty
                   && entryIDs(unreadable.queue.value) == ["u-1"],
                   "L131: an unreadable claim is left in place (its bytes could not be kept) and the queue is untouched")
        }

    }
    section("testClaimQuarantine 3") {
        // 3. Two valid claims for one owner: nothing orders them, so both are set
        //    aside with their exact bytes, neither is applied, and replay continues.
        let conflict = ReplayHarness(root, "claim-conflict", "[" + expenseEntry(tag, "c-a") + "]")
        _ = try conflict.transport.claim(verifiedAccountBinding: binding)
        let other = ReplayHarness(root, "claim-conflict-other", "[" + expenseEntry(tag, "c-b") + "]")
        _ = try other.transport.claim(verifiedAccountBinding: binding)
        guard let otherFile = other.files("claim-").first else { return expect(false, "sanity: a second claim") }
        try FileManager.default.moveItem(at: otherFile, to: conflict.claims.appendingPathComponent(otherFile.lastPathComponent))
        let conflictBytes = Set(try conflict.files("claim-").map { try Data(contentsOf: $0) })
        expect(conflictBytes.count == 2, "sanity: two valid claims for one owner")
        conflict.queue.value = "[" + expenseEntry(tag, "c-next") + "]"
        let conflictRun = try conflict.replay(binding, base: sourceSnapshot)
        expect(quarantineReason(conflictRun) == .conflictingClaims,
               "L131: conflicting claims are quarantined (got \(String(describing: conflictRun)))")
        let conflictRecords = conflict.records(binding)
        expect(conflict.files("claim-").isEmpty && conflictRecords.count == 2
               && Set(conflictRecords.compactMap(\.sourceBytes)) == conflictBytes
               && conflictRecords.allSatisfy { $0.reason == .conflictingClaims },
               "L131: each conflicting claim's exact bytes are kept")
        expect(conflict.saved == nil, "L131: neither conflicting claim is applied")
        let conflictNext = counts(try conflict.replay(binding, base: sourceSnapshot))
        expect(conflictNext?.changed == 1 && conflict.saved?.payload.expenses?.map(\.id) == ["e_siri_c-next"],
               "L131: replay continues after the conflict is set aside")

    }
    section("testClaimQuarantine 4") {
        // 4. An invalid claim beside one valid claim: only the invalid one is set
        //    aside, and the valid one then replays as the owner's only claim.
        let mixed = ReplayHarness(root, "claim-mixed", "[" + expenseEntry(tag, "v-1") + "]")
        _ = try mixed.transport.claim(verifiedAccountBinding: binding)
        guard let validName = mixed.files("claim-").first?.lastPathComponent else { return expect(false, "sanity: a valid claim") }
        try Data("garbage".utf8).write(
            to: mixed.claims.appendingPathComponent("claim-\(binding)-\(String(repeating: "f", count: 64)).json")
        )
        let mixedRun = try mixed.replay(binding, base: sourceSnapshot)
        expect(quarantineReason(mixedRun) == .invalidClaim,
               "L131: an invalid claim beside a valid one is set aside")
        expect(mixed.files("claim-").map(\.lastPathComponent) == [validName] && mixed.records(binding).count == 1,
               "L131: the valid claim is kept")
        let mixedNext = counts(try mixed.replay(binding, base: sourceSnapshot))
        expect(mixedNext?.changed == 1 && mixed.saved?.payload.expenses?.map(\.id) == ["e_siri_v-1"] && mixed.files("claim-").isEmpty,
               "L131: the remaining valid claim replays once")

    }
    section("testClaimQuarantine 5") {
        // 5. Another owner's claim is still discarded unread, never quarantined
        //    for this owner (Task 11.05).
        let foreignBinding = String(repeating: "c", count: 64)
        let foreign = ReplayHarness(root, "claim-foreign", "[" + expenseEntry(NativeWidgetOwnerTag.make(binding: foreignBinding), "f-1") + "]")
        _ = try foreign.transport.claim(verifiedAccountBinding: foreignBinding)
        guard let foreignFile = foreign.files("claim-").first else { return expect(false, "sanity: a foreign claim") }
        try Data("corrupt".utf8).write(to: foreignFile)
        foreign.queue.value = nil
        if case .nothingPending = try foreign.replay(binding, base: sourceSnapshot) {} else {
            expect(false, "L131: another owner's claim is discarded, not quarantined")
        }
        expect(foreign.files("").isEmpty, "L131: nothing of the other owner's remains")
    }
}
