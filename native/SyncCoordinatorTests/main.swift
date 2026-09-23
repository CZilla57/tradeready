import Foundation

private final class FakePushService: NativeMutationPushing {
    var callCount = 0
    var lastSubject: String?
    var lastSessionBytes: Data?
    var lastItemCount = 0
    var handler: (_ items: [Canonical.MutationItem], _ callIndex: Int) -> NativeMutationPushOutcome

    init(handler: @escaping (_ items: [Canonical.MutationItem], _ callIndex: Int) -> NativeMutationPushOutcome) {
        self.handler = handler
    }

    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem]
    ) async throws -> NativeMutationPushOutcome {
        let index = callCount
        callCount += 1
        lastSubject = expectedUserSubject
        lastSessionBytes = sessionBytes
        lastItemCount = items.count
        return handler(items, index)
    }
}

/// A push that suspends until the test resumes it — used to observe an in-flight
/// pass without real concurrency races.
private final class GatedPushService: NativeMutationPushing {
    var callCount = 0
    var didStart = false
    var receivedItems: [[Canonical.MutationItem]] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var openRequested = false
    var result: NativeMutationPushOutcome
    let gatesEveryCall: Bool

    init(result: NativeMutationPushOutcome, gatesEveryCall: Bool = true) {
        self.result = result
        self.gatesEveryCall = gatesEveryCall
    }

    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem]
    ) async throws -> NativeMutationPushOutcome {
        callCount += 1
        receivedItems.append(items)
        didStart = true
        if !gatesEveryCall, callCount > 1 { return result }
        await withCheckedContinuation { continuation in
            if openRequested {
                openRequested = false
                continuation.resume()
            } else {
                gate = continuation
            }
        }
        return result
    }

    func open() {
        if let gate {
            gate.resume()
            self.gate = nil
        } else {
            openRequested = true
        }
    }
}

private final class FakeReachability: NativeSyncReachability {
    var reachable: Bool
    init(reachable: Bool) { self.reachable = reachable }
    func isReachable() async -> Bool { reachable }
}

private final class EnvironmentBlockedPush: NativeMutationPushing {
    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem]
    ) async throws -> NativeMutationPushOutcome {
        throw NativeMutationPushError.productionWriteBlocked
    }
}

@main
struct SyncCoordinatorTests {
    @MainActor
    static func main() async throws {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures += 1; print("FAIL: \(label)") }
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tradeready-sync-coordinator-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let credentials = NativeSyncCredentials(
            subject: "11111111-2222-3333-4444-555555555555",
            sessionBytes: Data(#"{"access_token":"t"}"#.utf8)
        )
        func makeQueue(_ name: String) -> Canonical.NativeMutationQueue {
            Canonical.NativeMutationQueue(fileURL: root.appendingPathComponent("\(name).json"))
        }
        func seed(_ queue: Canonical.NativeMutationQueue, _ ids: [String]) throws {
            for id in ids {
                try queue.enqueue(
                    table: "jobs", op: .upsert, recordId: id,
                    payload: .object(["id": .string(id)])
                )
            }
        }
        func drained(pushed: Int, auth: Bool = false) -> NativeMutationPushOutcome {
            .init(remaining: [], pushedCount: pushed, failedTables: [], authRejected: auth, lastDiagnosticCode: nil)
        }
        func retained(_ items: [Canonical.MutationItem], pushed: Int, auth: Bool = false) -> NativeMutationPushOutcome {
            .init(
                remaining: items, pushedCount: pushed,
                failedTables: items.map(\.table), authRejected: auth,
                lastDiagnosticCode: auth ? "http-response/jobs/401" : "http-response/jobs/500"
            )
        }

        // Empty queue is a no-op that never touches the network.
        let idleQueue = makeQueue("idle")
        let idlePush = FakePushService { _, _ in drained(pushed: 0) }
        let idle = NativeSyncCoordinator(
            push: idlePush, queue: idleQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials }
        )
        expect(await idle.sync() == .idleNoChanges, "an empty queue is a no-op sync")
        expect(idlePush.callCount == 0, "an empty queue never calls the push transport")

        // Offline retains the queue without burning a push.
        let offlineQueue = makeQueue("offline")
        try seed(offlineQueue, ["j1"])
        let offlinePush = FakePushService { _, _ in drained(pushed: 1) }
        let offline = NativeSyncCoordinator(
            push: offlinePush, queue: offlineQueue,
            reachability: FakeReachability(reachable: false),
            credentialsProvider: { credentials }
        )
        expect(await offline.sync(trigger: .foreground) == .offline, "an unreachable device does not push")
        expect(offlinePush.callCount == 0 && offlineQueue.load().count == 1,
               "offline sync retains the queue and skips the transport")

