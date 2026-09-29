import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

enum NativeAuthenticatedIdentityError: LocalizedError, Equatable {
    case malformedStoredSession
    case missingAccessToken
    case missingRefreshToken
    case invalidConfiguration
    case rejectedSession
    case temporarilyUnavailable
    case unexpectedResponse
    case invalidUser
    case invalidBindingSecret

    var errorDescription: String? {
        switch self {
        case .malformedStoredSession:
            "The saved sign-in session could not be read."
        case .missingAccessToken:
            "The saved sign-in session does not contain an access token."
        case .missingRefreshToken:
            "The saved sign-in session does not contain a refresh token."
        case .invalidConfiguration:
            "Supabase authentication is not configured for this build."
        case .rejectedSession:
            "The saved sign-in session is no longer valid."
        case .temporarilyUnavailable:
            "The authentication service is temporarily unavailable."
        case .unexpectedResponse:
            "The authentication service returned an unexpected response."
        case .invalidUser:
            "The authentication service returned an invalid account identity."
        case .invalidBindingSecret:
            "The private account-binding key could not be created or verified."
        }
    }
}

protocol NativeAuthenticatedIdentityVerifying {
    func verify(sessionBytes: Data) async throws -> NativeVerifiedAuxiliaryIdentity
}

protocol NativeAuthenticatedSessionRefreshing {
    func refresh(sessionBytes: Data) async throws -> NativeRefreshedSession
}

struct NativeRefreshedSession: Equatable, Sendable {
    let bytes: Data
    /// This subject comes from the refresh response and must agree with the
    /// independent `/auth/v1/user` lookup before any owner state activates.
    let responseUserSubject: String
}

protocol NativeHTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativeHTTPDataLoading {}

