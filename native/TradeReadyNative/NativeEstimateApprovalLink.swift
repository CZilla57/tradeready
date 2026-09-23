import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum NativeEstimateApprovalLinkError: LocalizedError, Equatable {
    case invalidConfiguration
    case malformedSession
    case invalidJobID
    case rejectedSession
    case rateLimited
    case jobNotSynced
    case estimateChanged
    case revisionConflict
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Approval links are not configured for this build."
        case .malformedSession, .rejectedSession:
            "Your session has expired. Sign in again before creating an approval link."
        case .invalidJobID, .invalidResponse:
            "The approval service returned an unexpected response."
        case .rateLimited:
            "Too many approval links were requested. Wait a moment and try again."
        case .jobNotSynced:
            "This estimate has not reached the server yet. Open the app while online and try again."
        case .estimateChanged:
            "This estimate changed while the review was open. Review the latest estimate before creating its approval link."
        case .revisionConflict:
            "This estimate changed before the revision could begin. Refresh it and review the customer's latest decision."
        case .unavailable:
            "The approval service is unavailable. Check your connection and try again."
        }
    }
}

struct NativeEstimateApprovalLink: Equatable, Sendable {
    let url: URL
    let token: String
    let sentAt: String
}

protocol NativeEstimateApprovalHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativeEstimateApprovalHTTPDataLoading {}

protocol NativeEstimateApprovalLinking: Sendable {
    func createLink(
        jobID: String,
        snapshot: Canonical.EstimateApprovalSnapshot,
        sessionBytes: Data
    ) async throws -> NativeEstimateApprovalLink

    func beginDeclinedRevision(
        jobID: String,
        approvalToken: String,
        sessionBytes: Data
    ) async throws -> Canonical.Job
}

/// Authenticated client for the existing estimate approval endpoint. The
/// device sends no owner identifier and never mints a capability token; the
/// backend verifies the current Supabase bearer and derives row ownership.
struct NativeEstimateApprovalLinkService: NativeEstimateApprovalLinking {
    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct Body: Encodable {
        let jobId: String
        let snapshot: Canonical.EstimateApprovalSnapshot
    }

    private struct ResponseBody: Decodable {
        let url: String
        let token: String
        let sentAt: String
    }

    private struct RevisionBody: Encodable {
        let jobId: String
        let approvalToken: String
    }

    private struct RevisionResponseBody: Decodable {
        let job: Canonical.Job
    }

    let endpoint: URL
    let loader: any NativeEstimateApprovalHTTPDataLoading

    init(endpoint: URL, loader: any NativeEstimateApprovalHTTPDataLoading = URLSession.shared) {
        self.endpoint = endpoint
        self.loader = loader
    }

    func createLink(
        jobID: String,
        snapshot: Canonical.EstimateApprovalSnapshot,
        sessionBytes: Data
    ) async throws -> NativeEstimateApprovalLink {
        guard Self.isAllowedEndpoint(endpoint) else {
            throw NativeEstimateApprovalLinkError.invalidConfiguration
        }
        let trimmedID = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.count <= 200, trimmedID == jobID else {
            throw NativeEstimateApprovalLinkError.invalidJobID
        }
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: sessionBytes),
              !session.accessToken.isEmpty
        else { throw NativeEstimateApprovalLinkError.malformedSession }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Body(jobId: jobID, snapshot: snapshot))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch { throw NativeEstimateApprovalLinkError.unavailable }
        guard let http = response as? HTTPURLResponse else {
            throw NativeEstimateApprovalLinkError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw NativeEstimateApprovalLinkError.rejectedSession
        case 422: throw NativeEstimateApprovalLinkError.jobNotSynced
        case 429: throw NativeEstimateApprovalLinkError.rateLimited
        default: throw NativeEstimateApprovalLinkError.unavailable
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let publicURL = URL(string: decoded.url),
              Self.isValidToken(decoded.token),
              Self.isValidPublicURL(publicURL, jobID: jobID, token: decoded.token),
              decoded.sentAt.count <= 100,
              Self.isValidSentAt(decoded.sentAt)
        else { throw NativeEstimateApprovalLinkError.invalidResponse }
        return NativeEstimateApprovalLink(
            url: publicURL,
            token: decoded.token,
            sentAt: decoded.sentAt
        )
    }

    func beginDeclinedRevision(
        jobID: String,
        approvalToken: String,
        sessionBytes: Data
    ) async throws -> Canonical.Job {
        guard Self.isAllowedEndpoint(endpoint) else {
            throw NativeEstimateApprovalLinkError.invalidConfiguration
        }
        let trimmedID = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.count <= 200, trimmedID == jobID else {
            throw NativeEstimateApprovalLinkError.invalidJobID
        }
        guard Self.isValidToken(approvalToken),
              let session = try? JSONDecoder().decode(StoredSession.self, from: sessionBytes),
              !session.accessToken.isEmpty
        else { throw NativeEstimateApprovalLinkError.malformedSession }

        let revisionEndpoint = endpoint
            .deletingLastPathComponent()
            .appendingPathComponent("revise-declined")
        guard Self.isAllowedEndpoint(revisionEndpoint) else {
            throw NativeEstimateApprovalLinkError.invalidConfiguration
        }
        var request = URLRequest(url: revisionEndpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(RevisionBody(
            jobId: jobID,
            approvalToken: approvalToken
        ))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch { throw NativeEstimateApprovalLinkError.unavailable }
        guard let http = response as? HTTPURLResponse else {
            throw NativeEstimateApprovalLinkError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw NativeEstimateApprovalLinkError.rejectedSession
        case 409: throw NativeEstimateApprovalLinkError.revisionConflict
        case 422: throw NativeEstimateApprovalLinkError.jobNotSynced
        case 429: throw NativeEstimateApprovalLinkError.rateLimited
        default: throw NativeEstimateApprovalLinkError.unavailable
        }

        guard let decoded = try? JSONDecoder().decode(RevisionResponseBody.self, from: data),
              decoded.job.id == jobID,
              decoded.job.status == JobStatus.lead.rawValue,
              decoded.job.approval == nil,
              decoded.job.estimateSentAt == nil,
              decoded.job.approvalHistory?.contains(where: { $0.token == approvalToken }) == true
        else { throw NativeEstimateApprovalLinkError.invalidResponse }
        return decoded.job
    }

    private static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil
        else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http"
            && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }

    private static func isValidPublicURL(_ url: URL, jobID: String, token: String) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let values = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        return values["j"] == jobID && values["t"] == token
    }

    private static func isValidToken(_ value: String) -> Bool {
        guard (16...256).contains(value.count) else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    private static func isValidSentAt(_ value: String) -> Bool {
        let standard = ISO8601DateFormatter()
        if standard.date(from: value) != nil { return true }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) != nil
    }
}