        // Signed out skips cleanly.
        let signedOutQueue = makeQueue("signed-out")
        try seed(signedOutQueue, ["j1"])
        let signedOutPush = FakePushService { _, _ in drained(pushed: 1) }
        let signedOut = NativeSyncCoordinator(
            push: signedOutPush, queue: signedOutQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { nil }
        )
        expect(await signedOut.sync(trigger: .foreground) == .notAuthenticated,
               "a signed-out device does not push")
        expect(signedOutPush.callCount == 0, "signed-out sync skips the transport")

        // A full drain clears the queue and passes the real credentials through.
        let successQueue = makeQueue("success")
        try seed(successQueue, ["j1", "j2"])
        let successPush = FakePushService { _, _ in drained(pushed: 2) }
        var successStatuses: [NativeSyncStatus] = []
        let success = NativeSyncCoordinator(
            push: successPush, queue: successQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            statusChanged: { successStatuses.append($0) }
        )
        expect(await success.sync(trigger: .foreground) == .completed(pushed: 2, authRefreshed: false),
               "a reachable, authenticated pass drains the queue")
        expect(successQueue.load().isEmpty, "a drained queue is emptied on disk")
        expect(successPush.lastSubject == credentials.subject
               && successPush.lastSessionBytes == credentials.sessionBytes,
               "the pass forwards the current verified subject and session")
        expect(success.status().consecutiveFailures == 0, "a full drain resets the failure count")
        expect(successStatuses.contains(where: { $0.isSyncing })
               && successStatuses.last?.isSyncing == false,
               "status observations bracket an in-flight pass")
        expect(success.status().lastSuccessfulSyncAt != nil,
               "a fully successful pass records its completion time")

        // Partial failure retains the remainder and opens a backoff window.
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let partialQueue = makeQueue("partial")
        try seed(partialQueue, ["j1", "j2"])
        let retainedItem = Array(partialQueue.load().suffix(1))
        let partialPush = FakePushService { _, index in
            index == 0 ? retained(retainedItem, pushed: 1) : drained(pushed: 1)
        }
        let partial = NativeSyncCoordinator(
            push: partialPush, queue: partialQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            now: { clock }, baseBackoff: 5, maxBackoff: 300
        )
        expect(await partial.sync(trigger: .foreground) == .partial(pushed: 1, remaining: 1, authRefreshed: false),
               "a partial push reports the retained remainder")
        expect(partialQueue.load().count == 1, "the unacknowledged remainder stays queued")
        expect(partial.status().consecutiveFailures == 1
               && partial.status().nextEarliestAttempt == clock.addingTimeInterval(5),
               "a failure opens an exponential backoff window")
        expect(partial.status().diagnosticCode == "http-response/jobs/500",
               "a partial push exposes only its bounded diagnostic code")
        // A trigger inside the window is deferred and does not re-push.
        expect(await partial.sync(trigger: .foreground) == .backoffDeferred,
               "a trigger inside the backoff window is deferred")
        expect(partialPush.callCount == 1, "a deferred trigger never reaches the transport")
        // Manual retry bypasses the window.
        clock = clock.addingTimeInterval(1)
        expect(await partial.sync(trigger: .manual) == .completed(pushed: 1, authRefreshed: false),
               "a manual trigger bypasses the backoff window")
        expect(partialQueue.load().isEmpty && partial.status().consecutiveFailures == 0,
               "a successful retry drains the queue and clears backoff")

        let protectedPullQueue = makeQueue("pending-local-skips-pull")
        try seed(protectedPullQueue, ["j-local"])
        let protectedRemainder = protectedPullQueue.load()
        var protectedPullCount = 0
        let protectedPullPush = FakePushService { items, _ in
            retained(items, pushed: 0)
        }
        let protectedPull = NativeSyncCoordinator(
            push: protectedPullPush, queue: protectedPullQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            pull: { protectedPullCount += 1; return .completed }
        )
        expect(await protectedPull.sync(trigger: .foreground)
               == .partial(pushed: 0, remaining: protectedRemainder.count, authRefreshed: false),
               "a failed local push retains its pending mutation")
        expect(protectedPullCount == 0,
               "remote pull waits rather than overwriting pending local truth")

