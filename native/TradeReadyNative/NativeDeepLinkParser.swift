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
    }

    static let pendingOpenURLMaximumAge: TimeInterval = 5 * 60

    static func parse(_ rawURL: String) -> Route? {
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
              !identifier.isEmpty
        else { return nil }

        switch components[0].lowercased() {
        case "job": return .job(id: identifier)
        case "onmyway": return .onMyWay(id: identifier)
        default: return nil
        }
    }

    /// Validates the App Group cold-launch handoff as one boundary: payload
    /// shape, freshness, and URL grammar must all pass before a route escapes.
    static func parsePendingOpenURL(_ raw: String, now: Date) -> PendingOpenURL? {
        struct Payload: Decodable {
            let url: String
            let at: String
        }

        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.url.isEmpty,
              let stampedAt = parseISO8601(payload.at),
              let route = parse(payload.url)
        else { return nil }

        let age = now.timeIntervalSince(stampedAt)
        guard age >= 0, age <= pendingOpenURLMaximumAge else { return nil }
        return PendingOpenURL(url: payload.url, at: stampedAt, route: route)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