/// Validates migrated Supabase session bytes against the Auth server. The
/// embedded user object and JWT claims are deliberately ignored: only the
/// subject returned by `/auth/v1/user` is allowed to cross the verified
/// identity boundary.
struct NativeSupabaseAuthenticatedIdentityVerifier:
    NativeAuthenticatedIdentityVerifying,
    NativeAuthenticatedSessionRefreshing
{
    private struct StoredSession: Decodable {
        let accessToken: String
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private struct RefreshRequest: Encodable {
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    private struct AuthUser: Decodable {
        let id: String
        let email: String?
    }

    let supabaseURL: URL
    let publishableKey: String
    let loader: any NativeHTTPDataLoading
    let now: () -> Date

    init(
        supabaseURL: URL,
        publishableKey: String,
        loader: any NativeHTTPDataLoading = URLSession.shared,
        now: @escaping () -> Date = { Date() }
    ) {
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.loader = loader
        self.now = now
    }

    func verify(sessionBytes: Data) async throws -> NativeVerifiedAuxiliaryIdentity {
        let session = try decodeStoredSession(sessionBytes)
        guard !session.accessToken.isEmpty else {
            throw NativeAuthenticatedIdentityError.missingAccessToken
        }
        guard supabaseURL.scheme == "https", supabaseURL.host != nil,
              !publishableKey.isEmpty
        else { throw NativeAuthenticatedIdentityError.invalidConfiguration }

        var request = URLRequest(url: supabaseURL.appending(path: "auth/v1/user"))
        request.httpMethod = "GET"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(for: request)
        } catch {
            throw NativeAuthenticatedIdentityError.temporarilyUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw NativeAuthenticatedIdentityError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw NativeAuthenticatedIdentityError.rejectedSession
            }
            if http.statusCode == 408 || http.statusCode == 429
                || (500..<600).contains(http.statusCode)
            {
                throw NativeAuthenticatedIdentityError.temporarilyUnavailable
            }
            throw NativeAuthenticatedIdentityError.unexpectedResponse
        }

        let user: AuthUser
        do {
            user = try JSONDecoder().decode(AuthUser.self, from: data)
        } catch {
            throw NativeAuthenticatedIdentityError.invalidUser
        }
        do {
            return try NativeVerifiedAuxiliaryIdentity(opaqueSubject: user.id, email: user.email)
        } catch {
            throw NativeAuthenticatedIdentityError.invalidUser
        }
    }

    /// Exchanges the migrated refresh token for a successor session. The
    /// response is authoritative; stale provider/user fields from the old
    /// session are not merged into the rotated session.
    func refresh(sessionBytes: Data) async throws -> NativeRefreshedSession {
        let session = try decodeStoredSession(sessionBytes)
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw NativeAuthenticatedIdentityError.missingRefreshToken
        }
        guard supabaseURL.scheme == "https", supabaseURL.host != nil,
              !publishableKey.isEmpty
        else { throw NativeAuthenticatedIdentityError.invalidConfiguration }

        var components = URLComponents(
            url: supabaseURL.appending(path: "auth/v1/token"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = components?.url else {
            throw NativeAuthenticatedIdentityError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(RefreshRequest(refreshToken: refreshToken))

        let responseBytes: Data
        let response: URLResponse
        do {
            (responseBytes, response) = try await loader.data(for: request)
        } catch {
            throw NativeAuthenticatedIdentityError.temporarilyUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw NativeAuthenticatedIdentityError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 400 || http.statusCode == 401
                || http.statusCode == 403 || http.statusCode == 422
            {
                throw NativeAuthenticatedIdentityError.rejectedSession
            }
            if http.statusCode == 408 || http.statusCode == 429
                || (500..<600).contains(http.statusCode)
            {
                throw NativeAuthenticatedIdentityError.temporarilyUnavailable
            }
            throw NativeAuthenticatedIdentityError.unexpectedResponse
        }

        var refreshedObject: [String: Any]
        do {
            guard let refreshed = try JSONSerialization.jsonObject(with: responseBytes) as? [String: Any]
            else { throw NativeAuthenticatedIdentityError.unexpectedResponse }
            refreshedObject = refreshed
        } catch let error as NativeAuthenticatedIdentityError {
            throw error
        } catch {
            throw NativeAuthenticatedIdentityError.unexpectedResponse
        }
        guard let newAccessToken = refreshedObject["access_token"] as? String,
              !newAccessToken.isEmpty,
              let newRefreshToken = refreshedObject["refresh_token"] as? String,
              !newRefreshToken.isEmpty,
              let expiresIn = refreshedObject["expires_in"] as? NSNumber,
              expiresIn.doubleValue > 0,
              let responseUser = refreshedObject["user"] as? [String: Any],
              let responseUserID = responseUser["id"] as? String,
              !responseUserID.isEmpty
        else { throw NativeAuthenticatedIdentityError.unexpectedResponse }

        if refreshedObject["expires_at"] == nil {
            refreshedObject["expires_at"] = floor(now().timeIntervalSince1970 + expiresIn.doubleValue)
        }
        do {
            return NativeRefreshedSession(
                bytes: try JSONSerialization.data(withJSONObject: refreshedObject, options: [.sortedKeys]),
                responseUserSubject: responseUserID
            )
        } catch {
            throw NativeAuthenticatedIdentityError.unexpectedResponse
        }
    }

    private func decodeStoredSession(_ bytes: Data) throws -> StoredSession {
        do {
            return try JSONDecoder().decode(StoredSession.self, from: bytes)
        } catch {
            throw NativeAuthenticatedIdentityError.malformedStoredSession
        }
    }
}

/// Remembers the exact Keychain session that most recently crossed the live
/// `/auth/v1/user` boundary. This is an availability cache, not a replacement
/// for verification: it is consulted only for a temporary transport/service
/// failure and only when the active session bytes still match exactly.
struct NativeVerifiedSessionIdentityCache {
    static let key = NativeKeychainSecureSettingsStore.verifiedSessionIdentityAccount
    static let currentSchemaVersion = 1

    private struct Record: Codable, Equatable {
        let schemaVersion: Int
        let sessionSHA256: String
        let subject: String
        let email: String?
    }

    let backend: any NativeSecureKeyValueBacking

    func store(
        sessionBytes: Data,
        identity: NativeVerifiedAuxiliaryIdentity
    ) throws {
        let record = Record(
            schemaVersion: Self.currentSchemaVersion,
            sessionSHA256: Self.sessionDigest(sessionBytes),
            subject: identity.opaqueSubject,
            email: identity.email
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(record)
        try backend.upsert(bytes, key: Self.key)
        guard try backend.read(key: Self.key) == bytes else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: Self.key)
        }
    }

    func identity(forExactSession sessionBytes: Data) throws -> NativeVerifiedAuxiliaryIdentity? {
        guard let bytes = try backend.read(key: Self.key) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: bytes),
              record.schemaVersion == Self.currentSchemaVersion,
              record.sessionSHA256.count == 64,
              record.sessionSHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else { throw NativeAuthenticatedIdentityError.invalidUser }
        guard record.sessionSHA256 == Self.sessionDigest(sessionBytes) else { return nil }
        do {
            return try NativeVerifiedAuxiliaryIdentity(
                opaqueSubject: record.subject,
                email: record.email
            )
        } catch {
            throw NativeAuthenticatedIdentityError.invalidUser
        }
    }

    func clear() throws {
        try backend.remove(key: Self.key)
        guard try backend.read(key: Self.key) == nil else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: Self.key)
        }
    }

    static func sessionDigest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}

