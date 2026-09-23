import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

enum NativeAppleSignInNonceError: LocalizedError {
    case unavailable
    case invalidBytes

    var errorDescription: String? {
        "Sign in with Apple could not create a secure request. Please try again."
    }
}

/// One nonce exists only for one Apple sheet and its matching Supabase token
/// exchange. Neither the raw value nor its digest is logged or persisted.
enum NativeAppleSignInNonce {
    static let byteCount = 32

    static func generate() throws -> String {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NativeAppleSignInNonceError.unavailable
        }
        return try rawValue(from: Data(bytes))
        #else
        throw NativeAppleSignInNonceError.unavailable
        #endif
    }

    static func rawValue(from bytes: Data) throws -> String {
        guard bytes.count == byteCount else { throw NativeAppleSignInNonceError.invalidBytes }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hashedValue(for rawValue: String) -> String {
        SHA256.hash(data: Data(rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
