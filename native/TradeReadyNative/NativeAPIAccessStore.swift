import Foundation

/// Roadmap Phase 23 (open-API spec §9): the `AppStore` side of Settings ›
/// API access. Keys are server authority only (§13 D14), so nothing here
/// touches the snapshot, the mutation queue or the settings blob: each call
/// reads the current Keychain session, sends one request through
/// `NativeAPIKeyAdministrationService` and hands the answer back. The only
/// local effect is an analytics event carrying a scope count.
extension AppStore {
    /// Whether a verified owner with a completed workspace is signed in.
    /// Signed out, the screen shows its sign-in state and sends nothing.
    var apiAccessIsSignedIn: Bool { apiAccessOwnerKey != nil }

    /// The client Settings › API access uses. `service` is the host-test
    /// seam; the app resolves the configured endpoint on every call.
    func apiKeyManager(service: NativeAPIKeyAdministrationService? = nil) -> NativeAPIKeyStoreManager {
        NativeAPIKeyStoreManager(store: self, service: service)
    }

    /// §9 analytics: `api_key_created` / `api_key_revoked` with the scope
    /// count only.
    func trackAPIAccess(_ event: NativeAPIAccessAnalyticsEvent) {
        switch event {
        case let .keyCreated(scopeCount): trackAPIKeyCreated(scopeCount: scopeCount)
        case let .keyRevoked(scopeCount): trackAPIKeyRevoked(scopeCount: scopeCount)
        }
    }
}

/// The store-bound `NativeAPIKeyManaging`: the owner is captured before each
/// request and rechecked after it, so a sign-out or account switch while a
/// request is open never shows one account's keys, or a new key, to another.
/// A 401 refreshes the session once through the app's own activator.
@MainActor
struct NativeAPIKeyStoreManager: NativeAPIKeyManaging {
    weak var store: AppStore?
    let service: NativeAPIKeyAdministrationService?

    func list() async throws -> NativeAPIKeyList {
        try await run { try await $0.list(sessionBytes: $1) }
    }

    func create(_ request: NativeAPIKeyCreateRequest, operationId: String) async throws -> NativeAPIKeyIssued {
        try await run { try await $0.create(request, operationId: operationId, sessionBytes: $1) }
    }

    func rotate(keyId: String, grace: NativeAPIKeyGrace, operationId: String) async throws -> NativeAPIKeyIssued {
        try await run { try await $0.rotate(keyId: keyId, grace: grace, operationId: operationId, sessionBytes: $1) }
    }

    func revoke(keyId: String) async throws -> NativeAPIKeySummary {
        try await run { try await $0.revoke(keyId: keyId, sessionBytes: $1) }
    }

    func activity(keyId: String?) async throws -> [NativeAPIActivityEvent] {
        try await run { try await $0.activity(keyId: keyId, sessionBytes: $1) }
    }

    private func run<T>(
        _ call: (NativeAPIKeyAdministrationService, Data) async throws -> T
    ) async throws -> T {
        guard let store, let owner = store.apiAccessOwnerKey else { throw NativeAPIKeyAdminError.signedOut }
        let bytes: Data
        do {
            bytes = try await store.scheduleBookingSessionBytes()
        } catch {
            throw NativeAPIKeyAdminError.signedOut
        }
        let base = try service ?? NativeAPIKeyAdministrationService(
            endpoint: NativeAPIKeyAdministrationService.resolvedEndpoint()
        )
        let wired = base.withRefresh { [weak store] in
            await store?.apiAccessRefreshedSession(excluding: bytes)
        }
        let result: T
        do {
            result = try await call(wired, bytes)
        } catch {
            guard store.apiAccessOwnerKey == owner else { throw NativeAPIKeyAdminError.ownerChanged }
            throw error
        }
        guard store.apiAccessOwnerKey == owner else { throw NativeAPIKeyAdminError.ownerChanged }
        return result
    }
}
