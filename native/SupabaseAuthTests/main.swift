import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class AuthLoader: NativeHTTPDataLoading {
    struct Stub { let status: Int; let body: Data }
    var stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(_ stubs: [Stub]) { self.stubs = stubs }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let stub = stubs.removeFirst()
        return (
            stub.body,
            HTTPURLResponse(
                url: request.url!, statusCode: stub.status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private final class RecoveryKeyValueBackend: NativeSecureKeyValueBacking {
    var values: [String: Data] = [:]
    func upsert(_ value: Data, key: String) throws { values[key] = value }
    func read(key: String) throws -> Data? { values[key] }
    func remove(key: String) throws { values[key] = nil }
}

@main
struct SupabaseAuthTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let token = Data("""
        {"access_token":"access","refresh_token":"refresh","expires_in":3600,"user":{"id":"user-1","email":"owner@example.com"}}
        """.utf8)
        let signInLoader = AuthLoader([.init(status: 200, body: token)])
        let signInClient = NativeSupabaseEmailAuthClient(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key",
            loader: signInLoader,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
        let session = try await signInClient.signIn(
            email: " owner@example.com ", password: "private-password"
        )
        let request = signInLoader.requests[0]
        let requestBody = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        let stored = try JSONSerialization.jsonObject(with: session.bytes) as! [String: Any]
        expect(request.url?.absoluteString == "https://project.supabase.co/auth/v1/token?grant_type=password",
               "password sign-in uses the GoTrue password grant")
        expect(request.value(forHTTPHeaderField: "apikey") == "publishable-key",
               "password sign-in uses only the client-safe publishable key")
        expect(requestBody == ["email": "owner@example.com", "password": "private-password"],
               "credentials are trimmed and sent only in the JSON body")
        expect(session.userSubject == "user-1" && session.email == "owner@example.com",
               "token response exposes the server user identity")
        expect(stored["expires_at"] as? Double == 2_000_003_600,
               "session persistence synthesizes absolute expiry")

        let nonceBytes = Data(0..<UInt8(NativeAppleSignInNonce.byteCount))
        let rawNonce = try NativeAppleSignInNonce.rawValue(from: nonceBytes)
        expect(rawNonce == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
               "Apple raw nonce is fixed-length base64url without padding")
        expect(NativeAppleSignInNonce.hashedValue(for: "test-nonce") ==
               "ed04c4e9ea6c49cf9ceb39098787c5b9842524f96b07ef45305476a11caec9b4",
               "Apple sends the deterministic SHA-256 nonce value")

        let appleLoader = AuthLoader([.init(status: 200, body: token)])
        let appleSession = try await NativeSupabaseEmailAuthClient(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key", loader: appleLoader
        ).signInWithApple(idToken: "apple-id-token", rawNonce: rawNonce)
        let appleRequest = appleLoader.requests[0]
        let appleBody = try JSONSerialization.jsonObject(
            with: appleRequest.httpBody!
        ) as! [String: String]
        expect(appleRequest.url?.absoluteString ==
               "https://project.supabase.co/auth/v1/token?grant_type=id_token",
               "Apple sign-in uses Supabase's native ID-token grant")
        expect(appleBody == [
            "provider": "apple", "id_token": "apple-id-token", "nonce": rawNonce
        ] && appleSession.userSubject == "user-1",
               "Apple token exchange sends the provider, token, and matching raw nonce only")

        let googleLoader = AuthLoader([.init(status: 200, body: token)])
        let googleSession = try await NativeSupabaseEmailAuthClient(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key", loader: googleLoader
        ).signInWithGoogle(idToken: "google-id-token", rawNonce: rawNonce)
        let googleRequest = googleLoader.requests[0]
        let googleBody = try JSONSerialization.jsonObject(
            with: googleRequest.httpBody!
        ) as! [String: String]
        expect(googleRequest.url?.absoluteString ==
               "https://project.supabase.co/auth/v1/token?grant_type=id_token",
               "Google sign-in uses Supabase's native ID-token grant")
        expect(googleBody == [
            "provider": "google", "id_token": "google-id-token", "nonce": rawNonce
        ] && googleSession.userSubject == "user-1",
               "Google token exchange sends the provider, token, and matching raw nonce only")
        expect(NativeGoogleSignInError.isCancellation(NSError(
            domain: "com.google.GIDSignIn", code: -5
        )), "Google SDK cancellation is recognized without surfacing an auth error")
        expect(!NativeGoogleSignInError.isCancellation(NSError(
            domain: "com.google.GIDSignIn", code: -2
        )), "Google SDK failures are not mistaken for user cancellation")

        let pkce = try NativePasswordRecoveryPKCE.value(from: Data(0..<32))
        expect(pkce.verifier == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
               && pkce.challenge == "6oZqdX5MOLq_qBJ8vppAnT4fk6AP8UiP9zX8-Rev_9A",
               "recovery PKCE uses base64url verifier and SHA-256 challenge")
        expect(NativePasswordRecoveryLink.parse(
            URL(string: "tradeready://reset-password?code=one-time-code")!
        ) == .code("one-time-code"), "recovery accepts the exact native PKCE callback")
        expect(NativePasswordRecoveryLink.parse(
            URL(string: "tradeready://reset-password?code=one&code=two")!
        ) == .invalid, "recovery rejects duplicate codes")
        expect(NativePasswordRecoveryLink.parse(
            URL(string: "tradeready://reset-password?code=one&next=job")!
        ) == .invalid, "recovery rejects unapproved callback parameters")
        expect(NativePasswordRecoveryLink.parse(
            URL(string: "tradeready://reset-password?code=one#access_token=secret")!
        ) == .invalid, "recovery rejects token-bearing fragments")
        expect(NativePasswordRecoveryLink.parse(
            URL(string: "tradeready://job/job-1")!
        ) == nil, "recovery parser leaves unrelated app routes alone")

        let recoveryBackend = RecoveryKeyValueBackend()
        let recoveryStore = NativePasswordRecoveryStore(backend: recoveryBackend)
        try recoveryStore.savePending(verifier: pkce.verifier)
        let pendingRecovery = try recoveryStore.read()
        expect(pendingRecovery?.codeVerifier == pkce.verifier,
               "recovery verifier round-trips only through secure storage")
        try recoveryStore.markActive(userSubject: "user-1")
        let activeRecovery = try recoveryStore.read()
        expect(activeRecovery?.codeVerifier == nil && activeRecovery?.activeUserSubject == "user-1",
               "verified recovery activation removes the reusable verifier")
        try recoveryStore.clear()
        let clearedRecovery = try recoveryStore.read()
        expect(clearedRecovery == nil, "recovery state clears exactly")

        let invalidLoader = AuthLoader([.init(
            status: 400,
            body: Data("{\"error_code\":\"invalid_credentials\",\"msg\":\"Invalid login credentials\"}".utf8)
        )])
        do {
            _ = try await NativeSupabaseEmailAuthClient(
                supabaseURL: URL(string: "https://project.supabase.co")!,
                publishableKey: "publishable-key", loader: invalidLoader
            ).signIn(email: "owner@example.com", password: "wrong")
            expect(false, "invalid credentials fail")
        } catch NativeSupabaseAuthError.invalidCredentials {}

        let signupLoader = AuthLoader([
            .init(status: 200, body: Data("{\"id\":\"pending-user\",\"email\":\"new@example.com\"}".utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data("{}".utf8))
        ])
        let signupClient = NativeSupabaseEmailAuthClient(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key", loader: signupLoader
        )
        let redirect = URL(string: "https://gettradereadyapp.com/confirmed.html")!
        let signup = try await signupClient.signUp(
            email: "new@example.com", password: "secret1", redirectTo: redirect
        )
        expect(signup == .confirmationRequired(email: "new@example.com"),
               "confirmed-email projects do not invent a local session")
        expect(signupLoader.requests[0].url?.query == "redirect_to=https://gettradereadyapp.com/confirmed.html",
               "signup carries the approved confirmation redirect")
        try await signupClient.requestPasswordReset(
            email: "new@example.com",
            redirectTo: URL(string: "tradeready://reset-password")!,
            codeChallenge: "recovery-challenge"
        )
        try await signupClient.resendSignUpConfirmation(
            email: "new@example.com", redirectTo: redirect
        )
        expect(signupLoader.requests.map { $0.url?.path ?? "" } == [
            "/auth/v1/signup", "/auth/v1/recover", "/auth/v1/resend"
        ], "signup, recovery, and resend use their distinct endpoints")
        let recoveryRequestBody = try JSONSerialization.jsonObject(
            with: signupLoader.requests[1].httpBody!
        ) as! [String: String]
        expect(recoveryRequestBody == [
            "email": "new@example.com",
            "code_challenge": "recovery-challenge",
            "code_challenge_method": "s256"
        ], "recovery request sends PKCE state in the JSON body")
        let resendBody = try JSONSerialization.jsonObject(
            with: signupLoader.requests[2].httpBody!
        ) as! [String: String]
        expect(resendBody["type"] == "signup",
               "confirmation resend cannot be confused with another OTP type")

        let recoveryLoader = AuthLoader([
            .init(status: 200, body: token),
            .init(status: 200, body: Data("{\"id\":\"user-1\",\"email\":\"owner@example.com\"}".utf8))
        ])
        let recoveryClient = NativeSupabaseEmailAuthClient(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key", loader: recoveryLoader
        )
        let recoverySession = try await recoveryClient.exchangePasswordRecoveryCode(
            "one-time-code", codeVerifier: pkce.verifier
        )
        try await recoveryClient.updatePassword(
            "new-private-password",
            sessionBytes: recoverySession.bytes,
            expectedUserSubject: "user-1"
        )
        let exchangeBody = try JSONSerialization.jsonObject(
            with: recoveryLoader.requests[0].httpBody!
        ) as! [String: String]
        expect(recoveryLoader.requests[0].url?.absoluteString ==
               "https://project.supabase.co/auth/v1/token?grant_type=pkce"
               && exchangeBody == ["auth_code": "one-time-code", "code_verifier": pkce.verifier],
               "recovery exchanges the one-time code with its matching verifier")
        let updateBody = try JSONSerialization.jsonObject(
            with: recoveryLoader.requests[1].httpBody!
        ) as! [String: String]
        expect(recoveryLoader.requests[1].httpMethod == "PUT"
               && recoveryLoader.requests[1].url?.path == "/auth/v1/user"
               && recoveryLoader.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer access"
               && updateBody == ["password": "new-private-password"],
               "password update uses only the verified recovery session")

        let revokeLoader = AuthLoader([
            .init(status: 204, body: Data()),
            .init(status: 401, body: Data("{}".utf8))
        ])
        let revokeClient = NativeSupabaseEmailAuthClient(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key", loader: revokeLoader
        )
        try await revokeClient.revoke(sessionBytes: session.bytes)
        try await revokeClient.revoke(sessionBytes: session.bytes)
        let revokeRequest = revokeLoader.requests[0]
        expect(revokeRequest.url?.absoluteString ==
               "https://project.supabase.co/auth/v1/logout?scope=local",
               "sign-out revokes only the current device session")
        expect(revokeRequest.httpMethod == "POST"
               && revokeRequest.value(forHTTPHeaderField: "Authorization") == "Bearer access"
               && revokeRequest.httpBody == nil,
               "sign-out authenticates with the access token and sends no credential body")

        let rateLoader = AuthLoader([.init(status: 429, body: Data("{}".utf8))])
        do {
            try await NativeSupabaseEmailAuthClient(
                supabaseURL: URL(string: "https://project.supabase.co")!,
                publishableKey: "publishable-key", loader: rateLoader
            ).requestPasswordReset(
                email: "new@example.com", redirectTo: nil, codeChallenge: "challenge"
            )
            expect(false, "rate limiting fails")
        } catch NativeSupabaseAuthError.rateLimited {}

        if failures > 0 {
            print("FAILED: Supabase auth tests (\(failures) failure(s))")
            Foundation.exit(1)
        }
        print("PASS: Supabase authentication tests")
    }
}