/// Produces a non-reversible account namespace using an app-local Keychain
/// secret. The secret and raw subject never enter snapshots or receipts.
struct NativeKeychainAuxiliaryAccountBindingProvider: NativeAuxiliaryAccountBindingProviding {
    static let key = "auxiliary-account-binding-key.v1"
    static let secretByteCount = 32

    let backend: any NativeSecureKeyValueBacking
    let makeSecret: () throws -> Data

    init(
        backend: any NativeSecureKeyValueBacking = NativeKeychainBackend(),
        makeSecret: @escaping () throws -> Data = Self.makeSecureSecret
    ) {
        self.backend = backend
        self.makeSecret = makeSecret
    }

    func keyedBinding(for opaqueSubject: String) throws -> Data {
        let secret: Data
        if let existing = try backend.read(key: Self.key) {
            secret = existing
        } else {
            secret = try makeSecret()
            guard secret.count == Self.secretByteCount else {
                throw NativeAuthenticatedIdentityError.invalidBindingSecret
            }
            try backend.upsert(secret, key: Self.key)
            guard try backend.read(key: Self.key) == secret else {
                throw NativeAuthenticatedIdentityError.invalidBindingSecret
            }
        }
        guard secret.count == Self.secretByteCount else {
            throw NativeAuthenticatedIdentityError.invalidBindingSecret
        }
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(opaqueSubject.utf8),
            using: SymmetricKey(data: secret)
        )
        return Data(code)
    }

    private static func makeSecureSecret() throws -> Data {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: secretByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NativeAuthenticatedIdentityError.invalidBindingSecret
        }
        return Data(bytes)
        #else
        throw NativeAuthenticatedIdentityError.invalidBindingSecret
        #endif
    }
}

struct NativeAuthenticatedIdentityActivationOutcome: Equatable, Sendable {
    enum VerificationSource: Equatable, Sendable {
        case live
        case inMemoryLiveSession
        case exactSessionOfflineCache

        var isOfflineFallback: Bool { self != .live }
    }

    enum AccountState: Equatable, Sendable {
        case noAuxiliaryArtifact
        case noAccountState
        case staged
        case ownerMismatch
    }

    let accountState: AccountState
    let newlyStagedCount: Int
    let alreadyStagedCount: Int
    let typedAccountState: NativeTypedAccountState?
    let localOwnerVerified: Bool
    /// Non-reversible HMAC namespace for owner-bound local consumers.
    let accountBinding: String?
    /// Stable namespace for all native account state, even when no legacy
    /// account artifact exists. This does not assert legacy-data ownership.
    let verifiedAccountBinding: String
    /// Subject most recently established by `/auth/v1/user`. Offline activation
    /// can reuse it only while the exact verified Keychain session still matches.
    let verifiedUserSubject: String
    let verifiedEmail: String?
    let verificationSource: VerificationSource
}

