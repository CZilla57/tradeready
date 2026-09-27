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

/// Phase 12 (12.00b.1): a push that answers from a per-call script and
/// records, per call, the record keys it was told got a 403 before the
/// pass's one successful refresh.
private final class ScriptedPushService: NativeMutationPushing {
    var calls: [(items: [Canonical.MutationItem], forbiddenBeforeRefresh: Set<String>)] = []
    var script: (_ items: [Canonical.MutationItem], _ forbiddenBeforeRefresh: Set<String>, _ callIndex: Int) -> NativeMutationPushOutcome
    var beforeReturn: () -> Void = {}

    init(script: @escaping (_ items: [Canonical.MutationItem], _ forbiddenBeforeRefresh: Set<String>, _ callIndex: Int) -> NativeMutationPushOutcome) {
        self.script = script
    }

    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem]
    ) async throws -> NativeMutationPushOutcome {
        try await push(sessionBytes: sessionBytes, expectedUserSubject: expectedUserSubject, items: items, forbiddenBeforeRefresh: [])
    }

    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem],
        forbiddenBeforeRefresh: Set<String>
    ) async throws -> NativeMutationPushOutcome {
        let index = calls.count
        calls.append((items, forbiddenBeforeRefresh))
        let outcome = script(items, forbiddenBeforeRefresh, index)
        beforeReturn()
        return outcome
    }
}

/// The outcome the real push builds for these per-change HTTP statuses: the
/// shared classification, per change, with the 403 keys it reports back.
private func classifiedOutcome(
    _ items: [Canonical.MutationItem],
    forbiddenBeforeRefresh: Set<String>,
    status: (Canonical.MutationItem) -> Int
) -> NativeMutationPushOutcome {
    var remaining: [Canonical.MutationItem] = []
    var rejected: [NativeMutationRejection] = []
    var forbiddenKeys: Set<String> = []
    var pushed = 0
    var auth = false
    for item in items {
        let code = status(item)
        let key = NativeMutationPushClassification.recordKey(item)
        switch NativeMutationPushClassification.classify(
            .http(statusCode: code), forbiddenBeforeRefresh: forbiddenBeforeRefresh.contains(key)
        ) {
        case .accepted: pushed += 1
        case .rejected: rejected.append(.init(item: item, statusCode: code))
        case .authRejected:
            auth = true
            remaining.append(item)
            if code == 403 { forbiddenKeys.insert(key) }
        case .transient: remaining.append(item)
        }
    }
    return NativeMutationPushOutcome(
        remaining: remaining, pushedCount: pushed,
        failedTables: remaining.isEmpty ? [] : ["jobs"], authRejected: auth,
        lastDiagnosticCode: nil, rejected: rejected, forbiddenKeys: forbiddenKeys
    )
}

private struct SettleFailed: Error {}

