import Foundation
import MapKit

var failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

func job(
    _ id: String,
    date: String = "2026-09-20",
    start: String? = "09:00",
    end: String? = "10:00",
    address: String = "1 Main St, Phoenix, AZ",
    title: String = "Job"
) -> NativeRouteStopInput {
    NativeRouteStopInput(
        id: id,
        title: "\(title) \(id)",
        customerName: "Customer \(id)",
        scheduledDate: date,
        scheduledStartTime: start,
        scheduledEndTime: end,
        address: address
    )
}

// MARK: - Daily membership (oracle: loadJobsForDate)

expect(
    NativeRoutePlanning.dailyStops(jobs: [], dateString: "2026-09-20").isEmpty,
    "empty day returns no stops"
)

let otherDay = NativeRoutePlanning.dailyStops(
    jobs: [job("a", date: "2026-09-21")],
    dateString: "2026-09-20"
)
expect(otherDay.isEmpty, "jobs on other dates are excluded from the day")

let one = NativeRoutePlanning.dailyStops(jobs: [job("a")], dateString: "2026-09-20")
expect(one.count == 1 && one[0].id == "a", "one dated job returns one stop")
expect(one[0].hasUsableAddress, "a job with an address is navigable")

// MARK: - Ordering (oracle: loadJobsForDate comparator)

let mixed = NativeRoutePlanning.dailyStops(
    jobs: [
        job("untimed-nil", start: nil),
        job("late", start: "14:00"),
        job("early", start: "08:00"),
        job("untimed-empty", start: ""),
        job("mid", start: "09:30"),
    ],
    dateString: "2026-09-20"
)
expect(
    mixed.map(\.id) == ["early", "mid", "late", "untimed-nil", "untimed-empty"],
    "timed stops sort ascending with nil/empty-start jobs last in source order, got \(mixed.map(\.id))"
)

// MARK: - Addressless projection (oracle: RouteScreen address rows)

let withGaps = NativeRoutePlanning.dailyStops(
    jobs: [
        job("no-addr", address: ""),
        job("blank-addr", address: "   "),
        job("has-addr", address: "9 Oak Ave"),
    ],
    dateString: "2026-09-20"
)
expect(withGaps.count == 3, "addressless rows stay in the stop list")
expect(
    withGaps.filter { !$0.hasUsableAddress }.map(\.id) == ["no-addr", "blank-addr"],
    "empty and whitespace-only addresses are not navigable"
)
expect(
    NativeRoutePlanning.usableAddresses(stops: withGaps) == ["9 Oak Ave"],
    "destinations exclude addressless rows"
)
expect(
    NativeRoutePlanning.navigableStops(stops: withGaps).map(\.id) == ["has-addr"],
    "navigableStops mirrors the usable-address projection"
)

// MARK: - No canonical writes

let sourceJobs = [job("a", start: "10:00"), job("b", start: "08:00", address: "")]
let snapshotJobs = sourceJobs
var session = NativeRoutePlanning.dailyStops(jobs: sourceJobs, dateString: "2026-09-20")
session = NativeRoutePlanning.moveDown(stops: session, at: 0)
session = NativeRoutePlanning.resetOrder(stops: session)
_ = NativeRoutePlanning.fullRouteURL(stops: session, businessAddress: "Shop")
expect(sourceJobs == snapshotJobs, "planning never mutates its inputs")

// MARK: - Reorder / reset (oracle: moveUp/moveDown/resetOrder)

let ordered = NativeRoutePlanning.dailyStops(
    jobs: [job("a", start: "08:00"), job("b", start: "09:00"), job("c", start: "10:00")],
    dateString: "2026-09-20"
)
expect(
    NativeRoutePlanning.moveUp(stops: ordered, at: 0) == ordered,
    "moveUp at the top is a no-op"
)
expect(
    NativeRoutePlanning.moveDown(stops: ordered, at: 2) == ordered,
    "moveDown at the bottom is a no-op"
)
expect(
    NativeRoutePlanning.moveUp(stops: ordered, at: 9) == ordered
        && NativeRoutePlanning.moveDown(stops: ordered, at: -1) == ordered,
    "out-of-range moves are no-ops"
)
let moved = NativeRoutePlanning.moveDown(
    stops: NativeRoutePlanning.moveUp(stops: ordered, at: 2),
    at: 0
)
expect(moved.map(\.id) == ["c", "a", "b"], "up/down reorder the session list, got \(moved.map(\.id))")
let reset = NativeRoutePlanning.resetOrder(stops: moved)
expect(reset.map(\.id) == ["a", "b", "c"], "reset restores source time order after reorders")

