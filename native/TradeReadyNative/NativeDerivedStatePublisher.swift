import Foundation

/// Task 10.09 (requirement B1): the post-sync-commit seam.
///
/// Contract: "exactly once per committed canonical sync commit." A commit is
/// any durable write of a merged canonical snapshot — the coordinator's
/// delta pull, a direct delta pull (booking response/reschedule/portal-admin
/// recovery paths), the initial full sync, and the booking-intake local
/// commit each call `publish` exactly once, from the snapshot they just
/// committed. There is intentionally no single call-site "funnel": `AppStore`
/// calls `publish` from every place a canonical snapshot is durably
/// committed (see `AppStore.pullDeltaIfPossible` and
/// `AppStore.runBookingIntakeAfterVerifiedPull`). A logical operation that
/// performs two separate commits (e.g. `prepareBookingReschedule`'s
/// `syncNowAndWait` pull followed by its own direct `pullDeltaIfPossible`)
/// legitimately publishes twice — once per commit — and the generation guard
/// below (not a single call site) is what keeps those publishes correctly
/// ordered. `publish` never runs for an offline, signed-out, `.alreadyRunning`,
/// or pre-commit-failed pass, because none of those paths reach a commit.
///
/// Generic over the canonical input (`Input`) and the derived business
/// snapshot output (`Output`) so this file has zero dependency on concrete
/// domain types (`Canonical.Snapshot`, `NativeBusinessSnapshot`) and can be
/// unit-tested in complete isolation — see `native/run-background-refresh-tests.sh`.
/// `AppStore` instantiates `NativeDerivedStatePublisher<Canonical.Snapshot,
/// NativeBusinessSnapshot>`.
///
/// `publish` republishes every derived output from the `canonical` argument
/// it is given — never from stale in-memory collections read separately —
/// and each output is independently failure-isolated: one throwing/failing
/// output must not stop or corrupt the others.
///
/// Concrete outputs (see the task brief):
///  (a) notification reconciliation, through the 10.08
///      `NativeEstimateFollowUpNotificationCoordinator.synchronize(now:)`
///      seam (`notifySynchronize`, wired by `AppStore`) — not a second
///      reconcile path.
///  (b) `register`/`unregister`: the registration point the Phase 11 widget
///      mirror (11.01) plugs into. No widget code lives here; a registered
///      observer receives the same `Output` snapshot built for (c).
///  (c) `cachedSnapshot`: the refreshed cached business snapshot for coach
///      cold start (10.13 reads `AppStore.cachedBusinessSnapshot`).
@MainActor
final class NativeDerivedStatePublisher<Input, Output> {
    typealias SnapshotObserver = (Output) throws -> Void

    /// Observers are app-lifetime (the 11.01 widget mirror registers once at
    /// launch and expects every later commit's snapshot, across sign-out and
    /// sign-in). Only `publish` and `unregister` ever remove one; the
    /// account-boundary cache clear (`reset()`) must never touch this map.
    private var observers: [UUID: SnapshotObserver] = [:]

    /// Output (c), scoped to the owner it was built for. `nil` cache or a
    /// binding that no longer matches the live `ownerBinding()` both read as
    /// "no cached snapshot" — the read fails closed rather than ever handing
    /// back a previous owner's data.
    private var cachedOutput: Output?
    private var cachedOutputOwnerBinding: String?

    /// Monotonically increasing per `publish` call. A publish that resumes
    /// from an `await` after a later publish has already run must not write
    /// the cache or notify observers with its now-stale snapshot — see the
    /// generation check below.
    private var generation: UInt64 = 0

    private let notifySynchronize: (Date) async throws -> Void
    private let makeSnapshot: (Input, Date) throws -> Output
    private let ownerBinding: () -> String?
    private let now: () -> Date

    init(
        notifySynchronize: @escaping (Date) async throws -> Void,
        makeSnapshot: @escaping (Input, Date) throws -> Output,
        ownerBinding: @escaping () -> String?,
        now: @escaping () -> Date = Date.init
    ) {
        self.notifySynchronize = notifySynchronize
        self.makeSnapshot = makeSnapshot
        self.ownerBinding = ownerBinding
        self.now = now
    }

    /// Output (b): registers an observer that receives every future
    /// committed snapshot, including ones published after a sign-out/sign-in
    /// cycle. Returns a token for `unregister`.
    @discardableResult
    func register(_ observer: @escaping SnapshotObserver) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func unregister(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    /// Output (c), read for the CURRENT verified owner only. Returns `nil`
    /// when nothing has published yet this launch, after an account-boundary
    /// `reset()`, or when the cache belongs to an owner other than the one
    /// live right now — a fail-closed read, not a trust-the-caller one.
    var cachedSnapshot: Output? {
        guard let cachedOutputOwnerBinding, cachedOutputOwnerBinding == ownerBinding() else {
            return nil
        }
        return cachedOutput
    }

    /// Account boundary (sign-out, "use another account", recovery
    /// signed-out): clears the owner-scoped cached snapshot only. Observer
    /// registrations are NOT cleared here — they are app-lifetime and must
    /// keep receiving the next owner's publishes after sign-in.
    func reset() {
        cachedOutput = nil
        cachedOutputOwnerBinding = nil
    }

    /// Republishes every derived output from `canonical`. Call this exactly
    /// once per committed canonical sync commit, with the owner binding
    /// verified at the moment of that commit. Identity is re-checked before
    /// touching each output and again after every `await`, so a sign-out or
    /// account-switch race during notification reconciliation can neither
    /// leak nor cache another owner's data. A generation guard additionally
    /// protects against this same publish resuming, after its `await`, later
    /// than a newer publish that already ran to completion — the older,
    /// now-stale snapshot must never overwrite the newer one.
    func publish(canonical: Input, expectedOwnerBinding: String) async {
        guard ownerBinding() == expectedOwnerBinding else { return }
        generation &+= 1
        let myGeneration = generation

        // (a) notification reconciliation. Isolated: a throwing/failing
        // reconcile must not block (b)/(c) below, and never corrupts the
        // prior cached snapshot or observer registrations.
        do {
            try await notifySynchronize(now())
        } catch {
            // Isolated failure — (b)/(c) still get their chance below.
        }
        guard ownerBinding() == expectedOwnerBinding else { return }
        // Superseded by a later publish while suspended above: that later
        // publish already wrote the cache/observers with fresher data, so
        // this one must stop here rather than overwrite it.
        guard myGeneration == generation else { return }

        // (b)/(c) share one build so every observer and the cache see the
        // identical snapshot. Isolated from (a); a build failure leaves the
        // prior cached snapshot and prior observer state completely
        // untouched (fail-safe: no partial/corrupt cache is ever published).
        // `makeSnapshot` is synchronous — no suspension occurs between here
        // and the cache write below, so no further owner/generation race is
        // possible and no redundant re-check is needed after it runs.
        let snapshot: Output
        do {
            snapshot = try makeSnapshot(canonical, now())
        } catch {
            return
        }

        cachedOutput = snapshot
        cachedOutputOwnerBinding = expectedOwnerBinding
        for (_, observer) in observers {
            // Isolated per observer: one throwing observer must not block or
            // corrupt delivery to the others, nor the cache already set above.
            do {
                try observer(snapshot)
            } catch {
                // Isolated failure — the remaining observers still run.
            }
        }
    }
}
