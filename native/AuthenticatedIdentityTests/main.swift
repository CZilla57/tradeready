import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class MemorySecureBackend: NativeSecureKeyValueBacking {
    var values: [String: Data] = [:]
    func upsert(_ value: Data, key: String) throws { values[key] = value }
    func read(key: String) throws -> Data? { values[key] }
    func remove(key: String) throws { values.removeValue(forKey: key) }
}

private final class StubLoader: NativeHTTPDataLoading {
    var statusCode = 200
    var responseData = Data("{\"id\":\"server-user\"}".utf8)
    var thrownError: Error?
    private(set) var request: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        if let thrownError { throw thrownError }
        return (
            responseData,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private final class SwitchableVerifier: NativeAuthenticatedIdentityVerifying {
    let expectedSession: Data
    let identity: NativeVerifiedAuxiliaryIdentity
    var error: NativeAuthenticatedIdentityError?

    init(expectedSession: Data, subject: String, email: String? = nil) throws {
        self.expectedSession = expectedSession
        identity = try NativeVerifiedAuxiliaryIdentity(opaqueSubject: subject, email: email)
    }

    func verify(sessionBytes: Data) async throws -> NativeVerifiedAuxiliaryIdentity {
        if let error { throw error }
        guard sessionBytes == expectedSession else {
            throw NativeAuthenticatedIdentityError.malformedStoredSession
        }
        return identity
    }
}

private final class SequencedLoader: NativeHTTPDataLoading {
    struct Response {
        let statusCode: Int
        let data: Data
    }

    var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let next = responses.removeFirst()
        return (
            next.data,
            HTTPURLResponse(
                url: request.url!, statusCode: next.statusCode,
                httpVersion: nil, headerFields: nil
            )!
        )
    }
}

private struct StubVerifier: NativeAuthenticatedIdentityVerifying {
    let expectedSession: Data
    let subject: String

    func verify(sessionBytes: Data) async throws -> NativeVerifiedAuxiliaryIdentity {
        guard sessionBytes == expectedSession else {
            throw NativeAuthenticatedIdentityError.malformedStoredSession
        }
        return try NativeVerifiedAuxiliaryIdentity(opaqueSubject: subject)
    }
}

@main
struct AuthenticatedIdentityTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let loader = StubLoader()
        let verifier = NativeSupabaseAuthenticatedIdentityVerifier(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key",
            loader: loader
        )
        let session = Data(
            "{\"access_token\":\"private-access-token\",\"refresh_token\":\"private-refresh-token\",\"user\":{\"id\":\"untrusted-local-user\"}}".utf8
        )
        let identity = try await verifier.verify(sessionBytes: session)
        expect(identity.opaqueSubject == "server-user",
               "only the server-returned Supabase subject becomes verified")
        expect(loader.request?.url?.absoluteString == "https://project.supabase.co/auth/v1/user",
               "identity verification uses the Supabase user endpoint")
        expect(loader.request?.value(forHTTPHeaderField: "apikey") == "publishable-key"
               && loader.request?.value(forHTTPHeaderField: "Authorization") == "Bearer private-access-token",
               "verification sends the publishable key and migrated access token")
        expect(loader.request?.httpMethod == "GET" && loader.request?.httpBody == nil,
               "identity verification is a read-only request")

        loader.thrownError = URLError(.notConnectedToInternet)
        do {
            _ = try await verifier.verify(sessionBytes: session)
            expect(false, "offline transport failures are classified separately")
        } catch NativeAuthenticatedIdentityError.temporarilyUnavailable {}
        loader.thrownError = nil

        do {
            _ = try await verifier.verify(sessionBytes: Data("not-json".utf8))
            expect(false, "malformed stored sessions fail closed")
        } catch NativeAuthenticatedIdentityError.malformedStoredSession {}