// MARK: - Origin fallback (oracle: openFullRoute)

let originStops = NativeRoutePlanning.dailyStops(
    jobs: [job("a", address: "First Stop"), job("b", address: "Second Stop")],
    dateString: "2026-09-20"
)
expect(
    NativeRoutePlanning.routeOrigin(businessAddress: "  Shop HQ  ", stops: originStops) == "Shop HQ",
    "trimmed business address wins as origin"
)
expect(
    NativeRoutePlanning.routeOrigin(businessAddress: "   ", stops: originStops) == "First Stop",
    "blank business address falls back to the first usable stop"
)
expect(
    NativeRoutePlanning.routeOrigin(businessAddress: nil, stops: originStops) == "First Stop",
    "missing business address falls back to the first usable stop"
)
let noUsable = NativeRoutePlanning.dailyStops(
    jobs: [job("a", address: "")],
    dateString: "2026-09-20"
)
expect(
    NativeRoutePlanning.routeOrigin(businessAddress: nil, stops: noUsable) == nil
        && NativeRoutePlanning.fullRouteURL(stops: noUsable, businessAddress: nil) == nil,
    "no usable address means no origin and no full-route URL"
)

// MARK: - Handoff URLs (oracle: mapsUrlForAddress / navigateTo / openFullRoute)

let unicodeAddress = "123 Mañana St #5 & Söhne, Zürich"
if let apple = NativeRoutePlanning.appleMapsURL(address: unicodeAddress) {
    expect(apple.scheme == "maps", "per-stop handoff uses the maps: scheme")
    let items = URLComponents(url: apple, resolvingAgainstBaseURL: false)?.queryItems
    expect(
        items?.first(where: { $0.name == "daddr" })?.value == unicodeAddress,
        "Apple Maps daddr round-trips the Unicode address"
    )
    expect(
        items?.first(where: { $0.name == "dirflg" })?.value == "d",
        "Apple Maps handoff requests driving directions"
    )
    expect(
        !apple.absoluteString.contains(" ") && apple.absoluteString.contains("%"),
        "Apple Maps URL is percent-encoded"
    )
} else {
    expect(false, "appleMapsURL builds a URL for a Unicode address")
}
expect(
    NativeRoutePlanning.appleMapsURL(address: "   ") == nil,
    "blank addresses produce no per-stop URL"
)
if let google = NativeRoutePlanning.googleMapsURL(address: unicodeAddress) {
    let items = URLComponents(url: google, resolvingAgainstBaseURL: false)?.queryItems
    expect(
        google.absoluteString.hasPrefix("https://maps.google.com/")
            && items?.first(where: { $0.name == "daddr" })?.value == unicodeAddress,
        "Google fallback URL carries the encoded address"
    )
} else {
    expect(false, "googleMapsURL builds a fallback URL")
}

let slashStops = NativeRoutePlanning.dailyStops(
    jobs: [
        job("a", start: "08:00", address: "100 A/B Blvd, Reno, NV"),
        job("b", start: "09:00", address: unicodeAddress),
    ],
    dateString: "2026-09-20"
)
if let full = NativeRoutePlanning.fullRouteURL(stops: slashStops, businessAddress: "Shop HQ") {
    // NOTE: URL.path percent-decodes, so segments are read from the raw
    // absoluteString past the fixed prefix.
    let prefix = "https://www.google.com/maps/dir/"
    let raw = full.absoluteString.hasPrefix(prefix)
        ? String(full.absoluteString.dropFirst(prefix.count))
        : nil
    let segments = raw?.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    expect(
        segments?.count == 3,
        "full-route URL holds exactly origin + stops segments (embedded slashes encoded), got \(full.absoluteString)"
    )
    let decoded = segments?.map { $0.removingPercentEncoding ?? $0 }
    expect(
        decoded == ["Shop HQ", "100 A/B Blvd, Reno, NV", unicodeAddress],
        "full-route segments decode to origin + stops in order"
    )
    expect(
        (full.absoluteString.contains("%2F") || full.absoluteString.contains("%2f"))
            && !full.absoluteString.contains(" ")
            && !full.absoluteString.contains("ñ"),
        "full-route URL encodes slashes, spaces and non-ASCII like encodeURIComponent"
    )
} else {
    expect(false, "fullRouteURL builds a multi-stop URL")
}

