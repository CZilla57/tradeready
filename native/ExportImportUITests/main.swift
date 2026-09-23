import Foundation

// Export + import UI tests (task 9.13, requirements X1, X2, I1-I3).
//
// The bytes are covered by CSVExportTests / AccountingPackageTests /
// ZipArchiveTests (9.06) and the engine by CSVImportTests / ImportMappingTests /
// ImportEngineTests / ImportHistoryTests (9.07). These vectors cover what 9.13
// owns: the range presets and the custom-range guard, the export rows with live
// counts, the share-file tail, and the import lifecycle copy/validation/report/
// history projection.

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

private func invoice(_ overrides: String = "") -> Canonical.Invoice {
    let base = """
    {"id":"inv1","customer":"Alice","number":"INV-001","amount":1000,"due":"2026-03-01",
     "email":"","phone":"","desc":"","paid":true,"paidAt":"2026-03-05"}
    """
    return try! decoder.decode(Canonical.Invoice.self, from: Data(merge(base, overrides).utf8))
}

private func expense(_ overrides: String = "") -> Canonical.Expense {
    let base = #"{"id":"e1","createdAt":"2026-03-10","description":"Parts","amount":200,"category":"materials","date":"2026-03-10","notes":""}"#
    return try! decoder.decode(Canonical.Expense.self, from: Data(merge(base, overrides).utf8))
}

