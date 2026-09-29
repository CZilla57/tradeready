import Foundation

/// Strict parser for links produced by the legacy widget and App Intents.
/// Any application can invoke a custom URL scheme, so callers must still
/// verify authentication, local ownership, and record existence before routing.
enum NativeDeepLinkParser {
    enum Route: Equatable, Sendable {
        case job(id: String)
        case onMyWay(id: String)

        var jobID: String {
            switch self {
            case .job(let id), .onMyWay(let id): id
            }
        }
    }

    struct PendingOpenURL: Equatable, Sendable {
        let url: String
        let at: Date
        let route: Route
        /// Task 11.06 (contract §6.2): `hash(O)` stamped by `OnMyWayIntent`.
        /// Nil for an untagged (RN-era or foreign) stash, which the consumer
        /// discards.
        let ownerTag: String?
    }

    static let pendingOpenURLMaximumAge: TimeInterval = 5 * 60

    /// Task 11.06 (recorded native difference, contract §6.1): an oversized
    /// link is dropped before any parsing. A producer's longest link is
    /// `tradeready://onmyway/` plus a 128-byte id percent-encoded (at most
    /// 3 × 128 bytes), far below this bound.
    static let maximumURLLength = 1024
    /// The same bound for the raw `pendingOpenUrl` JSON (`{url, at, ownerTag}`).
    static let maximumPendingOpenURLLength = 4096

    static func parse(_ rawURL: String) -> Route? {
        guard rawURL.utf8.count <= maximumURLLength else { return nil }
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "tradeready://"
        guard trimmed.count >= prefix.count,
              trimmed.prefix(prefix.count).lowercased() == prefix
        else { return nil }

        let remainder = trimmed.dropFirst(prefix.count)
        let components = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              !components[1].contains("?"),
              !components[1].contains("#"),
              let identifier = String(components[1]).removingPercentEncoding,
              !identifier.isEmpty,
              // Task 11.06: the id must also be a valid record identifier
              // (non-empty, at most 128 UTF-8 bytes, no control characters),
              // the same rule the widget/Siri writers and the replay planner use.
              WidgetActionFieldRules.isValidIdentifier(identifier)
        else { return nil }

        switch components[0].lowercased() {
        case "job": return .job(id: identifier)
        case "onmyway": return .onMyWay(id: identifier)
        default: return nil
        }
    }

    /// The raw `pendingOpenUrl` value `{url, at, ownerTag}`, size-bounded and
    /// decoded with no freshness or grammar check. The one decoder for both
    /// the cold consumer and the warm-route dedupe (`takeMatching`).
    struct PendingOpenURLPayload: Decodable, Equatable, Sendable {
        let url: String
        let at: String
        let ownerTag: String?
    }

    static func decodePendingOpenURLPayload(_ raw: String) -> PendingOpenURLPayload? {
        guard raw.utf8.count <= maximumPendingOpenURLLength,
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(PendingOpenURLPayload.self, from: data)
    }

    /// Validates the App Group cold-launch handoff as one boundary: payload
    /// shape, freshness, and URL grammar must all pass before a route escapes.
    static func parsePendingOpenURL(_ raw: String, now: Date) -> PendingOpenURL? {
        guard let payload = decodePendingOpenURLPayload(raw),
              !payload.url.isEmpty,
              let stampedAt = parseISO8601(payload.at),
              let route = parse(payload.url)
        else { return nil }

        let age = now.timeIntervalSince(stampedAt)
        guard age >= 0, age <= pendingOpenURLMaximumAge else { return nil }
        return PendingOpenURL(url: payload.url, at: stampedAt, route: route, ownerTag: payload.ownerTag)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