/// Phase 12 (12.00b.1, I2): refused changes leave the queue through the
/// settle step, a repeated 403 is refused after one refresh, a failed settle
/// keeps the whole attempt queued, and the pull keeps running.
@MainActor
private func rejectedChanges(
    makeQueue: (String) -> Canonical.NativeMutationQueue,
    seed: (Canonical.NativeMutationQueue, [String]) throws -> Void,
    credentials: NativeSyncCredentials,
    expect: (Bool, String) -> Void
) async throws {
    func outcome(
        remaining: [Canonical.MutationItem] = [], pushed: Int, rejected: [NativeMutationRejection] = [],
        auth: Bool = false, code: String? = nil
    ) -> NativeMutationPushOutcome {
        .init(
            remaining: remaining, pushedCount: pushed,
            failedTables: remaining.isEmpty ? [] : ["jobs"], authRejected: auth,
            lastDiagnosticCode: code, rejected: rejected
        )
    }

    // A refused change is settled (set aside) and then leaves the queue; the
    // accepted ones are cleared; the pass completes and the pull runs.
    let queue = makeQueue("rejected-settle")
    try seed(queue, ["good", "poison", "slow"])
    let items = queue.load()
    let good = items[0], poison = items[1], slow = items[2]
    var settlements: [NativeMutationPushSettlement] = []
    var pulls = 0
    let push = ScriptedPushService { _, _, _ in
        outcome(remaining: [slow], pushed: 1, rejected: [.init(item: poison, statusCode: 422)], code: "rejected/jobs/422")
    }
    let coordinator = NativeSyncCoordinator(
        push: push, queue: queue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        settleRejected: { settlements.append($0) },
        pull: { pulls += 1; return .completed }
    )
    let result = await coordinator.sync(trigger: .foreground)
    expect(result == .partial(pushed: 1, remaining: 1, authRefreshed: false),
           "12.00b.1: the refused change is not counted as remaining")
    expect(settlements.count == 1 && settlements.first?.rejected == [.init(item: poison, statusCode: 422)]
           && settlements.first?.cleared == [good],
           "12.00b.1: one settle per attempt: the refused change, and the accepted one cleared")
    expect(queue.load() == [slow], "12.00b.1: the refused change left the queue; the transient one stays")
    expect(pulls == 1, "12.00b.1: the pull still runs with a transient change queued")

    // Phase 12 (12.00b.2-L, P12-017): a guarded change whose row moved on
    // leaves the queue and is handed to the settle step as superseded, never
    // as cleared (it reached nothing, so it clears no refused change of that
    // record). The pass completes and the pull runs.
    let supersedeQueue = makeQueue("guard-superseded")
    try seed(supersedeQueue, ["kept", "moved-on"])
    let keptItem = supersedeQueue.load()[0], movedOn = supersedeQueue.load()[1]
    var guardSettled: [NativeMutationPushSettlement] = []
    var guardPulls = 0
    let guardCoordinator = NativeSyncCoordinator(
        push: ScriptedPushService { _, _, _ in
            var result = outcome(pushed: 1)
            result.superseded = [movedOn]
            return result
        },
        queue: supersedeQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        settleRejected: { guardSettled.append($0) },
        pull: { guardPulls += 1; return .completed }
    )
    expect(await guardCoordinator.sync(trigger: .foreground) == .completed(pushed: 1, authRefreshed: false),
           "P12-017: a superseded guarded change is not a failure")
    expect(guardSettled.count == 1 && guardSettled.first?.superseded == [movedOn]
           && guardSettled.first?.cleared == [keptItem] && guardSettled.first?.rejected == [],
           "P12-017: the settle step gets it as superseded, not cleared")
    expect(supersedeQueue.load().isEmpty && guardPulls == 1, "P12-017: it left the queue and the pull ran")
    // A settle step that cannot take it keeps the whole attempt queued.
    let supersedeFailQueue = makeQueue("guard-superseded-fail")
    try seed(supersedeFailQueue, ["moved-on-2"])
    let movedOnFail = supersedeFailQueue.load()[0]
    let guardFail = NativeSyncCoordinator(
        push: ScriptedPushService { _, _, _ in
            var result = outcome(pushed: 0)
            result.superseded = [movedOnFail]
            return result
        },
        queue: supersedeFailQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        settleRejected: { _ in throw SettleFailed() }
    )
    _ = await guardFail.sync(trigger: .foreground)
    expect(supersedeFailQueue.load() == [movedOnFail],
           "P12-017: a failed settle keeps the superseded change queued (it is sent again)")

    // Only refusals: the pass completes, with no failure or backoff.
    let onlyQueue = makeQueue("rejected-only")
    try seed(onlyQueue, ["poison-2"])
    let onlyPoison = onlyQueue.load()[0]
    var onlySettled: [NativeMutationPushSettlement] = []
    let only = NativeSyncCoordinator(
        push: ScriptedPushService { _, _, _ in
            outcome(pushed: 0, rejected: [.init(item: onlyPoison, statusCode: 400)], code: "rejected/jobs/400")
        },
        queue: onlyQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        settleRejected: { onlySettled.append($0) }
    )
    expect(await only.sync(trigger: .foreground) == .completed(pushed: 0, authRefreshed: false),
           "12.00b.1: a pass whose only problem is a refusal completes")
    expect(onlyQueue.load().isEmpty && only.status().consecutiveFailures == 0 && only.status().nextEarliestAttempt == nil,
           "12.00b.1: a refusal is not a failure: no backoff, empty queue")
    expect(onlySettled.count == 1, "12.00b.1: the refusal was settled once")

    // A 403 keeps the auth path once; the same change's 403 on the
    // post-refresh push is refused, and nothing is pushed a third time.
    let forbiddenQueue = makeQueue("rejected-403")
    try seed(forbiddenQueue, ["locked"])
    let locked = forbiddenQueue.load()[0]
    var refreshes = 0
    var forbiddenSettled: [NativeMutationPushSettlement] = []
    let forbiddenPush = ScriptedPushService { items, forbidden, _ in
        classifiedOutcome(items, forbiddenBeforeRefresh: forbidden) { _ in 403 }
    }
    let forbidden = NativeSyncCoordinator(
        push: forbiddenPush, queue: forbiddenQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        refreshSession: { refreshes += 1; return true },
        settleRejected: { forbiddenSettled.append($0) }
    )
    expect(await forbidden.sync(trigger: .foreground) == .completed(pushed: 0, authRefreshed: true),
           "12.00b.1: a repeated 403 after one refresh is refused, and the pass completes")
    expect(forbiddenPush.calls.map(\.forbiddenBeforeRefresh) == [[], ["jobs/locked"]] && refreshes == 1,
           "12.00b.1: one refresh, one retry told which change got the 403, no third push")
    expect(forbiddenSettled.last?.rejected == [.init(item: locked, statusCode: 403)] && forbiddenQueue.load().isEmpty,
           "12.00b.1: the repeated 403 is set aside and leaves the queue")

    // Fix round 1 (review M1): the repeated-403 rule is per change. One
    // change gets a 503 and another a 403; after the refresh both get a 403.
    // Only the change whose 403 repeated is refused; the other's first 403
    // keeps the auth path and it stays queued for the next pass.
    let mixedQueue = makeQueue("rejected-403-mixed")
    try seed(mixedQueue, ["flaky", "locked-too"])
    let flaky = mixedQueue.load()[0], lockedToo = mixedQueue.load()[1]
    var mixedRefreshes = 0
    var mixedSettled: [NativeMutationPushSettlement] = []
    let mixedPush = ScriptedPushService { items, forbidden, index in
        classifiedOutcome(items, forbiddenBeforeRefresh: forbidden) { item in
            index == 0 && item.recordId == "flaky" ? 503 : 403
        }
    }
    let mixed = NativeSyncCoordinator(
        push: mixedPush, queue: mixedQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        refreshSession: { mixedRefreshes += 1; return true },
        settleRejected: { mixedSettled.append($0) }
    )
    let mixedResult = await mixed.sync(trigger: .foreground)
    expect(mixedPush.calls.count == 2 && mixedRefreshes == 1
           && mixedPush.calls.last?.forbiddenBeforeRefresh == ["jobs/locked-too"],
           "M1: the retry is told only the change that got the first 403")
    expect(mixedSettled.flatMap(\.rejected) == [.init(item: lockedToo, statusCode: 403)],
           "M1: only the change whose 403 repeated is refused")
    expect(mixedQueue.load() == [flaky],
           "M1: a change whose first 403 came on the retry stays queued")
    expect(mixedResult == .partial(pushed: 0, remaining: 1, authRefreshed: true),
           "M1: the pass is partial with the one change still queued")

    // A settle that throws acknowledges nothing from that attempt: every
    // started change stays queued (each write is idempotent), and the pass
    // reports a bounded store diagnostic. The pull still runs.
    let failQueue = makeQueue("rejected-settle-fails")
    try seed(failQueue, ["ok", "bad"])
    let failItems = failQueue.load()
    var failPulls = 0
    let failing = NativeSyncCoordinator(
        push: ScriptedPushService { _, _, _ in
            outcome(pushed: 1, rejected: [.init(item: failItems[1], statusCode: 409)], code: "rejected/jobs/409")
        },
        queue: failQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        settleRejected: { _ in throw SettleFailed() },
        pull: { failPulls += 1; return .completed }
    )
    let failResult = await failing.sync(trigger: .foreground)
    expect(failQueue.load() == failItems, "12.00b.1: a failed settle keeps every started change queued, in order")
    expect(failResult == .partial(pushed: 1, remaining: 2, authRefreshed: false),
           "12.00b.1: a failed settle is a partial pass")
    expect(failing.status().diagnosticCode == "rejected-store/unavailable",
           "12.00b.1: a failed settle reports the bounded rejected-store code")
    expect(failPulls == 1, "12.00b.1: the pull runs after a failed settle too")

    // No settle step configured: a refusal stays queued (fail closed).
    let unwiredQueue = makeQueue("rejected-unwired")
    try seed(unwiredQueue, ["refused"])
    let refused = unwiredQueue.load()[0]
    let unwired = NativeSyncCoordinator(
        push: ScriptedPushService { _, _, _ in
            outcome(pushed: 0, rejected: [.init(item: refused, statusCode: 422)], code: "rejected/jobs/422")
        },
        queue: unwiredQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials }
    )
    _ = await unwired.sync(trigger: .foreground)
    expect(unwiredQueue.load() == [refused], "12.00b.1: without a settle step a refusal stays queued")

    // A change replaced while its refused version was on the wire is not set
    // aside: the newer change stays queued and goes out on its own.
    let supersededQueue = makeQueue("rejected-superseded")
    try seed(supersededQueue, ["edited"])
    let original = supersededQueue.load()[0]
    var supersededSettled: [NativeMutationPushSettlement] = []
    let supersededPush = ScriptedPushService { _, _, index in
        index == 0
            ? outcome(pushed: 0, rejected: [.init(item: original, statusCode: 422)], code: "rejected/jobs/422")
            : outcome(pushed: 1)
    }
    supersededPush.beforeReturn = {
        guard supersededPush.calls.count == 1 else { return }
        _ = try? supersededQueue.enqueue(
            table: "jobs", op: .upsert, recordId: "edited",
            payload: .object(["id": .string("edited"), "title": .string("newer")])
        )
    }
    let superseded = NativeSyncCoordinator(
        push: supersededPush, queue: supersededQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        settleRejected: { supersededSettled.append($0) }
    )
    _ = await superseded.sync(trigger: .foreground)
    expect(supersededSettled.allSatisfy { $0.rejected.isEmpty },
           "12.00b.1: a refusal of a change replaced in flight is not set aside")
    expect(supersededPush.calls.count == 1 && supersededQueue.load().count == 1
           && supersededQueue.load()[0].payload != original.payload,
           "12.00b.1: the newer change stays queued for the next pass")
}

