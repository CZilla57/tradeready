import Foundation

// Import column-mapping + date tests (task 9.07).
//
// Ports __tests__/importMapping.test.ts: the foreign-header vocabularies
// (Jobber / Housecall Pro / QuickBooks), longest-first matching, date-format
// detection including ambiguity and 4-digit-first, and local-frame date parsing
// with rollover rejection.

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

private func testMapping() {
    let jobber = NativeImportMapping.detectMapping(entity: .jobs, headers: ["Job Title", "Client Name", "Job Status", "Start Date"])
    expectEqual(jobber, ["title", "customerName", "status", "scheduledDate"], "Jobber job headers map")

    let housecall = NativeImportMapping.detectMapping(entity: .customers, headers: ["Customer", "Email", "Mobile Phone", "Street Address", "Comments"])
    expectEqual(housecall, ["name", "email", "phone", "address", "notes"], "Housecall customer headers map")

    let quickbooks = NativeImportMapping.detectMapping(entity: .expenses, headers: ["Transaction Date", "Vendor", "Debit", "Account", "Memo"])
    expectEqual(quickbooks, ["date", "description", "amount", "category", "description"], "QuickBooks expense headers map (Memo is a description synonym)")

    // Longest-phrase-first: "Estimate Total" must win over the bare "Total".
    let longest = NativeImportMapping.detectMapping(entity: .jobs, headers: ["Estimate Total", "Total"])
    expectEqual(longest, ["estimateTotal", "estimateTotal"], "longest phrase wins")

    // Unknown headers map to nil; underscores/dashes normalize to spaces.
    let unknown = NativeImportMapping.detectMapping(entity: .customers, headers: ["Favourite Colour", "phone_number"])
    expectEqual(unknown, [nil, "phone"], "unknown header nil, snake_case normalizes")
}

private func testDateDetection() {
    expectEqual(NativeImportMapping.detectDateFormat(samples: ["2026-03-01"]), .ymd, "ISO is YMD")
    expectEqual(NativeImportMapping.detectDateFormat(samples: ["01/02/2026"]), .mdy, "ambiguous defaults to MDY")
    expectEqual(NativeImportMapping.detectDateFormat(samples: ["25/02/2026"]), .dmy, "first slot > 12 is DMY")
    expectEqual(NativeImportMapping.detectDateFormat(samples: ["02/25/2026"]), .mdy, "second slot > 12 is MDY")
    expectEqual(NativeImportMapping.detectDateFormat(samples: ["2026/02/25"]), .ymd, "4-digit-first is YMD")
    expectEqual(NativeImportMapping.detectDateFormat(samples: ["", "   "]), nil, "no numeric samples")
    expectEqual(NativeImportMapping.detectDateFormat(samples: ["not a date"]), nil, "unparseable samples")
    expectEqual(NativeImportMapping.detectDateFormat(samples: ["1.5.2026", "25.5.2026"]), .dmy, "dot separators supported")
}

private func testParseImportDate() {
    expectEqual(NativeImportMapping.parseImportDate("2026-03-01", format: nil), "2026-03-01", "ISO parses")
    expectEqual(NativeImportMapping.parseImportDate("03/01/2026", format: .mdy), "2026-03-01", "MDY parses")
    expectEqual(NativeImportMapping.parseImportDate("01/03/2026", format: .dmy), "2026-03-01", "DMY parses day/month/year")
    expectEqual(NativeImportMapping.parseImportDate("2026/03/01", format: nil), "2026-03-01", "4-digit-first parses as YMD")
    expectEqual(NativeImportMapping.parseImportDate("3/1/26", format: .mdy), "2026-03-01", "2-digit year expands")
    expectEqual(NativeImportMapping.parseImportDate("", format: nil), nil, "empty date")
    expectEqual(NativeImportMapping.parseImportDate("garbage", format: nil), nil, "unparseable date")
    expectEqual(NativeImportMapping.parseImportDate("13/13/2026", format: .mdy), nil, "month 13 rejected")
    expectEqual(NativeImportMapping.parseImportDate("02/31/2026", format: .mdy), nil, "rollover date rejected")
    expectEqual(NativeImportMapping.parseImportDate("02/29/2026", format: .mdy), nil, "non-leap Feb 29 rejected")
    expectEqual(NativeImportMapping.parseImportDate("02/29/2024", format: .mdy), "2024-02-29", "leap Feb 29 accepted")
    // Local frame: a date-only value must not shift a day.
    expectEqual(NativeImportMapping.parseImportDate("2026-01-01", format: nil), "2026-01-01", "first of month stays put")
}

private func testFieldDefs() {
    expectEqual(NativeImportMapping.fieldDefs[.customers]?.first?.key, "name", "customer first field")
    expect(NativeImportMapping.fieldDefs[.jobs]?.first { $0.key == "title" }?.required == true, "job title required")
    expect(NativeImportMapping.fieldDefs[.invoices]?.first { $0.key == "amount" }?.required == true, "invoice amount required")
    expect(NativeImportMapping.fieldDefs[.expenses]?.first { $0.key == "date" }?.required == true, "expense date required")
}

testMapping()
testDateDetection()
testParseImportDate()
testFieldDefs()

if failures == 0 {
    print("ImportMappingTests: all checks passed")
} else {
    print("ImportMappingTests: \(failures) failure(s)")
    exit(1)
}