// Full route follows the SELECTED order, not source order.
let reorderedForHandoff = NativeRoutePlanning.moveUp(stops: slashStops, at: 1)
expect(reorderedForHandoff.map(\.id) == ["b", "a"], "test selection is reordered first")
if let full = NativeRoutePlanning.fullRouteURL(stops: reorderedForHandoff, businessAddress: nil) {
    let prefix = "https://www.google.com/maps/dir/"
    let raw = String(full.absoluteString.dropFirst(prefix.count))
    let decoded = raw.split(separator: "/").map { String($0).removingPercentEncoding ?? "" }
    // Origin falls back to the first usable stop of the SELECTED order, so
    // the Unicode address leads, followed by the selected stop sequence.
    expect(
        decoded == [unicodeAddress, unicodeAddress, "100 A/B Blvd, Reno, NV"],
        "full-route waypoints preserve the reordered selection, got \(decoded)"
    )
} else {
    expect(false, "fullRouteURL follows reordered stops")
}

// MARK: - Map preview service (async, injectable fakes)

enum StubRouteError: Error { case boom }

struct StubGeocoder: NativeRouteGeocoding {
    var handler: @Sendable (String) async throws -> CLLocationCoordinate2D
    func coordinate(for address: String) async throws -> CLLocationCoordinate2D {
        try await handler(address)
    }
}

struct StubDirections: NativeRouteDirectionsEstimating {
    var handler: @Sendable (CLLocationCoordinate2D, CLLocationCoordinate2D) async throws -> NativeRouteLegEstimate
    func estimate(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) async throws -> NativeRouteLegEstimate {
        try await handler(from, to)
    }
}

final class AsyncBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var failures: [String] = []
    func add(_ message: String) {
        lock.lock()
        failures.append(message)
        lock.unlock()
    }
}

func asyncExpect(_ box: AsyncBox, _ condition: Bool, _ message: String) {
    if !condition { box.add(message) }
}

func runAsync(_ work: @escaping @Sendable () async -> Void) {
    let group = DispatchGroup()
    group.enter()
    Task {
        await work()
        group.leave()
    }
    group.wait()
}

let asyncBox = AsyncBox()
let leg = NativeRouteLegEstimate(distanceMeters: 1000, travelSeconds: 300)

func coord(_ latitude: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: -112.0)
}

// Partial lookup: one bad address is reported, the rest still previews,
// and the stop list is untouched.
runAsync {
    let geocoder = StubGeocoder { address in
        if address == "Bad Stop" { throw StubRouteError.boom }
        return coord(Double(address.count))
    }
    let directions = StubDirections { _, _ in leg }
    let runner = NativeRoutePreviewRunner(geocoder: geocoder, directions: directions)
    let stops = NativeRoutePlanning.dailyStops(
        jobs: [
            job("a", start: "08:00", address: "Good One"),
            job("b", start: "09:00", address: "Bad Stop"),
            job("c", start: "10:00", address: "Good Two"),
        ],
        dateString: "2026-09-20"
    )
    let preview = await runner.preview(
        stops: stops,
        originAddress: "Shop HQ",
        ownerID: "owner-1",
        dateString: "2026-09-20"
    )
    guard let preview else {
        asyncExpect(asyncBox, false, "partial preview returns a value, not nil")
        return
    }
    asyncExpect(asyncBox, preview.isPartial, "one failed address yields a partial preview")
    asyncExpect(asyncBox, preview.legs.count == 2, "legs bridge across the failed stop")
    asyncExpect(asyncBox, preview.legs.allSatisfy(\.isPreviewEstimate), "legs are labeled preview estimates")
    asyncExpect(
        asyncBox,
        preview.failures == [NativeRoutePreviewFailure(stopID: "b", address: "Bad Stop")],
        "the failed stop is reported with its ID and address"
    )
    asyncExpect(asyncBox, stops.count == 3, "map failure does not shrink the stop list")
}

