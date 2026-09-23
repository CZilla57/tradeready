import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum NativeSupabaseAuthError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidEmail
    case passwordTooShort
    case invalidCredentials
    case rateLimited
    case rejected(message: String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Sign-in is not configured for this build."
        case .invalidEmail:
            "Enter a valid email address."
        case .passwordTooShort:
            "Password must be at least 6 characters."
        case .invalidCredentials:
            "Email or password is incorrect."
        case .rateLimited:
            "Too many emails were sent. Check your inbox or wait a few minutes and try again."
        case .rejected(let message):
            message.isEmpty ? "Authentication failed. Please try again." : message
        case .unexpectedResponse:
            "The authentication service returned an unexpected response."
        }
    }
}

struct NativeSupabaseSignedInSession: Equatable, Sendable {
    let bytes: Data
    let userSubject: String
    let email: String?
}

enum NativeSupabaseSignUpResult: Equatable, Sendable {
    case confirmationRequired(email: String)
    case signedIn(NativeSupabaseSignedInSession)
}

protocol NativeSupabaseEmailAuthServing {
    func signIn(email: String, password: String) async throws -> NativeSupabaseSignedInSession
    func signUp(email: String, password: String, redirectTo: URL?) async throws -> NativeSupabaseSignUpResult
    func requestPasswordReset(
        email: String,
        redirectTo: URL?,
        codeChallenge: String
    ) async throws
    func exchangePasswordRecoveryCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> NativeSupabaseSignedInSession
    func updatePassword(
        _ password: String,
        sessionBytes: Data,
        expectedUserSubject: String
    ) async throws
    func resendSignUpConfirmation(email: String, redirectTo: URL?) async throws
}

protocol NativeSupabaseSessionRevoking {
    func revoke(sessionBytes: Data) async throws
}

enum NativeSupabaseIDTokenProvider: String, Encodable {
    case apple
    case google
}

/// Small REST client for the stable GoTrue endpoints already used by
/// supabase-js. Passwords exist only in request memory and are never persisted,
/// logged, placed in URLs, or copied into diagnostics.
struct NativeSupabaseEmailAuthClient: NativeSupabaseEmailAuthServing, NativeSupabaseSessionRevoking {
    private struct Credentials: Encodable { let email: String; let password: String }
    private struct RecoveryRequest: Encodable {
        let email: String
        let codeChallenge: String
        let codeChallengeMethod = "s256"

