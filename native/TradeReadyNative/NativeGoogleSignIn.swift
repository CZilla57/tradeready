import Foundation
#if canImport(GoogleSignIn) && canImport(UIKit)
import GoogleSignIn
import UIKit
#endif

struct NativeGoogleSignInCredential: Equatable, Sendable {
    let idToken: String
    let rawNonce: String
}

enum NativeGoogleSignInError: LocalizedError, Equatable {
    case cancelled
    case unavailable
    case missingIDToken
    case failed

    var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case .unavailable: "Sign in with Google is unavailable in this build."
        case .missingIDToken: "Google did not return an identity token. Please try again."
        case .failed: "Sign in with Google failed. Please try again."
        }
    }

    /// Google's documented cancellation error is stable across SDK 9.x. Keep
    /// the classifier testable without importing the SDK into command-line tests.
    static func isCancellation(_ error: NSError) -> Bool {
        error.domain == "com.google.GIDSignIn" && error.code == -5
    }
}

/// Owns the one interactive Google sheet and returns only the ID token needed
/// by Supabase. Profile fields and Google access tokens never become identity
/// evidence or enter TradeReady persistence.
@MainActor
enum NativeGoogleSignInProvider {
    static func signIn() async throws -> NativeGoogleSignInCredential {
        #if canImport(GoogleSignIn) && canImport(UIKit)
        guard let presenter = activePresenter() else {
            throw NativeGoogleSignInError.unavailable
        }
        let rawNonce: String
        do { rawNonce = try NativeAppleSignInNonce.generate() }
        catch { throw NativeGoogleSignInError.failed }
        let hashedNonce = NativeAppleSignInNonce.hashedValue(for: rawNonce)

        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: nil,
                nonce: hashedNonce
            ) { result, error in
                if let error = error as NSError? {
                    let mappedError: NativeGoogleSignInError =
                        NativeGoogleSignInError.isCancellation(error) ? .cancelled : .failed
                    continuation.resume(throwing: mappedError)
                    return
                }
                guard let idToken = result?.user.idToken?.tokenString,
                      !idToken.isEmpty else {
                    continuation.resume(throwing: NativeGoogleSignInError.missingIDToken)
                    return
                }
                continuation.resume(returning: .init(idToken: idToken, rawNonce: rawNonce))
            }
        }
        #else
        throw NativeGoogleSignInError.unavailable
        #endif
    }

    static func handle(_ url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.handle(url)
        #else
        false
        #endif
    }

    static func clearLocalCredential() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
    }

    #if canImport(GoogleSignIn) && canImport(UIKit)
    private static func activePresenter() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }?
            .rootViewController
        return topViewController(from: root)
    }

    private static func topViewController(from root: UIViewController?) -> UIViewController? {
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tabs = root as? UITabBarController {
            return topViewController(from: tabs.selectedViewController)
        }
        return root
    }
    #endif
}
