import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Widget snapshot contract tests (task 11.01, requirements W1, M1).
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §2 (schema, fixtures F1–F6, ownerTag, owner predicate), §3.1–3.3 (write
// triggers, seam observer overload, stale window), §4.2 (lock protocol).
// RN oracle: `__tests__/widgetBridge.test.js` (fixture sources) and the RN
// `BridgeSnapshot` decoder (`targets/widget/Widgets.swift:13-35`, copied
// verbatim below as `RNBridgeSnapshot`).
//
// Every App Group touch uses a throwaway suite + lock file: a plain `swiftc`
// binary has no App Group entitlement.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

// MARK: - RN reference decoder (verbatim field shape from targets/widget/Widgets.swift:13-35)

private struct RNBridgeSnapshot: Decodable {
    var version: Int
    var updatedAt: String
    var nextJob: NextJob?
    var timer: TimerState?
    var outstandingTotal: Double?

    struct NextJob: Decodable {
        var id: String
        var customerName: String
        var title: String
        var scheduledDate: String
        var scheduledStartTime: String?
        var address: String
    }

    struct TimerState: Decodable {
        var jobId: String
        var jobTitle: String
        var customerName: String
        var startedAt: String
    }
}

private func rnDecode(_ json: String) -> RNBridgeSnapshot? {
    try? JSONDecoder().decode(RNBridgeSnapshot.self, from: Data(json.utf8))
}

// MARK: - Fixtures F1–F6 (contract §2.4, verbatim)

private let fixtureF1 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":null,"timer":null,"outstandingTotal":0}"#
private let fixtureF2 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":{"id":"j9","customerName":"Alice Johnson","title":"Fence repair","scheduledDate":"2026-08-04","scheduledStartTime":"10:30","address":"12 Oak St"},"timer":{"jobId":"j2","jobTitle":"Deck build","customerName":"Bob Smith","startedAt":"2026-08-03T10:00:00.000Z"},"outstandingTotal":160}"#
private let fixtureF3 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":{"id":"j5","customerName":"Dana Lee","title":"Gutter clean","scheduledDate":"2026-08-05","scheduledStartTime":null,"address":""},"timer":null,"outstandingTotal":1234.56}"#
private let fixtureF4 = #"{"nextJob":{"address":"1420 Maple Ave","customerName":"Alex Morgan","id":"sample","scheduledDate":"2026-01-01","scheduledStartTime":"09:00","title":"Water heater replacement"},"outstandingTotal":0,"ownerTag":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","timer":null,"updatedAt":"2026-01-01T08:00:00.000Z","version":1}"#
private let fixtureF5 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":null,"timer":null,"futureField":{"x":1}}"#
private let fixtureF6 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":{"id":"j5","customerName":"Dana Lee","title":"Gutter clean","scheduledDate":"2026-08-05","scheduledStartTime":null,"address":null},"timer":null,"outstandingTotal":0}"#

// MARK: - Canonical fixture builders

private let decoder = JSONDecoder()

private func merge(_ base: String, _ overrides: String) -> String {
    guard !overrides.isEmpty else { return base }
    func fields(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
               let text = String(data: data, encoding: .utf8) {
                result[key] = text
            }
        }
        return result
    }
    let merged = fields(base).merging(fields(overrides)) { _, new in new }
    let body = merged.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
    return "{\(body)}"
}

/// RN `job()` from `__tests__/widgetBridge.test.js`.
private func job(_ overrides: String = "") -> Canonical.Job {
    let base = """
    {"id":"j1","customerId":"c1","customerName":"Alice Johnson","title":"Fence repair","description":"",
     "status":"scheduled","scheduledDate":null,"scheduledStartTime":null,"scheduledEndTime":null,
     "address":"12 Oak St","estimateTotal":0,"laborHours":0,"laborRate":0,"materials":[],
     "materialMarkup":0,"overhead":0,"margin":0,"notes":"","invoiceId":null,"createdAt":"2026-08-01"}
    """
    return try! decoder.decode(Canonical.Job.self, from: Data(merge(base, overrides).utf8))
}

/// RN `invoice()` from `__tests__/widgetBridge.test.js`.
private func invoice(_ overrides: String = "") -> Canonical.Invoice {
    let base = """
    {"id":"i1","customer":"Alice Johnson","number":"INV-0001","amount":100,"due":"2026-08-10",
     "email":"","phone":"","desc":"","paid":false}
    """
    return try! decoder.decode(Canonical.Invoice.self, from: Data(merge(base, overrides).utf8))
}

private let phoenix: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
    return calendar
}()

/// RN `NOW = new Date(2026, 7, 3, 12, 0, 0)` in `TZ=America/Phoenix`
/// (UTC−7, no DST) = 2026-08-03T19:00:00Z. Pinned as an absolute instant and
/// projected with an explicit Phoenix calendar, so the result is the same
/// whatever TZ the runner uses.
private let now = ISO8601DateFormatter().date(from: "2026-08-03T19:00:00Z")!

private func business(invoices: [Canonical.Invoice], jobs: [Canonical.Job] = [], at date: Date = now) -> NativeBusinessSnapshot {
    NativeBusinessSnapshotEngine.make(
        invoices: invoices, jobs: jobs, customers: [], expenses: [], trips: [],
        values: NativeTaxSettingsValues(), mileageRate: 0.7, now: date
    )
}

private func project(_ jobs: [Canonical.Job], invoices: [Canonical.Invoice] = []) -> WidgetSnapshot {
    NativeWidgetSnapshotProjection.project(
        jobs: jobs, business: business(invoices: invoices, jobs: jobs), now: now, calendar: phoenix
    )
}

