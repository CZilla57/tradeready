import Foundation

// Phase 9 cross-client qualification (task 9.14).
//
// One canonical fixture is pushed through every Phase 9 surface in a single run:
// the report cards, tax set-aside, mileage deduction, pricebook CRUD + job
// prefill, the three CSV exports, the deterministic accountant ZIP, and the
// import commit/report/undo lifecycle. Each focused runner already covers its own
// task in depth; this suite exists to prove the SEAMS hold together — the numbers
// the cards show are the numbers the exports carry, the CSV the app exports is a
// CSV the app can re-import, and undo strips the batch it created and nothing
// else.

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

private func decode<T: Decodable>(_ json: String) -> T {
    try! decoder.decode(T.self, from: Data(json.utf8))
}

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private let quarterThree = NativeCashBasis.parseLocalDate("2026-08-20")!

// MARK: - The shared fixture

/// One paid invoice with a legacy ledger, one unpaid large invoice, one expense,
/// one trip, one customer, one job with a change order, one pricebook entry.
private enum Fixture {
    static let invoices: [Canonical.Invoice] = [
        decode("""
        {"id":"inv-100","customer":"Alice","number":"INV-100","amount":1000,"due":"2026-08-01",
         "email":"alice@example.com","phone":"555-0100","desc":"Water heater","paid":true,
         "paidAt":"2026-08-05"}
        """),
        decode("""
        {"id":"inv-101","customer":"Bob","number":"INV-101","amount":2500,"due":"2026-08-15",
         "email":"bob@example.com","phone":"555-0101","desc":"Repipe","paid":false}
        """),
    ]

    static let expenses: [Canonical.Expense] = [
        decode("""
        {"id":"exp-1","createdAt":"2026-08-10","description":"Supply House","amount":250.5,
         "category":"materials","date":"2026-08-10","notes":"copper"}
        """),
    ]

    static let trips: [Canonical.Trip] = [
        decode("""
        {"id":"trip-1","date":"2026-08-11","odometerStart":1000,"odometerEnd":1012.4,"miles":12.4,
         "fromLabel":"Home / Shop","toLabel":"Alice","purpose":"Install","createdAt":"2026-08-11"}
        """),
    ]

