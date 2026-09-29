import Foundation

// Mileage / trip domain tests (task 9.03).
//
// Ports __tests__/mileageUtils.test.js and the AddTripScreen save rules
// (validation, mileage preview, createdAt preservation on edit). No canonical
// write occurs here — the projection is asserted, not applied.

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

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func decodeTrip(_ json: String) -> Canonical.Trip {
    try! JSONDecoder().decode(Canonical.Trip.self, from: Data(json.utf8))
}

private func decodeJob(_ json: String) -> Canonical.Job {
    try! JSONDecoder().decode(Canonical.Job.self, from: Data(json.utf8))
}

private func trip(date: String, miles: String) -> Canonical.Trip {
    decodeTrip("""
    {"id":"t-\(date)","date":"\(date)","odometerStart":0,"odometerEnd":0,"miles":\(miles),
     "fromJobId":null,"fromLabel":"Home / Shop","toJobId":null,"toLabel":"Home / Shop",
     "purpose":"","createdAt":"\(date)"}
    """)
}

private func draft(
    date: String = "2026-03-10",
    start: String = "45210",
    end: String = "45240",
    from: NativeTripEndpoint = .home,
    to: NativeTripEndpoint = .home,
    purpose: String = "Drive to job site"
) -> NativeTripDraft {
    NativeTripDraft(
        date: date, odometerStartText: start, odometerEndText: end,
        from: from, to: to, purpose: purpose
    )
}

// MARK: - computeTripMiles / formatMiles (mileageUtils.test.js)

private func testTripMiles() {
    expectEqual(NativeMileage.computeTripMiles(start: 45210, end: 45240), decimal("30"), "end minus start")
    expectEqual(NativeMileage.computeTripMiles(start: 45240, end: 45210), 0, "end < start clamps to zero")
    expectEqual(NativeMileage.computeTripMiles(start: 100, end: 100), 0, "equal readings are zero")
    expectEqual(NativeMileage.computeTripMiles(start: 1, end: decimal("1.05")), decimal("0.1"), "rounds to 0.1")
    expectEqual(NativeMileage.formatMiles(12), "12.0 mi", "formatMiles one decimal + suffix")
    expectEqual(NativeMileage.defaultMileageRate, decimal("0.70"), "default rate 0.70")
    expectEqual(NativeMileage.homeLabel, "Home / Shop", "home label")
}

// MARK: - mileageSummary (mileageUtils.test.js)

private func testMileageSummary() {
    let start = NativeCashBasis.localDate(year: 2026, month: 0, day: 1)
    let end = NativeCashBasis.localDate(year: 2026, month: 11, day: 31, hour: 23, minute: 59, second: 59)
    let trips = [
        trip(date: "2026-03-10", miles: "20"),
        trip(date: "2026-06-01", miles: "30"),
        trip(date: "2025-12-31", miles: "99"),
    ]
    let summary = NativeMileage.summary(trips: trips, start: start, end: end, rate: decimal("0.70"))
    expectEqual(summary.tripCount, 2, "out-of-range trip excluded")
    expectEqual(summary.totalMiles, decimal("50"), "in-range miles summed")
    expectEqual(summary.deduction, decimal("35"), "deduction = miles * rate")

    let empty = NativeMileage.summary(trips: [], start: start, end: end, rate: decimal("0.70"))
    expectEqual(empty.tripCount, 0, "empty window trip count")
    expectEqual(empty.totalMiles, 0, "empty window miles")
    expectEqual(empty.deduction, 0, "empty window deduction")

    // Rounding: 12.34 + 5.66 = 18.00 exactly at 0.1 precision; 0.05 rounds up.
    let rounding = NativeMileage.summary(
        trips: [trip(date: "2026-04-01", miles: "0.05")], start: start, end: end, rate: decimal("0.70")
    )
    expectEqual(rounding.totalMiles, decimal("0.1"), "total miles rounded to 0.1")
    expectEqual(rounding.deduction, decimal("0.07"), "deduction rounded to cents")
}

// MARK: - rate resolution

private func testRateResolution() {
    expectEqual(NativeMileage.effectiveRate(nil), decimal("0.70"), "nil settings use the default rate")

    let settings = try! JSONDecoder().decode(Canonical.Settings.self, from: Data("""
    {"businessName":"B","contactName":"","phone":"","email":"","address":"","trade":"Plumbing",
     "laborRate":85,"materialMarkup":20,"overheadPercent":15,"marginPercent":20,"minimumJobFee":75,
     "travelFeePerMile":0,"emergencyMultiplier":1.5,"paymentNotes":"","provider":"stripe","rules":[],
     "mileageRate":0.67}
    """.utf8))
    expectEqual(NativeMileage.effectiveRate(settings), decimal("0.67"), "user override wins")

    let noRate = try! JSONDecoder().decode(Canonical.Settings.self, from: Data("""
    {"businessName":"B","contactName":"","phone":"","email":"","address":"","trade":"Plumbing",
     "laborRate":85,"materialMarkup":20,"overheadPercent":15,"marginPercent":20,"minimumJobFee":75,
     "travelFeePerMile":0,"emergencyMultiplier":1.5,"paymentNotes":"","provider":"stripe","rules":[]}
    """.utf8))
    expectEqual(NativeMileage.effectiveRate(noRate), decimal("0.70"), "absent mileageRate defaults to 0.70")
}

