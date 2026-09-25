import Foundation

// Phase 12 (12.00b.1, known issue I2, contract §17.2): how the push transport
// treats one write's response. Before this, every non-2xx except 401/403 was
// transient, so a change the server will never accept stayed queued forever,
// and the coordinator skipped every pull while anything was queued: one such
// change wedged all sync for the account. A non-auth 4xx is now `rejected`:
// the change leaves the queue for the owner-scoped rejected-change store
// (`NativeRejectedChangeStore`), where Settings › Cloud Sync offers Retry and
// Discard (owner decision D3).

/// What came back for one write.
enum NativeMutationPushResponse: Equatable {
    case http(statusCode: Int)
    /// A response that is not HTTP.
    case nonHTTP
    /// The request failed before a response arrived (offline, timeout, reset).
    case transportError
}

/// How the push treats one write's response.
enum NativeMutationPushResponseClass: Equatable {
    /// 2xx: the server took the change; it leaves the queue.
    case accepted
    /// 401, or a 403 before this pass refreshed the session: the coordinator
    /// refreshes once and retries the remainder.
    case authRejected
    /// A non-auth 4xx the server will not accept on a retry (400, 404, 409,
    /// 413, 422, …), or a 403 that repeats after one successful refresh in the
    /// same pass: the change leaves the queue for the rejected-change store.
    case rejected
    /// 408, 425, 429, 5xx, 3xx, any other status, a transport error or a
    /// non-HTTP response: the change stays queued and retries with backoff.
    case transient
}

enum NativeMutationPushClassification {
    /// The 4xx statuses that can succeed unchanged later (timeout, too early,
    /// rate limited): they stay transient.
    static let transientClientStatuses: Set<Int> = [408, 425, 429]

    /// The single status → class mapping (plan 12.00b.1 step 1, controller
    /// resolution 1). `afterAuthRefresh` is true only for the push that
    /// follows one successful session refresh in the same pass.
    static func classify(
        _ response: NativeMutationPushResponse,
        afterAuthRefresh: Bool
    ) -> NativeMutationPushResponseClass {
        guard case let .http(status) = response else { return .transient }
        switch status {
        case 200..<300: return .accepted
        case 401: return .authRejected
        case 403: return afterAuthRefresh ? .rejected : .authRejected
        case _ where transientClientStatuses.contains(status): return .transient
        case 400..<500: return .rejected
        default: return .transient
        }
    }
}

/// One change the server refused, with the status it refused it with. It
/// holds the queued change itself (for Retry), so it is customer data: never
/// logged and never reported. Diagnostics carry only its table and status.
struct NativeMutationRejection: Equatable {
    var item: Canonical.MutationItem
    var statusCode: Int
}
