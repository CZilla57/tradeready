import Foundation
#if canImport(Network)
import Network
#endif

/// Why one sync pass was triggered. Recorded for diagnostics; the coordinator
/// treats every trigger the same except that `manual` bypasses backoff.
enum NativeSyncTrigger: String, Equatable {
    case foreground
    case signedIn
    case localChange
    case manual
    case periodic
}

/// The result of one sync pass, suitable for a future status surface and for
/// tests. It never carries account identifiers or record values.
enum NativeSyncOutcome: Equatable {
    case idleNoChanges
    case offline
    case notAuthenticated
    case backoffDeferred
    case alreadyRunning
    /// Every queued change was accepted by the server.
    case completed(pushed: Int, authRefreshed: Bool)
    /// Some changes were pushed; `remaining` are retained for retry.
    case partial(pushed: Int, remaining: Int, authRefreshed: Bool)
    /// The push could not run to a per-item result (configuration/transport).
    case failed(remaining: Int)
}

/// Privacy-safe result of the incremental pull half of a sync pass. Diagnostic
/// codes are produced only from bounded stage/table/status components; they
/// never contain account IDs, record IDs, URLs, credentials, or row values.
struct NativeSyncPullResult: Equatable {
    enum State: Equatable {
        case completed
        case partial
        case failed
        case skipped
    }

    var state: State
    var diagnosticCode: String?

    static let completed = NativeSyncPullResult(state: .completed, diagnosticCode: nil)
    static let skipped = NativeSyncPullResult(state: .skipped, diagnosticCode: nil)

    static func partial(_ diagnosticCode: String?) -> NativeSyncPullResult {
        NativeSyncPullResult(state: .partial, diagnosticCode: diagnosticCode ?? "pull/partial")
    }

    static func failed(_ diagnosticCode: String) -> NativeSyncPullResult {
        NativeSyncPullResult(state: .failed, diagnosticCode: diagnosticCode)
    }
}

/// Observable, privacy-safe sync state consumed by AppStore and SwiftUI. The
/// durable mutation queue remains the source of truth for `pendingCount`.
struct NativeSyncStatus: Equatable {
    var pendingCount: Int = 0
    var isSyncing = false
    var consecutiveFailures = 0
    var lastOutcome: NativeSyncOutcome?
    var lastPullResult: NativeSyncPullResult?
    var lastSuccessfulSyncAt: Date?
    var nextEarliestAttempt: Date?
    var diagnosticCode: String?
}

/// The minimal push surface the coordinator drives. `NativeSupabaseMutationPushService`
/// is the production implementation; tests inject a fake.
protocol NativeMutationPushing {
    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem]
    ) async throws -> NativeMutationPushOutcome

    /// Phase 12 (12.00b.1): the push that follows one successful session
    /// refresh in the same pass passes `afterAuthRefresh: true`, so a 403
    /// that repeats is refused instead of retried.
    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem],
        afterAuthRefresh: Bool
    ) async throws -> NativeMutationPushOutcome
}

extension NativeMutationPushing {
    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem],
        afterAuthRefresh: Bool
    ) async throws -> NativeMutationPushOutcome {
        try await push(sessionBytes: sessionBytes, expectedUserSubject: expectedUserSubject, items: items)
    }
}

extension NativeSupabaseMutationPushService: NativeMutationPushing {}

/// Phase 12 (12.00b.1, I2): what one push attempt did to the queue, handed
/// to the rejected-change store before the queue commits the attempt.
struct NativeMutationPushSettlement: Equatable {
    /// The changes the server refused, each still queued unchanged: they move
    /// to the rejected-change store.
    var rejected: [NativeMutationRejection]
    /// Every other change the attempt took off the queue (accepted, or
    /// dropped as unsendable). A set-aside change for the same record is
    /// superseded by it.
    var cleared: [Canonical.MutationItem]
}

/// Connectivity gate. The coordinator never pushes while unreachable, so an
/// offline device retains its queue instead of burning retries and backoff.
protocol NativeSyncReachability {
    func isReachable() async -> Bool
}