private func trip(_ overrides: String = "") -> Canonical.Trip {
    let base = #"{"id":"t1","date":"2026-03-10","odometerStart":0,"odometerEnd":10,"miles":10,"fromLabel":"Home / Shop","toLabel":"Home / Shop","purpose":"","createdAt":"2026-03-10"}"#
    return try! decoder.decode(Canonical.Trip.self, from: Data(merge(base, overrides).utf8))
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
private let jan15 = NativeCashBasis.parseLocalDate("2026-01-15")!
private let dec20 = NativeCashBasis.parseLocalDate("2025-12-20")!

// MARK: - Ranges

private func testExportRanges() {
    expectEqual(
        NativeExportRangeChoice.allCases.map(\.label),
        ["This Month", "This Quarter", "This Year", "Last Year", "All Time", "Custom"],
        "RN's range chips, in order"
    )
    expectEqual(
        NativeExportRangeChoice.allCases.map(\.rawValue),
        ["this_month", "this_quarter", "this_year", "last_year", "all_time", "custom"],
        "range ids match the RN presets"
    )

    for choice in NativeExportRangeChoice.allCases where !choice.isCustom {
        let range = NativeExportRange.range(
            for: choice, customStart: march10, customEnd: march10, now: march10
        )
        let expected = NativeCashBasis.exportRange(for: choice.rawValue, now: march10)
        expectEqual(range.start, expected.start, "\(choice.rawValue) start matches exportDateRange")
        expectEqual(range.end, expected.end, "\(choice.rawValue) end matches exportDateRange")
    }

    let custom = NativeExportRange.range(
        for: .custom, customStart: jan15, customEnd: march10, now: march10
    )
    expectEqual(NativeCashBasis.ymd(custom.start), "2026-01-15", "custom start is the picked day")
    expectEqual(NativeCashBasis.ymd(custom.end), "2026-03-10", "custom end is the picked day")
    let endOfDay = NativeCashBasis.localCalendar.dateComponents([.hour, .minute, .second], from: custom.end)
    expectEqual(endOfDay.hour, 23, "the custom end is the local end of the day (hour)")
    expectEqual(endOfDay.minute, 59, "the custom end is the local end of the day (minute)")
    expectEqual(endOfDay.second, 59, "the custom end is the local end of the day (second)")

    expect(!NativeExportRange.isInvalid(.thisYear, customStart: march10, customEnd: dec20),
           "a preset can never be invalid")
    expect(NativeExportRange.isInvalid(.custom, customStart: march10, customEnd: dec20),
           "a custom start after the end is invalid")
    expect(!NativeExportRange.isInvalid(.custom, customStart: march10, customEnd: march10),
           "a single-day custom range is valid")
    expect(!NativeExportRange.isInvalid(.custom, customStart: dec20, customEnd: march10),
           "a forward custom range is valid")
    expectEqual(NativeExportRange.invalidTitle, "Check your dates", "invalid-range title")
    expectEqual(NativeExportRange.invalidMessage, "The start date is after the end date.", "invalid-range copy")
}

// MARK: - Export rows

private func testExportRows() {
    expectEqual(NativeExportDataset.allCases.map(\.label), ["Income", "Expenses", "Mileage"], "dataset order")
    expectEqual(NativeExportDataset.income.hint, "One row per payment received", "income hint")
    expectEqual(NativeExportDataset.expenses.hint, "One row per expense", "expense hint")
    expectEqual(NativeExportDataset.mileage.hint, "One row per logged trip", "mileage hint")
    expectEqual(NativeExportRows.packageLabel, "Accountant package (.zip)", "package row label")
    expectEqual(NativeExportRows.packageHint, "Everything your accountant needs, in one file", "package row hint")

    let range = NativeExportRange.range(for: .thisYear, customStart: march10, customEnd: march10, now: march10)
    let invoices = [
        invoice(#"{"id":"a","paidAt":"2026-03-05"}"#),
        invoice(#"{"id":"b","paidAt":"2025-11-05","amount":50}"#),
    ]
    let csvs = NativeExportRows.csvs(
        invoices: invoices,
        expenses: [expense(), expense(#"{"id":"e2","date":"2025-12-01"}"#)],
        trips: [trip(), trip(#"{"id":"t2","date":"2025-12-02"}"#)],
        range: range
    )
    let rows = NativeExportRows.rows(csvs, range: range, rangeID: NativeExportRangeChoice.thisYear.rawValue)
    expectEqual(rows.map(\.dataset), [.income, .expenses, .mileage], "three dataset rows in order")
    expectEqual(rows[0].rowCount, 1, "income counts only in-range payments")
    expectEqual(rows[1].rowCount, 1, "expenses count only in-range rows")
    expectEqual(rows[2].rowCount, 1, "mileage counts only in-range trips")
    expectEqual(rows[0].detailText, "1 rows · One row per payment received", "row detail copy is RN's")
    expectEqual(rows[0].filename, "tradeready-income_2026-01-01_2026-12-31.csv", "dated filename")

    let allTime = NativeExportRange.range(for: .allTime, customStart: march10, customEnd: march10, now: march10)
    let allRows = NativeExportRows.rows(
        NativeExportRows.csvs(invoices: invoices, expenses: [], trips: [], range: allTime),
        range: allTime, rangeID: NativeExportRangeChoice.allTime.rawValue
    )
    expectEqual(allRows[0].filename, "tradeready-income_all-time.csv", "the all-time filename has no dates")
    expectEqual(allRows[0].rowCount, 2, "all-time includes last year's payment")
    expectEqual(allRows[1].rowCount, 0, "a collection with no rows reports zero")
    let emptyWindow = NativeExportRange.range(for: .lastYear, customStart: march10, customEnd: march10, now: march10)
    let lastYearRows = NativeExportRows.rows(
        NativeExportRows.csvs(invoices: [], expenses: [], trips: [], range: emptyWindow),
        range: emptyWindow, rangeID: NativeExportRangeChoice.lastYear.rawValue
    )
    expectEqual(lastYearRows[0].rowCount, 0, "an empty window has no income rows")

    expectEqual(
        NativeExportRows.footnote,
        "CSV files open in Excel, Numbers, Google Sheets, and import into accounting software. Amounts are plain numbers; income is listed by payment received.",
        "footnote copy"
    )
}

// MARK: - Share tail

private func testShareTail() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tradeready-export-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let csv = "A,B\r\n1,2\r\n"
    let payload = NativeCSVExport.sharePayload(csv: csv)
    expect(payload.starts(with: Data([0xEF, 0xBB, 0xBF])), "the CSV share payload is BOM-prefixed for Excel")
    expectEqual(String(data: payload.dropFirst(3), encoding: .utf8), csv, "the BOM precedes the exact bytes")

    let url = try! NativeExportShare.write(payload, filename: "tradeready-income.csv", directory: directory)
    expectEqual(url.lastPathComponent, "tradeready-income.csv", "the share filename is preserved")
    expectEqual(try! Data(contentsOf: url), payload, "the written bytes match the payload")

    let second = try! NativeExportShare.write(Data("updated".utf8), filename: "tradeready-income.csv", directory: directory)
    expectEqual(try! Data(contentsOf: second), Data("updated".utf8), "an existing export is replaced")

    let zipBytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    expectEqual(NativeCSVExport.sharePayload(zipBytes: zipBytes), Data(zipBytes), "the ZIP payload is passed through untouched")
}

// MARK: - Import lifecycle

private func testImportLifecycle() {
    expectEqual(
        NativeImportEntity.allCases.map { NativeImportCopy.entityLabel($0) },
        ["Customers", "Jobs", "Invoices", "Expenses"],
        "entity chips, in RN's order"
    )
    expectEqual(NativeImportCopy.title, "Import data", "screen title")
    expectEqual(NativeImportCopy.matchColumnsTitle, "Match columns", "mapping heading")
    expectEqual(NativeImportCopy.ignoreOptionLabel, "Ignore", "the Ignore option is offered per column")
    expectEqual(NativeImportCopy.dateFormatLabel, "Date format", "date format label")
    expectEqual(
        NativeImportDateFormatChoice.allCases.map(\.label),
        ["Auto", "M-D-Y", "D-M-Y", "Y-M-D"],
        "date format choices"
    )

    let customerMapping: [String?] = ["name", nil, nil]
    expect(NativeImportCopy.missingRequiredFields(.customers, mapping: customerMapping).isEmpty,
           "a name column satisfies customers")
    expectEqual(NativeImportCopy.missingRequiredFields(.jobs, mapping: ["title"]), ["customerName"],
                "jobs need a customer column too")
    expectEqual(NativeImportCopy.missingRequiredFields(.invoices, mapping: []), ["customer", "amount"],
                "invoices need customer and amount")
    expectEqual(NativeImportCopy.missingRequiredFields(.expenses, mapping: ["amount"]), ["date"],
                "expenses need a date")
    expectEqual(NativeImportCopy.mapRequiredMessage(["customer", "amount"]),
                "Still need: customer, amount", "the RN 'still need' copy")

    expectEqual(NativeImportCopy.mappedDateColumnIndex(.invoices, mapping: ["customer", "amount", "due"]), 2,
                "a mapped due column opens the date selector")
    expect(NativeImportCopy.mappedDateColumnIndex(.invoices, mapping: ["customer", "amount"]) == nil,
           "no date column means no selector")
    expectEqual(NativeImportCopy.mappedDateColumnIndex(.jobs, mapping: ["title", "scheduledDate"]), 1,
                "the jobs date column is scheduledDate")
    expect(NativeImportCopy.mappedDateColumnIndex(.customers, mapping: ["name"]) == nil,
           "customers have no date column")

    let samples = NativeImportCopy.dateSamples(
        .invoices,
        mapping: ["customer", "amount", "due"],
        rows: [["Alice", "100", "03/10/2026"], ["Bob", "200", "04/11/2026"]]
    )
    expectEqual(samples, ["03/10/2026", "04/11/2026"], "auto-detection reads the mapped date column")

    expectEqual(NativeImportCopy.previewLine(["Alice", "100"]), "Alice · 100", "preview rows join with a middot")
    expectEqual(NativeImportCopy.readyText(rowCount: 3), "3 row(s) ready to import.", "ready copy")
    expectEqual(
        NativeImportCopy.summaryLine(.customers, counts: NativeImportCounts(ok: 2, skip: 1, flag: 0, created: 1, matched: 1)),
        "1 new · 1 matched existing · 1 skipped",
        "customer report line"
    )
    expectEqual(
        NativeImportCopy.summaryLine(.jobs, counts: NativeImportCounts(ok: 1, skip: 1, flag: 1, created: 0, matched: 0)),
        "1 imported · 1 flagged (unrecognized status) · 1 skipped",
        "job report line"
    )
    expectEqual(
        NativeImportCopy.summaryLine(.invoices, counts: NativeImportCounts(ok: 1, skip: 0, flag: 1, created: 0, matched: 0)),
        "1 imported · 1 flagged (paid claim, no paid date) · 0 skipped",
        "invoice report line"
    )
    expectEqual(
        NativeImportCopy.summaryLine(.expenses, counts: NativeImportCounts(ok: 2, skip: 0, flag: 1, created: 0, matched: 0)),
        "2 imported · 1 flagged (unrecognized category) · 0 skipped",
        "expense report line"
    )

    let outcomes = [
        NativeRowOutcome(rowIndex: 0, status: "ok", reason: nil),
        NativeRowOutcome(rowIndex: 1, status: "skip", reason: "Missing name"),
        NativeRowOutcome(rowIndex: 4, status: "flag", reason: "Unrecognized status"),
        NativeRowOutcome(rowIndex: 9, status: "skip", reason: nil),
    ]
    let problems = NativeImportCopy.problemRows(outcomes)
    expectEqual(problems.rows.count, 3, "only non-ok rows are reported")
    expectEqual(problems.extra, 0, "nothing overflows at this size")
    expectEqual(NativeImportCopy.outcomeText(outcomes[1]), "Row 2: Missing name", "skip copy uses the 1-based row")
    expectEqual(NativeImportCopy.outcomeText(outcomes[2]), "Row 5: Unrecognized status", "flag copy uses the 1-based row")
    expectEqual(NativeImportCopy.outcomeText(outcomes[3]), "Row 10: Skipped", "a reasonless skip falls back to the status word")

    let many = (0..<60).map { NativeRowOutcome(rowIndex: $0, status: "skip", reason: "nope") }
    let capped = NativeImportCopy.problemRows(many)
    expectEqual(capped.rows.count, NativeImportCopy.reportRowCap, "the report caps its rows")
    expectEqual(capped.extra, 60 - NativeImportCopy.reportRowCap, "the remainder is summarized")

    expectEqual(NativeImportCopy.undoAlert(.customers).title, "Import undone", "undo title")
    expectEqual(NativeImportCopy.undoAlert(.customers).message, "The imported customers were removed.", "customer undo copy")
    expectEqual(NativeImportCopy.undoAlert(.jobs).message, "The imported jobs were removed.", "job undo copy")
    expectEqual(NativeImportCopy.undoAlert(.invoices).message, "The imported invoices were removed.", "invoice undo copy")
    expectEqual(NativeImportCopy.undoAlert(.expenses).message, "The imported expenses were removed.", "expense undo copy")
    expectEqual(NativeImportCopy.importFailedMessage, "Nothing was changed. Please try again.", "the failure path changes nothing")
    expectEqual(NativeImportCopy.alreadyImportedMessage, "This exact file looks imported already. Import again?",
                "the same-file warning is a question, not a block")
    expectEqual(NativeImportCopy.largeFileMessage, "Only the first 5,000 rows were read.", "large-file notice")

    let record = NativeImportBatchRecord(
        batchId: "imp_1_1",
        entity: NativeImportEntity.customers.rawValue,
        fileHash: "abc",
        date: "2026-03-10",
        counts: NativeImportCountsCodable(NativeImportCounts(ok: 2, skip: 1, flag: 0, created: 1, matched: 1))
    )
    expectEqual(NativeImportCopy.historyText(record), "2026-03-10 · Customers · 1 new · 1 matched existing · 1 skipped",
                "history rows read like the report")
}

// MARK: - Engine seam

private func testImportEngineSeam() {
    let csv = "Name,Email,Phone\nAlice,alice@example.com,555-0100\n,\nBob,bob@example.com,555-0101\n"
    let parsed = NativeCSVImport.parseCsv(csv)
    expectEqual(parsed.headers, ["Name", "Email", "Phone"], "headers parse")
    expectEqual(parsed.rows.count, 3, "data rows parse")
    let mapping = NativeImportMapping.detectMapping(entity: .customers, headers: parsed.headers)
    expectEqual(mapping, ["name", "email", "phone"], "headers map by vocabulary")
    let result = NativeImportEngine.buildCustomerImport(
        rows: parsed.rows,
        mapping: mapping,
        existing: [],
        batchID: "imp_test_1",
        environment: .live()
    )
    expectEqual(result.counts.created, 2, "two customers import")
    expectEqual(result.counts.skip, 1, "the nameless row is skipped")
    expectEqual(
        NativeImportCopy.summaryLine(.customers, counts: result.counts),
        "2 new · 0 matched existing · 1 skipped",
        "the screen's summary line matches the engine"
    )
    expectEqual(NativeImportCopy.missingRequiredFields(.customers, mapping: mapping), [], "the mapping is complete")
    expect(!NativeCSVImport.hashCsv(csv).isEmpty, "the re-import file hash is non-empty")
    expect(NativeCSVImport.hashCsv(csv) == NativeCSVImport.hashCsv(csv), "the hash is deterministic")
    expect(NativeCSVImport.hashCsv(csv) != NativeCSVImport.hashCsv(csv + "\n"), "a different file hashes differently")
}

// MARK: - Run

testExportRanges()
testExportRows()
testShareTail()
testImportLifecycle()
testImportEngineSeam()

if failures == 0 {
    print("Export/import UI tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}