        // Backoff elapses: a later trigger runs again on its own.
        clock = Date(timeIntervalSince1970: 2_000_000)
        let backoffQueue = makeQueue("backoff")
        try seed(backoffQueue, ["j1"])
        let backoffRemainder = backoffQueue.load()
        let backoffPush = FakePushService { _, index in
            index == 0 ? retained(backoffRemainder, pushed: 0) : drained(pushed: 1)
        }
        let backoff = NativeSyncCoordinator(
            push: backoffPush, queue: backoffQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            now: { clock }, baseBackoff: 5, maxBackoff: 300
        )
        _ = await backoff.sync(trigger: .foreground)
        expect(await backoff.sync(trigger: .periodic) == .backoffDeferred, "within the window a periodic tick defers")
        clock = clock.addingTimeInterval(6)
        expect(await backoff.sync(trigger: .periodic) == .completed(pushed: 1, authRefreshed: false),
               "once the window elapses the next trigger pushes again")

        // Auth rejection refreshes the session once and retries the remainder.
        let authQueue = makeQueue("auth")
        try seed(authQueue, ["j1"])
        let authRemainder = authQueue.load()
        var refreshCount = 0
        let authPush = FakePushService { _, index in
            index == 0 ? retained(authRemainder, pushed: 0, auth: true) : drained(pushed: 1)
        }
        let auth = NativeSyncCoordinator(
            push: authPush, queue: authQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            refreshSession: { refreshCount += 1; return true }
        )
        expect(await auth.sync(trigger: .foreground) == .completed(pushed: 1, authRefreshed: true),
               "an auth rejection refreshes the session and retries the remainder")
        expect(refreshCount == 1 && authPush.callCount == 2, "the refresh-and-retry runs exactly once")
        expect(authQueue.load().isEmpty, "the retried push drains the queue")

        // A failed refresh retains the remainder without a retry.
        let authFailQueue = makeQueue("auth-fail")
        try seed(authFailQueue, ["j1"])
        let authFailRemainder = authFailQueue.load()
        let authFailPush = FakePushService { _, _ in retained(authFailRemainder, pushed: 0, auth: true) }
        let authFail = NativeSyncCoordinator(
            push: authFailPush, queue: authFailQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            refreshSession: { false }
        )
        expect(await authFail.sync(trigger: .foreground) == .partial(pushed: 0, remaining: 1, authRefreshed: false),
               "a failed refresh retains the remainder without retrying")
        expect(authFailPush.callCount == 1 && authFailQueue.load().count == 1,
               "a failed refresh does not double-push and keeps the queue")

