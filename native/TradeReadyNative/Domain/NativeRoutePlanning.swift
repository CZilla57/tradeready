import Foundation

/// Pure daily-route policy ported from `screens/RouteScreen.tsx` and
/// `utils/storage/dailyOps.ts` (`loadJobsForDate`).
///
/// This type is dependency-free (Foundation only) so the swiftc host-test
/// harness can compile it standalone. It never touches persistence, network,
/// MapKit, or the canonical store: it projects canonical-shaped inputs into a
/// session-local ordered stop list plus safely encoded navigation handoffs.
///
/// Pinned oracle behavior (contract decisions §9, R1-01):
/// - Daily membership is `scheduledDate == dateString` with **no**
///   status/archive filter, matching `loadJobsForDate`/RouteScreen today.
/// - Initial order is start-time ascending with untimed jobs (nil or empty
///   start) last, matching the RN comparator. Ties keep source order.
/// - Reorder (up/down) and reset are session-local; reset restores source
///   ordering. Refresh/re-entry re-runs `dailyStops`, discarding reorders.
/// - Addressless rows stay in the stop list but are excluded from navigation
///   destinations. A whitespace-only address counts as missing for
///   destinations (RN would attempt a useless handoff); the row itself is
///   still shown, so membership stays exact.
/// - Full-route handoff preserves the *selected* order and uses the trimmed
///   business address as origin, falling back to the first usable stop.
/// - No optimization, no reschedule, no canonical writes: every function
///   returns new values and leaves its inputs untouched.
public struct NativeRouteStopInput: Equatable, Sendable {
    /// Canonical field names (`Canonical.Job`), kept as plain strings so this
    /// file has no dependency on the canonical model sources.
    public var id: String
    public var title: String
    public var customerName: String
    public var scheduledDate: String?
    public var scheduledStartTime: String?
    public var scheduledEndTime: String?
    public var address: String

    public init(
        id: String,
        title: String,
        customerName: String,
        scheduledDate: String?,
        scheduledStartTime: String?,
        scheduledEndTime: String?,
        address: String
    ) {
        self.id = id
        self.title = title
        self.customerName = customerName
        self.scheduledDate = scheduledDate
        self.scheduledStartTime = scheduledStartTime
        self.scheduledEndTime = scheduledEndTime
        self.address = address
    }
}

public struct NativeRouteStop: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var customerName: String
    public var scheduledStartTime: String?
    public var scheduledEndTime: String?
    /// Raw stored address, exactly as canonical carries it.
    public var address: String
    /// Position in the source (membership) ordering, so `resetOrder` can
    /// restore it after arbitrary session-local reorders.
    public var sourceOrder: Int
    /// Trimmed address, or nil when blank. Drives navigation eligibility.
    public var normalizedAddress: String?
    public var hasUsableAddress: Bool { normalizedAddress != nil }

    public init(
        id: String,
        title: String,
        customerName: String,
        scheduledStartTime: String?,
        scheduledEndTime: String?,
        address: String,
        sourceOrder: Int
    ) {
        self.id = id
        self.title = title
        self.customerName = customerName
        self.scheduledStartTime = scheduledStartTime
        self.scheduledEndTime = scheduledEndTime
        self.address = address
        self.sourceOrder = sourceOrder
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizedAddress = trimmed.isEmpty ? nil : trimmed
    }
}

public enum NativeRoutePlanning {
    /// Filters jobs to `scheduledDate == dateString` and returns them in
    /// source order (timed first by start, untimed last, stable).
    public static func dailyStops(
        jobs: [NativeRouteStopInput],
        dateString: String
    ) -> [NativeRouteStop] {
        var stops: [NativeRouteStop] = []
        stops.reserveCapacity(jobs.count)
        for job in jobs {
            guard job.scheduledDate == dateString else { continue }
            stops.append(
                NativeRouteStop(
                    id: job.id,
                    title: job.title,
                    customerName: job.customerName,
                    scheduledStartTime: job.scheduledStartTime,
                    scheduledEndTime: job.scheduledEndTime,
                    address: job.address,
                    sourceOrder: stops.count
                )
            )
        }
        return sourceOrdered(stops)
    }

    /// Session-local move-up, mirroring `RouteScreen.moveUp` (index 0 is a
    /// no-op; out-of-range indices are no-ops rather than RN's undefined
    /// swap, which would corrupt the list).
    public static func moveUp(stops: [NativeRouteStop], at index: Int) -> [NativeRouteStop] {
        guard index > 0, index < stops.count else { return stops }
        var next = stops
        next.swapAt(index - 1, index)
        return next
    }