/// The verified identity and session bytes for a push. Supplied lazily so the
/// coordinator always reads the current Keychain session, never a stale copy.
struct NativeSyncCredentials: Equatable {
    let subject: String
    let sessionBytes: Data
}

/// Reachability-aware orchestration for the Phase 4 outbound queue.
///
/// It serializes sync passes (a trigger arriving mid-pass coalesces into one
/// follow-up run), skips cleanly when offline, signed out, or inside a backoff
/// window, drains the durable queue through the push transport, persists only
/// the unacknowledged remainder, and — on an auth rejection — refreshes the
/// session once and retries the remainder. Transient failures grow an
/// exponential backoff; a fully completed push/pull pass resets it.
@MainActor
final class NativeSyncCoordinator {
    typealias Status = NativeSyncStatus

    private let push: any NativeMutationPushing
    private let queue: Canonical.NativeMutationQueue
    private let reachability: any NativeSyncReachability
    private let credentialsProvider: () async -> NativeSyncCredentials?
    private let refreshSession: () async -> Bool
    private let settleRejected: ((NativeMutationPushSettlement) throws -> Void)?
    private let pull: (() async -> NativeSyncPullResult)?
    private let statusChanged: (NativeSyncStatus) -> Void
    private let now: () -> Date
    private let baseBackoff: TimeInterval
    private let maxBackoff: TimeInterval

    private var isRunning = false
    private var needsRerun = false
    private var idleWaiters: [CheckedContinuation<NativeSyncOutcome?, Never>] = []
    private var consecutiveFailures = 0
    private var nextEarliestAttempt: Date?
    private var lastOutcome: NativeSyncOutcome?
    private var lastPullResult: NativeSyncPullResult?
    private var lastSuccessfulSyncAt: Date?
    private var diagnosticCode: String?
    private var retryTask: Task<Void, Never>?
    private var accountGeneration: UInt64 = 0

    init(
        push: any NativeMutationPushing,
        queue: Canonical.NativeMutationQueue,
        reachability: any NativeSyncReachability,
        credentialsProvider: @escaping () async -> NativeSyncCredentials?,
        refreshSession: @escaping () async -> Bool = { false },
        settleRejected: ((NativeMutationPushSettlement) throws -> Void)? = nil,
        pull: (() async -> NativeSyncPullResult)? = nil,
        statusChanged: @escaping (NativeSyncStatus) -> Void = { _ in },
        now: @escaping () -> Date = Date.init,
        baseBackoff: TimeInterval = 5,
        maxBackoff: TimeInterval = 300
    ) {
        self.push = push
        self.queue = queue
        self.reachability = reachability
        self.credentialsProvider = credentialsProvider
        self.refreshSession = refreshSession
        self.settleRejected = settleRejected
        self.pull = pull
        self.statusChanged = statusChanged
        self.now = now
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
    }

    func status() -> Status {
        NativeSyncStatus(
            pendingCount: queue.load().count,
            isSyncing: isRunning,
            consecutiveFailures: consecutiveFailures,
            lastOutcome: lastOutcome,
            lastPullResult: lastPullResult,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            nextEarliestAttempt: nextEarliestAttempt,
            diagnosticCode: diagnosticCode
        )
    }

    /// Clears account-scoped runtime state. The durable queue is scrubbed by
    /// AppStore before this is called; cancelling the retry prevents an old
    /// account's backoff task from running under a newly signed-in identity.
    func reset() {
        accountGeneration &+= 1
        retryTask?.cancel()
        retryTask = nil
        needsRerun = false
        consecutiveFailures = 0
        nextEarliestAttempt = nil
        lastOutcome = nil
        lastPullResult = nil
        lastSuccessfulSyncAt = nil
        diagnosticCode = nil
        publishStatus()
    }

    /// Records a local queue/persistence failure without exposing the failed
    /// record. The user can retry from the status surface and share the code.
    func recordLocalFailure(_ code: String) {
        diagnosticCode = code
        publishStatus()
    }