        // A transport/configuration throw fails closed and retains the queue.
        struct PushBlewUp: Error {}
        final class ThrowingPush: NativeMutationPushing {
            func push(sessionBytes: Data, expectedUserSubject: String, items: [Canonical.MutationItem]) async throws -> NativeMutationPushOutcome {
                throw PushBlewUp()
            }
        }
        let throwQueue = makeQueue("throw")
        try seed(throwQueue, ["j1"])
        let throwing = NativeSyncCoordinator(
            push: ThrowingPush(), queue: throwQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials }
        )
        expect(await throwing.sync(trigger: .foreground) == .failed(remaining: 1),
               "a push that throws fails closed and retains the queue")
        expect(throwQueue.load().count == 1, "a thrown push loses no queued work")

        let environmentQueue = makeQueue("environment-blocked")
        try seed(environmentQueue, ["j1"])
        var environmentPullCount = 0
        let environmentBlocked = NativeSyncCoordinator(
            push: EnvironmentBlockedPush(), queue: environmentQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            pull: { environmentPullCount += 1; return .completed }
        )
        expect(await environmentBlocked.sync(trigger: .foreground) == .failed(remaining: 1),
               "an unsafe Supabase environment fails closed")
        expect(environmentQueue.load().count == 1 && environmentPullCount == 0,
               "an environment block retains queued work and skips the pull")
        expect(environmentBlocked.status().diagnosticCode == "push/environment",
               "an environment block exposes only a bounded diagnostic code")

        // A trigger arriving mid-pass coalesces into the running pass.
        let coalesceQueue = makeQueue("coalesce")
        try seed(coalesceQueue, ["j1"])
        let gated = GatedPushService(result: drained(pushed: 1))
        let coalesce = NativeSyncCoordinator(
            push: gated, queue: coalesceQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials }
        )
        let firstPass = Task { await coalesce.sync(trigger: .foreground) }
        while !gated.didStart { await Task.yield() }
        let overlapping = await coalesce.sync(trigger: .localChange)
        expect(overlapping == .alreadyRunning, "a trigger during an in-flight pass reports already-running")
        async let waitedOutcome = coalesce.waitUntilIdle()
        await Task.yield()
        gated.open()
        let firstOutcome = await firstPass.value
        expect(firstOutcome == .completed(pushed: 1, authRefreshed: false), "the in-flight pass completes normally")
        expect(await waitedOutcome == firstOutcome,
               "an awaited caller remains attached until the coalesced pass is idle")
        expect(gated.callCount == 1 && coalesceQueue.load().isEmpty,
               "the coalesced re-run sees an empty queue and does not push again")

        // A newer mutation for the same record can arrive while the older one
        // is on the wire (delete undo is the important production case). The
        // stale acknowledgement must retain and then push the replacement.
        let inFlightQueue = makeQueue("in-flight-replacement")
        try inFlightQueue.enqueue(
            table: "jobs", op: .delete, recordId: "j-undo", payload: nil
        )
        let inFlightPush = GatedPushService(
            result: drained(pushed: 1),
            gatesEveryCall: false
        )
        let inFlight = NativeSyncCoordinator(
            push: inFlightPush, queue: inFlightQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials }
        )
        let deletingPass = Task { await inFlight.sync(trigger: .localChange) }
        while !inFlightPush.didStart { await Task.yield() }
        try inFlightQueue.enqueue(
            table: "jobs", op: .upsert, recordId: "j-undo",
            payload: .object(["id": .string("j-undo"), "title": .string("Restored")])
        )
        expect(await inFlight.sync(trigger: .localChange) == .alreadyRunning,
               "replacement mutation coalesces behind the active delete push")
        inFlightPush.open()
        _ = await deletingPass.value
        expect(inFlightPush.callCount == 2,
               "the coordinator reruns after an in-flight replacement")
        expect(inFlightPush.receivedItems.last?.first?.op == .upsert,
               "the rerun pushes the newer restored-record upsert")
        expect(inFlightQueue.load().isEmpty,
               "the replacement drains only after its own acknowledgement")

        // Account scrub can happen while a network request is suspended. The
        // stale response must never recreate the old owner's queue afterward.
        let invalidatedQueue = makeQueue("invalidated-account")
        try seed(invalidatedQueue, ["j1"])
        let invalidatedGate = GatedPushService(
            result: retained(invalidatedQueue.load(), pushed: 0)
        )
        let invalidated = NativeSyncCoordinator(
            push: invalidatedGate, queue: invalidatedQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials }
        )
        let stalePass = Task { await invalidated.sync(trigger: .foreground) }
        while !invalidatedGate.didStart { await Task.yield() }
        try invalidatedQueue.removeAll()
        invalidated.reset()
        invalidatedGate.open()
        _ = await stalePass.value
        expect(invalidatedQueue.load().isEmpty
               && invalidated.status().diagnosticCode == nil,
               "an in-flight old-account response cannot republish scrubbed work")

        // A pull step runs after a reachable, authenticated push and drains the
        // queue in the same pass.
        let pullQueue = makeQueue("pull")
        try seed(pullQueue, ["j1"])
        var pullCount = 0
        let pullPush = FakePushService { _, _ in drained(pushed: 1) }
        let withPull = NativeSyncCoordinator(
            push: pullPush, queue: pullQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            pull: { pullCount += 1; return .completed }
        )
        expect(await withPull.sync(trigger: .foreground) == .completed(pushed: 1, authRefreshed: false),
               "a push-then-pull pass completes")
        expect(pullCount == 1, "the pull runs after the push")

        // An empty queue still pulls when a pull is configured (a foreground with
        // no local edits must fetch remote changes).
        let pullOnlyQueue = makeQueue("pull-only")
        var pullOnlyCount = 0
        let pullOnly = NativeSyncCoordinator(
            push: FakePushService { _, _ in drained(pushed: 0) }, queue: pullOnlyQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            pull: { pullOnlyCount += 1; return .completed }
        )
        expect(await pullOnly.sync(trigger: .foreground) == .completed(pushed: 0, authRefreshed: false),
               "an empty queue with a pull configured still runs a pass")
        expect(pullOnlyCount == 1, "the pull runs even with nothing to push")

        // The pull is skipped when the pass cannot reach the server.
        var offlinePullCount = 0
        let offlinePullQueue = makeQueue("offline-pull")
        let offlinePull = NativeSyncCoordinator(
            push: FakePushService { _, _ in drained(pushed: 0) }, queue: offlinePullQueue,
            reachability: FakeReachability(reachable: false),
            credentialsProvider: { credentials },
            pull: { offlinePullCount += 1; return .completed }
        )
        expect(await offlinePull.sync(trigger: .foreground) == .offline, "an offline pass reports offline")
        expect(offlinePullCount == 0, "an offline pass never pulls")

        // The pull is skipped when signed out.
        var signedOutPullCount = 0
        let signedOutPullQueue = makeQueue("signed-out-pull")
        let signedOutPull = NativeSyncCoordinator(
            push: FakePushService { _, _ in drained(pushed: 0) }, queue: signedOutPullQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { nil },
            pull: { signedOutPullCount += 1; return .completed }
        )
        expect(await signedOutPull.sync(trigger: .foreground) == .notAuthenticated, "a signed-out pass reports not-authenticated")
        expect(signedOutPullCount == 0, "a signed-out pass never pulls")

        // Pending local writes protect canonical truth during the failed pass
        // and throughout its push-failure backoff window.
        var backoffPullCount = 0
        let backoffPullQueue = makeQueue("backoff-pull")
        try seed(backoffPullQueue, ["j1"])
        var backoffPullClock = Date(timeIntervalSince1970: 3_000_000)
        let backoffPullRemainder = backoffPullQueue.load()
        let backoffPull = NativeSyncCoordinator(
            push: FakePushService { _, _ in retained(backoffPullRemainder, pushed: 0) },
            queue: backoffPullQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            pull: { backoffPullCount += 1; return .completed },
            now: { backoffPullClock }, baseBackoff: 5, maxBackoff: 300
        )
        _ = await backoffPull.sync(trigger: .foreground)
        expect(backoffPullCount == 0, "a failed first push does not pull over pending local truth")
        backoffPullClock = backoffPullClock.addingTimeInterval(1)
        expect(await backoffPull.sync(trigger: .foreground) == .backoffDeferred, "a pass inside the window defers")
        expect(backoffPullCount == 0, "a deferred pass does not pull")

        // A scheduled retry makes network-interruption recovery automatic even
        // when no later foreground or edit trigger arrives.
        let automaticQueue = makeQueue("automatic-retry")
        try seed(automaticQueue, ["j1"])
        let automaticRemainder = automaticQueue.load()
        let automaticPush = FakePushService { _, index in
            index == 0 ? retained(automaticRemainder, pushed: 0) : drained(pushed: 1)
        }
        let automatic = NativeSyncCoordinator(
            push: automaticPush, queue: automaticQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            baseBackoff: 0.01, maxBackoff: 0.01
        )
        _ = await automatic.sync(trigger: .foreground)
        try await Task.sleep(nanoseconds: 80_000_000)
        expect(automaticPush.callCount == 2 && automaticQueue.load().isEmpty,
               "a failed push retries automatically after backoff")

        // Pull failures are visible and retryable even when there was nothing
        // waiting to push.
        let pullFailureQueue = makeQueue("pull-failure")
        var pullFailureCount = 0
        let pullFailure = NativeSyncCoordinator(
            push: FakePushService { _, _ in drained(pushed: 0) }, queue: pullFailureQueue,
            reachability: FakeReachability(reachable: true),
            credentialsProvider: { credentials },
            pull: {
                pullFailureCount += 1
                return pullFailureCount == 1 ? .failed("transport/jobs") : .completed
            },
            baseBackoff: 0.01, maxBackoff: 0.01
        )
        _ = await pullFailure.sync(trigger: .foreground)
        expect(pullFailure.status().diagnosticCode == "transport/jobs",
               "a pull failure reaches the privacy-safe status surface")
        try await Task.sleep(nanoseconds: 80_000_000)
        expect(pullFailureCount == 2
               && pullFailure.status().diagnosticCode == nil
               && pullFailure.status().consecutiveFailures == 0
               && pullFailure.status().lastSuccessfulSyncAt != nil,
               "a scheduled pull retry clears the diagnostic after success")

        automatic.reset()
        expect(automatic.status() == NativeSyncStatus(),
               "an account-boundary reset clears retries and prior status")

        if failures == 0 { print("PASS: native sync coordinator tests") }
        else { exit(1) }
    }
}