// Total route failure is separate from stop-list data.
runAsync {
    let geocoder = StubGeocoder { _ in throw StubRouteError.boom }
    let directions = StubDirections { _, _ in leg }
    let runner = NativeRoutePreviewRunner(geocoder: geocoder, directions: directions)
    let stops = NativeRoutePlanning.dailyStops(
        jobs: [job("a", address: "Nowhere")],
        dateString: "2026-09-20"
    )
    let preview = await runner.preview(
        stops: stops,
        originAddress: "Lost Origin",
        ownerID: "owner-1",
        dateString: "2026-09-20"
    )
    guard let preview else {
        asyncExpect(asyncBox, false, "failed preview returns an error state, not nil")
        return
    }
    asyncExpect(asyncBox, preview.hasNoPreview, "unresolvable origin yields no legs")
    asyncExpect(
        asyncBox,
        preview.failures == [NativeRoutePreviewFailure(stopID: nil, address: "Lost Origin")],
        "origin failure is attributed to the origin"
    )
    asyncExpect(asyncBox, stops.count == 1, "error map state stays separate from stop-list data")
}

// Directions failure on one pair keeps the other legs.
runAsync {
    let geocoder = StubGeocoder { address in coord(Double(address.count)) }
    let directions = StubDirections { from, _ in
        if from.latitude == 8 { throw StubRouteError.boom }
        return leg
    }
    let runner = NativeRoutePreviewRunner(geocoder: geocoder, directions: directions)
    let stops = NativeRoutePlanning.dailyStops(
        jobs: [
            job("a", start: "08:00", address: "12345678"),
            job("b", start: "09:00", address: "abcdefghi"),
        ],
        dateString: "2026-09-20"
    )
    // Origin "HQ" resolves to latitude 2, so the origin→a leg succeeds and
    // only the a→b leg (from latitude 8) fails.
    let preview = await runner.preview(stops: stops, originAddress: "HQ", ownerID: "o", dateString: "d")
    asyncExpect(asyncBox, preview?.legs.map(\.toStopID) == ["a"], "one directions failure keeps the surviving leg")
    asyncExpect(
        asyncBox,
        preview?.failures == [NativeRoutePreviewFailure(stopID: "b", address: "abcdefghi")],
        "the failed pair is reported"
    )
}

// Preview legs follow the selected order.
runAsync {
    final class Pairs: @unchecked Sendable {
        let lock = NSLock()
        var latitudes: [Double] = []
        func record(_ from: Double, _ to: Double) {
            lock.lock()
            latitudes.append(contentsOf: [from, to])
            lock.unlock()
        }
    }
    let pairs = Pairs()
    let coords = ["First Stop": 1.0, "Second Stop": 2.0, "Third Stop": 3.0]
    let geocoder = StubGeocoder { address in coord(coords[address] ?? 0) }
    let directions = StubDirections { from, to in
        pairs.record(from.latitude, to.latitude)
        return leg
    }
    let runner = NativeRoutePreviewRunner(geocoder: geocoder, directions: directions)
    let stops = NativeRoutePlanning.dailyStops(
        jobs: [
            job("a", start: "08:00", address: "First Stop"),
            job("b", start: "09:00", address: "Second Stop"),
            job("c", start: "10:00", address: "Third Stop"),
        ],
        dateString: "2026-09-20"
    )
    let selected = NativeRoutePlanning.moveUp(stops: NativeRoutePlanning.moveUp(stops: stops, at: 2), at: 1)
    let preview = await runner.preview(stops: selected, originAddress: nil, ownerID: "o", dateString: "d")
    asyncExpect(asyncBox, selected.map(\.id) == ["c", "a", "b"], "test selection is reordered first")
    asyncExpect(
        asyncBox,
        preview?.legs.map(\.toStopID) == ["a", "b"],
        "legs connect consecutive stops in the selected order"
    )
    asyncExpect(asyncBox, pairs.latitudes == [3.0, 1.0, 1.0, 2.0], "directions ran in selected order")
}

