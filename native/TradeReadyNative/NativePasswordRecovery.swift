import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

enum NativePasswordRecoveryError: LocalizedError, Equatable {
    case unavailable
    case invalidLink
    case expiredLink
    case passwordTooShort
    case corruptState

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Password recovery is unavailable. Request a new reset link and try again."
        case .invalidLink:
            "This password reset link is invalid. Request a new link and try again."
        case .expiredLink:
            "This password reset link is invalid or expired. Request a new link and try again."
        case .passwordTooShort:
            "Password must be at least 8 characters."
        case .corruptState:
            "Saved password recovery state could not be read."
        }
    }
}

enum NativePasswordRecoveryLink: Equatable {
    case code(String)
    case providerError
    case invalid

    static func parse(_ url: URL) -> NativePasswordRecoveryLink? {
        guard url.scheme?.lowercased() == "tradeready",
              url.host?.lowercased() == "reset-password"
        else { return nil }
        guard url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty
        else { return .invalid }

        let allowed = Set(["code", "error", "error_code", "error_description"])
        guard items.allSatisfy({ allowed.contains($0.name) }),
              Set(items.map(\.name)).count == items.count
        else { return .invalid }

        if items.count == 1, items[0].name == "code",
           let code = items[0].value?.trimmingCharacters(in: .whitespacesAndNewlines),
           !code.isEmpty
        {
            return .code(code)
        }
        if let error = items.first(where: { $0.name == "error" })?.value,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           items.allSatisfy({ $0.name != "code" })
        {
            return .providerError
        }
        return .invalid
    }
}

struct NativePasswordRecoveryPKCE: Equatable {
    static let byteCount = 32

    let verifier: String
    let challenge: String

    static func generate() throws -> NativePasswordRecoveryPKCE {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NativePasswordRecoveryError.unavailable
        }
        return try value(from: Data(bytes))
        #else
        throw NativePasswordRecoveryError.unavailable
        #endif
    }

    static func value(from bytes: Data) throws -> NativePasswordRecoveryPKCE {
        guard bytes.count == byteCount else { throw NativePasswordRecoveryError.unavailable }
        let verifier = base64URL(bytes)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return .init(verifier: verifier, challenge: challenge)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct NativePasswordRecoveryState: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let codeVerifier: String?
    let activeUserSubject: String?

    init(codeVerifier: String? = nil, activeUserSubject: String? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.codeVerifier = codeVerifier
        self.activeUserSubject = activeUserSubject
    }
}

struct NativePasswordRecoveryStore {
    static let key = NativeKeychainSecureSettingsStore.passwordRecoveryStateAccount

    let backend: any NativeSecureKeyValueBacking

    init(backend: any NativeSecureKeyValueBacking = NativeKeychainBackend()) {
        self.backend = backend
    }

    func savePending(verifier: String) throws {
        guard verifier.count >= 43 else { throw NativePasswordRecoveryError.unavailable }
        try write(.init(codeVerifier: verifier))
    }

    func read() throws -> NativePasswordRecoveryState? {
        guard let bytes = try backend.read(key: Self.key) else { return nil }
        guard let state = try? JSONDecoder().decode(NativePasswordRecoveryState.self, from: bytes),
              state.schemaVersion == NativePasswordRecoveryState.currentSchemaVersion,
              state.codeVerifier != nil || state.activeUserSubject != nil
        else { throw NativePasswordRecoveryError.corruptState }
        return state
    }

    func markActive(userSubject: String) throws {
        guard !userSubject.isEmpty else { throw NativePasswordRecoveryError.unavailable }
        try write(.init(activeUserSubject: userSubject))
    }

    func clearPending(expectedVerifier: String) throws {
        guard let state = try read(), state.codeVerifier == expectedVerifier else { return }
        try clear()
    }

    func clear() throws {
        try backend.remove(key: Self.key)
        guard try backend.read(key: Self.key) == nil else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: Self.key)
        }
    }

    private func write(_ state: NativePasswordRecoveryState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(state)
        try backend.upsert(bytes, key: Self.key)
        guard try backend.read(key: Self.key) == bytes else {
            throw NativeSecureSettingsStoreError.verificationFailed(key: Self.key)
        }
    }
}
