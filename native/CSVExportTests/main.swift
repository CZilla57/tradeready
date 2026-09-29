import Foundation

// CSV export builder tests (task 9.06).
//
// Ports __tests__/csvExport.test.ts: escaping, CRLF assembly, income rows as
// payments (legacy method blanked, voided excluded), expense labels + receipt
// flag, raw mileage rows, filenames, and row counts.

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

private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// Injects the required-but-incidental contact fields so each fixture only has
/// to spell out the fields the vector is about.
private func invoice(_ json: String) -> Canonical.Invoice {
    decode(Canonical.Invoice.self, withDefaults(json, ["email": "", "phone": ""]))
}

private func withDefaults(_ json: String, _ defaults: [String: Any]) -> String {
    guard var object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
        return json
    }
    for (key, value) in defaults where object[key] == nil { object[key] = value }
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return json }
    return String(decoding: data, as: UTF8.self)
}
private func expense(_ json: String) -> Canonical.Expense { decode(Canonical.Expense.self, json) }
private func trip(_ json: String) -> Canonical.Trip { decode(Canonical.Trip.self, json) }

private let jan1 = NativeCashBasis.localDate(year: 2026, month: 0, day: 1)
private let dec31 = NativeCashBasis.localDate(year: 2026, month: 11, day: 31, hour: 23, minute: 59, second: 59)

private let incomeHeader = "Date,Customer,Invoice #,Invoice Description,Method,Note,Amount\r\n"

// MARK: - escaping / assembly

private func testEscaping() {
    expectEqual(NativeCSVExport.escapeCsvField("Deck repair"), "Deck repair", "plain passes through")
    expectEqual(NativeCSVExport.escapeCsvField(""), "", "empty passes through")
    expectEqual(NativeCSVExport.escapeCsvField("Smith, Jones & Co"), "\"Smith, Jones & Co\"", "comma quotes")
    expectEqual(NativeCSVExport.escapeCsvField("the \"big\" job"), "\"the \"\"big\"\" job\"", "quotes doubled")
    expectEqual(NativeCSVExport.escapeCsvField("line one\nline two"), "\"line one\nline two\"", "newline quotes")
    expectEqual(NativeCSVExport.escapeCsvField("a\rb"), "\"a\rb\"", "carriage return quotes")
    expectEqual(NativeCSVExport.escapeCsvField("José Núñez"), "José Núñez", "accents untouched")

    expectEqual(NativeCSVExport.toCsv(["A", "B"], []), "A,B\r\n", "header only")
    expectEqual(NativeCSVExport.toCsv(["A", "B"], [["1", "2"], ["3", "4"]]), "A,B\r\n1,2\r\n3,4\r\n", "CRLF rows")
    expectEqual(NativeCSVExport.toCsv(["Name, full"], [["say \"hi\""]]), "\"Name, full\"\r\n\"say \"\"hi\"\"\"\r\n", "headers escaped too")
}

// MARK: - income