/// Phase 12 (12.02, charter TH-5): a change the push drops as unsendable
/// (`record-contract/<table>`) leaves the queue and the pass can still end
/// `.completed`, so the status carries the pass's discarded count and table
/// for `AppStore`'s remote signal. Only a real drop counts: a settle that
/// keeps the attempt queued discards nothing, and every pass starts at zero.
@MainActor
private func discardedChanges(
    makeQueue: (String) -> Canonical.NativeMutationQueue,
    seed: (Canonical.NativeMutationQueue, [String]) throws -> Void,
    credentials: NativeSyncCredentials,
    expect: (Bool, String) -> Void
) async throws {
    func dropping(_ bad: [Canonical.MutationItem], pushed: Int) -> NativeMutationPushOutcome {
        var outcome = NativeMutationPushOutcome(
            remaining: [], pushedCount: pushed,
            failedTables: bad.isEmpty ? [] : ["jobs"], authRejected: false,
            lastDiagnosticCode: bad.isEmpty ? nil : "record-contract/jobs"
        )
        outcome.discarded = bad
        return outcome
    }

    let queue = makeQueue("discarded")
    try seed(queue, ["good", "unsendable"])
    let unsendable = queue.load()[1]
    var settled: [NativeMutationPushSettlement] = []
    let coordinator = NativeSyncCoordinator(
        push: ScriptedPushService { _, _, index in dropping(index == 0 ? [unsendable] : [], pushed: 1) },
        queue: queue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        settleRejected: { settled.append($0) }
    )
    expect(await coordinator.sync(trigger: .foreground) == .completed(pushed: 1, authRefreshed: false),
           "12.02 TH-5: a pass whose only problem is a discarded change still completes")
    expect(queue.load().isEmpty, "12.02 TH-5: the discarded change left the queue")
    expect(coordinator.status().discardedCount == 1 && coordinator.status().discardedTable == "jobs",
           "12.02 TH-5: the status carries the pass's discarded count and table")
    expect(coordinator.status().diagnosticCode == "record-contract/jobs",
           "12.02 TH-5: the bounded record-contract code stays on the status")

    try seed(queue, ["later"])
    _ = await coordinator.sync(trigger: .foreground)
    expect(coordinator.status().discardedCount == 0 && coordinator.status().discardedTable == nil,
           "12.02 TH-5: a later pass that discards nothing starts again from zero")

    // A settle that cannot record the attempt keeps every started change
    // queued, the unsendable one included: nothing was discarded.
    let keptQueue = makeQueue("discarded-settle-failed")
    try seed(keptQueue, ["kept-good", "kept-unsendable"])
    let keptUnsendable = keptQueue.load()[1]
    let kept = NativeSyncCoordinator(
        push: ScriptedPushService { _, _, _ in dropping([keptUnsendable], pushed: 1) },
        queue: keptQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials },
        settleRejected: { _ in throw SettleFailed() }
    )
    _ = await kept.sync(trigger: .foreground)
    expect(keptQueue.load().count == 2 && kept.status().discardedCount == 0,
           "12.02 TH-5: a failed settle keeps the change queued and counts no discard")

    // An account boundary clears it with the rest of the status.
    let resetQueue = makeQueue("discarded-reset")
    try seed(resetQueue, ["reset-unsendable"])
    let resetUnsendable = resetQueue.load()[0]
    let resetting = NativeSyncCoordinator(
        push: ScriptedPushService { _, _, _ in dropping([resetUnsendable], pushed: 0) },
        queue: resetQueue,
        reachability: FakeReachability(reachable: true),
        credentialsProvider: { credentials }
    )
    _ = await resetting.sync(trigger: .foreground)
    expect(resetting.status().discardedCount == 1, "12.02 TH-5: sanity: the drop was counted")
    resetting.reset()
    expect(resetting.status() == NativeSyncStatus(), "12.02 TH-5: reset clears the discarded count and table")
    expect(settled.count >= 1, "12.02 TH-5: sanity: the settle step saw the attempt")
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
        // Phase 12 (12.00b.1, I2): the pull runs after every push pass that
        // reached per-item results, as RN's syncIfOnline does (utils/sync.ts
        // 316-326: pushQueue at 320, then pullRemote at 321). The 11.12 pull
        // commit keeps the pending record (AppStore.rebasePulledDelta).
        expect(protectedPullCount == 1,
               "the pull still runs after a partial push; the pull commit protects pending local truth")

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
        expect(backoffPullCount == 1, "a failed first push still pulls once (12.00b.1: pull after push, like RN)")
        backoffPullClock = backoffPullClock.addingTimeInterval(1)
        expect(await backoffPull.sync(trigger: .foreground) == .backoffDeferred, "a pass inside the window defers")
        expect(backoffPullCount == 1, "a deferred pass does not pull")

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

        try await rejectedChanges(makeQueue: makeQueue, seed: seed, credentials: credentials, expect: expect)
        try await discardedChanges(makeQueue: makeQueue, seed: seed, credentials: credentials, expect: expect)

        if failures == 0 { print("PASS: native sync coordinator tests") }
        else { exit(1) }
    }
}
