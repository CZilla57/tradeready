import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Phase 24 §6.3: the owner's autopay transport against the Worker's owner
/// routes (spec §4.8, JWT):
/// - `GET /api/autopay/status` → `{enrollments, charges}`, decoded by
///   `NativeAutopay.parseStatus`;
/// - `POST /api/autopay/manage {action: "remove", enrollmentId}`, which
///   revokes the enrollment as the owner, detaches the card on Stripe and
///   emails the customer. The route is idempotent.
///
/// Validation mirrors `NativeInvoiceDeliveryService`: endpoints are
/// host-bearing https (or loopback http) URLs with no credentials, query or
/// fragment, and 401/403 map to `.rejectedSession` so `AppStore` can run its
/// one verified session-refresh retry. Foundation only.
enum NativeAutopayServiceError: Error, Equatable {
    case invalidConfiguration, malformedSession, invalidEnrollmentID, rejectedSession, notFound, invalidResponse, unavailable
}

protocol NativeAutopayHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: NativeAutopayHTTPDataLoading {}

protocol NativeAutopayServing: Sendable {
    func status(sessionBytes: Data) async throws -> NativeAutopayStatusSnapshot
    func removeCard(enrollmentID: String, sessionBytes: Data) async throws
}

struct NativeAutopayService: NativeAutopayServing {
    private struct Session: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }
    private struct ManageBody: Encodable {
        let action: String
        let enrollmentId: String
    }

    let statusEndpoint: URL
    let manageEndpoint: URL
    let loader: any NativeAutopayHTTPDataLoading

    init(statusEndpoint: URL, manageEndpoint: URL, loader: any NativeAutopayHTTPDataLoading = URLSession.shared) {
        self.statusEndpoint = statusEndpoint
        self.manageEndpoint = manageEndpoint
        self.loader = loader
    }

    func status(sessionBytes: Data) async throws -> NativeAutopayStatusSnapshot {
        guard Self.validEndpoint(statusEndpoint) else { throw NativeAutopayServiceError.invalidConfiguration }
        let token = try accessToken(sessionBytes)
        var request = URLRequest(url: statusEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await load(request)
        try success(response)
        guard let snapshot = NativeAutopay.parseStatus(data) else { throw NativeAutopayServiceError.invalidResponse }
        return snapshot
    }

    func removeCard(enrollmentID: String, sessionBytes: Data) async throws {
        guard Self.validEndpoint(manageEndpoint) else { throw NativeAutopayServiceError.invalidConfiguration }
        guard Self.validID(enrollmentID) else { throw NativeAutopayServiceError.invalidEnrollmentID }
        let token = try accessToken(sessionBytes)
        var request = URLRequest(url: manageEndpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(ManageBody(action: "remove", enrollmentId: enrollmentID))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await load(request)
        try success(response)
    }

    private func accessToken(_ bytes: Data) throws -> String {
        guard let session = try? JSONDecoder().decode(Session.self, from: bytes), !session.accessToken.isEmpty else {
            throw NativeAutopayServiceError.malformedSession
        }
        return session.accessToken
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await loader.data(for: request) }
        catch { throw NativeAutopayServiceError.unavailable }
    }

    private func success(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw NativeAutopayServiceError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw NativeAutopayServiceError.rejectedSession }
        if http.statusCode == 404 { throw NativeAutopayServiceError.notFound }
        guard (200..<300).contains(http.statusCode) else { throw NativeAutopayServiceError.unavailable }
    }

    /// Enrollment ids are server uuids; anything else never leaves the device.
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func validEndpoint(_ url: URL) -> Bool {
        url.host != nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && (url.scheme == "https"
                || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")))
    }
}