/// RN `buildWidgetSnapshot` outstanding fixture: 100 + (100 − 40) + 0 = 160.
private let rnOutstandingInvoices = [
    invoice(#"{"id":"unpaid","amount":100}"#),
    invoice(#"{"id":"partly","amount":100,"payments":[{"id":"p1","amount":40,"date":"2026-08-01","method":"cash"}]}"#),
    invoice(#"{"id":"settled","amount":500,"paid":true}"#),
]

private func topLevelKeys(_ json: String) -> Set<String> {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
    return Set(object.keys)
}

private func jsonObject(_ json: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
}

// MARK: - Test doubles

private final class RecordingReloader: NativeWidgetTimelineReloading {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func reloadAllTimelines() { lock.lock(); _count += 1; lock.unlock() }
}

private final class LockedFlag {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

private struct TempAppGroup {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    var lockFile: URL { directory.appendingPathComponent(WidgetAppGroup.lockFileName) }

    init(_ label: String) {
        suiteName = "com.tradeready.widget-snapshot.tests.\(label).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-1101-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    func mirror(_ reloader: RecordingReloader) -> NativeWidgetMirror {
        NativeWidgetMirror(defaults: defaults, lockFile: lockFile, reloader: reloader)
    }

    var scrubber: NativeAppGroupAccountScrubber {
        NativeAppGroupAccountScrubber(suiteName: suiteName, defaults: defaults, lockFile: lockFile)
    }

    var storedJSON: String? { defaults.string(forKey: WidgetAppGroup.snapshotKey) }
    var stored: WidgetSnapshot? { WidgetSnapshot.load(from: defaults) }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Holds the §4.2 advisory lock on a SEPARATE descriptor, exactly as the
/// extension process would.
private func holdLock(at url: URL) -> Int32 {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    precondition(descriptor >= 0)
    precondition(flock(descriptor, LOCK_EX) == 0)
    return descriptor
}

private func releaseLock(_ descriptor: Int32) {
    flock(descriptor, LOCK_UN)
    close(descriptor)
}

@MainActor
private final class SubscriptionStub: NativeSubscriptionServing {
    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func loadOffering() async throws -> NativeSubscriptionOffering { .init(packages: []) }
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        .init(entitlement: .init(isActive: false, isTrialing: false), userCancelled: false)
    }
    func restore() async throws -> NativeSubscriptionEntitlement { .init(isActive: false, isTrialing: false) }
    /// Runs inside sign-out's post-scrub window (after the App Group wipe,
    /// before `applyCompletedSignOutState` tears the owner down).
    var onLogOut: (() async -> Void)?
    func logOut() async { await onLogOut?() }
}

// MARK: - 1. Decode F1–F6 (§2.4)

private func testFixtureDecode() {
    let f1 = WidgetSnapshot.decode(json: fixtureF1)
    expect(f1 != nil, "F1 (empty) decodes")
    expectEqual(f1?.version, 1, "F1 version")
    expect(f1?.nextJob == nil && f1?.timer == nil, "F1 nulls decode as nil")
    expectEqual(f1?.outstandingTotal, 0, "F1 total")
    expect(f1?.ownerTag == nil, "F1 has no ownerTag (RN writer)")

    let f2 = WidgetSnapshot.decode(json: fixtureF2)
    expect(f2 != nil, "F2 (full) decodes")
    expectEqual(f2?.nextJob, WidgetSnapshot.NextJob(
        id: "j9", customerName: "Alice Johnson", title: "Fence repair",
        scheduledDate: "2026-08-04", scheduledStartTime: "10:30", address: "12 Oak St"
    ), "F2 nextJob fields")
    expectEqual(f2?.timer, WidgetSnapshot.TimerState(
        jobId: "j2", jobTitle: "Deck build", customerName: "Bob Smith", startedAt: "2026-08-03T10:00:00.000Z"
    ), "F2 timer fields")
    expectEqual(f2?.outstandingTotal, 160, "F2 total")

    let f3 = WidgetSnapshot.decode(json: fixtureF3)
    expect(f3 != nil, "F3 decodes")
    expect(f3?.nextJob?.scheduledStartTime == nil, "F3 null start time decodes as nil")
    expectEqual(f3?.nextJob?.address, "", "F3 empty address stays a string")
    expectEqual(f3?.outstandingTotal, 1234.56, "F3 fractional total")
    expect(f3?.timer == nil, "F3 no timer")

    let f4 = WidgetSnapshot.decode(json: fixtureF4)
    expect(f4 != nil, "F4 (native writer shape) decodes")
    expectEqual(f4?.ownerTag, String(repeating: "a", count: 64), "F4 ownerTag decodes")
    expectEqual(f4?.nextJob?.id, "sample", "F4 nextJob id")

    let f5 = WidgetSnapshot.decode(json: fixtureF5)
    expect(f5 != nil, "F5 (missing total, unknown key) decodes — unknown keys are ignored")
    expect(f5?.outstandingTotal == nil, "F5 missing outstandingTotal decodes as nil")

    expect(WidgetSnapshot.decode(json: fixtureF6) == nil, "F6 (address: null) is rejected")
    expect(WidgetSnapshot.decode(json: "not json") == nil, "garbage is rejected")
    expect(WidgetSnapshot.decode(json: #"{"version":1}"#) == nil, "missing updatedAt is rejected")

    // The RN decoder agrees on every fixture (§16 scratchpad result, now committed).
    expect([fixtureF1, fixtureF2, fixtureF3, fixtureF4, fixtureF5].allSatisfy { rnDecode($0) != nil },
           "RN BridgeSnapshot decodes F1–F5")
    expect(rnDecode(fixtureF6) == nil, "RN BridgeSnapshot rejects F6")
}

// MARK: - 2. Encoder shape (§2.3)

private func testEncoderShape() throws {
    // F4 is the native writer shape: re-encoding its decode is byte-identical
    // (sorted keys, explicit nulls, ownerTag, `0` total).
    let f4 = WidgetSnapshot.decode(json: fixtureF4)!
    expectEqual(try f4.encodedJSON(), fixtureF4, "encoding the F4 decode reproduces F4 byte-for-byte")

    let empty = WidgetSnapshot(updatedAt: "2026-08-03T19:00:00.000Z", nextJob: nil, timer: nil,
                               outstandingTotal: 0, ownerTag: "tag")
    expectEqual(try empty.encodedJSON(),
                #"{"nextJob":null,"outstandingTotal":0,"ownerTag":"tag","timer":null,"updatedAt":"2026-08-03T19:00:00.000Z","version":1}"#,
                "empty snapshot: explicit nulls for nextJob/timer, sorted keys")

    let f3 = WidgetSnapshot.decode(json: fixtureF3)!
    let f3JSON = try f3.encodedJSON()
    expect(f3JSON.contains(#""scheduledStartTime":null"#), "a nil start time is written as explicit null")
    expect(f3JSON.contains(#""address":"""#), "an empty address is written as a string")
    expect(f3JSON.contains(#""outstandingTotal":1234.56"#), "a fractional total is a plain JSON number of dollars")
    expect(!f3JSON.contains("ownerTag"), "a nil ownerTag is omitted (decoders treat missing as no owner)")

    let f2JSON = try WidgetSnapshot.decode(json: fixtureF2)!.encodedJSON()
    expect(f2JSON.contains(#""outstandingTotal":160,"#), "a whole-dollar total encodes as 160")
    // Round trip through BOTH decoders (decode equivalence, §2.2).
    expectEqual(WidgetSnapshot.decode(json: f2JSON), WidgetSnapshot.decode(json: fixtureF2),
                "native encode → native decode round-trips F2")
    let rn = rnDecode(f2JSON)
    expect(rn != nil, "RN BridgeSnapshot decodes a native-encoded snapshot")
    expectEqual(rn?.nextJob?.id, "j9", "RN decode of native output keeps nextJob.id")
    expectEqual(rn?.timer?.startedAt, "2026-08-03T10:00:00.000Z", "RN decode of native output keeps timer")

    // `updatedAt` formatting is JS `toISOString()`-compatible.
    expectEqual(WidgetSnapshot.isoTimestamp(now), "2026-08-03T19:00:00.000Z", "updatedAt has fractional seconds and Z")
    expectEqual(WidgetSnapshot.parseISODate("2026-08-03T19:00:00Z"), now, "plain ISO parses (two-step)")
    expectEqual(WidgetSnapshot.parseISODate("2026-08-03T19:00:00.000Z"), now, "fractional ISO parses")

    // Local-frame start parsing (RN `startDate`): never UTC.
    let local = WidgetSnapshot.NextJob(id: "x", customerName: "", title: "", scheduledDate: "2026-08-04",
                                       scheduledStartTime: "10:30", address: "")
    expectEqual(local.startDate(timeZone: phoenix.timeZone),
                ISO8601DateFormatter().date(from: "2026-08-04T17:30:00Z")!,
                "scheduledDate + time parse in the local frame")
    var dateOnly = local
    dateOnly.scheduledStartTime = nil
    expectEqual(dateOnly.startDate(timeZone: phoenix.timeZone),
                ISO8601DateFormatter().date(from: "2026-08-04T07:00:00Z")!,
                "a date-only schedule parses to local midnight")
}

// MARK: - 3. Projection (RN selectNextJob / selectActiveTimer / buildWidgetSnapshot)

private func testProjection() throws {
    // Both next job and timer: the F2 fixture, built from canonical records.
    let both = project([
        job(#"{"id":"j9","scheduledDate":"2026-08-04","scheduledStartTime":"10:30","notes":"gate code 4471"}"#),
        job(#"{"id":"j2","title":"Deck build","customerName":"Bob Smith","timeSessions":[{"start":"2026-08-03T08:00:00.000Z","end":"2026-08-03T09:00:00.000Z"},{"start":"2026-08-03T10:00:00.000Z"}]}"#),
    ], invoices: rnOutstandingInvoices)
    expectEqual(both, WidgetSnapshot.decode(json: fixtureF2)!, "projection (next job + timer) equals fixture F2")
    let bothJSON = try both.encodedJSON()
    expect(!bothJSON.contains("gate code"), "minimal projection: job notes never reach the snapshot")
    expectEqual(topLevelKeys(bothJSON), ["version", "updatedAt", "nextJob", "timer", "outstandingTotal"],
                "minimal projection: exactly the contract's top-level keys (ownerTag is added by the writer)")
    expectEqual(Set((jsonObject(bothJSON)?["nextJob"] as? [String: Any])?.keys ?? [:].keys),
                ["id", "customerName", "title", "scheduledDate", "scheduledStartTime", "address"],
                "minimal projection: nextJob carries only the displayed fields")

    // No next job, no timer: the F1 fixture.
    let empty = project([job(#"{"id":"unscheduled"}"#)])
    expectEqual(empty, WidgetSnapshot.decode(json: fixtureF1)!, "projection (no next job, no timer) equals fixture F1")

    // No next job, timer running.
    let timerOnly = project([
        job(#"{"id":"yesterday","scheduledDate":"2026-08-02","timeSessions":[{"start":"2026-08-03T10:00:00.000Z"}]}"#),
    ])
    expect(timerOnly.nextJob == nil, "no next job: a past-dated job never surfaces")
    expectEqual(timerOnly.timer?.jobId, "yesterday", "no next job: the running timer still projects")

    // Next job, no timer: the F3 fixture (null start time, empty address, fractional total).
    let noTimer = project([
        job(#"{"id":"j5","customerName":"Dana Lee","title":"Gutter clean","scheduledDate":"2026-08-05","address":"","timeSessions":[{"start":"2026-08-01T10:00:00.000Z","end":"2026-08-01T11:00:00.000Z"}]}"#),
    ], invoices: [invoice(#"{"id":"frac","amount":1234.555}"#)])
    expectEqual(noTimer, WidgetSnapshot.decode(json: fixtureF3)!, "projection (next job, no timer) equals fixture F3")

    // selectNextJob vectors (widgetBridge.test.js).
    func next(_ jobs: [Canonical.Job]) -> String? {
        NativeWidgetSnapshotProjection.nextJob(jobs: jobs, now: now, calendar: phoenix)?.id
    }
    expectEqual(next([
        job(#"{"id":"tomorrow","scheduledDate":"2026-08-04","scheduledStartTime":"08:00"}"#),
        job(#"{"id":"today-pm","scheduledDate":"2026-08-03","scheduledStartTime":"14:00"}"#),
        job(#"{"id":"today-am","scheduledDate":"2026-08-03","scheduledStartTime":"09:00"}"#),
    ]), "today-am", "earliest upcoming job by date, then start time")
    expectEqual(next([job(#"{"id":"current","scheduledDate":"2026-08-03","scheduledStartTime":"09:00"}"#)]),
                "current", "today's job stays next after its start time passes")
    expectEqual(next([
        job(#"{"id":"no-time","scheduledDate":"2026-08-03","scheduledStartTime":null}"#),
        job(#"{"id":"timed","scheduledDate":"2026-08-03","scheduledStartTime":"15:00"}"#),
    ]), "timed", "same-day jobs without a start time sort after timed ones")
    expect(next([
        job(#"{"id":"yesterday","scheduledDate":"2026-08-02","scheduledStartTime":"08:00"}"#),
        job(#"{"id":"archived","scheduledDate":"2026-08-03","archivedAt":"2026-08-01"}"#),
        job(#"{"id":"done","scheduledDate":"2026-08-03","status":"complete"}"#),
        job(#"{"id":"invoiced","scheduledDate":"2026-08-03","status":"invoiced"}"#),
        job(#"{"id":"paid","scheduledDate":"2026-08-03","status":"paid"}"#),
        job(#"{"id":"declined","scheduledDate":"2026-08-03","status":"declined"}"#),
        job(#"{"id":"unscheduled","scheduledDate":null}"#),
    ]) == nil, "skips past dates, archived jobs, done statuses and unscheduled jobs")
    expectEqual(next([job(#"{"id":"lead-job","status":"lead","scheduledDate":"2026-08-05"}"#)]),
                "lead-job", "a lead created with a schedule counts")
    expectEqual(next([
        job(#"{"id":"first","scheduledDate":"2026-08-05"}"#),
        job(#"{"id":"second","scheduledDate":"2026-08-05"}"#),
    ]), "first", "exact ties keep input order (stable sort)")
    expectEqual(next([job(#"{"id":"blank-archive","scheduledDate":"2026-08-05","archivedAt":""}"#)]),
                "blank-archive", "an empty archivedAt is not archived (RN falsy check)")
    let blankTime = NativeWidgetSnapshotProjection.nextJob(
        jobs: [job(#"{"id":"blank-time","scheduledDate":"2026-08-05","scheduledStartTime":""}"#)],
        now: now, calendar: phoenix
    )
    expect(blankTime != nil && blankTime?.scheduledStartTime == nil, "an empty start time projects as nil")
    // FA-039: in Phoenix it is still 2026-08-03 at 19:00Z; a UTC parse would also say 08-03 here,
    // so probe the evening edge where UTC has already rolled to 08-04.
    let evening = ISO8601DateFormatter().date(from: "2026-08-04T05:30:00Z")! // 22:30 on 08-03 in Phoenix
    expectEqual(NativeWidgetSnapshotProjection.nextJob(
        jobs: [job(#"{"id":"tonight","scheduledDate":"2026-08-03","scheduledStartTime":"08:00"}"#)],
        now: evening, calendar: phoenix
    )?.id, "tonight", "today is the LOCAL date (a UTC date would drop today's job after 17:00 in Phoenix)")

    // selectActiveTimer vectors.
    expect(NativeWidgetSnapshotProjection.activeTimer(jobs: [
        job(#"{"timeSessions":[{"start":"2026-08-03T08:00:00.000Z","end":"2026-08-03T10:00:00.000Z"}]}"#),
        job(#"{"id":"j2","timeSessions":[]}"#),
        job(#"{"id":"j3"}"#),
    ]) == nil, "no running session → nil timer")
    expectEqual(NativeWidgetSnapshotProjection.activeTimer(jobs: [
        job(#"{"id":"older","timeSessions":[{"start":"2026-08-03T08:00:00.000Z"}]}"#),
        job(#"{"id":"newer","timeSessions":[{"start":"2026-08-03T11:00:00.000Z"}]}"#),
    ])?.jobId, "newer", "two running sessions: the latest clock-in wins")
    expectEqual(NativeWidgetSnapshotProjection.activeTimer(jobs: [
        job(#"{"id":"archived-running","archivedAt":"2026-08-02","timeSessions":[{"start":"2026-08-03T11:00:00.000Z"}]}"#),
    ])?.jobId, "archived-running", "an archived job's running clock is never hidden (RN parity)")
}

// MARK: - 4. outstandingTotal is the 10.01 value (§2.2)

private func testOutstandingTotalFromBusinessSnapshot() {
    let rollup = business(invoices: rnOutstandingInvoices)
    expectEqual(rollup.outstandingTotal, 160, "sanity: 10.01 outstanding on the RN fixture is 160")
    expectEqual(project([], invoices: rnOutstandingInvoices).outstandingTotal, 160,
                "projection outstandingTotal equals the 10.01 snapshot value (160)")

    let fractional = business(invoices: [
        invoice(#"{"id":"a","amount":1000.005}"#),
        invoice(#"{"id":"b","amount":234.55,"payments":[{"id":"p","amount":0.001,"date":"2026-08-01","method":"cash"}]}"#),
    ])
    let expected = Double(NSDecimalNumber(decimal: FinancialDecimal.cents(fractional.outstandingTotal)).stringValue)!
    expectEqual(NativeWidgetSnapshotProjection.outstandingTotal(fractional), expected,
                "outstandingTotal = FinancialDecimal.cents(NativeBusinessSnapshot.outstandingTotal)")
    expectEqual(NativeWidgetSnapshotProjection.outstandingTotal(fractional), 1234.55,
                "dollars rounded to 2 dp (1234.554 → 1234.55)")
}

// MARK: - 5. ownerTag (§2.3)

private func testOwnerTag() {
    // printf 'tradeready.widget.owner.v1:bind-11.01' | shasum -a 256
    expectEqual(NativeWidgetOwnerTag.make(binding: "bind-11.01"),
                "1e5d7fb08a5be400f0b4515415ee7a0cc66d76a13b46baf11bc2df299128e19f",
                "ownerTag = lowercase hex SHA-256 of the prefixed binding")
    let tag = NativeWidgetOwnerTag.make(binding: "bind-11.01")
    expect(tag.count == 64 && tag.allSatisfy { "0123456789abcdef".contains($0) }, "ownerTag is 64 lowercase hex chars")
    expect(!tag.contains("bind"), "the raw binding never appears in the tag")
    expect(NativeWidgetOwnerTag.make(binding: "bind-other") != tag, "different owners get different tags")
}

// MARK: - 6. Stale window (§3.3)

private func testStaleWindow() throws {
    func snapshot(ageSeconds: TimeInterval) -> WidgetSnapshot {
        WidgetSnapshot(updatedAt: WidgetSnapshot.isoTimestamp(now.addingTimeInterval(-ageSeconds)),
                       nextJob: nil, timer: nil, outstandingTotal: 0)
    }
    expect(!snapshot(ageSeconds: 86_399).isStale(now: now), "86,399 s is fresh")
    expect(!snapshot(ageSeconds: 86_400).isStale(now: now), "exactly 86,400 s is fresh")
    expect(snapshot(ageSeconds: 86_401).isStale(now: now), "86,401 s is stale")
    expect(snapshot(ageSeconds: -1).isStale(now: now), "a negative age is stale")
    var garbage = snapshot(ageSeconds: 0)
    garbage.updatedAt = "yesterday"
    expect(garbage.isStale(now: now), "an unparseable updatedAt is stale")

    // A stale stored mirror: re-projection stamps the injected clock, so the
    // new snapshot is fresh even though the records did not change.
    let stale = WidgetSnapshot.decode(json: fixtureF1.replacingOccurrences(
        of: "2026-08-03T19:00:00.000Z", with: "2026-08-02T18:59:59.000Z"))!
    expect(stale.isStale(now: now), "stale fixture (86,401 s old) is stale")
    let refreshed = project([])
    expectEqual(refreshed.updatedAt, "2026-08-03T19:00:00.000Z", "re-projection stamps updatedAt from the injected clock")
    expect(!refreshed.isStale(now: now), "the re-projected snapshot is fresh")
    expect(refreshed.hasSameContent(as: stale), "stale and refreshed snapshots differ only in updatedAt")
}

// MARK: - 7. Writer (§3.1, §4.2)

private func testWriter() throws {
    let group = TempAppGroup("writer")
    defer { group.cleanUp() }
    let reloader = RecordingReloader()
    let mirror = group.mirror(reloader)
    let projection = project([job(#"{"id":"j9","scheduledDate":"2026-08-04","scheduledStartTime":"10:30"}"#)])

    // Signed out: a no-op, never a clear.
    group.defaults.set("sentinel", forKey: WidgetAppGroup.snapshotKey)
    expectEqual(mirror.write(projection: projection, ownerBinding: nil, isCurrentOwner: { _ in true }, force: true, now: now),
                .skippedNoOwner, "no owner binding → skippedNoOwner")
    expectEqual(group.storedJSON, "sentinel", "a gated-off write neither writes nor clears")
    expectEqual(reloader.count, 0, "a gated-off write does not reload timelines")

    // Owner mismatch re-checked INSIDE the lock.
    var checkedOwners: [String] = []
    expectEqual(mirror.write(projection: projection, ownerBinding: "bind-a",
                             isCurrentOwner: { checkedOwners.append($0); return false }, force: true, now: now),
                .skippedOwnerChanged, "owner mismatch under the lock → skippedOwnerChanged")
    expectEqual(checkedOwners, ["bind-a"], "the in-lock re-check receives the binding being written")
    expectEqual(group.storedJSON, "sentinel", "an owner-mismatched write leaves the suite untouched")
    expectEqual(reloader.count, 0, "an owner-mismatched write does not reload")

    // Success.
    expectEqual(mirror.write(projection: projection, ownerBinding: "bind-11.01", isCurrentOwner: { $0 == "bind-11.01" },
                             force: true, now: now), .written, "exact owner → written")
    expectEqual(group.stored?.ownerTag, NativeWidgetOwnerTag.make(binding: "bind-11.01"), "the writer stamps ownerTag")
    expectEqual(group.stored?.nextJob?.id, "j9", "the written snapshot carries the projection")
    expect(rnDecode(group.storedJSON ?? "") != nil, "the stored JSON decodes with RN's BridgeSnapshot")
    expectEqual(reloader.count, 1, "a write reloads timelines once")

    // Non-forced write of unchanged, fresh content is skipped; forced is not.
    let later = now.addingTimeInterval(60)
    let sameLater = NativeWidgetSnapshotProjection.project(
        jobs: [job(#"{"id":"j9","scheduledDate":"2026-08-04","scheduledStartTime":"10:30"}"#)],
        business: business(invoices: []), now: later, calendar: phoenix)
    expectEqual(mirror.write(projection: sameLater, ownerBinding: "bind-11.01", isCurrentOwner: { _ in true },
                             force: false, now: later), .unchanged, "unchanged fresh content (non-forced) → unchanged")
    expectEqual(reloader.count, 1, "an unchanged write does not reload")
    expectEqual(group.stored?.updatedAt, "2026-08-03T19:00:00.000Z", "an unchanged write keeps the stored copy")
    expectEqual(mirror.write(projection: sameLater, ownerBinding: "bind-11.01", isCurrentOwner: { _ in true },
                             force: true, now: later), .written, "a forced write refreshes updatedAt")
    expectEqual(group.stored?.updatedAt, "2026-08-03T19:01:00.000Z", "forced write stored the new updatedAt")

    // Non-forced write of unchanged content whose stored copy has aged: rewritten.
    let muchLater = later.addingTimeInterval(NativeWidgetMirror.unchangedRefreshInterval)
    let sameMuchLater = NativeWidgetSnapshotProjection.project(
        jobs: [job(#"{"id":"j9","scheduledDate":"2026-08-04","scheduledStartTime":"10:30"}"#)],
        business: business(invoices: []), now: muchLater, calendar: phoenix)
    expectEqual(mirror.write(projection: sameMuchLater, ownerBinding: "bind-11.01", isCurrentOwner: { _ in true },
                             force: false, now: muchLater), .written,
                "an aged mirror is rewritten even when nothing else changed (never drifts stale)")

    // A different owner's content is never considered unchanged.
    expectEqual(mirror.write(projection: sameMuchLater, ownerBinding: "bind-other", isCurrentOwner: { _ in true },
                             force: false, now: muchLater), .written, "a new owner tag always rewrites")
    expectEqual(group.stored?.ownerTag, NativeWidgetOwnerTag.make(binding: "bind-other"), "the new owner's tag is stored")

    // Unavailable container.
    let unavailable = NativeWidgetMirror(defaults: nil, lockFile: group.lockFile, reloader: reloader)
    expectEqual(unavailable.write(projection: projection, ownerBinding: "bind-11.01", isCurrentOwner: { _ in true },
                                  force: true, now: now), .unavailable, "no App Group suite → unavailable")
    let noLock = NativeWidgetMirror(defaults: group.defaults, lockFile: nil, reloader: reloader)
    expectEqual(noLock.write(projection: projection, ownerBinding: "bind-11.01", isCurrentOwner: { _ in true },
                             force: true, now: now), .unavailable, "no container lock file → unavailable")
}

// MARK: - 8. The writer holds the lock (§4.2)

private func testWriterHoldsLock() throws {
    let group = TempAppGroup("lock")
    defer { group.cleanUp() }
    let reloader = RecordingReloader()
    let mirror = group.mirror(reloader)
    let projection = project([job(#"{"id":"j9","scheduledDate":"2026-08-04"}"#)])

    // (a) An extension holds the lock and appends an action. The writer must
    // wait for the release and must not clobber the extension's write.
    let held = holdLock(at: group.lockFile)
    let writerDone = DispatchSemaphore(value: 0)
    let finishedWhileHeld = LockedFlag(false)
    let holderReleased = LockedFlag(false)
    let outcomeBox = LockedFlag(false)
    DispatchQueue.global().async {
        let outcome = mirror.write(projection: projection, ownerBinding: "bind-11.01",
                                   isCurrentOwner: { _ in true }, force: true, now: now)
        finishedWhileHeld.set(!holderReleased.get())
        outcomeBox.set(outcome == .written)
        writerDone.signal()
    }
    expect(writerDone.wait(timeout: .now() + 0.4) == .timedOut, "the writer blocks while another descriptor holds the lock")
    expect(group.storedJSON == nil, "nothing is written while the lock is held elsewhere")
    group.defaults.set(#"[{"id":"a1","type":"timer_stop","at":"2026-08-03T19:00:00.000Z"}]"#, forKey: WidgetAppGroup.actionsKey)
    holderReleased.set(true)
    releaseLock(held)
    expect(writerDone.wait(timeout: .now() + 5) == .success, "the writer proceeds once the lock is released")
    expect(!finishedWhileHeld.get(), "the writer never completed while the lock was held")
    expect(outcomeBox.get(), "the writer then writes")
    expectEqual(group.defaults.string(forKey: WidgetAppGroup.actionsKey),
                #"[{"id":"a1","type":"timer_stop","at":"2026-08-03T19:00:00.000Z"}]"#,
                "the extension's concurrent queue write survives the mirror write")
    expectEqual(group.stored?.nextJob?.id, "j9", "the mirror write landed after the release")

    // (b) Scrub race: a sign-out scrub holds the lock, wipes the suite and
    // tears the owner down while a write is waiting. The waiting writer
    // re-checks the owner inside the lock and never re-populates the suite.
    let ownerIsLive = LockedFlag(true)
    let scrubHeld = holdLock(at: group.lockFile)
    let raceDone = DispatchSemaphore(value: 0)
    let raceOutcome = LockedFlag(false)
    DispatchQueue.global().async {
        let outcome = mirror.write(projection: projection, ownerBinding: "bind-11.01",
                                   isCurrentOwner: { _ in ownerIsLive.get() }, force: true, now: now)
        raceOutcome.set(outcome == .skippedOwnerChanged)
        raceDone.signal()
    }
    expect(raceDone.wait(timeout: .now() + 0.3) == .timedOut, "the racing writer waits behind the scrub")
    group.defaults.removePersistentDomain(forName: group.suiteName)
    ownerIsLive.set(false)
    releaseLock(scrubHeld)
    expect(raceDone.wait(timeout: .now() + 5) == .success, "the racing writer finishes after the scrub")
    expect(raceOutcome.get(), "the racing writer sees the owner change under the lock → skippedOwnerChanged")
    expect(WidgetAppGroup.accountKeys.allSatisfy { group.defaults.object(forKey: $0) == nil },
           "the scrubbed suite stays empty (no re-population)")
}

// MARK: - 9. Seam observer overload (§3.2)

@MainActor
private func testPublisherCommitObserver() async {
    var owner: String? = "bind-11.01"
    let publisher = NativeDerivedStatePublisher<Canonical.Snapshot, NativeBusinessSnapshot>(
        notifySynchronize: { _ in },
        makeSnapshot: { canonical, date in
            NativeBusinessSnapshotEngine.make(
                invoices: canonical.payload.invoices ?? [], jobs: canonical.payload.jobs ?? [],
                customers: [], expenses: [], trips: [], values: NativeTaxSettingsValues(),
                mileageRate: 0.7, now: date
            )
        },
        ownerBinding: { owner },
        now: { now }
    )
    var legacy: [NativeBusinessSnapshot] = []
    var commits: [(jobs: [String], total: Decimal, binding: String)] = []
    publisher.register { legacy.append($0) }
    struct Boom: Error {}
    publisher.register(committed: { _, _, _ in throw Boom() })
    let token = publisher.register(committed: { canonical, output, binding in
        commits.append(((canonical.payload.jobs ?? []).map(\.id), output.outstandingTotal, binding))
    })

    let canonical = Canonical.Snapshot(payload: Canonical.SnapshotPayload(
        invoices: rnOutstandingInvoices, jobs: [job(#"{"id":"committed-job"}"#)]
    ))
    await publisher.publish(canonical: canonical, expectedOwnerBinding: "bind-11.01")
    expectEqual(commits.count, 1, "a commit observer fires once per committed publish")
    expectEqual(commits.first?.jobs, ["committed-job"], "it receives the committed canonical input")
    expectEqual(commits.first?.total, 160, "it receives the output built from that input")
    expectEqual(commits.first?.binding, "bind-11.01", "it receives the verified expectedOwnerBinding")
    expectEqual(legacy.count, 1, "existing (Output) observers are unchanged, despite a throwing commit observer")

    await publisher.publish(canonical: canonical, expectedOwnerBinding: "someone-else")
    expectEqual(commits.count, 1, "an owner-mismatched publish never reaches a commit observer")

    owner = nil
    await publisher.publish(canonical: canonical, expectedOwnerBinding: "bind-11.01")
    expectEqual(commits.count, 1, "a signed-out publish never reaches a commit observer")

    owner = "bind-11.01"
    publisher.reset()
    await publisher.publish(canonical: canonical, expectedOwnerBinding: "bind-11.01")
    expectEqual(commits.count, 2, "commit observers survive the account-boundary reset()")

    publisher.unregister(token)
    await publisher.publish(canonical: canonical, expectedOwnerBinding: "bind-11.01")
    expectEqual(commits.count, 2, "unregister removes a commit observer")
    expectEqual(legacy.count, 3, "unregistering a commit observer leaves Output observers registered")
}

// MARK: - 10. AppStore wiring: triggers, owner gate, seam, sign-out

@MainActor
private func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<5 { await Task.yield() }
}

@MainActor
private func makeStore(
    _ label: String,
    jobs: [Canonical.Job],
    group: TempAppGroup,
    reloader: RecordingReloader,
    subscription: SubscriptionStub? = nil
) throws -> AppStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-1101-store-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("store.json")
    try Canonical.SnapshotRepository(primaryURL: url).save(
        Canonical.Snapshot(payload: Canonical.SnapshotPayload(invoices: rnOutstandingInvoices, jobs: jobs))
    )
    return AppStore(
        fileURL: url,
        seedIfMissing: false,
        appGroupAccountScrubber: group.scrubber,
        subscriptionService: subscription ?? SubscriptionStub(),
        widgetTimelineReloader: reloader,
        secureSettingsStore: hostTestSecureSettingsStore()
    )
}

@MainActor
private func testAppStoreWiring() async throws {
    let group = TempAppGroup("store")
    defer { group.cleanUp() }
    let reloader = RecordingReloader()
    let store = try makeStore("wiring", jobs: [
        job(#"{"id":"future","scheduledDate":"2099-01-01","scheduledStartTime":"08:00"}"#),
    ], group: group, reloader: reloader)

    // Not installed: nothing touches the suite.
    expect(store.refreshWidgetMirror(force: true) == nil, "no installed mirror → refresh is a no-op")

    // Installed while signed out: the owner gate is closed.
    store.installWidgetMirror(group.mirror(reloader))
    await settle()
    expect(store.widgetMirrorOwnerBinding == nil, "signed out → no widget owner binding")
    expect(group.storedJSON == nil, "installing while signed out writes nothing")
    expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "signed out → skippedNoOwner")

    // Exact owner (the §2.5 predicate opens): the gate change triggers a write.
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-11.01", binding: "bind-11.01")
    expectEqual(store.widgetMirrorOwnerBinding, "bind-11.01", "the widget owner is derivedStatePublishBinding")
    expectEqual(store.widgetMirrorOwnerBinding, store.derivedStatePublishBinding, "one owner predicate (C22)")
    await settle()
    expectEqual(group.stored?.ownerTag, NativeWidgetOwnerTag.make(binding: "bind-11.01"),
                "the sign-in gate change mirrors a snapshot tagged for the owner")
    expectEqual(group.stored?.nextJob?.id, "future", "the mirrored snapshot projects the live canonical jobs")
    expectEqual(group.stored?.outstandingTotal, 160, "the mirrored total is the 10.01 value")

    // Canonical-write trigger: a clock-in commit is mirrored (after the save).
    let beforeClockIn = reloader.count
    expect(store.clockIn(jobID: "future", on: now), "sanity: clock-in commits")
    expect(group.stored?.timer == nil, "the canonical-write mirror is deferred until after the commit turn")
    await settle()
    expectEqual(group.stored?.timer?.jobId, "future", "a committed clock-in is mirrored (timer)")
    expect(reloader.count > beforeClockIn, "the canonical-write mirror reloads timelines")

    // Owner cleared: refresh is a no-op, never a clear.
    let snapshotBeforeClear = group.storedJSON
    store.scheduleBookingTestClearOwner()
    await settle()
    expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "cleared owner → skippedNoOwner")
    expectEqual(group.storedJSON, snapshotBeforeClear, "a gated-off refresh leaves the suite for the scrubber")

    // Seam observer (trigger 3): writes the COMMITTED canonical input, tagged
    // for the publish's expectedOwnerBinding.
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-11.01", binding: "bind-11.01")
    await settle()
    group.defaults.removeObject(forKey: WidgetAppGroup.snapshotKey)
    let committed = Canonical.Snapshot(payload: Canonical.SnapshotPayload(
        invoices: [], jobs: [job(#"{"id":"from-seam","scheduledDate":"2099-02-02"}"#)]
    ))
    await store.derivedStatePublisher.publish(canonical: committed, expectedOwnerBinding: "bind-11.01")
    expectEqual(group.stored?.nextJob?.id, "from-seam", "the seam observer writes after a committed publish, from the committed input")
    expectEqual(store.lastWidgetSeamSource, .delivered, "a direct publish (no local write since capture) projects the delivered canonical")
    expectEqual(group.stored?.outstandingTotal, 0, "the seam write uses the publish's business snapshot")
    expectEqual(group.stored?.ownerTag, NativeWidgetOwnerTag.make(binding: "bind-11.01"), "the seam write is tagged for expectedOwnerBinding")

    group.defaults.removeObject(forKey: WidgetAppGroup.snapshotKey)
    await store.derivedStatePublisher.publish(canonical: committed, expectedOwnerBinding: "someone-else")
    expect(group.storedJSON == nil, "an owner-mismatched publish never writes the mirror")

    // Foreground trigger (forced; refreshes updatedAt).
    expectEqual(store.refreshWidgetMirror(force: true, now: now), .written, "a forced refresh writes for the exact owner")
    expectEqual(group.stored?.updatedAt, "2026-08-03T19:00:00.000Z", "the forced refresh stamps the injected clock")
}

/// A fake `notifySynchronize` that suspends until the test opens it.
@MainActor
private final class SyncGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        continuation?.resume()
        continuation = nil
    }
}

/// Fix round 1 (contract §3.2 amendment): the seam projects the NEWEST
/// canonical for the delivered owner — never an older canonical over a newer
/// local write — and seam writes are non-forced (deduped).
@MainActor
private func testSeamProjectsNewestCanonical() async throws {
    let group = TempAppGroup("seam-newest")
    defer { group.cleanUp() }
    let reloader = RecordingReloader()
    let store = try makeStore("seam-newest", jobs: [
        job(#"{"id":"future","scheduledDate":"2099-01-01","scheduledStartTime":"08:00"}"#),
    ], group: group, reloader: reloader)
    store.installWidgetMirror(group.mirror(reloader))
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-11.01", binding: "bind-11.01")
    await settle()
    expect(group.stored?.timer == nil, "sanity: no timer mirrored before the clock-in")

    // (a) Nothing moved on: the production publish path projects the
    // delivered canonical and writes.
    group.defaults.removeObject(forKey: WidgetAppGroup.snapshotKey)
    let reloadsBeforeDelivered = reloader.count
    await store.publishDerivedState(expectedOwnerBinding: "bind-11.01")
    expectEqual(store.lastWidgetSeamSource, .delivered, "no local write during the publish → the delivered canonical is projected")
    expectEqual(group.stored?.nextJob?.id, "future", "the delivered-canonical seam write lands")
    expectEqual(group.stored?.ownerTag, NativeWidgetOwnerTag.make(binding: "bind-11.01"), "the delivered write is tagged for the owner")
    expectEqual(reloader.count, reloadsBeforeDelivered + 1, "the delivered-canonical seam write reloads once")

    // (b) A local clock-in lands while the publish is suspended in
    // notifySynchronize. Trigger 1 mirrors the timer; the resumed seam
    // delivery must not roll it back to the captured pre-edit canonical.
    let gate = SyncGate()
    store.notificationSynchronizeHook = { _ in await gate.wait() }
    defer { store.notificationSynchronizeHook = nil }
    let publish = Task { @MainActor in
        await store.publishDerivedState(expectedOwnerBinding: "bind-11.01")
    }
    await settle()
    expect(gate.entered, "sanity: the publish is suspended in notifySynchronize")
    expect(store.clockIn(jobID: "future", on: now), "sanity: clock-in commits during the suspended publish")
    await settle()
    expectEqual(group.stored?.timer?.jobId, "future", "trigger 1 mirrors the clock-in while the publish is suspended")
    gate.open()
    await publish.value
    await settle()
    expectEqual(store.lastWidgetSeamSource, .live, "the live snapshot moved on → the seam projects the live snapshot")
    expectEqual(group.stored?.timer?.jobId, "future", "the resumed seam write never drops the newer local timer")
    expectEqual(group.stored?.ownerTag, NativeWidgetOwnerTag.make(binding: "bind-11.01"), "the live projection is tagged for expectedOwnerBinding")

    // (c) Non-forced seam: an unchanged, fresh mirror is not rewritten.
    store.notificationSynchronizeHook = nil
    let storedBefore = group.storedJSON
    let reloadsBeforeDedupe = reloader.count
    await store.publishDerivedState(expectedOwnerBinding: "bind-11.01")
    expectEqual(store.lastWidgetSeamSource, .delivered, "sanity: nothing moved on for the follow-up publish")
    expectEqual(group.storedJSON, storedBefore, "a seam delivery of unchanged content leaves the mirror as is")
    expectEqual(reloader.count, reloadsBeforeDedupe, "a seam delivery of unchanged content does not reload timelines")

    // (d) Owner mismatch is still refused on the live path.
    let beforeMismatch = group.storedJSON
    await store.publishDerivedState(expectedOwnerBinding: "someone-else")
    expectEqual(group.storedJSON, beforeMismatch, "a mismatched publish never writes, live or delivered")
}

@MainActor
private func testSignOutScrubsAndReloads() async throws {
    let group = TempAppGroup("signout")
    defer { group.cleanUp() }
    let reloader = RecordingReloader()
    let subscription = SubscriptionStub()
    let store = try makeStore("signout", jobs: [
        job(#"{"id":"future","scheduledDate":"2099-01-01"}"#),
    ], group: group, reloader: reloader, subscription: subscription)
    store.installWidgetMirror(group.mirror(reloader))
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-11.01", binding: "bind-11.01")
    await settle()
    expect(group.stored?.ownerTag != nil, "sanity: the owner's snapshot is mirrored before sign-out")
    group.defaults.set("[]", forKey: WidgetAppGroup.actionsKey)

    // Queue a canonical-write mirror, then sign out before it runs: the
    // queued write must not re-populate the scrubbed suite.
    expect(store.clockIn(jobID: "future", on: now), "sanity: clock-in commits right before sign-out")
    let reloadsBefore = reloader.count

    // Post-scrub window: the suite is already wiped but the owner binding
    // `O` is still set and memory still holds the old account's records.
    // A foreground refresh or a seam publish landing here must not write.
    var windowRefresh: NativeWidgetMirrorOutcome?
    var windowSuiteWasEmpty = false
    var windowSnapshotAfterPublish: String?
    subscription.onLogOut = { [weak store] in
        guard let store else { return }
        windowSuiteWasEmpty = group.storedJSON == nil
        windowRefresh = store.refreshWidgetMirror(force: true)
        await store.derivedStatePublisher.publish(
            canonical: Canonical.Snapshot(payload: Canonical.SnapshotPayload(
                invoices: [], jobs: [job(#"{"id":"late-seam","scheduledDate":"2099-03-03"}"#)]
            )),
            expectedOwnerBinding: "bind-11.01"
        )
        await settle()
        windowSnapshotAfterPublish = group.storedJSON
    }
    try await store.signOut(revokeRemote: false)
    await settle()
    expect(windowSuiteWasEmpty, "sanity: the post-scrub window starts with a wiped suite")
    expectEqual(windowRefresh, .skippedNoOwner, "a refresh between the scrub and owner teardown is gated off")
    expect(windowSnapshotAfterPublish == nil,
           "neither a refresh, a seam publish nor a queued canonical-write mirror repopulates the suite mid-sign-out")
    expect(WidgetAppGroup.accountKeys.allSatisfy { group.defaults.object(forKey: $0) == nil },
           "sign-out wipes every account key from the suite (scrubber is the wipe authority)")
    expect(reloader.count > reloadsBefore, "sign-out reloads widget timelines after the wipe")
    expect(store.widgetMirrorOwnerBinding == nil, "after sign-out the owner gate is closed")
    expectEqual(store.refreshWidgetMirror(force: true), .skippedNoOwner, "a post-sign-out refresh is a no-op")
    expect(group.storedJSON == nil, "nothing re-populates the suite after sign-out")
}

// MARK: - Main

@main
struct WidgetSnapshotTests {
    @MainActor
    static func main() async throws {
        testFixtureDecode()
        try testEncoderShape()
        try testProjection()
        testOutstandingTotalFromBusinessSnapshot()
        testOwnerTag()
        try testStaleWindow()
        try testWriter()
        try testWriterHoldsLock()
        await testPublisherCommitObserver()
        try await testAppStoreWiring()
        try await testSeamProjectsNewestCanonical()
        try await testSignOutScrubsAndReloads()

        if failures > 0 {
            print("Widget snapshot tests: \(failures) failure(s)")
            exit(1)
        }
        print("Widget snapshot tests passed")
    }
}