// MARK: - editor validation (AddTripScreen)

private func testValidation() {
    expect(NativeMileage.validationError(draft()) == nil, "valid draft saves")
    expectEqual(NativeMileage.validationError(draft(date: "")), .invalidDate, "empty date rejected")
    expectEqual(NativeMileage.validationError(draft(date: "03/10/2026")), .invalidDate, "non-ISO date rejected")
    expectEqual(NativeMileage.validationError(draft(date: "2026-02-31")), .invalidDate, "rollover date rejected")
    expectEqual(NativeMileage.validationError(draft(start: "")), .missingReadings, "missing start reading")
    expectEqual(NativeMileage.validationError(draft(end: "  ")), .missingReadings, "blank end reading")
    expectEqual(NativeMileage.validationError(draft(start: "100", end: "99")), .endBeforeStart, "end below start rejected")
    expect(NativeMileage.validationError(draft(start: "100", end: "100")) == nil, "equal readings allowed")
    expect(NativeMileage.validationError(draft(start: "0", end: "5")) == nil, "zero start reading allowed")

    expectEqual(NativeMileage.previewMiles(draft(start: "100", end: "130")), decimal("30"), "preview distance")
    expect(NativeMileage.endBelowStart(draft(start: "100", end: "99")), "endBelowStart flag")
    expect(!NativeMileage.endBelowStart(draft(start: "100", end: "")), "blank end reading is not the invalid flag")
}

// MARK: - record projection (create/edit)

private func testProjection() {
    let job = decodeJob("""
    {"id":"j1","customerId":"c1","customerName":"","title":"Faucet swap","description":"",
     "status":"complete","address":"","estimateTotal":0,"laborHours":0,"laborRate":0,"materials":[],
     "materialMarkup":0,"overhead":0,"margin":0,"notes":"","createdAt":"2026-07-01"}
    """)
    expectEqual(NativeMileage.endpointLabel(for: job), "Faucet swap", "endpoint label falls back to title")

    // Create: generated id + supplied createdAt.
    let createFields = NativeMileage.projectedFields(
        draft: draft(), existing: nil, tripID: "t-new", createdAt: "2026-03-10T17:00:00.000Z"
    )
    expectEqual(createFields["id"], .string("t-new"), "create uses the generated id")
    expectEqual(createFields["createdAt"], .string("2026-03-10T17:00:00.000Z"), "create stamps createdAt")
    expectEqual(createFields["miles"], .number(30), "create derives miles")
    expectEqual(createFields["purpose"], .string("Drive to job site"), "purpose trimmed")

    // Edit: createdAt preserved, endpoints/purpose updated, only owned fields emitted.
    let existing = trip(date: "2026-03-01", miles: "12")
    let editDraft = NativeTripDraft(
        date: "2026-03-11",
        odometerStartText: "200",
        odometerEndText: "260",
        from: .home,
        to: NativeTripEndpoint(jobId: "j1", label: "Faucet swap"),
        purpose: "  Supply run  "
    )
    let editFields = NativeMileage.projectedFields(
        draft: editDraft, existing: existing, tripID: existing.id, createdAt: "2026-03-11T09:00:00.000Z"
    )
    expectEqual(editFields["createdAt"], .string("2026-03-01"), "edit preserves createdAt")
    expectEqual(editFields["id"], .string(existing.id), "edit keeps the id")
    expectEqual(editFields["toJobId"], .string("j1"), "edit sets toJobId")
    expectEqual(editFields["toLabel"], .string("Faucet swap"), "edit sets toLabel")
    expectEqual(editFields["purpose"], .string("Supply run"), "edit trims purpose")
    expectEqual(editFields["miles"], .number(60), "edit recomputes miles")
    expectEqual(editFields.count, 11, "projection emits only the 11 owned fields (unknown fields untouched)")
    expect(!editFields.keys.contains("unknownField"), "projection never invents keys")
}

// MARK: - run

testTripMiles()
testMileageSummary()
testRateResolution()
testValidation()
testProjection()

if failures == 0 {
    print("MileageTests: all checks passed")
} else {
    print("MileageTests: \(failures) failure(s)")
    exit(1)
}
