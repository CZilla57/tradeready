import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Next Job widget policy tests (task 11.02, requirement W2).
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §3.3 (stale window + boundary, the "separately from staleness"
// scheduledDate rule, the timeline entry at `updatedAt + 86400`) and §6.1
// (deep-link grammar). RN oracle: `targets/widget/Widgets.swift` (Next Job
// small/medium) and `utils/widgetBridge.ts#selectNextJob`.
//
// This suite exercises `NextJobWidgetPolicy` only (pure Foundation, no
// SwiftUI/WidgetKit) plus a round trip through the real
// `NativeDeepLinkParser`, so it never needs an App Group entitlement.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(actual)")
    }
}

// MARK: - Fixtures

private let phoenix: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
    return calendar
}()

private let posix = Locale(identifier: "en_US_POSIX")

/// Same pinned instant as `native/WidgetSnapshotTests/main.swift`: RN's
/// `NOW = new Date(2026, 7, 3, 12, 0, 0)` under `TZ=America/Phoenix`
/// (UTC−7, no DST) = 2026-08-03T19:00:00Z = local Aug 3, 12:00 noon.
private let now = ISO8601DateFormatter().date(from: "2026-08-03T19:00:00Z")!
private let today = "2026-08-03"

private func iso(_ date: Date) -> String { WidgetSnapshot.isoTimestamp(date) }

private func nextJob(
    id: String = "j9",
    customerName: String = "Alice Johnson",
    title: String = "Fence repair",
    scheduledDate: String,
    scheduledStartTime: String? = nil,
    address: String = "12 Oak St"
) -> WidgetSnapshot.NextJob {
    WidgetSnapshot.NextJob(
        id: id, customerName: customerName, title: title,
        scheduledDate: scheduledDate, scheduledStartTime: scheduledStartTime, address: address
    )
}

private func snapshot(updatedAt: String, nextJob: WidgetSnapshot.NextJob? = nil) -> WidgetSnapshot {
    WidgetSnapshot(updatedAt: updatedAt, nextJob: nextJob, timer: nil, outstandingTotal: 0)
}

// MARK: - resolveState: missing/blank snapshot

private func testMissingSnapshot() {
    expectEqual(
        NextJobWidgetPolicy.resolveState(snapshot: nil, now: now, calendar: phoenix),
        .missing,
        "a nil snapshot (missing key or undecodable JSON) resolves to .missing"
    )
}

// MARK: - resolveState: §3.3 stale boundary

private func testStaleBoundary() {
    let job = nextJob(scheduledDate: today)

    func stateAtAge(_ age: TimeInterval) -> NextJobWidgetState {
        let updatedAt = now.addingTimeInterval(-age)
        return NextJobWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: iso(updatedAt), nextJob: job), now: now, calendar: phoenix
        )
    }

    expectEqual(stateAtAge(86_399), .job(job), "age 86,399s is fresh (§3.3 boundary)")
    expectEqual(stateAtAge(86_400), .job(job), "age exactly 86,400s is fresh (§3.3: exactly fresh)")
    expectEqual(stateAtAge(86_401), .stale, "age 86,401s is stale (§3.3 boundary)")

    let futureUpdatedAt = now.addingTimeInterval(60)
    expectEqual(
        NextJobWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: iso(futureUpdatedAt), nextJob: job), now: now, calendar: phoenix
        ),
        .stale,
        "a negative age (updatedAt in the future) is stale"
    )

    expectEqual(
        NextJobWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: "not-a-real-timestamp", nextJob: job), now: now, calendar: phoenix
        ),
        .stale,
        "an unparseable updatedAt is stale"
    )
}

// MARK: - resolveState: §3.3 "separately from staleness" scheduledDate rule

private func testNoUpcomingJobRule() {
    let fresh = iso(now)

    expectEqual(
        NextJobWidgetPolicy.resolveState(snapshot: snapshot(updatedAt: fresh, nextJob: nil), now: now, calendar: phoenix),
        .noUpcomingJob,
        "a fresh snapshot with no nextJob is .noUpcomingJob"
    )

    let yesterdayJob = nextJob(scheduledDate: "2026-08-02")
    expectEqual(
        NextJobWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: fresh, nextJob: yesterdayJob), now: now, calendar: phoenix
        ),
        .noUpcomingJob,
        "a fresh snapshot whose nextJob.scheduledDate is before local today is .noUpcomingJob, not .job (§3.3)"
    )

    let todayJob = nextJob(scheduledDate: today)
    expectEqual(
        NextJobWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: fresh, nextJob: todayJob), now: now, calendar: phoenix
        ),
        .job(todayJob),
        "a fresh snapshot with a today-dated nextJob is .job"
    )

    let futureJob = nextJob(scheduledDate: "2026-08-10")
    expectEqual(
        NextJobWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: fresh, nextJob: futureJob), now: now, calendar: phoenix
        ),
        .job(futureJob),
        "a fresh snapshot with a future-dated nextJob is .job"
    )

    // A stale snapshot never reaches the scheduledDate check: no customer
    // name/address/link even if the payload still contains an upcoming job.
    let staleUpdatedAt = iso(now.addingTimeInterval(-90_000))
    expectEqual(
        NextJobWidgetPolicy.resolveState(
            snapshot: snapshot(updatedAt: staleUpdatedAt, nextJob: futureJob), now: now, calendar: phoenix
        ),
        .stale,
        "staleness is checked before the scheduledDate rule"
    )
}

// MARK: - deepLinkURL: §6.1 grammar round trip through the real parser