private func testIncome() {
    expectEqual(NativeCSVExport.buildIncomeCsv(invoices: [], start: jan1, end: dec31), incomeHeader, "empty income is header only")

    let jane = invoice(#"{"id":"i1","customer":"Jane Smith","number":"INV-0001","desc":"Maintenance","amount":1000,"due":"2026-03-01","paid":false,"payments":[{"id":"p1","amount":400,"date":"2026-03-01","method":"cash"},{"id":"p2","amount":600,"date":"2026-04-15","method":"stripe"}]}"#)
    let lines = NativeCSVExport.buildIncomeCsv(invoices: [jane], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expectEqual(lines.count, 4, "header + 2 payments + trailing")
    expectEqual(lines[1], "2026-03-01,Jane Smith,INV-0001,Maintenance,cash,,400.00", "cash payment row")
    expectEqual(lines[2], "2026-04-15,Jane Smith,INV-0001,Maintenance,stripe,,600.00", "stripe payment row")

    let voided = invoice(#"{"id":"i2","customer":"A","number":"N1","desc":"","amount":1000,"due":"2026-03-01","paid":false,"payments":[{"id":"p1","amount":400,"date":"2026-03-01","method":"cash"},{"id":"p2","amount":600,"date":"2026-04-15","method":"stripe","voidedAt":"2026-04-16"}]}"#)
    let voidedCsv = NativeCSVExport.buildIncomeCsv(invoices: [voided], start: jan1, end: dec31)
    expect(voidedCsv.contains("400.00"), "non-voided payment exported")
    expect(!voidedCsv.contains("600.00"), "voided payment excluded")

    // April-only window: the March cash payment is out of range, April is in.
    let april1 = NativeCashBasis.localDate(year: 2026, month: 3, day: 1)
    let april30 = NativeCashBasis.localDate(year: 2026, month: 3, day: 30, hour: 23, minute: 59, second: 59)
    let ranged = NativeCSVExport.buildIncomeCsv(invoices: [jane], start: april1, end: april30).components(separatedBy: "\r\n")
    expectEqual(ranged.count, 3, "only the in-range payment")
    expect(ranged[1].hasPrefix("2026-04-15"), "in-range payment kept")
    expect(!ranged[1].contains("2026-03-01"), "out-of-range payment excluded")

    let legacy = invoice(#"{"id":"i3","customer":"Lee","number":"N2","desc":"Fix","amount":700,"due":"2026-02-01","paid":true,"paidAt":"2026-02-10"}"#)
    let legacyLines = NativeCSVExport.buildIncomeCsv(invoices: [legacy], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expectEqual(legacyLines.count, 3, "legacy paid emits one row")
    // Method blanked; the materialized legacy note is kept (csvExport.test.ts).
    expectEqual(
        legacyLines[1],
        "2026-02-10,Lee,N2,Fix,,Recorded before payment history was itemised,700.00",
        "legacy row dated paidAt with blank method and its note kept"
    )

    let legacyDue = invoice(#"{"id":"i4","customer":"Lee","number":"N3","desc":"Fix","amount":700,"due":"2026-02-10","paid":true}"#)
    expect(NativeCSVExport.buildIncomeCsv(invoices: [legacyDue], start: jan1, end: dec31).contains("2026-02-10"), "legacy without paidAt buckets on due")

    let legacyUnpaid = invoice(#"{"id":"i5","customer":"Lee","number":"N4","desc":"","amount":700,"due":"2026-02-10","paid":false}"#)
    expectEqual(NativeCSVExport.buildIncomeCsv(invoices: [legacyUnpaid], start: jan1, end: dec31), incomeHeader, "legacy unpaid emits nothing")

    let early = invoice(#"{"id":"i6","customer":"A","number":"N5","desc":"","amount":100,"due":"2026-02-01","paid":false,"payments":[{"id":"p1","amount":100,"date":"2026-02-01","method":"cash"}]}"#)
    let late = invoice(#"{"id":"i7","customer":"B","number":"N6","desc":"","amount":100,"due":"2026-06-01","paid":false,"payments":[{"id":"p1","amount":100,"date":"2026-06-01","method":"cash"}]}"#)
    let sortedLines = NativeCSVExport.buildIncomeCsv(invoices: [late, early], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expect(sortedLines[1].hasPrefix("2026-02-01"), "rows sorted by date ascending")
    expect(sortedLines[2].hasPrefix("2026-06-01"), "later row second")

    let comma = invoice(#"{"id":"i8","customer":"Smith, Jones & Co","number":"N7","desc":"lobby, phase 1","amount":50,"due":"2026-02-01","paid":false,"payments":[{"id":"p1","amount":50,"date":"2026-02-01","method":"cash"}]}"#)
    let commaCsv = NativeCSVExport.buildIncomeCsv(invoices: [comma], start: jan1, end: dec31)
    expect(commaCsv.contains("\"Smith, Jones & Co\""), "customer with comma escaped")
    expect(commaCsv.contains("\"lobby, phase 1\""), "description with comma escaped")
}

// MARK: - expenses

private func testExpenses() {
    let header = "Date,Description,Category,Amount,Notes,Has Receipt\r\n"
    expectEqual(NativeCSVExport.buildExpensesCsv(expenses: [], start: jan1, end: dec31), header, "empty expenses header only")

    let lumber = expense(#"{"id":"e1","createdAt":"2026-03-01","description":"Lumber","amount":250.5,"category":"materials","date":"2026-03-01","notes":"","receiptUri":"file:///r.jpg"}"#)
    let lines = NativeCSVExport.buildExpensesCsv(expenses: [lumber], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expectEqual(lines[1], "2026-03-01,Lumber,Materials,250.50,,Yes", "category label and receipt flag")

    let unknown = expense(#"{"id":"e2","createdAt":"2026-03-01","description":"Mystery","amount":10,"category":"zzz","date":"2026-03-01","notes":""}"#)
    expect(NativeCSVExport.buildExpensesCsv(expenses: [unknown], start: jan1, end: dec31).contains(",Other,"), "unknown category falls back to Other")
    expect(NativeCSVExport.buildExpensesCsv(expenses: [lumber], start: jan1, end: dec31).contains(",No\r\n") == false, "receipt present is Yes")

    let fuel = expense(#"{"id":"e3","createdAt":"2026-04-01","description":"Fuel","amount":60,"category":"fuel","date":"2026-04-01","notes":""}"#)
    let blades = expense(#"{"id":"e4","createdAt":"2026-05-01","description":"Blades","amount":20,"category":"tools","date":"2026-05-01","notes":""}"#)
    let rows = NativeCSVExport.buildExpensesCsv(expenses: [blades, fuel], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expectEqual(rows.count, 4, "header + 2 + trailing")
    expect(rows[1].contains("Fuel"), "earlier month first")
    expect(rows[2].contains("Blades"), "later month second")

    let outside = expense(#"{"id":"e5","createdAt":"2025-01-01","description":"Old","amount":5,"category":"other","date":"2025-01-01","notes":""}"#)
    expectEqual(NativeCSVExport.buildExpensesCsv(expenses: [outside], start: jan1, end: dec31), header, "out-of-range expense excluded")
}

// MARK: - mileage + filenames

private func testTripsAndFilenames() {
    let header = "Date,From,To,Purpose,Odometer Start,Odometer End,Miles\r\n"
    let drive = trip(#"{"id":"t1","date":"2026-03-10","odometerStart":45210,"odometerEnd":45240,"miles":30,"fromJobId":null,"fromLabel":"Home / Shop","toJobId":"j1","toLabel":"Acme","purpose":"Service call","createdAt":"2026-03-10"}"#)
    let lines = NativeCSVExport.buildTripsCsv(trips: [drive], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expectEqual(lines[1], "2026-03-10,Home / Shop,Acme,Service call,45210,45240,30", "raw trip row, no decimal padding")
    expectEqual(NativeCSVExport.buildTripsCsv(trips: [], start: jan1, end: dec31), header, "empty mileage header only")

    let range = NativeCashBasis.exportRange(for: "this_month", now: NativeCashBasis.localDate(year: 2026, month: 5, day: 15))
    expectEqual(NativeCSVExport.csvFilename(dataset: "income", range: range, rangeID: "this_month"), "tradeready-income_2026-06-01_2026-06-30.csv", "filename uses local dates")
    expectEqual(NativeCSVExport.csvFilename(dataset: "expenses", range: range, rangeID: "all_time"), "tradeready-expenses_all-time.csv", "all-time filename")
    expectEqual(NativeCSVExport.csvRowCount(lines.joined(separator: "\r\n")), 1, "row count excludes header")
    expectEqual(NativeCSVExport.csvRowCount(header), 0, "header-only row count is zero")
}

// MARK: - run

testEscaping()
testIncome()
testExpenses()
testTripsAndFilenames()

if failures == 0 {
    print("CSVExportTests: all checks passed")
} else {
    print("CSVExportTests: \(failures) failure(s)")
    exit(1)
}