    static let customers: [Canonical.Customer] = [
        decode(#"{"id":"cust-1","name":"Alice","email":"alice@example.com","phone":"555-0100","address":"1 Main St","notes":"","createdAt":"2026-01-05"}"#),
    ]

    static let jobs: [Canonical.Job] = [
        decode("""
        {"id":"job-1","customerId":"cust-1","customerName":"Alice","title":"Water heater install",
         "description":"Swap tank","status":"complete","address":"1 Main St",
         "estimateTotal":1000,"laborHours":4,"laborRate":100,"materials":[],"materialMarkup":0,
         "overhead":15,"margin":20,"notes":"","createdAt":"2026-07-01"}
        """),
    ]

    static let pricebook: [Canonical.PricebookEntry] = [
        decode("""
        {"id":"pb-1","name":"Water heater swap","description":"Standard 40 gal swap","category":"Plumbing",
         "laborHours":4,"laborRate":95,"materials":[{"id":"m1","name":"Tank","quantity":1,"unitCost":600}],
         "materialMarkup":20,"jobCosts":[{"id":"jc1","label":"Permit","category":"permit","quantity":1,
         "unitCost":120,"markupPercent":0,"markupPolicy":"passthrough","taxable":false,"customerVisible":true}],
         "overhead":15,"margin":20,"estimateTotal":1500,
         "createdAt":"2026-06-01T00:00:00.000Z","updatedAt":"2026-06-01T00:00:00.000Z"}
        """),
    ]
}

private var yearRange: NativeDateRange {
    NativeExportRange.range(for: .thisYear, customStart: quarterThree, customEnd: quarterThree, now: quarterThree)
}

// MARK: - 1. Reports, tax, mileage on the fixture

private func testReportsAndCards() {
    let range = NativeCashBasis.range(for: "this_year", now: quarterThree)
    expectEqual(
        NativeCashBasis.collected(invoices: Fixture.invoices, start: range.start, end: range.end),
        decimal("1000"),
        "cash basis collects the paid invoice only"
    )

    let overview = NativeMoneyOverview.make(
        filter: .thisYear,
        invoices: Fixture.invoices,
        expenses: Fixture.expenses,
        jobs: Fixture.jobs,
        trips: Fixture.trips,
        pricebook: Fixture.pricebook,
        taxValues: NativeTaxSettingsValues(taxIncomeRate: decimal("25"), vehicleDeductionMethod: .mileage),
        mileageRate: decimal("0.7"),
        laborCostRate: nil,
        now: quarterThree
    )
    expectEqual(overview.summary.income, decimal("1000"), "summary card income")
    expectEqual(overview.summary.expenses, decimal("250.5"), "summary card expenses")
    expectEqual(overview.summary.netProfit, decimal("749.5"), "summary card net profit")
    expectEqual(overview.state, .content, "the fixture renders the section stack")

    // The mileage card and the mileage log must agree on the same window.
    let logCard = NativeMileageLog.summaryCard(
        trips: Fixture.trips, start: range.start, end: range.end, rate: decimal("0.7")
    )
    expectEqual(logCard.deductionText, overview.mileage.deductionText, "log card and overview card agree")
    expectEqual(logCard.subtitle, overview.mileage.subtitle, "log card and overview subtitle agree")
    expectEqual(logCard.deductionText, "$8.68", "12.4 mi at $0.70")

    // The tax card reads the same invoices/expenses/trips.
    let tax = NativeMoneyTaxCard.make(
        invoices: Fixture.invoices,
        expenses: Fixture.expenses,
        trips: Fixture.trips,
        values: NativeTaxSettingsValues(taxIncomeRate: decimal("25"), vehicleDeductionMethod: .mileage),
        mileageRate: decimal("0.7"),
        now: quarterThree
    )
    expect(!tax.breakdown.needsVehicleChoice, "an elected method clears the vehicle prompt")
    expect(tax.breakdown.incomeRateSet, "a set income rate is reported as set")
    expect(tax.reserveText.hasPrefix("$"), "the reserve is a money string")
    expect(tax.ytdLabel.contains("for the year so far"), "the YTD line states its scope")
}

// MARK: - 2. Pricebook CRUD + prefill

private func testPricebookSeam() {
    // The pricebook card's count is the same collection the export screen reads.
    let card = NativeMoneyPricebookCard.make(entries: Fixture.pricebook)
    expectEqual(card.countText, "1 service", "pricebook card count")
    expectEqual(card.categoryText, "1 category", "pricebook card category count")

    // Create → the engine's total; edit → createdAt and unknowns survive.
    let draft = NativePricebookEntryDraft(
        name: "Panel upgrade",
        description: nil,
        category: "Electrical",
        laborHours: decimal("2"),
        laborBreakdown: nil,
        laborRate: decimal("100"),
        materials: [],
        materialMarkup: decimal("0"),
        jobCosts: [],
        overhead: decimal("0"),
        margin: decimal("0")
    )
    let created = NativePricebook.createFields(draft: draft, id: "pb-2", now: "2026-08-20T00:00:00.000Z")
    guard let record = NativePricebook.decode(Canonical.PricebookEntry.self, created) else {
        expect(false, "a created pricebook entry decodes")
        return
    }
    expectEqual(record.estimateTotal, decimal("200"), "the stored total is the engine's")
    expectEqual(record.createdAt, "2026-08-20T00:00:00.000Z", "create stamps createdAt")

    var withUnknown = created
    withUnknown["futureField"] = .string("kept")
    let edited = NativePricebook.appliedFields(
        draft: NativePricebookEntryDraft(
            name: "Panel upgrade", description: "200A", category: "Electrical",
            laborHours: decimal("3"), laborBreakdown: nil, laborRate: decimal("100"),
            materials: [], materialMarkup: decimal("0"), jobCosts: [],
            overhead: decimal("0"), margin: decimal("0")
        ),
        to: withUnknown,
        now: "2026-08-21T00:00:00.000Z"
    )
    expectEqual(edited["futureField"], .string("kept"), "an edit preserves unknown fields")
    expectEqual(edited["createdAt"], .string("2026-08-20T00:00:00.000Z"), "an edit preserves createdAt")

    // Prefill onto a job: only the entry's pricing fields move.
    let jobDraft = NativeJobPricingDraft(job: Fixture.jobs[0], settings: nil)
    let prefilled = NativePricebookPrefill.applying(
        NativePricebook.jobPrefill(from: Fixture.pricebook[0]), to: jobDraft
    )
    expectEqual(prefilled.laborHours, decimal("4"), "prefill moves labor hours")
    expectEqual(prefilled.materials.first?.name, "Tank", "prefill moves materials")
    expectEqual(prefilled.materials.first?.unitCost, decimal("600"), "prefill keeps the material cost")
    expectEqual(prefilled.jobCosts.first?.markupPolicy, "passthrough", "prefill keeps the direct-cost policy")
    expectEqual(prefilled.minimumJobFee, jobDraft.minimumJobFee, "prefill keeps the job's minimum fee")
}

// MARK: - 3. CSV bytes

private func testCSVSeam() {
    let range = yearRange
    let income = NativeCSVExport.buildIncomeCsv(invoices: Fixture.invoices, start: range.start, end: range.end)
    let expenses = NativeCSVExport.buildExpensesCsv(expenses: Fixture.expenses, start: range.start, end: range.end)
    let mileage = NativeCSVExport.buildTripsCsv(trips: Fixture.trips, start: range.start, end: range.end)

    expect(income.contains("Alice") && income.contains("1000"), "income CSV carries the paid invoice")
    expect(!income.contains("Bob"), "income CSV excludes the unpaid invoice")
    expect(expenses.contains("Supply House") && expenses.contains("250.5"), "expense CSV carries the expense")
    expect(mileage.contains("12.4"), "mileage CSV carries the trip")

    // Every export is CRLF-terminated and stable across builds.
    for (name, csv) in [("income", income), ("expenses", expenses), ("mileage", mileage)] {
        expect(csv.hasSuffix("\r\n"), "\(name) CSV ends with CRLF")
        expect(!csv.contains("\n\n"), "\(name) CSV has no blank line")
    }
    expectEqual(
        NativeCSVExport.buildIncomeCsv(invoices: Fixture.invoices, start: range.start, end: range.end),
        income,
        "income CSV is deterministic"
    )

    // The screen's row counts are the CRLF-derived counts of these strings.
    let rows = NativeExportRows.rows(
        NativeExportRows.csvs(invoices: Fixture.invoices, expenses: Fixture.expenses, trips: Fixture.trips, range: range),
        range: range,
        rangeID: NativeExportRangeChoice.thisYear.rawValue
    )
    expectEqual(rows.map(\.rowCount), [1, 1, 1], "one row per dataset for the fixture")
    expectEqual(rows[0].detailText, "1 rows · One row per payment received", "the export screen's live count")
}

// MARK: - 4. Deterministic accountant package

private func testPackageSeam() {
    let range = yearRange
    let input = NativePackageInput(
        invoices: Fixture.invoices,
        expenses: Fixture.expenses,
        trips: Fixture.trips,
        customers: Fixture.customers,
        jobNameById: ["job-1": "Water heater install"]
    )
    let first = NativeAccountingPackage.buildAccountingPackage(input, start: range.start, end: range.end)
    let second = NativeAccountingPackage.buildAccountingPackage(input, start: range.start, end: range.end)

    expectEqual(first.filename, "TradeReady-Accounting_2026-01-01_2026-12-31.zip", "package filename")
    expect(first.bytes.count > 0, "the package has bytes")
    expectEqual(first.bytes, second.bytes, "the package is byte-deterministic across builds")
    expectEqual(
        NativeZipArchive.crc32(first.bytes),
        NativeZipArchive.crc32(second.bytes),
        "the whole-archive CRC-32 is stable"
    )
    // A different window must produce different bytes (the range is stamped in).
    let narrow = NativeAccountingPackage.buildAccountingPackage(
        input,
        start: NativeCashBasis.parseLocalDate("2026-08-01")!,
        end: NativeCashBasis.parseLocalDate("2026-08-31")!
    )
    expect(narrow.bytes != first.bytes, "a different range produces a different package")

    // The summary the package carries matches the card figures for the window.
    let summary = NativeAccountingPackage.buildSummary(input, start: range.start, end: range.end)
    expectEqual(summary.cashCollected, decimal("1000"), "package cash collected matches the card")
    expectEqual(summary.expensesTotal, decimal("250.5"), "package expenses match the card")
    expectEqual(summary.netCash, decimal("749.5"), "package net cash")
    // Per contract §2.2 an invoice is in scope when its id recovers an issue
    // date or it has a non-voided payment in range: the paid invoice qualifies,
    // the unpaid "inv-101" (no recoverable date, no payments) does not.
    expectEqual(summary.invoicesCount, 1, "only the invoiced-and-paid record is in scope")
    expectEqual(summary.mileageTripsCount, 1, "the trip is in scope")
    let json = NativeAccountingPackage.buildSummaryJson(summary)
    expect(json.contains("\"net_cash\": 749.5"), "summary JSON carries the net cash")
    expect(json.contains("\"range_start\": \"2026-01-01\""), "summary JSON carries the range")
}

// MARK: - 5. Import round trip (export → re-import → counts → undo)

private func testImportRoundTrip() {
    let range = yearRange
    let expensesCsv = NativeCSVExport.buildExpensesCsv(
        expenses: Fixture.expenses, start: range.start, end: range.end
    )

    // 1. Parse the exported file exactly as the import screen does.
    let parsed = NativeCSVImport.parseCsv(expensesCsv)
    expect(parsed.headers.contains("Date") && parsed.headers.contains("Amount"), "the export parses as CSV")
    expectEqual(parsed.rows.count, 1, "the exported file has the one expense row")

    // 2. Map it with the same vocabulary the screen uses.
    let mapping = NativeImportMapping.detectMapping(entity: .expenses, headers: parsed.headers)
    expectEqual(NativeImportCopy.missingRequiredFields(.expenses, mapping: mapping), [],
                "the exported headers satisfy the required columns")

    // 3. Commit against an unrelated pre-existing expense.
    var unrelated: Canonical.Expense = decode("""
    {"id":"exp-keep","createdAt":"2026-01-02","description":"Kept","amount":10,"category":"other",
     "date":"2026-01-02","notes":"","importBatchId":"imp_other_1"}
    """)
    unrelated.importBatchId = "imp_other_1"
    let batchID = "imp_qual_1"
    let result = NativeImportEngine.buildExpenseImport(
        rows: parsed.rows,
        mapping: mapping,
        existingExpenses: [unrelated],
        batchID: batchID,
        dateFormat: NativeImportMapping.detectDateFormat(samples: parsed.rows.map { $0[0] }),
        environment: .live()
    )
    expectEqual(result.counts.ok, 1, "the exported expense imports")
    expectEqual(result.counts.skip, 0, "nothing is skipped")
    expectEqual(result.expenses.count, 2, "the pre-existing record plus the imported one")
    expectEqual(result.expenses.first?.id, unrelated.id, "an existing record keeps its position and identity")
    expectEqual(
        NativeImportCopy.summaryLine(.expenses, counts: result.counts),
        "1 imported · 0 flagged (unrecognized category) · 0 skipped",
        "the screen's report line matches the engine"
    )
    guard let reimported = result.expenses.first(where: { $0.importBatchId == batchID }) else {
        expect(false, "the imported record carries the batch marker")
        return
    }
    expectEqual(reimported.amount, decimal("250.5"), "the amount survives the round trip")
    expectEqual(reimported.category, "materials", "the category survives the round trip")
    expectEqual(reimported.date, "2026-08-10", "the date survives the round trip")
    expectEqual(reimported.description, "Supply House", "the description survives the round trip")
    expectEqual(reimported.receiptUri == nil, true, "an exported expense re-imports without a receipt reference")
    expectEqual(reimported.importBatchId, batchID, "only the imported record carries the batch marker")
    expectEqual(reimported.id == unrelated.id, false, "the import never reuses an existing id")

    // 4. A second import of the same file against the now-larger collection
    //    still creates one row — the engine does not de-duplicate expenses, so
    //    the same-file warning is the user-facing guard.
    let again = NativeImportEngine.buildExpenseImport(
        rows: parsed.rows,
        mapping: mapping,
        existingExpenses: result.expenses,
        batchID: "imp_qual_2",
        dateFormat: nil,
        environment: .live()
    )
    expectEqual(again.expenses.count, 3, "a deliberate re-import adds its own row")
    expectEqual(NativeImportCopy.alreadyImportedMessage,
                "This exact file looks imported already. Import again?",
                "that second import is what the same-file warning asks about")

    // 5. Undo strips the batch it created and leaves the unrelated record.
    let afterUndo = NativeImportEngine.stripBatch(result.expenses, batchID: batchID) { $0.importBatchId }
    expectEqual(afterUndo.map(\.id), [unrelated.id], "undo removes only the batch's own records")
    expectEqual(afterUndo.first?.description, "Kept", "the unrelated expense survives undo")
}

// MARK: - Run

testReportsAndCards()
testPricebookSeam()
testCSVSeam()
testPackageSeam()
testImportRoundTrip()

if failures == 0 {
    print("Phase 9 qualification tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}