private func testDeepLinkGrammarRoundTrip() {
    let cases: [String] = ["j9", "job with spaces", "a/b", "a?b", "a#b", "50%", "café-☕", "job'quote"]
    for id in cases {
        guard let url = NextJobWidgetPolicy.deepLinkURL(jobID: id) else {
            failures += 1
            print("FAIL: deepLinkURL produced nil for id \(id)")
            continue
        }
        guard let route = NativeDeepLinkParser.parse(url.absoluteString) else {
            failures += 1
            print("FAIL: NativeDeepLinkParser rejected the generated URL \(url.absoluteString) for id \(id)")
            continue
        }
        expectEqual(route, .job(id: id), "widgetURL for id \(id) round-trips through the real parser exactly")
    }

    expect(NextJobWidgetPolicy.deepLinkURL(jobID: "") == nil, "an empty job id produces no deep link")

    let url = NextJobWidgetPolicy.deepLinkURL(jobID: "j9")
    expectEqual(url?.absoluteString, "tradeready://job/j9", "the plain-id URL matches the grammar exactly, no reformatting")
}

// MARK: - nextRefreshDate: §3.3 timeline entry

private func testNextRefreshDate() {
    expect(
        NextJobWidgetPolicy.nextRefreshDate(snapshot: nil, now: now, calendar: phoenix) == nil,
        "no snapshot means no self-scheduled refresh"
    )

    let staleSnapshot = snapshot(updatedAt: iso(now.addingTimeInterval(-90_000)), nextJob: nil)
    expect(
        NextJobWidgetPolicy.nextRefreshDate(snapshot: staleSnapshot, now: now, calendar: phoenix) == nil,
        "an already-stale snapshot schedules no further refresh"
    )

    // updatedAt == now: next local midnight (2026-08-04T07:00:00Z in
    // America/Phoenix, fixed UTC−7) is earlier than updatedAt + 86,400.
    let freshNow = snapshot(updatedAt: iso(now), nextJob: nil)
    let expectedMidnight = ISO8601DateFormatter().date(from: "2026-08-04T07:00:00Z")!
    expectEqual(
        NextJobWidgetPolicy.nextRefreshDate(snapshot: freshNow, now: now, calendar: phoenix),
        expectedMidnight,
        "the next local midnight wins when it is earlier than updatedAt + 86,400"
    )

    // updatedAt 23h before now: updatedAt + 86,400 lands 1h after `now`,
    // before the next local midnight (12h after `now`) — the contract's
    // literal "timeline entry at updatedAt + 86400" case.
    let updatedAt23hAgo = now.addingTimeInterval(-82_800)
    let recentUpdate = snapshot(updatedAt: iso(updatedAt23hAgo), nextJob: nil)
    let expectedStaleDeadline = updatedAt23hAgo.addingTimeInterval(86_400)
    expectEqual(
        NextJobWidgetPolicy.nextRefreshDate(snapshot: recentUpdate, now: now, calendar: phoenix),
        expectedStaleDeadline,
        "updatedAt + 86,400 wins when it is earlier than the next local midnight"
    )
    expectEqual(iso(expectedStaleDeadline), "2026-08-03T20:00:00.000Z", "sanity: updatedAt + 86,400 is 1h after `now`")
}

// MARK: - whenLabel

private func testWhenLabel() {
    // en_US_POSIX's short time style separates the time from AM/PM with a
    // narrow no-break space (U+202F), not a plain space.
    let todayWithTime = nextJob(scheduledDate: today, scheduledStartTime: "10:30")
    expectEqual(
        NextJobWidgetPolicy.whenLabel(for: todayWithTime, now: now, calendar: phoenix, locale: posix),
        "Today \u{00B7} 10:30\u{202F}AM",
        "today with a start time shows \"Today · h:mm a\""
    )

    let tomorrowNoTime = nextJob(scheduledDate: "2026-08-04")
    expectEqual(
        NextJobWidgetPolicy.whenLabel(for: tomorrowNoTime, now: now, calendar: phoenix, locale: posix),
        "Tomorrow",
        "tomorrow with no start time shows \"Tomorrow\" and no time suffix"
    )

    let laterNoTime = nextJob(scheduledDate: "2026-08-10")
    expectEqual(
        NextJobWidgetPolicy.whenLabel(for: laterNoTime, now: now, calendar: phoenix, locale: posix),
        "Mon, Aug 10",
        "a later date falls back to \"EEE, MMM d\""
    )

    let laterWithTime = nextJob(scheduledDate: "2026-08-10", scheduledStartTime: "14:00")
    expectEqual(
        NextJobWidgetPolicy.whenLabel(for: laterWithTime, now: now, calendar: phoenix, locale: posix),
        "Mon, Aug 10 \u{00B7} 2:00\u{202F}PM",
        "a later date with a start time appends the formatted time"
    )

    let unparseable = nextJob(scheduledDate: "not-a-date")
    expectEqual(
        NextJobWidgetPolicy.whenLabel(for: unparseable, now: now, calendar: phoenix, locale: posix),
        "not-a-date",
        "an unparseable scheduledDate falls back to the raw string, never a crash or a guess"
    )
}

// MARK: - Run

testMissingSnapshot()
testStaleBoundary()
testNoUpcomingJobRule()
testDeepLinkGrammarRoundTrip()
testNextRefreshDate()
testWhenLabel()

if failures > 0 {
    print("Next Job widget policy tests: \(failures) failure(s)")
    exit(1)
}
print("Next Job widget policy tests passed")
