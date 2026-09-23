import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport + frozen-snapshot errors for the change-order approval link.
///
/// Dedicated to change orders: the job-only transport in
/// `NativeEstimateApprovalLink.swift` is hard-coded to the estimate endpoint
/// body (`{jobId, snapshot}`) and validates a `j+t` public URL, so it cannot
/// mint a change-order link (`{jobId, changeOrderId, snapshot}` on
/// `change.html` with a `j+co+t` URL). The classification mirrors the estimate
/// transport so callers fail closed the same way:
/// - `.changeOrderStale`: the job/order moved or the frozen snapshot no longer
///   matches the canonical order (stale review sheet).
/// - `.rejectedSession`: exact owner recheck failed (owner switch) or the
///   backend rejected the bearer (401/403).
/// - `.invalidResponse`: malformed success payload or a public URL that does
///   not carry the exact `j+co+t` triple (cross-job/order link).
/// - `.alreadyDecided`: 409 terminal — the order was decided (on-site manual
///   decision or a raced customer decision). Retrying the same draft cannot
///   succeed; record a new change order instead.
enum NativeChangeOrderApprovalLinkError: LocalizedError, Equatable {
    case invalidConfiguration
    case malformedSession
    case rejectedSession
    case rateLimited
    case jobNotSynced
    case changeOrderStale
    case alreadyDecided
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Approval links are not configured for this build."
        case .malformedSession, .rejectedSession:
            "Your session has expired. Sign in again before creating an approval link."
        case .rateLimited:
            "Too many approval links were requested. Wait a moment and try again."
        case .jobNotSynced:
            "This change has not reached the server yet. Open the app while online and try again."
        case .changeOrderStale:
            "This change changed while the review was open. Review the latest change before creating its approval link."
        case .alreadyDecided:
            "This change was already decided. Issue a new change order instead of re-sending this one."
        case .invalidResponse:
            "The approval service returned an unexpected response."
        case .unavailable:
            "The approval service is unavailable. Check your connection and try again."
        }
    }
}

struct NativeChangeOrderApprovalLink: Equatable, Sendable {
    let url: URL
    let token: String
    let sentAt: String
}

/// Frozen customer-facing snapshot for ONE change order, taken when the review
/// opens. Reuses `Canonical.EstimateApprovalSnapshot` verbatim (same shape the
/// backend `change-view`/`change-respond` endpoints handle): context totals
/// (original/new billable) are deliberately NOT frozen — `change-view`
/// computes them live so multi-CO jobs show truthful numbers.
struct NativeChangeOrderApprovalDraft {
    let jobID: String
    let changeOrderID: String
    let snapshot: Canonical.EstimateApprovalSnapshot
}

enum NativeChangeOrderApprovalSnapshot {
    private struct LineItem: Encodable {
        let label: String
        let amount: Decimal
    }

    private struct Document: Encodable {
        let businessName: String
        let customerName: String
        let jobTitle: String
        let lineItems: [LineItem]
        let total: Decimal
        let currency: String
    }

    /// Mirrors `buildChangeOrderSnapshot` in `utils/changeOrders.ts`.
    /// (`CanonicalUIAdapters.decode` lives in a private extension, so the
    /// frozen document round-trips through JSON here instead.)
    static func build(
        order: Canonical.ChangeOrder,
        job: Canonical.Job,
        customerName: String?,
        businessName: String
    ) throws -> Canonical.EstimateApprovalSnapshot {
        let resolvedCustomer = (customerName?.isEmpty == false ? customerName : nil) ?? job.customerName
        let document = Document(
            businessName: businessName.isEmpty ? "Your tradesperson" : businessName,
            customerName: resolvedCustomer,
            jobTitle: job.title,
            lineItems: [LineItem(label: order.title, amount: order.amount)],
            total: order.amount,
            currency: "USD"
        )
        return try JSONDecoder().decode(
            Canonical.EstimateApprovalSnapshot.self,
            from: JSONEncoder().encode(document)
        )
    }
}

/// Durable-mirror rule for the server-minted link. Writes ONLY the
/// server-issued token, sent time, and frozen snapshot into the exact pending
/// CO; server decision/signature fields (`decision`, `consentAt`,
/// `signerName`, `declineReason`, `ip`, `userAgent`) plus unknown
/// forward-compatible fields on the approval and the order are preserved via
/// `estimateApprovalAfterLink`'s merge. Fails closed: a missing, cancelled, or
/// already-decided order throws instead of overwriting newer state.
enum NativeChangeOrderApprovalMirror {
    static func apply(
        to job: Canonical.Job,
        changeOrderID: String,
        token: String,
        sentAt: String,
        snapshot: Canonical.EstimateApprovalSnapshot
    ) throws -> Canonical.Job {
        guard let index = job.changeOrders?.firstIndex(where: { $0.id == changeOrderID }) else {
            throw NativeChangeOrderApprovalLinkError.changeOrderStale
        }
        let order = job.changeOrders![index]
        if !(order.cancelledAt ?? "").isEmpty {
            throw NativeChangeOrderApprovalLinkError.changeOrderStale
        }
        if order.manualDecision != nil || order.approval?.decision != nil {
            throw NativeChangeOrderApprovalLinkError.alreadyDecided
        }
        var result = job
        result.changeOrders![index].approval = try CanonicalUIAdapters.estimateApprovalAfterLink(
            existing: order.approval,
            snapshot: snapshot,
            token: token,
            sentAt: sentAt
        )
        return result
    }
}

protocol NativeChangeOrderApprovalHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativeChangeOrderApprovalHTTPDataLoading {}

protocol NativeChangeOrderApprovalLinking: Sendable {
    func createLink(
        jobID: String,
        changeOrderID: String,
        snapshot: Canonical.EstimateApprovalSnapshot,
        sessionBytes: Data
    ) async throws -> NativeChangeOrderApprovalLink
}

/// Authenticated client for the change-order approval endpoint
/// (`POST /api/estimate/create-link` with `{jobId, changeOrderId, snapshot}`).
/// The device sends no owner identifier and never mints a capability token;
/// the backend verifies the current Supabase bearer and derives row ownership.
///
/// Device-gate note: the minted URL points at public `change.html`
/// (env-overridable `CHANGE_PUBLIC_BASE` beside `estimate.html`), so the link
/// is only customer-usable once the Worker route + static page are deployed.
struct NativeChangeOrderApprovalLinkService: NativeChangeOrderApprovalLinking {
    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct Body: Encodable {
        let jobId: String
        let changeOrderId: String
        let snapshot: Canonical.EstimateApprovalSnapshot
    }

    private struct ResponseBody: Decodable {
        let url: String
        let token: String
        let sentAt: String
    }

    let endpoint: URL
    let loader: any NativeChangeOrderApprovalHTTPDataLoading

    init(endpoint: URL, loader: any NativeChangeOrderApprovalHTTPDataLoading = URLSession.shared) {
        self.endpoint = endpoint
        self.loader = loader
    }

    func createLink(
        jobID: String,
        changeOrderID: String,
        snapshot: Canonical.EstimateApprovalSnapshot,
        sessionBytes: Data
    ) async throws -> NativeChangeOrderApprovalLink {
        guard Self.isAllowedEndpoint(endpoint) else {
            throw NativeChangeOrderApprovalLinkError.invalidConfiguration
        }
        guard Self.isValidID(jobID) else {
            throw NativeChangeOrderApprovalLinkError.changeOrderStale
        }
        guard Self.isValidID(changeOrderID) else {
            throw NativeChangeOrderApprovalLinkError.changeOrderStale
        }
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: sessionBytes),
              !session.accessToken.isEmpty
        else { throw NativeChangeOrderApprovalLinkError.malformedSession }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Body(
            jobId: jobID,
            changeOrderId: changeOrderID,
            snapshot: snapshot
        ))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch { throw NativeChangeOrderApprovalLinkError.unavailable }
        guard let http = response as? HTTPURLResponse else {
            throw NativeChangeOrderApprovalLinkError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw NativeChangeOrderApprovalLinkError.rejectedSession
        case 409: throw NativeChangeOrderApprovalLinkError.alreadyDecided
        case 422: throw NativeChangeOrderApprovalLinkError.jobNotSynced
        case 429: throw NativeChangeOrderApprovalLinkError.rateLimited
        default: throw NativeChangeOrderApprovalLinkError.unavailable
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let publicURL = URL(string: decoded.url),
              Self.isValidToken(decoded.token),
              Self.isValidPublicURL(
                  publicURL,
                  jobID: jobID,
                  changeOrderID: changeOrderID,
                  token: decoded.token
              ),
              decoded.sentAt.count <= 100,
              Self.isValidSentAt(decoded.sentAt)
        else { throw NativeChangeOrderApprovalLinkError.invalidResponse }
        return NativeChangeOrderApprovalLink(
            url: publicURL,
            token: decoded.token,
            sentAt: decoded.sentAt
        )
    }

    private static func isValidID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 200 && trimmed == value
    }

    private static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil
        else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http"
            && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }

    /// The public change-order page carries all three of `j`, `co`, and `t`
    /// (see `createLink.js` `CHANGE_PUBLIC_BASE`). A link missing any of them
    /// — or pointing at another job/order — fails closed.
    private static func isValidPublicURL(
        _ url: URL,
        jobID: String,
        changeOrderID: String,
        token: String
    ) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let values = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        return values["j"] == jobID && values["co"] == changeOrderID && values["t"] == token
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
