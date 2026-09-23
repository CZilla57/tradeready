import Foundation

/// Task 10.09 (requirement B1): the single post-sync-commit seam.
///
/// Invoked exactly once after a real (non-`.alreadyRunning`) sync pass
/// commits its canonical snapshot — foreground or background — and never on
/// an offline, signed-out, or failed pass. Those never reach the commit
/// boundary that calls `publish`: see `AppStore.pullDeltaIfPossible`, the
/// only call site, which returns before ever touching this type unless the
/// pull actually applied and durably saved a merged canonical snapshot.
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

    private var observers: [UUID: SnapshotObserver] = [:]

    /// Output (c). `nil` until the first successful `publish` this launch,
    /// or after `reset()` at the account boundary.
    private(set) var cachedSnapshot: Output?

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
    /// committed snapshot. Returns a token for `unregister`.
    @discardableResult
    func register(_ observer: @escaping SnapshotObserver) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func unregister(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    /// Clears cached derived state and every observer registration at the
    /// account boundary (sign-out / account switch). A stale cache or a
    /// carried-over observer callback from a previous owner must never
    /// survive into the next signed-in identity.
    func reset() {
        cachedSnapshot = nil
        observers.removeAll()
    }

    /// Republishes every derived output from `canonical`. Call this exactly
    /// once per real committed sync pass, with the owner binding verified at
    /// the moment of commit. Identity is re-checked before touching each
    /// output and again after every `await`, so a sign-out or account-switch
    /// race during notification reconciliation or snapshot rebuild can
    /// neither leak nor cache another owner's data.
    func publish(canonical: Input, expectedOwnerBinding: String) async {
        guard ownerBinding() == expectedOwnerBinding else { return }

        // (a) notification reconciliation. Isolated: a throwing/failing
        // reconcile must not block (b)/(c) below, and never corrupts the
        // prior cached snapshot or observer registrations.
        do {
            try await notifySynchronize(now())
        } catch {
            // Isolated failure — (b)/(c) still get their chance below.
        }
        guard ownerBinding() == expectedOwnerBinding else { return }

        // (b)/(c) share one build so every observer and the cache see the
        // identical snapshot. Isolated from (a); a build failure leaves the
        // prior cached snapshot and prior observer state completely
        // untouched (fail-safe: no partial/corrupt cache is ever published).
        let snapshot: Output
        do {
            snapshot = try makeSnapshot(canonical, now())
        } catch {
            return
        }
        guard ownerBinding() == expectedOwnerBinding else { return }

        cachedSnapshot = snapshot
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
