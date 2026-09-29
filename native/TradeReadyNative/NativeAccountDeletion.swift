import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum NativeAccountDeletionError: LocalizedError, Equatable {
    case invalidConfiguration
    case missingSession
    case sessionExpired
    case rateLimited
    case rejected
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Account deletion is not configured for this build."
        case .missingSession, .sessionExpired:
            "Your session has expired. Sign in again before deleting your account."
        case .rateLimited:
            "Too many deletion attempts were made. Wait a few minutes and try again."
        case .rejected:
            "Your account could not be deleted. Try again or contact support."
        case .unexpectedResponse:
            "The account service returned an unexpected response."
        }
    }
}

enum NativeAccountDeletionConfirmation {
    static let phrase = "DELETE"

    static func matches(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == phrase
    }
}

/// Authenticated client for the existing trusted backend deletion boundary.
/// The Supabase access token is sent only as a bearer header; no service key,
/// account identifier, or business data is accepted from the device.
struct NativeAccountDeletionClient {
    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct Success: Decodable { let success: Bool }

    let endpoint: URL
    let loader: any NativeHTTPDataLoading

    init(endpoint: URL, loader: any NativeHTTPDataLoading = URLSession.shared) {
        self.endpoint = endpoint
        self.loader = loader
    }

    func deleteAccount(sessionBytes: Data) async throws {
        let session: StoredSession
        do { session = try JSONDecoder().decode(StoredSession.self, from: sessionBytes) }
        catch { throw NativeAccountDeletionError.missingSession }
        guard !session.accessToken.isEmpty else { throw NativeAccountDeletionError.missingSession }
        let isLocalDevelopment = endpoint.scheme == "http"
            && ["localhost", "127.0.0.1", "::1"].contains(endpoint.host ?? "")
        guard (endpoint.scheme == "https" || isLocalDevelopment), endpoint.host != nil else {
            throw NativeAccountDeletionError.invalidConfiguration
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeAccountDeletionError.unexpectedResponse
        }
        switch http.statusCode {
        case 200..<300:
            guard let result = try? JSONDecoder().decode(Success.self, from: data), result.success else {
                throw NativeAccountDeletionError.unexpectedResponse
            }
        case 401, 403:
            throw NativeAccountDeletionError.sessionExpired
        case 429:
            throw NativeAccountDeletionError.rateLimited
        default:
            throw NativeAccountDeletionError.rejected
        }
    }
}