    /// Session-local move-down, mirroring `RouteScreen.moveDown`.
    public static func moveDown(stops: [NativeRouteStop], at index: Int) -> [NativeRouteStop] {
        guard index >= 0, index + 1 < stops.count else { return stops }
        var next = stops
        next.swapAt(index, index + 1)
        return next
    }

    /// Restores source ordering (timed first, untimed last), mirroring
    /// `RouteScreen.resetOrder`. Works after any number of reorders because
    /// `sourceOrder` travels with each stop.
    public static func resetOrder(stops: [NativeRouteStop]) -> [NativeRouteStop] {
        sourceOrdered(stops)
    }

    /// Usable destination addresses in the *selected* order. Addressless rows
    /// are excluded; the stop list itself is unaffected.
    public static func usableAddresses(stops: [NativeRouteStop]) -> [String] {
        stops.compactMap(\.normalizedAddress)
    }

    /// Stops eligible for navigation handoff, in the selected order.
    public static func navigableStops(stops: [NativeRouteStop]) -> [NativeRouteStop] {
        stops.filter { $0.hasUsableAddress }
    }

    /// Handoff origin: the trimmed business address when non-blank, otherwise
    /// the first usable stop. Nil when nothing is navigable.
    /// Mirrors `openFullRoute`: `businessAddress?.trim() || addresses[0]`.
    public static func routeOrigin(
        businessAddress: String?,
        stops: [NativeRouteStop]
    ) -> String? {
        let trimmed = (businessAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return usableAddresses(stops: stops).first
    }

    /// Per-stop Apple Maps handoff, mirroring `mapsUrlForAddress` on iOS:
    /// `maps://maps.apple.com/?daddr=<encoded>&dirflg=d`.
    /// URLComponents performs the percent-encoding (Unicode-safe).
    public static func appleMapsURL(address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "maps"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "daddr", value: trimmed),
            URLQueryItem(name: "dirflg", value: "d"),
        ]
        return components.url
    }

    /// Per-stop Google Maps web fallback, mirroring `navigateTo`'s fallback:
    /// `https://maps.google.com/?daddr=<encoded>`.
    public static func googleMapsURL(address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.google.com"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "daddr", value: trimmed)]
        return components.url
    }

    /// Full-route Google Maps web handoff, mirroring `openFullRoute`:
    /// `https://www.google.com/maps/dir/<origin>/<stop...>` with each segment
    /// `encodeURIComponent`-encoded and joined by `/`. The origin segment is
    /// always present (business address or first usable stop). Nil when no
    /// stop has a usable address.
    public static func fullRouteURL(
        stops: [NativeRouteStop],
        businessAddress: String?
    ) -> URL? {
        let addresses = usableAddresses(stops: stops)
        guard !addresses.isEmpty else { return nil }
        let origin = routeOrigin(businessAddress: businessAddress, stops: stops) ?? addresses[0]
        let segments = [origin] + addresses
        let encoded = segments.map { percentEncodedRouteSegment($0) }
        return URL(string: "https://www.google.com/maps/dir/" + encoded.joined(separator: "/"))
    }

    // MARK: - Private

    /// RN comparator: missing/empty start sorts after any timed start;
    /// otherwise code-unit comparison (`localeCompare` on zero-padded
    /// `HH:MM` strings). `sourceOrder` keeps ties (including untimed-vs-
    /// untimed) in source sequence.
    private static func sourceOrdered(_ stops: [NativeRouteStop]) -> [NativeRouteStop] {
        stops.sorted { a, b in
            let aStart = a.scheduledStartTime.flatMap { $0.isEmpty ? nil : $0 }
            let bStart = b.scheduledStartTime.flatMap { $0.isEmpty ? nil : $0 }
            switch (aStart, bStart) {
            case (nil, nil):
                return a.sourceOrder < b.sourceOrder
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (aTime?, bTime?):
                if aTime != bTime { return aTime < bTime }
                return a.sourceOrder < b.sourceOrder
            }
        }
    }

    /// `encodeURIComponent` equivalent for full-route path segments: leaves
    /// `A-Za-z0-9 - _ . ! ~ * ' ( )` unescaped and percent-encodes everything
    /// else (including `/`, spaces, commas, and non-ASCII) as UTF-8 bytes.
    /// `CharacterSet.urlPathAllowed` must NOT be used here: it leaves `/`
    /// unescaped, which would split one address into several waypoints.
    private static func percentEncodedRouteSegment(_ value: String) -> String {
        // ASCII-only, mirroring encodeURIComponent exactly: Unicode letters
        // must NOT sneak in via CharacterSet.alphanumerics (which covers all
        // of Unicode). Everything outside this set becomes UTF-8 %XX bytes.
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