    /// Runs one sync pass, coalescing any trigger that arrives mid-pass into a
    /// single follow-up run. `manual` triggers bypass the backoff window.
    @discardableResult
    func sync(trigger: NativeSyncTrigger = .manual) async -> NativeSyncOutcome {
        guard !isRunning else {
            needsRerun = true
            return .alreadyRunning
        }
        isRunning = true
        publishStatus()
        defer {
            isRunning = false
            publishStatus()
            let completedOutcome = lastOutcome
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume(returning: completedOutcome) }
        }

        var outcome = await runOnce(force: trigger == .manual)
        // A change enqueued while the pass was in flight must not wait for the
        // next external trigger. Re-run once (never forced) while work remains.
        while needsRerun {
            needsRerun = false
            guard !queue.load().isEmpty || pull != nil else { break }
            outcome = await runOnce(force: false)
        }
        return outcome
    }

    /// Waits for the active pass and any coalesced rerun to finish. This keeps
    /// callers such as pull-to-refresh and sync-before-sign-out attached to the
    /// real operation even when another lifecycle trigger started it first.
    func waitUntilIdle() async -> NativeSyncOutcome? {
        guard isRunning else { return lastOutcome }
        return await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func runOnce(force: Bool) async -> NativeSyncOutcome {
        let generation = accountGeneration
        let items = queue.load()
        // A pass with nothing to push and no pull configured is a pure no-op —
        // preserve the early return so a push-only coordinator never touches the
        // network on an empty queue. With a pull wired, an empty queue still runs
        // so a foreground with no local edits can fetch remote changes.
        guard !items.isEmpty || pull != nil else {
            cancelRetry()
            return record(.idleNoChanges)
        }
        if !force, let next = nextEarliestAttempt, now() < next {
            return record(.backoffDeferred)
        }
        let reachable = await reachability.isReachable()
        guard generation == accountGeneration else { return .notAuthenticated }
        guard reachable else {
            scheduleRetryWithoutFailure()
            return record(.offline)
        }
        let credentials = await credentialsProvider()
        guard generation == accountGeneration else { return .notAuthenticated }
        guard let credentials else {
            cancelRetry()
            return record(.notAuthenticated)
        }
        // A real network attempt supersedes the previous bounded diagnostic.
        // Any new push or pull failure below will publish its own code.
        diagnosticCode = nil
        lastPullResult = nil
        publishStatus()

        // Push first (RN's syncIfOnline order): local writes reach the server
        // before the pull overwrites the local snapshot with the merged result.
        let outcome: NativeSyncOutcome
        if items.isEmpty {
            outcome = record(.completed(pushed: 0, authRefreshed: false))
        } else {
            do {
                outcome = try await runPush(
                    items,
                    credentials: credentials,
                    generation: generation
                )
            } catch SyncInvalidation.accountChanged {
                return .notAuthenticated
            } catch {
                registerFailure()
                diagnosticCode = Self.pushDiagnosticCode(for: error)
                // A thrown push means the transport is unhealthy; skip the pull
                // this pass rather than compounding the failure.
                return record(.failed(remaining: queue.load().count))
            }
        }
        // Phase 12 (12.00b.1, I2; contract §17.2): pull after every push pass
        // that reached per-item results, even with changes still queued, as
        // RN's `syncIfOnline` does (`utils/sync.ts` 316-326: `pushQueue`,
        // then `pullRemote`). The pull never overwrites a record with a queued
        // change: the 11.12 commit keeps it (`AppStore.rebasePulledDelta`,
        // "pending wins"), which also keeps a delete followed by undo
        // local-first. So one change that keeps failing no longer holds back
        // every other record's inbound updates. A thrown push (configuration,
        // session, environment) returned above and skips the pull, as RN's
        // `try` block does.
        // Pull rides the same reachability/auth/backoff gates. It owns its own
        // commit and refresh, so its result does not alter the push outcome or
        // the push-driven backoff.
        if let pull {
            let result = await pull()
            guard generation == accountGeneration else { return .notAuthenticated }
            lastPullResult = result
            switch result.state {
            case .completed:
                if queue.load().isEmpty, diagnosticCode == nil {
                    consecutiveFailures = 0
                    lastSuccessfulSyncAt = now()
                    cancelRetry()
                }
            case .partial, .failed:
                // The first code of the pass wins, like the transports' own
                // diagnostics: a push failure's code is not replaced.
                if diagnosticCode == nil { diagnosticCode = result.diagnosticCode ?? "pull/unavailable" }
                if nextEarliestAttempt == nil { registerFailure() }
            case .skipped:
                break
            }
            publishStatus()
        } else if queue.load().isEmpty, diagnosticCode == nil {
            lastSuccessfulSyncAt = now()
            cancelRetry()
        }
        return outcome
    }

    private func runPush(
        _ items: [Canonical.MutationItem],
        credentials: NativeSyncCredentials,
        generation: UInt64
    ) async throws -> NativeSyncOutcome {
        var outcome = try await push.push(
            sessionBytes: credentials.sessionBytes,
            expectedUserSubject: credentials.subject,
            items: items,
            afterAuthRefresh: false
        )
        guard generation == accountGeneration else { throw SyncInvalidation.accountChanged }
        outcome = settle(outcome, startedItems: items)
        var authRefreshed = false
        var attemptedRemainder = outcome.remaining
        var queuedRemainder: [Canonical.MutationItem]
        if outcome.authRejected {
            // Persist progress before refreshing so a crash during refresh
            // cannot re-send already-accepted items on the next launch. Merge
            // the acknowledgement with newer mutations enqueued in flight.
            _ = try queue.reconcilePush(startedItems: items, remaining: outcome.remaining)
            let didRefresh = await refreshSession()
            guard generation == accountGeneration else { throw SyncInvalidation.accountChanged }
            let fresh = await credentialsProvider()
            guard generation == accountGeneration else { throw SyncInvalidation.accountChanged }
            let currentItems = queue.load()
            let retryItems = outcome.remaining.filter { currentItems.contains($0) }
            if didRefresh, let fresh, !retryItems.isEmpty {
                authRefreshed = true
                // A 403 on this push, after one successful refresh, is a
                // refusal (12.00b.1); nothing is pushed a third time.
                outcome = try await push.push(
                    sessionBytes: fresh.sessionBytes,
                    expectedUserSubject: fresh.subject,
                    items: retryItems,
                    afterAuthRefresh: true
                )
                guard generation == accountGeneration else { throw SyncInvalidation.accountChanged }
                outcome = settle(outcome, startedItems: retryItems)
                attemptedRemainder = outcome.remaining
                queuedRemainder = try queue.reconcilePush(
                    startedItems: retryItems,
                    remaining: outcome.remaining
                )
            } else {
                // Only unchanged items from the rejected attempt count as
                // failures. Newer replacements are pending work for the
                // coalesced rerun, not failures from this transport response.
                attemptedRemainder = outcome.remaining.filter { currentItems.contains($0) }
                queuedRemainder = currentItems
            }
        } else {
            attemptedRemainder = outcome.remaining
            queuedRemainder = try queue.reconcilePush(
                startedItems: items,
                remaining: outcome.remaining
            )
        }
        if let code = outcome.lastDiagnosticCode { diagnosticCode = code }
        if attemptedRemainder.isEmpty {
            consecutiveFailures = 0
            nextEarliestAttempt = nil
            if outcome.failedTables.isEmpty { diagnosticCode = nil }
            return record(.completed(pushed: outcome.pushedCount, authRefreshed: authRefreshed))
        }
        registerFailure()
        return record(.partial(
            pushed: outcome.pushedCount,
            remaining: queuedRemainder.count,
            authRefreshed: authRefreshed
        ))
    }

    /// Phase 12 (12.00b.1, I2): hands one attempt to the rejected-change
    /// store before the queue commits it. A refused change still queued
    /// unchanged is set aside; one replaced while it was on the wire is
    /// superseded (the newer change stays queued and is pushed on its own).
    /// If the store cannot take the attempt, nothing from it is
    /// acknowledged: every started change stays queued (each write is
    /// idempotent and is sent again next pass), so a refusal is never lost
    /// and no set-aside entry outlives a change that replaced it. With no
    /// settle step configured, a refusal stays queued.
    private func settle(
        _ outcome: NativeMutationPushOutcome,
        startedItems: [Canonical.MutationItem]
    ) -> NativeMutationPushOutcome {
        var result = outcome
        let refusedItems = outcome.rejected.map(\.item)
        let current = queue.load()
        let rejected = outcome.rejected.filter { current.contains($0.item) }
        let cleared = startedItems.filter { !outcome.remaining.contains($0) && !refusedItems.contains($0) }
        result.rejected = rejected
        guard !rejected.isEmpty || !cleared.isEmpty else { return result }
        guard let settleRejected else {
            if !rejected.isEmpty { keepQueued(rejected.map(\.item), in: &result, startedItems: startedItems) }
            return result
        }
        do {
            try settleRejected(NativeMutationPushSettlement(rejected: rejected, cleared: cleared))
        } catch {
            keepQueued(startedItems, in: &result, startedItems: startedItems)
            result.lastDiagnosticCode = "rejected-store/unavailable"
        }
        return result
    }

    /// Returns `items` to the attempt's remainder, in queue order.
    private func keepQueued(
        _ items: [Canonical.MutationItem],
        in outcome: inout NativeMutationPushOutcome,
        startedItems: [Canonical.MutationItem]
    ) {
        let kept = startedItems.filter { outcome.remaining.contains($0) || items.contains($0) }
        outcome.remaining = kept
        outcome.rejected.removeAll { items.contains($0.item) }
        outcome.failedTables = kept.reduce(into: [String]()) { tables, item in
            if !tables.contains(item.table) { tables.append(item.table) }
        }
    }

    private func registerFailure() {
        consecutiveFailures += 1
        let delay = min(baseBackoff * pow(2, Double(consecutiveFailures - 1)), maxBackoff)
        nextEarliestAttempt = now().addingTimeInterval(delay)
        scheduleRetry(after: delay)
    }

    private func scheduleRetryWithoutFailure() {
        let delay = baseBackoff
        nextEarliestAttempt = now().addingTimeInterval(delay)
        scheduleRetry(after: delay)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            guard !Task.isCancelled else { return }
            _ = await self?.sync(trigger: .periodic)
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        nextEarliestAttempt = nil
    }

    private static func pushDiagnosticCode(for error: Error) -> String {
        switch error {
        case NativeMutationPushError.invalidConfiguration: "push/configuration"
        case NativeMutationPushError.malformedSession: "push/session"
        case NativeMutationPushError.productionWriteBlocked: "push/environment"
        default: "push/unavailable"
        }
    }

    private enum SyncInvalidation: Error {
        case accountChanged
    }

    @discardableResult
    private func record(_ outcome: NativeSyncOutcome) -> NativeSyncOutcome {
        lastOutcome = outcome
        publishStatus()
        return outcome
    }

    private func publishStatus() {
        statusChanged(status())
    }
}

#if canImport(Network)
/// Production reachability backed by `NWPathMonitor`. It reports the last
/// observed path status and optimistically assumes reachable until the first
/// update arrives — a wrong optimistic attempt merely fails and is retried.
final class NativeNetworkPathReachability: NativeSyncReachability, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.satisfied = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "TradeReadySyncReachability"))
    }

    func isReachable() async -> Bool { currentlySatisfied() }

    private func currentlySatisfied() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return satisfied
    }
}
#else
/// Fallback for platforms without the Network framework: always attempt, and
/// let a real transport failure drive the queue's retry/backoff instead.
struct NativeAlwaysReachable: NativeSyncReachability {
    func isReachable() async -> Bool { true }
}
#endif
