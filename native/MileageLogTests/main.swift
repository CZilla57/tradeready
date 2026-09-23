import Foundation

// Mileage log presentation tests (task 9.11, requirements T1, T2 rates).
//
// The mileage math itself is covered by MileageTests (9.03). These vectors cover
// what 9.11 owns, ported from `screens/MileageLogScreen.tsx` and
// `screens/AddTripScreen.tsx`: the period row list and its ordering, the summary
// card and rate copy, the endpoint chips, the RN alert copy and order, the live
// distance line, and the editor's draft seeding.

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

private let decoder = JSONDecoder()

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func trip(_ overrides: String = "") -> Canonical.Trip {
    let base = """
    {"id":"t1","date":"2026-03-10","odometerStart":1000,"odometerEnd":1012.4,"miles":12.4,
     "fromLabel":"Home / Shop","toLabel":"Home / Shop","purpose":"","createdAt":"2026-03-10"}
    """
    return try! decoder.decode(Canonical.Trip.self, from: Data(merge(base, overrides).utf8))
}

private func job(_ overrides: String = "") -> Canonical.Job {
    let base = """
    {"id":"j1","customerId":"c1","customerName":"Alice","title":"Repipe","description":"",
     "status":"approved","address":"","estimateTotal":1000,"laborHours":4,"laborRate":100,
     "materials":[],"materialMarkup":0,"overhead":15,"margin":20,"notes":"","createdAt":"2026-03-01"}
    """
    return try! decoder.decode(Canonical.Job.self, from: Data(merge(base, overrides).utf8))
}

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

private let march10 = NativeCashBasis.parseLocalDate("2026-03-10")!

// MARK: - Rows