/// Serializes live identity activation. Repeated foreground/startup calls are
/// safe because both the planner and activation store are idempotent.
actor NativeAuthenticatedIdentityActivator {
    let auxiliaryArtifactURL: URL
    let sessionStore: NativeKeychainSecureSettingsStore
    let verifier: any NativeAuthenticatedIdentityVerifying
    let refresher: (any NativeAuthenticatedSessionRefreshing)?
    let bindingProvider: any NativeAuxiliaryAccountBindingProviding
    let activationStore: NativeAuxiliaryActivationStore
    private let fileManager: FileManager
    private var lastLiveVerifiedSessionDigest: String?
    private var lastLiveVerifiedIdentity: NativeVerifiedAuxiliaryIdentity?

    init(
        snapshotURL: URL,
        sessionStore: NativeKeychainSecureSettingsStore = .init(),
        verifier: any NativeAuthenticatedIdentityVerifying,
        refresher: (any NativeAuthenticatedSessionRefreshing)? = nil,
        bindingProvider: any NativeAuxiliaryAccountBindingProviding =
            NativeKeychainAuxiliaryAccountBindingProvider(),
        activationStore: NativeAuxiliaryActivationStore? = nil,
        fileManager: FileManager = .default
    ) {
        auxiliaryArtifactURL = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent(NativeAuxiliaryStateStore.filename)
        self.sessionStore = sessionStore
        self.verifier = verifier
        self.refresher = refresher
        self.bindingProvider = bindingProvider
        self.activationStore = activationStore ?? NativeAuxiliaryActivationStore(
            rootURL: snapshotURL.deletingLastPathComponent()
                .appendingPathComponent("AuxiliaryActivation", isDirectory: true)
        )
        self.fileManager = fileManager
    }

    func activate() async throws -> NativeAuthenticatedIdentityActivationOutcome? {
        guard let sessionBytes = try sessionStore.readSupabaseSession() else { return nil }
        var identity: NativeVerifiedAuxiliaryIdentity
        var verificationSource = NativeAuthenticatedIdentityActivationOutcome.VerificationSource.live
        let identityCache = NativeVerifiedSessionIdentityCache(backend: sessionStore.backend)
        do {
            identity = try await verifier.verify(sessionBytes: sessionBytes)
            try identityCache.store(sessionBytes: sessionBytes, identity: identity)
            rememberLiveVerification(sessionBytes: sessionBytes, identity: identity)
        } catch NativeAuthenticatedIdentityError.temporarilyUnavailable {
            let sessionDigest = NativeVerifiedSessionIdentityCache.sessionDigest(sessionBytes)
            if sessionDigest == lastLiveVerifiedSessionDigest,
               let liveIdentity = lastLiveVerifiedIdentity
            {
                identity = liveIdentity
                verificationSource = .inMemoryLiveSession
            } else {
                guard let cached = try identityCache.identity(forExactSession: sessionBytes) else {
                    throw NativeAuthenticatedIdentityError.temporarilyUnavailable
                }
                identity = cached
                verificationSource = .exactSessionOfflineCache
            }
        } catch NativeAuthenticatedIdentityError.rejectedSession {
            guard let refresher else { throw NativeAuthenticatedIdentityError.rejectedSession }
            let refreshed = try await refresher.refresh(sessionBytes: sessionBytes)
            // Persist before the follow-up user lookup: Supabase refresh tokens
            // rotate, so losing a successful response would otherwise strand
            // the session on credentials the server has already superseded.
            do {
                try sessionStore.replaceSupabaseSession(
                    expectedCurrent: sessionBytes,
                    with: refreshed.bytes
                )
                identity = try await verifier.verify(sessionBytes: refreshed.bytes)
                guard identity.opaqueSubject == refreshed.responseUserSubject else {
                    throw NativeAuthenticatedIdentityError.invalidUser
                }
                try identityCache.store(sessionBytes: refreshed.bytes, identity: identity)
                rememberLiveVerification(sessionBytes: refreshed.bytes, identity: identity)
            } catch NativeSecureSettingsStoreError.conflictingNativeSession {
                // Another serialized auth operation won the compare-and-swap.
                // Verify the now-current session instead of resurrecting the
                // stale refresh response.
                guard let current = try sessionStore.readSupabaseSession() else {
                    throw NativeAuthenticatedIdentityError.rejectedSession
                }
                identity = try await verifier.verify(sessionBytes: current)
                try identityCache.store(sessionBytes: current, identity: identity)
                rememberLiveVerification(sessionBytes: current, identity: identity)
            }
        }
        return try await activate(identity: identity, verificationSource: verificationSource)
    }

    /// Installs a newly authenticated session only after an independent user
    /// lookup agrees with the subject returned by the token endpoint. All
    /// Keychain session writers therefore remain serialized by this actor.
    func installVerifiedSession(
        sessionBytes: Data,
        responseUserSubject: String
    ) async throws -> NativeAuthenticatedIdentityActivationOutcome {
        let identity = try await verifier.verify(sessionBytes: sessionBytes)
        guard identity.opaqueSubject == responseUserSubject else {
            throw NativeAuthenticatedIdentityError.invalidUser
        }
        try NativeVerifiedSessionIdentityCache(backend: sessionStore.backend).store(
            sessionBytes: sessionBytes,
            identity: identity
        )
        try sessionStore.publishSupabaseSession(sessionBytes)
        rememberLiveVerification(sessionBytes: sessionBytes, identity: identity)
        return try await activate(identity: identity, verificationSource: .live)
    }

    func clearSession() throws {
        try sessionStore.clearSupabaseSession()
        lastLiveVerifiedSessionDigest = nil
        lastLiveVerifiedIdentity = nil
    }

    private func rememberLiveVerification(
        sessionBytes: Data,
        identity: NativeVerifiedAuxiliaryIdentity
    ) {
        lastLiveVerifiedSessionDigest = NativeVerifiedSessionIdentityCache.sessionDigest(sessionBytes)
        lastLiveVerifiedIdentity = identity
    }

    private func activate(
        identity: NativeVerifiedAuxiliaryIdentity,
        verificationSource: NativeAuthenticatedIdentityActivationOutcome.VerificationSource
    ) async throws -> NativeAuthenticatedIdentityActivationOutcome {
        let verifiedBinding = try bindingProvider.keyedBinding(for: identity.opaqueSubject)
            .map { String(format: "%02x", $0) }.joined()
        guard fileManager.fileExists(atPath: auxiliaryArtifactURL.path) else {
            return .init(
                accountState: .noAuxiliaryArtifact,
                newlyStagedCount: 0,
                alreadyStagedCount: 0,
                typedAccountState: nil,
                localOwnerVerified: false,
                accountBinding: nil,
                verifiedAccountBinding: verifiedBinding,
                verifiedUserSubject: identity.opaqueSubject,
                verifiedEmail: identity.email,
                verificationSource: verificationSource
            )
        }

        let artifactBytes = try Data(contentsOf: auxiliaryArtifactURL)
        let plan = try NativeAuxiliaryActivationPlanner.plan(
            sourceArtifactBytes: artifactBytes,
            identity: identity,
            accountBindingProvider: bindingProvider
        )
        let outcome = try await activationStore.stage(plan)
        let state: NativeAuthenticatedIdentityActivationOutcome.AccountState = switch plan.accountDisposition {
        case .notRequested: .noAccountState
        case .staged: .staged
        case .identityNotProven: .ownerMismatch
        }
        let accountTransaction = plan.transactions.first { $0.scope == .account }
        let typedState: NativeTypedAccountState?
        if state == .staged, let binding = accountTransaction?.accountBinding {
            typedState = try NativeTypedAccountStateConsumer.load(
                activationRootURL: activationStore.rootURL,
                accountBinding: binding,
                fileManager: fileManager
            )
        } else {
            typedState = nil
        }
        return .init(
            accountState: state,
            newlyStagedCount: outcome.newlyStagedCount,
            alreadyStagedCount: outcome.alreadyStagedCount,
            typedAccountState: typedState,
            localOwnerVerified: state == .staged,
            accountBinding: state == .staged ? accountTransaction?.accountBinding : nil,
            verifiedAccountBinding: verifiedBinding,
            verifiedUserSubject: identity.opaqueSubject,
            verifiedEmail: identity.email,
            verificationSource: verificationSource
        )
    }
}
