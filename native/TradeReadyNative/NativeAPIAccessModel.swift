import Combine
import Foundation

/// Roadmap Phase 23 (open-API spec §9): the state behind Settings › API
/// access. It talks only to a `NativeAPIKeyManaging` (the store-bound client
/// in the app, a fake in host tests) and holds no state past the screen: no
/// cache, no sync, no settings field (§13 D14).
///
/// Rules it enforces:
/// - One key change at a time, and no double submit: every async entry point
///   returns early while another runs.
/// - Create and rotate carry a client `operationId`. A failure that may have
///   committed keeps the exact request and its id as `pending`, and Retry
///   sends the same bytes again, so the server replays it instead of minting
///   a second key (§14.1). A new create or rotate waits until the pending one
///   is retried or dismissed.
/// - A 429 starts a wait of `Retry-After` (or the one-minute window) during
///   which nothing is sent.
/// - The raw key lives only in `sheet` while the show-once sheet is up.
///   Dismissing it drops the only reference; nothing else here ever holds it.
@MainActor
final class NativeAPIAccessModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(NativeAPIKeyAdminError)
    }

    enum Busy: Equatable {
        case loading, creating, retrying
        case rotating(keyId: String)
        case revoking(keyId: String)
    }

    struct PendingOperation: Equatable {
        enum Kind: Equatable {
            case create(NativeAPIKeyCreateRequest)
            case rotate(keyId: String, keyName: String, grace: NativeAPIKeyGrace)
        }

        let kind: Kind
        let operationId: String

        var title: String {
            switch kind {
            case let .create(request): "Creating “\(request.name)”"
            case let .rotate(_, keyName, _): "Rotating “\(keyName)”"
            }
        }
    }

    /// The show-once sheet's contents. Its only owner is `sheet`.
    struct Reveal: Equatable, Identifiable {
        let id: String
        let keyName: String
        let prefix: String
        let secret: NativeAPIKeySecret
        /// The key a rotation replaced, with its new end time.
        let previous: NativeAPIKeySummary?
    }

    enum Sheet: Equatable, Identifiable {
        case create
        case reveal(Reveal)

        var id: String {
            switch self {
            case .create: "create"
            case let .reveal(reveal): "reveal-\(reveal.id)"
            }
        }
    }

    struct Alert: Equatable, Identifiable {
        let id: String
        let title: String
        let message: String
        /// `already_completed`: the key whose secret is lost, offered for revoke.
        let revokeKeyId: String?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var keys: [NativeAPIKeySummary] = []
    @Published private(set) var maxLiveKeys = NativeAPIKeyAdministrationService.defaultMaxLiveKeys
    @Published private(set) var busy: Busy?
    @Published private(set) var pending: PendingOperation?
    @Published private(set) var rateLimitedUntil: Date?
    @Published private(set) var notice: String?
    @Published var alert: Alert?
    @Published private(set) var sheet: Sheet?
    @Published private(set) var activity: [NativeAPIActivityEvent] = []
    @Published private(set) var activityPhase: Phase = .idle

    private let manager: any NativeAPIKeyManaging
    private let track: (NativeAPIAccessAnalyticsEvent) -> Void
    private let now: () -> Date
    private let makeOperationID: () -> String
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var rateLimitTask: Task<Void, Never>?

    init(
        manager: any NativeAPIKeyManaging,
        track: @escaping (NativeAPIAccessAnalyticsEvent) -> Void = { _ in },
        now: @escaping () -> Date = { Date() },
        makeOperationID: @escaping () -> String = NativeAPIKeyAdministrationService.newOperationID,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.manager = manager
        self.track = track
        self.now = now
        self.makeOperationID = makeOperationID
        self.sleep = sleep
    }

    // MARK: Derived state

    /// Active keys and old keys in a rotation grace window.
    var liveKeys: [NativeAPIKeySummary] { keys.filter { $0.canRevoke(at: now()) } }
    /// Revoked and expired keys (read only).
    var pastKeys: [NativeAPIKeySummary] { keys.filter { !$0.canRevoke(at: now()) } }
    /// The keys that count toward the cap (grace-window keys don't, §14.1).
    var activeCount: Int { keys.filter { $0.status(at: now()) == .active }.count }
    var isAtKeyLimit: Bool { activeCount >= maxLiveKeys }

    func isRateLimited() -> Bool {
        guard let rateLimitedUntil else { return false }
        return now() < rateLimitedUntil
    }

    var rateLimitText: String? {
        guard let rateLimitedUntil, isRateLimited() else { return nil }
        return NativeAPIAccessText.rateLimited(until: rateLimitedUntil, now: now())
    }

    /// A create or rotate may start: nothing running, nothing unresolved,
    /// not waiting out a 429, and the list is known.
    var canStartKeyChange: Bool {
        phase == .loaded && busy == nil && pending == nil && !isRateLimited()
    }

    var canCreate: Bool { canStartKeyChange && !isAtKeyLimit }

    func keyName(for keyId: String) -> String? {
        keys.first { $0.id.lowercased() == keyId.lowercased() }?.name
    }

    // MARK: Loading

    func load() async {
        guard busy == nil else { return }
        guard !isRateLimited() else { return presentRateLimitWait() }
        busy = .loading
        defer { busy = nil }
        if phase != .loaded { phase = .loading }
        await reload()
    }

    private func reload() async {
        do {
            let list = try await manager.list()
            keys = list.keys
            maxLiveKeys = list.maxLiveKeys
            phase = .loaded
        } catch {
            let failure = Self.adminError(error, mutation: false)
            switch failure {
            case .signedOut, .malformedSession, .rejectedSession, .ownerChanged:
                // Never leave one account's keys on screen for another.
                keys = []
                phase = .failed(failure)
            default:
                if case let .rateLimited(seconds) = failure { startRateLimit(seconds) }
                if phase == .loaded {
                    alert = Alert(id: UUID().uuidString, title: "Couldn't refresh keys",
                                  message: failure.errorDescription ?? "", revokeKeyId: nil)
                } else {
                    phase = .failed(failure)
                }
            }
        }
    }

    func loadActivity() async {
        guard activityPhase != .loading else { return }
        guard !isRateLimited() else {
            activityPhase = .failed(.rateLimited(retryAfter: max(1, (rateLimitedUntil ?? now()).timeIntervalSince(now()))))
            return
        }
        activityPhase = .loading
        do {
            activity = try await manager.activity(keyId: nil)
            activityPhase = .loaded
        } catch {
            let failure = Self.adminError(error, mutation: false)
            if case let .rateLimited(seconds) = failure { startRateLimit(seconds) }
            activity = []
            activityPhase = .failed(failure)
        }
    }

    // MARK: Sheets

    func presentCreate() {
        guard canCreate, sheet == nil else { return }
        notice = nil
        sheet = .create
    }

    /// Closes whichever sheet is up. For the show-once sheet this drops the
    /// only reference to the raw key.
    func dismissSheet() {
        sheet = nil
    }

    // MARK: Create, rotate, retry

    func create(_ request: NativeAPIKeyCreateRequest) async {
        guard canCreate else { return }
        let operation = PendingOperation(kind: .create(request), operationId: makeOperationID())
        pending = operation
        await run(operation, as: .creating)
    }

    func rotate(_ key: NativeAPIKeySummary, grace: NativeAPIKeyGrace) async {
        guard canStartKeyChange, sheet == nil, key.canRotate(at: now()) else { return }
        let operation = PendingOperation(
            kind: .rotate(keyId: key.id, keyName: key.name, grace: grace), operationId: makeOperationID())
        pending = operation
        await run(operation, as: .rotating(keyId: key.id))
    }

    /// Sends the unresolved request again: the same body and the same
    /// `operationId`, so the server replays it rather than minting again.
    func retryPending() async {
        guard let pending, busy == nil, sheet == nil else { return }
        guard !isRateLimited() else { return presentRateLimitWait() }
        await run(pending, as: .retrying)
    }

    /// Forgets the unresolved request and reloads, so a key it did create
    /// shows in the list (and can be revoked: its secret is gone).
    func dismissPending() async {
        guard pending != nil, busy == nil else { return }
        pending = nil
        notice = "If that key was made, it's in the list below. Revoke it if you don't have it saved."
        await load()
    }

    private func run(_ operation: PendingOperation, as kind: Busy) async {
        busy = kind
        notice = nil
        defer { busy = nil }
        do {
            let issued: NativeAPIKeyIssued
            switch operation.kind {
            case let .create(request):
                issued = try await manager.create(request, operationId: operation.operationId)
            case let .rotate(keyId, _, grace):
                issued = try await manager.rotate(keyId: keyId, grace: grace, operationId: operation.operationId)
            }
            pending = nil
            upsert(issued.key)
            if let previous = issued.previous { upsert(previous) }
            sheet = .reveal(Reveal(
                id: issued.key.id, keyName: issued.key.name, prefix: issued.key.prefix,
                secret: issued.secret, previous: issued.previous
            ))
            if case .create = operation.kind {
                track(.keyCreated(scopeCount: issued.key.scopes.count))
            }
        } catch {
            let failure = Self.adminError(error, mutation: true)
            if !failure.keepsPendingOperation { pending = nil }
            // A request that may have committed is frozen: the create form
            // closes and Retry (same id, same bytes) waits on the list.
            if failure.keepsPendingOperation, sheet == .create { sheet = nil }
            if case let .rateLimited(seconds) = failure { startRateLimit(seconds) }
            alert = Self.alert(for: failure, operation: operation, id: UUID().uuidString)
            switch failure {
            case .signedOut, .malformedSession, .rejectedSession, .ownerChanged:
                keys = []
                phase = .failed(failure)
            case .alreadyCompleted, .notFound:
                // Show the server's current keys (the minted one included).
                await reload()
            default:
                break
            }
        }
    }

    // MARK: Revoke

    func revoke(keyId: String) async {
        guard busy == nil, NativeAPIKeyAdministrationService.isValidKeyID(keyId) else { return }
        guard !isRateLimited() else { return presentRateLimitWait() }
        let prior = keys.first { $0.id.lowercased() == keyId.lowercased() }
        busy = .revoking(keyId: keyId)
        notice = nil
        defer { busy = nil }
        do {
            let updated = try await manager.revoke(keyId: keyId)
            upsert(updated)
            if prior?.status(at: now()) != .revoked {
                track(.keyRevoked(scopeCount: updated.scopes.count))
            }
            let name = updated.name.isEmpty ? "The key" : "“\(updated.name)”"
            notice = "\(name) is revoked. Tools using it lose access on their next request."
        } catch {
            let failure = Self.adminError(error, mutation: true)
            if case let .rateLimited(seconds) = failure { startRateLimit(seconds) }
            let message = failure == .unknownOutcome
                ? "TradeReady couldn't confirm the key was revoked. Try again: revoking twice is safe."
                : failure.errorDescription ?? ""
            alert = Alert(id: UUID().uuidString, title: "Couldn't revoke key", message: message, revokeKeyId: nil)
            switch failure {
            case .signedOut, .malformedSession, .rejectedSession, .ownerChanged:
                keys = []
                phase = .failed(failure)
            default:
                break
            }
        }
    }

    // MARK: Helpers

    private func upsert(_ key: NativeAPIKeySummary) {
        if let index = keys.firstIndex(where: { $0.id.lowercased() == key.id.lowercased() }) {
            keys[index] = key
        } else {
            keys.insert(key, at: 0)
        }
    }

    private func startRateLimit(_ seconds: TimeInterval) {
        let wait = max(1, seconds)
        rateLimitedUntil = now().addingTimeInterval(wait)
        rateLimitTask?.cancel()
        let sleep = self.sleep
        rateLimitTask = Task { [weak self] in
            await sleep(wait)
            guard !Task.isCancelled else { return }
            self?.clearRateLimitIfDue()
        }
    }

    /// Ends the 429 wait once its time has passed (the timer calls it).
    func clearRateLimitIfDue() {
        guard let rateLimitedUntil, now() >= rateLimitedUntil else { return }
        self.rateLimitedUntil = nil
    }

    private func presentRateLimitWait() {
        alert = Alert(id: UUID().uuidString, title: "Please wait",
                      message: rateLimitText ?? NativeAPIKeyAdminError.rateLimited(retryAfter: 1).errorDescription ?? "",
                      revokeKeyId: nil)
    }

    static func adminError(_ error: Error, mutation: Bool) -> NativeAPIKeyAdminError {
        if let typed = error as? NativeAPIKeyAdminError { return typed }
        return mutation ? .unknownOutcome : .offline
    }

    static func alert(for failure: NativeAPIKeyAdminError, operation: PendingOperation, id: String) -> Alert {
        let isCreate: Bool
        if case .create = operation.kind { isCreate = true } else { isCreate = false }
        switch failure {
        case let .alreadyCompleted(keyId, prefix):
            let what = isCreate ? "This key was already created" : "The replacement key was already made"
            let named = prefix.isEmpty ? "" : " (\(prefix)…)"
            return Alert(
                id: id, title: isCreate ? "Key already created" : "Replacement already made",
                message: "\(what)\(named), but TradeReady can't show it again. Revoke it and create a new one.",
                revokeKeyId: keyId.isEmpty ? nil : keyId
            )
        case .unknownOutcome:
            return Alert(id: id, title: "Not confirmed", message: failure.errorDescription ?? "", revokeKeyId: nil)
        default:
            return Alert(
                id: id, title: isCreate ? "Couldn't create key" : "Couldn't rotate key",
                message: failure.errorDescription ?? "", revokeKeyId: nil
            )
        }
    }
}