private func testRows() {
    let year = NativeCashBasis.range(for: "this_year", now: march10)
    let trips = [
        trip(#"{"id":"a","date":"2026-03-02","miles":5,"purpose":"Supply run"}"#),
        trip(#"{"id":"b","date":"2026-03-20","miles":12.4,"fromLabel":"Home / Shop","toLabel":"Alice"}"#),
        trip(#"{"id":"c","date":"2025-12-30","miles":9,"purpose":"Last year"}"#),
    ]
    let rows = NativeMileageLog.rows(trips: trips, start: year.start, end: year.end)
    expectEqual(rows.map(\.id), ["b", "a"], "the log lists the window newest-first by date string")
    expectEqual(rows[0].routeText, "Home / Shop → Alice", "route copy")
    expectEqual(rows[0].dateText, "2026-03-20", "the stored date renders verbatim")
    expectEqual(rows[0].milesText, "12.4 mi", "miles copy is one decimal + mi")
    expectEqual(rows[0].accessibilityLabel, "Trip Home / Shop to Alice, 2026-03-20, 12.4 mi", "row accessibility label")
    expectEqual(rows[1].purpose, "Supply run", "purpose is carried for the row")

    let month = NativeCashBasis.range(for: "this_month", now: march10)
    let monthRows = NativeMileageLog.rows(trips: trips, start: month.start, end: month.end)
    expectEqual(monthRows.map(\.id), ["b", "a"], "the period chip narrows the list to the month")
    let lastMonth = NativeCashBasis.range(for: "last_month", now: march10)
    expect(
        NativeMileageLog.rows(trips: trips, start: lastMonth.start, end: lastMonth.end).isEmpty,
        "a window with no trips is empty"
    )

    let empty = NativeMileageLog.rows(trips: [], start: year.start, end: year.end)
    expect(empty.isEmpty, "an empty log has no rows")
}

// MARK: - Summary card

private func testSummaryCard() {
    let year = NativeCashBasis.range(for: "this_year", now: march10)
    let twoTrips = [
        trip(#"{"id":"a","date":"2026-03-02","miles":5}"#),
        trip(#"{"id":"b","date":"2026-03-20","miles":7.4}"#),
    ]
    let card = NativeMileageLog.summaryCard(trips: twoTrips, start: year.start, end: year.end, rate: decimal("0.7"))
    expectEqual(card.label, "Estimated deduction", "card label")
    expectEqual(card.deductionText, "$8.68", "deduction is miles × rate to the cent")
    expectEqual(card.subtitle, "12.4 mi · 2 trips · $0.70/mi", "summary subtitle")

    let one = NativeMileageLog.summaryCard(
        trips: [trip(#"{"id":"a","date":"2026-03-02","miles":1}"#)],
        start: year.start, end: year.end, rate: decimal("0.7")
    )
    expectEqual(one.subtitle, "1.0 mi · 1 trip · $0.70/mi", "a single trip is singular")

    let none = NativeMileageLog.summaryCard(trips: [], start: year.start, end: year.end, rate: decimal("0.7"))
    expectEqual(none.subtitle, "0.0 mi · 0 trips · $0.70/mi", "an empty window reports zeroes at the current rate")
    expectEqual(none.deductionText, "$0.00", "an empty window deducts nothing")
}

// MARK: - Endpoint chips

private func testEndpointChips() {
    let chips = NativeMileageLog.endpointChips([
        job(#"{"id":"j1","customerName":"Alice","title":"Repipe"}"#),
        job(#"{"id":"j2","customerName":"","title":"Water heater"}"#),
        job(#"{"id":"j3","customerName":"","title":""}"#),
        job(#"{"id":"j4","customerName":"Bob","title":"Archived","archivedAt":"2026-03-05"}"#),
    ])
    expectEqual(chips.count, 5, "the base plus every job")
    expectEqual(chips[0].label, "Home / Shop", "the base chip comes first")
    expect(chips[0].jobId == nil, "the base chip has no job id")
    expectEqual(chips.map(\.label), ["Home / Shop", "Alice", "Water heater", "Job", "Bob"],
                "labels fall back customerName → title → Job")
    expectEqual(chips[4].jobId, "j4", "an archived job is still offered (RN does not filter this picker)")
    expectEqual(chips[1].jobId, "j1", "chip keeps the exact job id")
}

// MARK: - Validation alerts + distance line

private func testAlertsAndDistance() {
    let invalidDate = NativeMileageLog.validationAlert(.invalidDate)
    expectEqual(invalidDate.title, "Invalid date", "invalid-date title")
    expectEqual(invalidDate.message, "Enter the trip date as YYYY-MM-DD.", "invalid-date copy")
    let missing = NativeMileageLog.validationAlert(.missingReadings)
    expectEqual(missing.title, "Missing readings", "missing-readings title")
    expectEqual(missing.message, "Enter both start and end odometer readings.", "missing-readings copy")
    let below = NativeMileageLog.validationAlert(.endBeforeStart)
    expectEqual(below.title, "Check readings", "end-before-start title")
    expectEqual(
        below.message,
        "End reading must be greater than or equal to the start reading.",
        "end-before-start copy"
    )

    // RN checks the date first, then presence, then ordering.
    var draft = NativeMileageLog.newDraft(now: march10)
    expectEqual(NativeMileage.validationError(draft), .missingReadings, "empty readings block save")
    draft.odometerStartText = "1000"
    draft.odometerEndText = "1012.4"
    expect(NativeMileage.validationError(draft) == nil, "a complete draft saves")
    expectEqual(NativeMileageLog.distanceText(draft), "Trip distance: 12.4 mi", "live distance copy")
    draft.odometerEndText = "999"
    expectEqual(NativeMileageLog.distanceText(draft), "End reading is less than start", "invalid distance copy")
    expectEqual(NativeMileage.validationError(draft), .endBeforeStart, "an end below the start blocks save")
    draft.odometerEndText = "1000"
    expectEqual(NativeMileageLog.distanceText(draft), "Trip distance: 0.0 mi", "equal readings are allowed")
    expect(NativeMileage.validationError(draft) == nil, "equal readings save")
}

// MARK: - Draft seeding

private func testDraftSeeding() {
    let new = NativeMileageLog.newDraft(now: march10)
    expectEqual(new.date, "2026-03-10", "a new trip starts on the local day")
    expectEqual(new.odometerStartText, "", "a new trip has no start reading")
    expectEqual(new.odometerEndText, "", "a new trip has no end reading")
    expectEqual(new.from.label, "Home / Shop", "a new trip starts at the base")
    expectEqual(new.to.label, "Home / Shop", "a new trip ends at the base")
    expectEqual(new.purpose, "", "a new trip has no purpose")

    let existing = trip(#"{"id":"t9","date":"2026-03-04","odometerStart":45210,"odometerEnd":45240.5,"miles":30.5,"fromJobId":"j1","fromLabel":"Alice","toJobId":null,"toLabel":"Home / Shop","purpose":"Parts run"}"#)
    let seeded = NativeMileageLog.draft(from: existing)
    expectEqual(seeded.date, "2026-03-04", "edit seeds the stored date")
    expectEqual(seeded.odometerStartText, "45210", "edit seeds the start reading")
    expectEqual(seeded.odometerEndText, "45240.5", "edit seeds a fractional end reading")
    expectEqual(seeded.from.jobId, "j1", "edit seeds the from job")
    expectEqual(seeded.from.label, "Alice", "edit seeds the from label")
    expect(seeded.to.jobId == nil, "edit seeds an unlinked destination")
    expectEqual(seeded.purpose, "Parts run", "edit seeds the purpose")
    expectEqual(NativeMileageLog.distanceText(seeded), "Trip distance: 30.5 mi", "a seeded trip previews its distance")

    // RN writes `String(0 || '')` → "" and then refuses to save without both
    // readings; native keeps the zero so the trip round-trips (recorded).
    let zeroStart = trip(#"{"id":"t10","date":"2026-03-05","odometerStart":0,"odometerEnd":10,"miles":10}"#)
    expectEqual(NativeMileageLog.readingText(zeroStart.odometerStart), "0", "a zero reading is kept")
    expectEqual(NativeMileageLog.draft(from: zeroStart).odometerStartText, "0", "edit seeds a zero start")
    expectEqual(NativeMileageLog.readingText(decimal("45210.500")), "45210.5", "trailing zeros are trimmed")
}

// MARK: - Run

testRows()
testSummaryCard()
testEndpointChips()
testAlertsAndDistance()
testDraftSeeding()

if failures == 0 {
    print("Mileage log tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}