        loader.statusCode = 401
        do {
            _ = try await verifier.verify(sessionBytes: session)
            expect(false, "rejected sessions cannot activate account state")
        } catch NativeAuthenticatedIdentityError.rejectedSession {}
        loader.statusCode = 200
        loader.responseData = Data("{\"id\":\"\"}".utf8)
        do {
            _ = try await verifier.verify(sessionBytes: session)
            expect(false, "empty server subjects fail closed")
        } catch NativeAuthenticatedIdentityError.invalidUser {}

        let bindingBackend = MemorySecureBackend()
        let secret = Data(repeating: 0x5a, count: 32)
        let bindingProvider = NativeKeychainAuxiliaryAccountBindingProvider(
            backend: bindingBackend,
            makeSecret: { secret }
        )
        let bindingOne = try bindingProvider.keyedBinding(for: "server-user")
        let bindingTwo = try bindingProvider.keyedBinding(for: "server-user")
        let otherBinding = try bindingProvider.keyedBinding(for: "other-user")
        expect(bindingOne == bindingTwo && bindingOne != otherBinding,
               "Keychain-backed HMAC account namespaces are stable and subject-specific")
        expect(bindingBackend.values[NativeKeychainAuxiliaryAccountBindingProvider.key] == secret,
               "account-binding secret is persisted separately from artifacts")
        expect(!String(decoding: bindingOne, as: UTF8.self).contains("server-user"),
               "derived account binding does not contain the raw subject")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-auth-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshotURL = root.appendingPathComponent("store.json")
        let artifactStore = NativeAuxiliaryStateStore(snapshotURL: snapshotURL)
        _ = try artifactStore.persist([
            "__themePreference": Data("dark".utf8),
            "onboardingComplete": Data("true".utf8),
            "__dataOwner": try JSONEncoder().encode("server-user")
        ])
        let sessionBackend = MemorySecureBackend()
        let nativeSessionStore = NativeKeychainSecureSettingsStore(backend: sessionBackend)
        try nativeSessionStore.persist(.init(supabaseSession: session))
        let activationRoot = root.appendingPathComponent("Activation", isDirectory: true)
        let activator = NativeAuthenticatedIdentityActivator(
            snapshotURL: snapshotURL,
            sessionStore: nativeSessionStore,
            verifier: StubVerifier(expectedSession: session, subject: "server-user"),
            bindingProvider: bindingProvider,
            activationStore: NativeAuxiliaryActivationStore(rootURL: activationRoot)
        )
        let first = try await activator.activate()
        let second = try await activator.activate()
        expect(first?.accountState == .staged && first?.newlyStagedCount == 2,
               "live verified owner stages device and account transactions")
        expect(first?.localOwnerVerified == true
               && first?.typedAccountState?.onboardingComplete == true
               && first?.accountBinding?.count == 64
               && first?.verifiedAccountBinding.count == 64
               && first?.accountBinding == second?.accountBinding,
               "exact owner activation exposes only the typed account-state projection")
        expect(second?.accountState == .staged && second?.alreadyStagedCount == 2,
               "repeated live activation is idempotent")

        let offlineSession = Data(
            "{\"access_token\":\"offline-access\",\"refresh_token\":\"offline-refresh\"}".utf8
        )
        let offlineBackend = MemorySecureBackend()
        let offlineStore = NativeKeychainSecureSettingsStore(backend: offlineBackend)
        try offlineStore.persist(.init(supabaseSession: offlineSession))
        let switchableVerifier = try SwitchableVerifier(
            expectedSession: offlineSession,
            subject: "offline-owner",
            email: "offline@example.com"
        )
        let offlineActivator = NativeAuthenticatedIdentityActivator(
            snapshotURL: root.appendingPathComponent("Offline/store.json"),
            sessionStore: offlineStore,
            verifier: switchableVerifier,
            bindingProvider: NativeKeychainAuxiliaryAccountBindingProvider(
                backend: offlineBackend,
                makeSecret: { secret }
            )
        )
        let onlineOutcome = try await offlineActivator.activate()
        expect(onlineOutcome?.verificationSource == .live,
               "successful server verification records a live activation")
        switchableVerifier.error = .temporarilyUnavailable
        let warmOfflineOutcome = try await offlineActivator.activate()
        expect(warmOfflineOutcome?.verificationSource == .inMemoryLiveSession
               && warmOfflineOutcome?.verifiedUserSubject == "offline-owner"
               && warmOfflineOutcome?.verifiedEmail == "offline@example.com",
               "a foreground outage preserves the exact in-memory live session")

