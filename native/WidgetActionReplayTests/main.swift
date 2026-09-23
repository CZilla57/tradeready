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
        var failures = 0
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

        let raw = """
        [{"id":"start-1","type":"timer_start","at":"2026-08-03T09:00:00.000Z","jobId":"j1","future":true},
         {"id":"stop-1","type":"timer_stop","at":"2026-08-03T11:00:00Z","jobId":"j1"},
         {"id":"trip-1","type":"trip_log","at":"2026-08-03T11:05:00Z","date":"2026-08-03","odometerStart":100,"odometerEnd":115},
         {"id":"expense-1","type":"expense_log","at":"2026-08-03T11:10:00Z","date":"2026-08-03","amount":42.5,"category":"materials","description":"Lumber"},
         {"id":"future-1","type":"future_action","at":"2026-08-03T12:00:00Z","payload":{"keep":"exact"}}]
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
          {"id":"start-atomic","type":"timer_start","at":"2026-08-03T09:00:00Z","jobId":"j1"},
          {"id":"stop-atomic","type":"timer_stop","at":"2026-08-03T08:00:00Z","jobId":"j1"},
          {"id":"trip-atomic","type":"trip_log","at":"2026-08-03T11:00:00Z","date":"2026-08-03","odometerStart":120,"odometerEnd":115},
          {"id":"expense-atomic","type":"expense_log","at":"2026-08-03T12:00:00Z","date":"2026-08-03","amount":25,"category":"future-category","description":""}
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

        let appended = #"{"id":"later-1","type":"timer_stop","at":"2026-08-03T13:00:00Z"}"#
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
            lockFile: failedRoot.appendingPathComponent("group/\(NativeWidgetActionClaimTransport.lockFileName)")
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
            lockFile: commitRoot.appendingPathComponent("group/\(NativeWidgetActionClaimTransport.lockFileName)")
        )
        let commitRepository = Canonical.SnapshotRepository(
            primaryURL: commitRoot.appendingPathComponent("store.json")
        )
        let committed = try NativeWidgetActionReplayCoordinator(
            transport: commitTransport,
            repository: commitRepository
        ).replayNext(snapshot: sourceSnapshot, verifiedAccountBinding: binding)
        if case let .committed(committedSnapshot, changed, ignored) = committed {
            expect(changed == 4 && ignored == 0 && committedSnapshot.payload.trips?.count == 1,
                   "coordinator commits the complete multi-family result")
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
            #"[{"id":"future-only","type":"newer_action","at":"2026-08-03T13:00:00Z","payload":{"keep":true}}]"#
        )
        let futureTransport = NativeWidgetActionClaimTransport(
            queue: futureQueue,
            claimDirectory: futureRoot.appendingPathComponent("claims", isDirectory: true),
            lockFile: futureRoot.appendingPathComponent("group/\(NativeWidgetActionClaimTransport.lockFileName)")
        )
        let futureRepository = Canonical.SnapshotRepository(
            primaryURL: futureRoot.appendingPathComponent("store.json")
        )
        let retained = try NativeWidgetActionReplayCoordinator(
            transport: futureTransport,
            repository: futureRepository
        ).replayNext(snapshot: sourceSnapshot, verifiedAccountBinding: binding)
        if case .retainedUnsupported(actionCount: 1) = retained {
            let futureClaimCount = try FileManager.default.contentsOfDirectory(
                atPath: futureRoot.appendingPathComponent("claims").path
            ).count
            let futureStoredSnapshot = try futureRepository.load()
            expect(futureQueue.value == nil && futureClaimCount == 1 && futureStoredSnapshot == nil,
                   "future action bytes remain in an unacknowledged durable claim")
        } else { expect(false, "future action batch remains deferred as one unit") }

        do {
            _ = try NativeWidgetActionBatchPlanner.prepare(rawValue: raw, verifiedAccountBinding: "not-a-binding")
            expect(false, "invalid account binding is rejected before replay planning")
        } catch NativeWidgetActionBatchError.invalidAccountBinding {}

        rejects("{}", .malformedQueue, "non-array queue is rejected")
        rejects("[{\"id\":\"\",\"type\":\"timer_stop\",\"at\":\"2026-08-03T11:00:00Z\"}]",
                .malformedAction(index: 0), "empty identifiers are rejected")
        rejects("[{\"id\":\"a\",\"type\":\"timer_stop\",\"at\":\"not-a-date\"}]",
                .malformedAction(index: 0), "invalid action instants are rejected")
        rejects("[{\"id\":\"a\",\"type\":\"timer_start\",\"at\":\"2026-08-03T11:00:00Z\"}]",
                .invalidAction(index: 0, field: "jobId"), "timer start requires a job")
        rejects("[{\"id\":\"a\",\"type\":\"timer_stop\",\"at\":\"2026-08-03T11:00:00Z\"},{\"id\":\"a\",\"type\":\"expense_log\",\"at\":\"2026-08-03T11:00:00Z\",\"date\":\"2026-08-03\",\"amount\":1}]",
                .duplicateActionID("a"), "duplicate IDs across action types reject the batch")
        rejects("[{\"id\":\"t\",\"type\":\"trip_log\",\"at\":\"2026-08-03T11:00:00Z\",\"date\":\"2026-02-30\",\"odometerStart\":0,\"odometerEnd\":1}]",
                .invalidAction(index: 0, field: "date"), "impossible local dates are rejected")
        rejects("[{\"id\":\"e\",\"type\":\"expense_log\",\"at\":\"2026-08-03T11:00:00Z\",\"date\":\"2026-08-03\",\"amount\":1000001}]",
                .invalidAction(index: 0, field: "amount"), "expense cap is enforced")
        rejects("[{\"id\":\"t\",\"type\":\"trip_log\",\"at\":\"2026-08-03T11:00:00Z\",\"date\":\"2026-08-03\",\"odometerStart\":-1,\"odometerEnd\":1}]",
                .invalidAction(index: 0, field: "odometerStart"), "negative odometers are rejected")

        if failures == 0 { print("PASS: native widget-action batch planner tests") }
        else { fatalError("\(failures) widget-action batch planner test(s) failed") }
    }
}