// Stale request: a newer preview wins; the older one returns nil.
runAsync {
    let geocoder = StubGeocoder { address in
        try? await Task.sleep(nanoseconds: 200_000_000)
        return coord(Double(address.count))
    }
    let directions = StubDirections { _, _ in leg }
    let runner = NativeRoutePreviewRunner(geocoder: geocoder, directions: directions)
    let stops = NativeRoutePlanning.dailyStops(
        jobs: [job("a", address: "Alpha"), job("b", address: "Beta")],
        dateString: "2026-09-20"
    )
    async let first = runner.preview(stops: stops, originAddress: nil, ownerID: "o", dateString: "d")
    try? await Task.sleep(nanoseconds: 50_000_000)
    let flipped = [stops[1], stops[0]]
    async let second = runner.preview(stops: flipped, originAddress: nil, ownerID: "o", dateString: "d")
    let r1 = await first
    let r2 = await second
    asyncExpect(asyncBox, r1 == nil, "superseded preview returns nil instead of stale legs")
    asyncExpect(
        asyncBox,
        r2?.orderedStopIDs == ["b", "a"] && r2?.legs.map(\.toStopID) == ["a"],
        "newer preview delivers the newer order"
    )
}

// Explicit cancellation invalidates in-flight work.
runAsync {
    let geocoder = StubGeocoder { address in
        try? await Task.sleep(nanoseconds: 200_000_000)
        return coord(Double(address.count))
    }
    let directions = StubDirections { _, _ in leg }
    let runner = NativeRoutePreviewRunner(geocoder: geocoder, directions: directions)
    let stops = NativeRoutePlanning.dailyStops(
        jobs: [job("a", address: "Alpha"), job("b", address: "Beta")],
        dateString: "2026-09-20"
    )
    async let inflight = runner.preview(stops: stops, originAddress: nil, ownerID: "o", dateString: "d")
    try? await Task.sleep(nanoseconds: 50_000_000)
    await runner.cancel()
    let result = await inflight
    asyncExpect(asyncBox, result == nil, "cancelled preview delivers nothing")
}

// Owner change supersedes the previous owner's request.
runAsync {
    let geocoder = StubGeocoder { address in
        try? await Task.sleep(nanoseconds: 200_000_000)
        return coord(Double(address.count))
    }
    let directions = StubDirections { _, _ in leg }
    let runner = NativeRoutePreviewRunner(geocoder: geocoder, directions: directions)
    let stops = NativeRoutePlanning.dailyStops(
        jobs: [job("a", address: "Alpha"), job("b", address: "Beta")],
        dateString: "2026-09-20"
    )
    async let oldOwner = runner.preview(stops: stops, originAddress: nil, ownerID: "owner-A", dateString: "d")
    try? await Task.sleep(nanoseconds: 50_000_000)
    async let newOwner = runner.preview(stops: stops, originAddress: nil, ownerID: "owner-B", dateString: "d")
    let rOld = await oldOwner
    let rNew = await newOwner
    asyncExpect(asyncBox, rOld == nil, "previous-owner preview is discarded after owner change")
    asyncExpect(asyncBox, rNew?.ownerID == "owner-B", "current-owner preview is delivered")
}

// Single stop with no origin: nothing to connect, but the result is a valid
// empty preview — not a stale-request nil.
runAsync {
    let geocoder = StubGeocoder { address in coord(Double(address.count)) }
    let directions = StubDirections { _, _ in leg }
    let runner = NativeRoutePreviewRunner(geocoder: geocoder, directions: directions)
    let stops = NativeRoutePlanning.dailyStops(
        jobs: [job("solo", address: "Only Stop")],
        dateString: "2026-09-20"
    )
    let preview = await runner.preview(stops: stops, originAddress: nil, ownerID: "o", dateString: "d")
    asyncExpect(asyncBox, preview != nil, "single stop yields an empty (not stale) preview")
    asyncExpect(
        asyncBox,
        preview?.legs.isEmpty == true && preview?.failures.isEmpty == true,
        "single stop with no origin has no legs and no failures"
    )
}

// MARK: - Report

if !asyncBox.failures.isEmpty {
    for message in asyncBox.failures {
        failures += 1
        print("FAIL: \(message)")
    }
}

if failures == 0 {
    print("PASS: native route planning tests")
} else {
    print("\(failures) native route planning test(s) failed")
    exit(1)
}
