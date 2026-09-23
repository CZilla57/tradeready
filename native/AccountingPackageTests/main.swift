import Foundation

// Accountant package tests (task 9.06).
//
// Ports the accountingPackage.* suites: issue-date recovery, invoice-in-scope,
// payment source, each CSV builder, warnings, summary numbers + exact JSON shape,
// README, filename, and the assembled package (entry order, BOM placement,
// determinism).

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

private func invoice(_ json: String) -> Canonical.Invoice { decode(Canonical.Invoice.self, json) }
private func expense(_ json: String) -> Canonical.Expense { decode(Canonical.Expense.self, json) }
private func customer(_ json: String) -> Canonical.Customer { decode(Canonical.Customer.self, json) }

private let jan1 = NativeCashBasis.localDate(year: 2026, month: 0, day: 1)
private let dec31 = NativeCashBasis.localDate(year: 2026, month: 11, day: 31, hour: 23, minute: 59, second: 59)

/// Epoch ms for 2026-03-01 UTC — the `inv<ms>` id shape `recoverIssueDate` reads.
private let march1Ms: Int64 = 1_772_323_200_000

// MARK: - scope + provenance

private func testScope() {
    expectEqual(NativeAccountingPackage.recoverIssueDate("inv\(march1Ms)"), "2026-03-01", "reads the id date")
    expect(NativeAccountingPackage.recoverIssueDate("1-seed") == nil, "unrecoverable id returns nil")
    expect(NativeAccountingPackage.recoverIssueDate("stripe_cs_test") == nil, "stripe id returns nil")
    expect(NativeAccountingPackage.recoverIssueDate("inv99999999999999999999") == nil, "absurd timestamp returns nil")

    expectEqual(NativeAccountingPackage.paymentSource("stripe_cs_1"), "stripe", "stripe source")
    expectEqual(NativeAccountingPackage.paymentSource("legacy_inv1"), "legacy", "legacy source")
    expectEqual(NativeAccountingPackage.paymentSource("p1"), "device", "device source")

    let issued = invoice(#"{"id":"inv\#(march1Ms)","customer":"A","number":"N1","desc":"","amount":100,"due":"2026-03-05","paid":false,"email":"","phone":""}"#)
    expect(NativeAccountingPackage.isInvoiceInScope(issued, start: jan1, end: dec31), "issue date in range is in scope")
    expect(!NativeAccountingPackage.isInvoiceInScope(issued, start: NativeCashBasis.localDate(year: 2027, month: 0, day: 1), end: NativeCashBasis.localDate(year: 2027, month: 11, day: 31)), "issue date out of range with no payment")

    // Unrecoverable id but an in-range payment → in scope.
    let paidNoIssue = invoice(#"{"id":"1-seed","customer":"A","number":"N2","desc":"","amount":100,"due":"2026-03-05","paid":false,"email":"","phone":"","payments":[{"id":"p1","amount":100,"date":"2026-03-05","method":"cash"}]}"#)
    expect(NativeAccountingPackage.isInvoiceInScope(paidNoIssue, start: jan1, end: dec31), "in-range payment puts an undated invoice in scope")

    // Unrecoverable id with only a voided payment → out of scope.
    let voidedOnly = invoice(#"{"id":"1-seed","customer":"A","number":"N3","desc":"","amount":100,"due":"2026-03-05","paid":false,"email":"","phone":"","payments":[{"id":"p1","amount":100,"date":"2026-03-05","method":"cash","voidedAt":"2026-03-06"}]}"#)
    expect(!NativeAccountingPackage.isInvoiceInScope(voidedOnly, start: jan1, end: dec31), "a voided-only payment does not put an invoice in scope")
}

// MARK: - builders

private func testBuilders() {
    let paid = invoice(#"{"id":"inv\#(march1Ms)","customer":"Acme","number":"INV-1","desc":"Job","amount":1000,"due":"2026-03-01","paid":false,"email":"a@x.com","phone":"555","jobId":"j1","lineItems":[{"description":"Labor","category":"labor","amount":600},{"description":"Parts","category":"materials","amount":400}],"payments":[{"id":"p1","amount":400,"date":"2026-03-01","method":"cash"},{"id":"p2","amount":600,"date":"2026-04-10","method":"stripe"}]}"#)
    // Unrecoverable id, but an in-range payment puts it in scope; its issue date
    // is therefore unknowable and must render blank.
    let open = invoice(#"{"id":"1-seed","customer":"Zed","number":"INV-2","desc":"","amount":50,"due":"2026-05-01","paid":false,"email":"","phone":"","payments":[{"id":"p1","amount":50,"date":"2026-05-01","method":"cash"}]}"#)

    let invoicesCsv = NativeAccountingPackage.buildInvoicesCsv([paid, open], start: jan1, end: dec31)
    let invoiceLines = invoicesCsv.components(separatedBy: "\r\n")
    expectEqual(invoiceLines.count, 4, "header + 2 invoices + trailing")
    expect(invoiceLines[1].hasPrefix("INV-1,2026-03-01,Acme"), "issue date recovered and rendered")
    expect(invoiceLines[1].contains("1000.00,1000.00,0.00,paid"), "amounts and status")
    expect(invoiceLines[2].hasPrefix("INV-2,"), "unrecoverable issue date left blank")

    let itemLines = NativeAccountingPackage.buildLineItemsCsv([paid], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expectEqual(itemLines.count, 4, "header + 2 line items + trailing")
    expectEqual(itemLines[1], "INV-1,Labor,labor,600.00", "line item row")

    let activity = NativeAccountingPackage.buildPaymentActivityCsv([paid], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expectEqual(activity.count, 4, "header + 2 payments + trailing")
    expectEqual(activity[1], "2026-03-01,Acme,INV-1,cash,,400.00,No,,device", "device payment row")
    expectEqual(activity[2], "2026-04-10,Acme,INV-1,stripe,,600.00,No,,device", "second payment row")

    let voided = invoice(#"{"id":"inv1","customer":"A","number":"N9","desc":"","amount":100,"due":"2026-03-01","paid":false,"email":"","phone":"","payments":[{"id":"p1","amount":100,"date":"2026-03-01","method":"cash","voidedAt":"2026-03-02"}]}"#)
    let voidedActivity = NativeAccountingPackage.buildPaymentActivityCsv([voided], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expect(voidedActivity[1].contains(",Yes,2026-03-02,"), "voided payment flagged with its date")

    let legacy = invoice(#"{"id":"inv5","customer":"A","number":"N10","desc":"","amount":300,"due":"2026-03-01","paid":true,"paidAt":"2026-03-04","email":"","phone":""}"#)
    let legacyActivity = NativeAccountingPackage.buildPaymentActivityCsv([legacy], start: jan1, end: dec31).components(separatedBy: "\r\n")
    expect(legacyActivity[1].hasSuffix(",legacy"), "legacy source labelled")
    expect(
        legacyActivity[1].contains("2026-03-04,A,N10,,Recorded before payment history was itemised,300.00"),
        "legacy method blanked, note kept, dated paidAt"
    )

    let withJob = expense(#"{"id":"e1","createdAt":"2026-03-05","description":"Lumber","amount":250.5,"category":"materials","date":"2026-03-05","notes":"","jobId":"j1"}"#)
    let expensesCsv = NativeAccountingPackage.buildExpensesCsv2([withJob], start: jan1, end: dec31, jobNameById: ["j1": "Acme Deck"])
    expect(expensesCsv.contains("Acme Deck"), "job name column resolved")

    let customers = [
        customer(#"{"id":"c2","name":"Zed","email":"","phone":"","address":"","notes":""}"#),
        customer(#"{"id":"c1","name":"Acme","email":"a@x.com","phone":"","address":"","notes":"","createdAt":"2026-01-01"}"#),
    ]
    let customersCsv = NativeAccountingPackage.buildCustomersCsv(customers).components(separatedBy: "\r\n")
    expect(customersCsv[1].hasPrefix("Acme,"), "customers sorted by name")
    expect(customersCsv[2].hasPrefix("Zed,"), "second customer")

    let mapping = NativeAccountingPackage.buildCategoryMappingCsv().components(separatedBy: "\r\n")
    expectEqual(mapping.count, 10, "category mapping: header + 8 + trailing")
    expectEqual(mapping[1], "materials,Materials", "first category row")
    expectEqual(mapping[8], "other,Other", "last category row")
}

// MARK: - warnings

private func testWarnings() {
    let empty = NativeAccountingPackage.collectWarnings(NativePackageInput(), start: jan1, end: dec31)
    expectEqual(empty.count, 1, "empty range yields one warning")
    expectEqual(empty.first?.code, "no_records_in_range", "empty-range warning code")
    expectEqual(empty.first?.severity, "info", "empty-range severity")

    let noLineItems = invoice(#"{"id":"inv\#(march1Ms)","customer":"A","number":"N1","desc":"","amount":100,"due":"2026-03-01","paid":false,"email":"","phone":""}"#)
    let legacy = invoice(#"{"id":"inv\#(march1Ms)","customer":"A","number":"N2","desc":"","amount":100,"due":"2026-03-01","paid":true,"paidAt":"2026-03-02","email":"","phone":""}"#)
    let overpaid = invoice(#"{"id":"inv\#(march1Ms)","customer":"A","number":"N3","desc":"","amount":100,"due":"2026-03-01","paid":false,"email":"","phone":"","payments":[{"id":"p1","amount":150,"date":"2026-03-05","method":"cash"}]}"#)
    let voided = invoice(#"{"id":"inv\#(march1Ms)","customer":"A","number":"N4","desc":"","amount":100,"due":"2026-03-01","paid":false,"email":"","phone":"","payments":[{"id":"p1","amount":100,"date":"2026-03-05","method":"cash","voidedAt":"2026-03-06"}]}"#)
    let unknownCategory = expense(#"{"id":"e1","createdAt":"2026-03-05","description":"Odd","amount":10,"category":"zzz","date":"2026-03-05","notes":""}"#)
    let tripInput = decode(Canonical.Trip.self, #"{"id":"t1","date":"2026-03-05","odometerStart":0,"odometerEnd":10,"miles":10,"fromJobId":null,"fromLabel":"Home / Shop","toJobId":null,"toLabel":"Home / Shop","purpose":"","createdAt":"2026-03-05"}"#)

    let input = NativePackageInput(invoices: [noLineItems, legacy, overpaid, voided], expenses: [unknownCategory], trips: [tripInput])
    let codes = NativeAccountingPackage.collectWarnings(input, start: jan1, end: dec31).map(\.code)
    expect(codes.contains("missing_line_items"), "missing line items")
    expect(codes.contains("legacy_invoice_no_ledger"), "legacy invoice notice")
    expect(codes.contains("overpayment_present"), "overpayment warning")
    expect(codes.contains("voided_payments_present"), "voided payments notice")
    expect(codes.contains("unknown_expense_category"), "unknown category warning")
    expect(codes.contains("mileage_is_device_local"), "device-local mileage notice")
    expect(!codes.contains("no_records_in_range"), "no empty-range warning when records exist")

    let warningsCsv = NativeAccountingPackage.buildWarningsCsv(NativeAccountingPackage.collectWarnings(input, start: jan1, end: dec31))
    expect(warningsCsv.hasPrefix("Code,Severity,Subject,Detail\r\n"), "warnings header")
}

// MARK: - summary + README + package

private func sampleInput() -> NativePackageInput {
    let paid = invoice(#"{"id":"inv\#(march1Ms)","customer":"Acme","number":"INV-1","desc":"Job","amount":1000,"due":"2026-03-01","paid":false,"email":"a@x.com","phone":"555","payments":[{"id":"p1","amount":400,"date":"2026-03-01","method":"cash"},{"id":"p2","amount":600,"date":"2026-04-10","method":"cash"}]}"#)
    let lumber = expense(#"{"id":"e1","createdAt":"2026-03-05","description":"Lumber","amount":250.5,"category":"materials","date":"2026-03-05","notes":""}"#)
    let zed = customer(#"{"id":"c1","name":"Zed","email":"","phone":"","address":"","notes":""}"#)
    return NativePackageInput(invoices: [paid], expenses: [lumber], customers: [zed])
}

private func testSummaryAndPackage() {
    let summary = NativeAccountingPackage.buildSummary(sampleInput(), start: jan1, end: dec31)
    expectEqual(summary.cashCollected, 1000, "cash collected")
    expectEqual(summary.expensesTotal, Decimal(string: "250.5"), "expenses total")
    expectEqual(summary.netCash, Decimal(string: "749.5"), "net cash")
    expectEqual(summary.invoicesCount, 1, "in-scope invoice count")
    expectEqual(summary.customersCount, 1, "customer count")
    expectEqual(summary.warningsCount, 1, "warnings count (missing line items)")
    expectEqual(summary.netCashBasis, "cash basis; before owner labor", "net cash basis label")

    let json = NativeAccountingPackage.buildSummaryJson(summary)
    let expected = """
    {
      "range_start": "2026-01-01",
      "range_end": "2026-12-31",
      "cash_collected": 1000,
      "voided_amount": 0,
      "expenses_total": 250.5,
      "net_cash": 749.5,
      "net_cash_basis": "cash basis; before owner labor",
      "invoices_count": 1,
      "customers_count": 1,
      "mileage_trips_count": 0,
      "mileage_miles_total": 0,
      "warnings_count": 1
    }
    """
    expectEqual(json, expected, "summary JSON matches JSON.stringify(_, null, 2)")

    let readme = NativeAccountingPackage.buildReadme(summary)
    expect(readme.hasPrefix("TradeReady accounting export\nDate range: 2026-01-01 to 2026-12-31\n"), "README header lines")
    expect(readme.hasSuffix("before paying yourself).\n"), "README trailing newline")

    expectEqual(NativeAccountingPackage.packageFilename(start: jan1, end: dec31, allTime: false), "TradeReady-Accounting_2026-01-01_2026-12-31.zip", "package filename")
    expectEqual(NativeAccountingPackage.packageFilename(start: Date(timeIntervalSince1970: 0), end: dec31, allTime: true), "TradeReady-Accounting_all-time.zip", "all-time package filename")

    let first = NativeAccountingPackage.buildAccountingPackage(sampleInput(), start: jan1, end: dec31)
    let second = NativeAccountingPackage.buildAccountingPackage(sampleInput(), start: jan1, end: dec31)
    expectEqual(first.filename, "TradeReady-Accounting_2026-01-01_2026-12-31.zip", "assembled filename")
    expectEqual(first.bytes, second.bytes, "package is byte-deterministic")
    // Byte-identical to the React Native export for this input: same length and
    // same CRC-32 over the whole archive, captured from the live oracle.
    expectEqual(first.bytes.count, 3931, "package byte length matches the RN oracle")
    expectEqual(NativeZipArchive.crc32(first.bytes), 555_132_606, "package CRC-32 matches the RN oracle")

    let emptyPackage = NativeAccountingPackage.buildAccountingPackage(NativePackageInput(), start: jan1, end: dec31)
    expectEqual(emptyPackage.bytes.count, 3626, "empty package byte length matches the RN oracle")
    expectEqual(NativeZipArchive.crc32(emptyPackage.bytes), 117_099_229, "empty package CRC-32 matches the RN oracle")

    let expectedOrder = [
        "invoices.csv", "invoice-line-items.csv", "active-payments.csv", "payment-activity.csv",
        "expenses.csv", "mileage.csv", "customers.csv", "category-mapping.csv",
        "export-warnings.csv", "summary.json", "README.txt",
    ]
    let entries = decodePackage(first.bytes)
    expectEqual(entries.map(\.name), expectedOrder, "fixed entry order")
    expectEqual(entries.count, 11, "eleven entries")

    for entry in entries where entry.name.hasSuffix(".csv") {
        expectEqual(Array(entry.data.prefix(3)), [0xEF, 0xBB, 0xBF], "\(entry.name) carries a UTF-8 BOM")
    }
    for name in ["summary.json", "README.txt"] {
        guard let entry = entries.first(where: { $0.name == name }) else { continue }
        expect(Array(entry.data.prefix(3)) != [0xEF, 0xBB, 0xBF], "\(name) has no BOM")
    }
    guard let summaryEntry = entries.first(where: { $0.name == "summary.json" }) else { return }
    expectEqual(String(decoding: summaryEntry.data, as: UTF8.self), json, "summary.json body matches the builder")
}

// MARK: - minimal stored-ZIP reader (names + bytes)

private struct PackageEntry: Equatable {
    var name: String
    var data: [UInt8]
}

private func readU16(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
}

private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
}

private func decodePackage(_ zip: [UInt8]) -> [PackageEntry] {
    var eocd = -1
    var i = zip.count - 22
    while i >= 0 {
        if readU32(zip, i) == 0x0605_4B50 { eocd = i; break }
        i -= 1
    }
    guard eocd >= 0 else { return [] }
    let count = readU16(zip, eocd + 10)
    var cursor = Int(readU32(zip, eocd + 16))
    var entries: [PackageEntry] = []
    for _ in 0..<count {
        let compressedSize = Int(readU32(zip, cursor + 20))
        let nameLen = readU16(zip, cursor + 28)
        let extraLen = readU16(zip, cursor + 30)
        let commentLen = readU16(zip, cursor + 32)
        let localOffset = Int(readU32(zip, cursor + 42))
        let localNameLen = readU16(zip, localOffset + 26)
        let localExtraLen = readU16(zip, localOffset + 28)
        let nameStart = localOffset + 30
        let nameBytes = Array(zip[nameStart..<(nameStart + localNameLen)])
        let dataStart = nameStart + localNameLen + localExtraLen
        entries.append(PackageEntry(
            name: String(decoding: nameBytes, as: UTF8.self),
            data: Array(zip[dataStart..<(dataStart + compressedSize)])
        ))
        cursor += 46 + nameLen + extraLen + commentLen
    }
    return entries
}

// MARK: - run

testScope()
testBuilders()
testWarnings()
testSummaryAndPackage()

if failures == 0 {
    print("AccountingPackageTests: all checks passed")
} else {
    print("AccountingPackageTests: \(failures) failure(s)")
    exit(1)
}