        enum CodingKeys: String, CodingKey {
            case email
            case codeChallenge = "code_challenge"
            case codeChallengeMethod = "code_challenge_method"
        }
    }
    private struct PKCEExchange: Encodable {
        let authCode: String
        let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case authCode = "auth_code"
            case codeVerifier = "code_verifier"
        }
    }
    private struct PasswordUpdate: Encodable { let password: String }
    private struct Resend: Encodable { let email: String; let type = "signup" }
    private struct IDTokenCredentials: Encodable {
        let provider: NativeSupabaseIDTokenProvider
        let idToken: String
        let nonce: String?

        enum CodingKeys: String, CodingKey {
            case provider, nonce
            case idToken = "id_token"
        }
    }

    private struct AuthUser: Decodable {
        let id: String
        let email: String?
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let expiresAt: Double?
        let user: AuthUser

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
            case user
        }
    }

    private struct SignUpResponse: Decodable {
        let id: String?
        let email: String?
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Double?
        let expiresAt: Double?
        let user: AuthUser?

        enum CodingKeys: String, CodingKey {
            case id, email, user
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
        }
    }

    private struct ErrorResponse: Decodable {
        let code: String?
        let errorCode: String?
        let message: String?
        let msg: String?

        enum CodingKeys: String, CodingKey {
            case code, message, msg
            case errorCode = "error_code"
        }
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

    func signIn(email: String, password: String) async throws -> NativeSupabaseSignedInSession {
        let email = try validated(email: email)
        guard !password.isEmpty else { throw NativeSupabaseAuthError.invalidCredentials }
        let data = try await send(
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "password")],
            body: Credentials(email: email, password: password)
        )
        let response: TokenResponse
        do { response = try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw NativeSupabaseAuthError.unexpectedResponse }
        return try normalizedSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            expiresAt: response.expiresAt,
            user: response.user,
            originalBytes: data
        )
    }

    func signUp(
        email: String,
        password: String,
        redirectTo: URL?
    ) async throws -> NativeSupabaseSignUpResult {
        let email = try validated(email: email)
        guard password.count >= 6 else { throw NativeSupabaseAuthError.passwordTooShort }
        let data = try await send(
            path: "auth/v1/signup",
            query: redirectQuery(redirectTo),
            body: Credentials(email: email, password: password)
        )
        let response: SignUpResponse
        do { response = try JSONDecoder().decode(SignUpResponse.self, from: data) }
        catch { throw NativeSupabaseAuthError.unexpectedResponse }

        if let accessToken = response.accessToken,
           let refreshToken = response.refreshToken,
           let expiresIn = response.expiresIn,
           let user = response.user
        {
            return .signedIn(try normalizedSession(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresIn: expiresIn,
                expiresAt: response.expiresAt,
                user: user,
                originalBytes: data
            ))
        }
        guard let id = response.id, !id.isEmpty else {
            throw NativeSupabaseAuthError.unexpectedResponse
        }
        return .confirmationRequired(email: response.email ?? email)
    }

    func requestPasswordReset(
        email: String,
        redirectTo: URL?,
        codeChallenge: String
    ) async throws {
        let email = try validated(email: email)
        guard !codeChallenge.isEmpty else { throw NativePasswordRecoveryError.unavailable }
        _ = try await send(
            path: "auth/v1/recover",
            query: redirectQuery(redirectTo),
            body: RecoveryRequest(email: email, codeChallenge: codeChallenge)
        )
    }

    func exchangePasswordRecoveryCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> NativeSupabaseSignedInSession {
        guard !code.isEmpty, !codeVerifier.isEmpty else {
            throw NativePasswordRecoveryError.invalidLink
        }
        let data = try await send(
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "pkce")],
            body: PKCEExchange(authCode: code, codeVerifier: codeVerifier)
        )
        let response: TokenResponse
        do { response = try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw NativeSupabaseAuthError.unexpectedResponse }
        return try normalizedSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            expiresAt: response.expiresAt,
            user: response.user,
            originalBytes: data
        )
    }

    func updatePassword(
        _ password: String,
        sessionBytes: Data,
        expectedUserSubject: String
    ) async throws {
        struct StoredSession: Decodable {
            let accessToken: String
            enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
        }
        guard password.count >= 8 else { throw NativePasswordRecoveryError.passwordTooShort }
        let session: StoredSession
        do { session = try JSONDecoder().decode(StoredSession.self, from: sessionBytes) }
        catch { throw NativeSupabaseAuthError.unexpectedResponse }
        guard !session.accessToken.isEmpty, !expectedUserSubject.isEmpty,
              supabaseURL.scheme == "https", supabaseURL.host != nil, !publishableKey.isEmpty
        else { throw NativeSupabaseAuthError.invalidConfiguration }

        var request = URLRequest(url: supabaseURL.appending(path: "auth/v1/user"))
        request.httpMethod = "PUT"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(PasswordUpdate(password: password))
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeSupabaseAuthError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mappedError(statusCode: http.statusCode, data: data)
        }
        let user: AuthUser
        do { user = try JSONDecoder().decode(AuthUser.self, from: data) }
        catch { throw NativeSupabaseAuthError.unexpectedResponse }
        guard user.id == expectedUserSubject else {
            throw NativeSupabaseAuthError.unexpectedResponse
        }
    }

    func resendSignUpConfirmation(email: String, redirectTo: URL?) async throws {
        let email = try validated(email: email)
        _ = try await send(
            path: "auth/v1/resend",
            query: redirectQuery(redirectTo),
            body: Resend(email: email)
        )
    }

    func signInWithApple(idToken: String, rawNonce: String) async throws -> NativeSupabaseSignedInSession {
        guard !idToken.isEmpty, !rawNonce.isEmpty else {
            throw NativeSupabaseAuthError.unexpectedResponse
        }
        let data = try await send(
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: IDTokenCredentials(provider: .apple, idToken: idToken, nonce: rawNonce)
        )
        let response: TokenResponse
        do { response = try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw NativeSupabaseAuthError.unexpectedResponse }
        return try normalizedSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            expiresAt: response.expiresAt,
            user: response.user,
            originalBytes: data
        )
    }

    func signInWithGoogle(idToken: String, rawNonce: String) async throws -> NativeSupabaseSignedInSession {
        guard !idToken.isEmpty, !rawNonce.isEmpty else {
            throw NativeSupabaseAuthError.unexpectedResponse
        }
        let data = try await send(
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: IDTokenCredentials(provider: .google, idToken: idToken, nonce: rawNonce)
        )
        let response: TokenResponse
        do { response = try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw NativeSupabaseAuthError.unexpectedResponse }
        return try normalizedSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            expiresAt: response.expiresAt,
            user: response.user,
            originalBytes: data
        )
    }

    /// Revokes only this device's refresh-token family. A rejected token is
    /// already terminal, so 401/403 still permit the local sign-out boundary.
    func revoke(sessionBytes: Data) async throws {
        struct StoredSession: Decodable {
            let accessToken: String
            enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
        }
        let session: StoredSession
        do { session = try JSONDecoder().decode(StoredSession.self, from: sessionBytes) }
        catch { throw NativeSupabaseAuthError.unexpectedResponse }
        guard !session.accessToken.isEmpty else { throw NativeSupabaseAuthError.unexpectedResponse }
        guard supabaseURL.scheme == "https", supabaseURL.host != nil, !publishableKey.isEmpty else {
            throw NativeSupabaseAuthError.invalidConfiguration
        }
        var components = URLComponents(
            url: supabaseURL.appending(path: "auth/v1/logout"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "scope", value: "local")]
        guard let url = components?.url else { throw NativeSupabaseAuthError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeSupabaseAuthError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 401 || http.statusCode == 403 else {
            throw mappedError(statusCode: http.statusCode, data: data)
        }
    }

    private func send<Body: Encodable>(
        path: String,
        query: [URLQueryItem],
        body: Body
    ) async throws -> Data {
        guard supabaseURL.scheme == "https", supabaseURL.host != nil, !publishableKey.isEmpty else {
            throw NativeSupabaseAuthError.invalidConfiguration
        }
        var components = URLComponents(
            url: supabaseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw NativeSupabaseAuthError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeSupabaseAuthError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mappedError(statusCode: http.statusCode, data: data)
        }
        return data
    }

    private func normalizedSession(
        accessToken: String,
        refreshToken: String,
        expiresIn: Double,
        expiresAt: Double?,
        user: AuthUser,
        originalBytes: Data
    ) throws -> NativeSupabaseSignedInSession {
        guard !accessToken.isEmpty, !refreshToken.isEmpty, expiresIn > 0, !user.id.isEmpty,
              var object = try JSONSerialization.jsonObject(with: originalBytes) as? [String: Any]
        else { throw NativeSupabaseAuthError.unexpectedResponse }
        object["expires_at"] = expiresAt ?? floor(now().timeIntervalSince1970 + expiresIn)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return .init(bytes: bytes, userSubject: user.id, email: user.email)
    }

    private func validated(email: String) throws -> String {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = value.firstIndex(of: "@"), at != value.startIndex,
              value[value.index(after: at)...].contains(".")
        else { throw NativeSupabaseAuthError.invalidEmail }
        return value
    }

    private func redirectQuery(_ redirectTo: URL?) -> [URLQueryItem] {
        guard let redirectTo else { return [] }
        return [URLQueryItem(name: "redirect_to", value: redirectTo.absoluteString)]
    }

    private func mappedError(statusCode: Int, data: Data) -> NativeSupabaseAuthError {
        if statusCode == 429 { return .rateLimited }
        let response = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        let code = (response?.errorCode ?? response?.code ?? "").lowercased()
        let message = (response?.message ?? response?.msg ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if code.contains("invalid_credentials") || message.lowercased().contains("invalid login credentials") {
            return .invalidCredentials
        }
        return .rejected(message: message)
    }
}