        let coldOfflineActivator = NativeAuthenticatedIdentityActivator(
            snapshotURL: root.appendingPathComponent("Offline/store.json"),
            sessionStore: offlineStore,
            verifier: switchableVerifier,
            bindingProvider: NativeKeychainAuxiliaryAccountBindingProvider(
                backend: offlineBackend,
                makeSecret: { secret }
            )
        )
        let coldOfflineOutcome = try await coldOfflineActivator.activate()
        expect(coldOfflineOutcome?.verificationSource == .exactSessionOfflineCache
               && coldOfflineOutcome?.verifiedUserSubject == "offline-owner"
               && coldOfflineOutcome?.verifiedEmail == "offline@example.com",
               "a cold outage reopens the exact previously verified Keychain session")

        try offlineStore.publishSupabaseSession(Data(
            "{\"access_token\":\"different\",\"refresh_token\":\"different\"}".utf8
        ))
        do {
            _ = try await offlineActivator.activate()
            expect(false, "a changed session cannot reuse cached offline identity")
        } catch NativeAuthenticatedIdentityError.temporarilyUnavailable {}

        try offlineStore.publishSupabaseSession(offlineSession)
        switchableVerifier.error = .rejectedSession
        do {
            _ = try await offlineActivator.activate()
            expect(false, "server rejection never falls back to cached identity")
        } catch NativeAuthenticatedIdentityError.rejectedSession {}

        try await offlineActivator.clearSession()
        expect((try? offlineBackend.read(key: NativeVerifiedSessionIdentityCache.key)) == nil,
               "sign-out removes the offline identity cache with the active session")

        let mismatchRoot = root.appendingPathComponent("Mismatch", isDirectory: true)
        let mismatch = try await NativeAuthenticatedIdentityActivator(
            snapshotURL: snapshotURL,
            sessionStore: nativeSessionStore,
            verifier: StubVerifier(expectedSession: session, subject: "different-user"),
            bindingProvider: bindingProvider,
            activationStore: NativeAuxiliaryActivationStore(rootURL: mismatchRoot)
        ).activate()
        expect(mismatch?.accountState == .ownerMismatch
               && mismatch?.newlyStagedCount == 1,
               "verified owner mismatch stages only validated device state")
        expect(mismatch?.localOwnerVerified == false && mismatch?.typedAccountState == nil
               && mismatch?.accountBinding == nil
               && mismatch?.verifiedAccountBinding.count == 64,
               "owner mismatch exposes neither ownership proof nor typed account state")
        expect(!FileManager.default.fileExists(atPath: mismatchRoot.appendingPathComponent("Accounts").path),
               "owner mismatch publishes no account envelope")

        let emptySessionStore = NativeKeychainSecureSettingsStore(backend: MemorySecureBackend())
        let noSession = try await NativeAuthenticatedIdentityActivator(
            snapshotURL: snapshotURL,
            sessionStore: emptySessionStore,
            verifier: StubVerifier(expectedSession: session, subject: "server-user"),
            bindingProvider: bindingProvider
        ).activate()
        expect(noSession == nil, "missing migrated session performs no activation")

        let refreshedSessionResponse = Data(
            "{\"access_token\":\"fresh-access\",\"refresh_token\":\"fresh-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"server-user\"}}".utf8
        )
        let refreshLoader = SequencedLoader(responses: [
            .init(statusCode: 403, data: Data("{\"error_code\":\"bad_jwt\"}".utf8)),
            .init(statusCode: 200, data: refreshedSessionResponse),
            .init(statusCode: 200, data: Data("{\"id\":\"server-user\"}".utf8))
        ])
        let refreshClient = NativeSupabaseAuthenticatedIdentityVerifier(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key",
            loader: refreshLoader,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
        let refreshBackend = MemorySecureBackend()
        let refreshStore = NativeKeychainSecureSettingsStore(backend: refreshBackend)
        let oldSession = Data(
            "{\"access_token\":\"expired-access\",\"refresh_token\":\"old-refresh\",\"future_field\":{\"kept\":true}}".utf8
        )
        try refreshStore.persist(.init(supabaseSession: oldSession))
        let refreshActivationRoot = root.appendingPathComponent("RefreshActivation", isDirectory: true)
        let refreshedOutcome = try await NativeAuthenticatedIdentityActivator(
            snapshotURL: snapshotURL,
            sessionStore: refreshStore,
            verifier: refreshClient,
            refresher: refreshClient,
            bindingProvider: bindingProvider,
            activationStore: NativeAuxiliaryActivationStore(rootURL: refreshActivationRoot)
        ).activate()
        let storedRefreshedBytes = try refreshStore.readSupabaseSession()!
        let storedRefreshed = try JSONSerialization.jsonObject(with: storedRefreshedBytes) as! [String: Any]
        expect(refreshedOutcome?.accountState == .staged,
               "a rejected access token refreshes before verified activation")
        expect(storedRefreshed["access_token"] as? String == "fresh-access"
               && storedRefreshed["refresh_token"] as? String == "fresh-refresh",
               "rotated access and refresh tokens become the active Keychain generation")
        expect(storedRefreshed["future_field"] == nil,
               "authoritative refresh response does not retain stale session fields")
        expect(storedRefreshed["expires_at"] as? Double == 2_000_003_600,
               "refresh synthesizes expires_at from a positive expires_in when absent")
        expect(refreshLoader.requests.map { $0.httpMethod ?? "" } == ["GET", "POST", "GET"],
               "refresh transaction rejects, rotates, then verifies the successor")
        expect(refreshLoader.requests[1].url?.absoluteString
               == "https://project.supabase.co/auth/v1/token?grant_type=refresh_token",
               "refresh uses the Supabase refresh-token grant endpoint")
        let refreshBody = try JSONSerialization.jsonObject(
            with: refreshLoader.requests[1].httpBody!
        ) as! [String: Any]
        expect(refreshBody["refresh_token"] as? String == "old-refresh",
               "refresh request contains only the stored refresh credential")

        let mismatchLoader = SequencedLoader(responses: [
            .init(statusCode: 403, data: Data()),
            .init(statusCode: 200, data: refreshedSessionResponse),
            .init(statusCode: 200, data: Data("{\"id\":\"different-server-user\"}".utf8))
        ])
        let mismatchClient = NativeSupabaseAuthenticatedIdentityVerifier(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key",
            loader: mismatchLoader
        )
        let mismatchRefreshBackend = MemorySecureBackend()
        let mismatchRefreshStore = NativeKeychainSecureSettingsStore(backend: mismatchRefreshBackend)
        try mismatchRefreshStore.persist(.init(supabaseSession: oldSession))
        do {
            _ = try await NativeAuthenticatedIdentityActivator(
                snapshotURL: snapshotURL,
                sessionStore: mismatchRefreshStore,
                verifier: mismatchClient,
                refresher: mismatchClient,
                bindingProvider: bindingProvider,
                activationStore: NativeAuxiliaryActivationStore(
                    rootURL: root.appendingPathComponent("RefreshSubjectMismatch")
                )
            ).activate()
            expect(false, "refresh and independent user subjects must agree")
        } catch NativeAuthenticatedIdentityError.invalidUser {}

        let terminalRefreshLoader = StubLoader()
        terminalRefreshLoader.statusCode = 422
        let terminalRefreshClient = NativeSupabaseAuthenticatedIdentityVerifier(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key",
            loader: terminalRefreshLoader
        )
        do {
            _ = try await terminalRefreshClient.refresh(sessionBytes: oldSession)
            expect(false, "unprocessable refresh tokens are terminal")
        } catch NativeAuthenticatedIdentityError.rejectedSession {}

        terminalRefreshLoader.statusCode = 200
        terminalRefreshLoader.responseData = Data(
            "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_in\":0,\"user\":{\"id\":\"server-user\"}}".utf8
        )
        do {
            _ = try await terminalRefreshClient.refresh(sessionBytes: oldSession)
            expect(false, "non-positive refresh expiry is rejected before publication")
        } catch NativeAuthenticatedIdentityError.unexpectedResponse {}

        do {
            try refreshStore.replaceSupabaseSession(
                expectedCurrent: oldSession,
                with: Data("different".utf8)
            )
            expect(false, "stale refresh responses cannot replace a newer active generation")
        } catch NativeSecureSettingsStoreError.conflictingNativeSession {}

        let directSession = Data(
            "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\"}".utf8
        )
        let directBackend = MemorySecureBackend()
        let directStore = NativeKeychainSecureSettingsStore(backend: directBackend)
        let directActivator = NativeAuthenticatedIdentityActivator(
            snapshotURL: root.appendingPathComponent("NoAuxiliary/store.json"),
            sessionStore: directStore,
            verifier: StubVerifier(expectedSession: directSession, subject: "new-user"),
            bindingProvider: bindingProvider
        )
        let directOutcome = try await directActivator.installVerifiedSession(
            sessionBytes: directSession,
            responseUserSubject: "new-user"
        )
        expect(directOutcome.accountState == .noAuxiliaryArtifact
               && (try? directStore.readSupabaseSession()) == directSession,
               "new sign-in is independently verified before atomic Keychain publication")
        try await directActivator.clearSession()
        expect((try? directStore.readSupabaseSession()) == nil,
               "explicit local sign-out removes the active session pointer")

        try directBackend.upsert(Data("provider-secret".utf8), key: "providerKey")
        try directBackend.upsert(Data("anthropic-secret".utf8), key: "anthropicKey")
        try directBackend.upsert(Data("groq-secret".utf8), key: "groqKey")
        try directStore.clearAccountValues()
        expect((try? directBackend.read(key: "providerKey")) == nil
               && (try? directBackend.read(key: "anthropicKey")) == nil
               && (try? directBackend.read(key: "groqKey")) == nil,
               "account cleanup removes migrated provider credentials")
        try directBackend.upsert(
            Data(repeating: 7, count: NativeKeychainAuxiliaryAccountBindingProvider.secretByteCount),
            key: NativeKeychainAuxiliaryAccountBindingProvider.key
        )
        try directStore.clearAllValues()
        expect((try? directBackend.read(
            key: NativeKeychainAuxiliaryAccountBindingProvider.key
        )) == nil, "permanent deletion removes the native account-binding secret")

        let mismatchBackend = MemorySecureBackend()
        let directMismatchStore = NativeKeychainSecureSettingsStore(backend: mismatchBackend)
        do {
            _ = try await NativeAuthenticatedIdentityActivator(
                snapshotURL: root.appendingPathComponent("RejectedDirect/store.json"),
                sessionStore: directMismatchStore,
                verifier: StubVerifier(expectedSession: directSession, subject: "other-user"),
                bindingProvider: bindingProvider
            ).installVerifiedSession(
                sessionBytes: directSession,
                responseUserSubject: "claimed-user"
            )
            expect(false, "token and independent user subjects must agree before publication")
        } catch NativeAuthenticatedIdentityError.invalidUser {}
        expect((try? directMismatchStore.readSupabaseSession()) == nil,
               "subject mismatch leaves no active Keychain session")

        if failures > 0 {
            print("FAILED: Authenticated identity tests (\(failures) failure(s))")
            Foundation.exit(1)
        }
        print("PASS: authenticated Supabase identity activation tests")
    }
}
