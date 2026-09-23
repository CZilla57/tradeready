import Foundation

// Import engine tests (task 9.07).
//
// Ports __tests__/importEngine*.test.ts: customers (join + blank-field backfill +
// notes-on-create-only), jobs (status mapping, flag-not-skip, unique ids),
// invoices (paid only from a real paid date, number fallback, unique id, matched
// vs created counts), expenses (category mapping), stripBatch undo, and the
// deterministic batch id.

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

private func environment(nowMs: Int64 = 1_772_323_200_000) -> NativeImportEnvironment {
    var customerCounter = 0
    var jobCounter = 0
    var expenseCounter = 0
    return NativeImportEnvironment(
        nowMs: { nowMs },
        today: { "2026-03-01" },
        newCustomerID: { customerCounter += 1; return "c\(customerCounter)" },
        newJobID: { jobCounter += 1; return "j\(jobCounter)" },
        newExpenseID: { expenseCounter += 1; return "e\(expenseCounter)" }
    )
}

private func customer(_ id: String, _ name: String, email: String = "") -> Canonical.Customer {
    NativeImportEngine.decode(Canonical.Customer.self, [
        "id": .string(id), "name": .string(name), "email": .string(email),
        "phone": .string(""), "address": .string(""), "notes": .string(""),
    ])!
}

// MARK: - customers

private func testCustomers() {
    let existing = [customer("c-existing", "Ada Lovelace", email: "ada@x.com")]
    let rows = [
        ["Ada Lovelace", "", ""],        // matched (blank fields backfilled)
        ["Grace Hopper", "g@x.com", "NASA"], // created
        ["", "", ""],                     // skipped
    ]
    let mapping: [String?] = ["name", "email", "notes"]
    let result = NativeImportEngine.buildCustomerImport(
        rows: rows, mapping: mapping, existing: existing, batchID: "imp_1", environment: environment()
    )
    expectEqual(result.counts.matched, 1, "one matched customer")
    expectEqual(result.counts.created, 1, "one created customer")
    expectEqual(result.counts.skip, 1, "blank name skipped")
    expectEqual(result.records.count, 2, "registry grew by one")
    expectEqual(result.outcomes.map(\.status), ["ok", "ok", "skip"], "row outcomes")

    let created = result.records.first { $0.name == "Grace Hopper" }!
    expectEqual(NativeImportEngine.fields(created)["importBatchId"], .string("imp_1"), "created customer stamped")
    let existingAfter = result.records.first { $0.id == "c-existing" }!
    expect(NativeImportEngine.fields(existingAfter)["importBatchId"] == nil, "matched customer not stamped")
    expectEqual(existingAfter.email, "ada@x.com", "existing email not clobbered")
    expectEqual(NativeImportEngine.fields(existingAfter)["notes"], .string(""), "matched customer notes untouched")
}

// MARK: - jobs

private func testJobs() {
    let rows = [
        ["Deck build", "Acme", "Approved", "2026-04-01"],
        ["Fence", "Acme", "Totally Unknown", ""],
        ["", "Acme", "", ""],
    ]
    let mapping: [String?] = ["title", "customerName", "status", "scheduledDate"]
    let result = NativeImportEngine.buildJobImport(
        rows: rows, mapping: mapping, existingCustomers: [], existingJobs: [],
        batchID: "imp_2", dateFormat: nil, environment: environment()
    )
    expectEqual(result.counts.ok, 1, "one clean job")
    expectEqual(result.counts.flag, 1, "unknown status flagged, not skipped")
    expectEqual(result.counts.skip, 1, "missing title skipped")
    expectEqual(result.outcomes.map(\.status), ["ok", "flag", "skip"], "job outcomes")
    expectEqual(result.jobs.count, 2, "two jobs created")
    expectEqual(result.customers.count, 1, "Acme joined once, not twice")
    expectEqual(result.jobs[0].status, "approved", "status mapped")
    expectEqual(result.jobs[0].scheduledDate, "2026-04-01", "scheduled date parsed")
    expectEqual(result.jobs[1].status, "lead", "unknown status falls back to lead")
    expectEqual(NativeImportEngine.fields(result.jobs[0])["importBatchId"], .string("imp_2"), "job stamped")
    expect(NativeImportEngine.fields(result.jobs[0])["estimateSentAt"] == nil, "no estimateSentAt on imported jobs")

    expectEqual(NativeImportEngine.mapJobStatus("Quote sent").status, "estimate_sent", "quote sent maps")
    expectEqual(NativeImportEngine.mapJobStatus("completed").status, "complete", "completed maps")
    expectEqual(NativeImportEngine.mapJobStatus("nonsense").recognized, false, "unrecognized flagged")
}

// MARK: - invoices

private func testInvoices() {
    let rows = [
        ["Acme", "$1,250.50", "INV-9", "2026-04-01", "2026-04-10"],  // paid
        ["Acme", "800", "", "", "Yes"],                               // paid claim, no date
        ["Beta", "", "", "", ""],                                     // no amount → skip
    ]
    let mapping: [String?] = ["customer", "amount", "number", "due", "paidAt"]
    let result = NativeImportEngine.buildInvoiceImport(
        rows: rows, mapping: mapping, existingCustomers: [], existingInvoices: [],
        batchID: "imp_3", dateFormat: nil, invoicePrefix: nil, invoiceStartNumber: nil,
        environment: environment()
    )
    expectEqual(result.counts.ok, 1, "one clean invoice")
    expectEqual(result.counts.flag, 1, "paid claim flagged")
    expectEqual(result.counts.skip, 1, "missing amount skipped")
    // The missing-amount guard runs BEFORE the customer upsert, so Beta is never created.
    expectEqual(result.counts.created, 1, "only the valid row's customer is created")
    expectEqual(result.invoices.count, 2, "two invoices created")
    expectEqual(result.invoices[0].amount, Decimal(string: "1250.5"), "money parsed and stripped of symbols")
    expectEqual(result.invoices[0].paid, true, "paid only from a real paid date")
    expectEqual(result.invoices[0].paidAt, "2026-04-10", "paidAt recorded")
    expectEqual(result.invoices[0].number, "INV-9", "mapped number kept")
    expectEqual(result.invoices[1].paid, false, "paid claim without a date imports outstanding")
    // nextInvoiceNumber scans the ALREADY-accumulated invoices (= RN), so the
    // INV-9 created by the first row bumps the fallback to INV-0010.
    expectEqual(result.invoices[1].number, "INV-0010", "missing number falls back to nextInvoiceNumber")
    expect(!result.invoices[1].id.isEmpty, "unique id assigned")

    // Ids are unique and decode back to the source issue date.
    expectEqual(
        NativeAccountingPackage.recoverIssueDate(result.invoices[0].id), "2026-04-01",
        "imported id decodes to the issue date"
    )
    expect(result.invoices[0].id != result.invoices[1].id, "ids are unique")

    // Cross-session collision bumps the slot instead of reusing an id.
    var used: Set<String> = ["\(1_775_001_600_000 + 1)"]
    let bumped = NativeImportEngine.uniqueImportInvoiceID(
        dateString: "2026-04-01", index: 0, nowMs: 1_775_001_600_000, usedIDs: &used
    )
    expect(bumped != "\(1_775_001_600_000 + 1)", "collision bumps the slot")

    expectEqual(NativeImportEngine.nextInvoiceNumber([], prefix: nil, startNumber: nil), "INV-0001", "first number")
    expectEqual(NativeImportEngine.nextInvoiceNumber([], prefix: "2026", startNumber: 5), "2026-0005", "start floor")
    let numbered = NativeImportEngine.decode(Canonical.Invoice.self, [
        "id": .string("1"), "customer": .string("A"), "number": .string("INV-0042"),
        "amount": .number(1), "due": .string("2026-01-01"), "email": .string(""),
        "phone": .string(""), "desc": .string(""), "paid": .bool(false),
    ])!
    expectEqual(NativeImportEngine.nextInvoiceNumber([numbered], prefix: nil, startNumber: nil), "INV-0043", "max+1")
}

// MARK: - expenses

private func testExpenses() {
    let rows = [
        ["42.50", "2026-03-05", "Lumber", "Materials"],
        ["10", "2026-03-06", "Snacks", "Totally Unknown"],
        ["", "2026-03-07", "No amount", ""],
        ["5", "not-a-date", "Bad date", ""],
    ]
    let mapping: [String?] = ["amount", "date", "description", "category"]
    let result = NativeImportEngine.buildExpenseImport(
        rows: rows, mapping: mapping, existingExpenses: [], batchID: "imp_4", dateFormat: nil, environment: environment()
    )
    expectEqual(result.counts.ok, 1, "one clean expense")
    expectEqual(result.counts.flag, 1, "unknown category flagged")
    expectEqual(result.counts.skip, 2, "missing amount and bad date skipped")
    expectEqual(result.expenses.count, 2, "two expenses created")
    expectEqual(result.expenses[0].category, "materials", "category mapped")
    expectEqual(result.expenses[0].amount, Decimal(string: "42.5"), "amount parsed")
    expectEqual(result.expenses[1].category, "other", "unknown category falls back to other")
    expectEqual(result.expenses[1].notes, "", "notes empty")
    expectEqual(NativeImportEngine.fields(result.expenses[0])["receiptUri"], .null, "imported expense has a null receipt")
    expectEqual(NativeImportEngine.fields(result.expenses[0])["importBatchId"], .string("imp_4"), "expense stamped")

    expectEqual(NativeImportEngine.mapExpenseCategory("gas").id, "fuel", "gas → fuel")
    expectEqual(NativeImportEngine.mapExpenseCategory("Subcontractor").id, "labor", "subcontractor → labor")
    expectEqual(NativeImportEngine.mapExpenseCategory("").recognized, false, "empty category unrecognized")
}

// MARK: - stripBatch (undo)

private func testStripBatch() {
    let records = [
        NativeImportEngine.decode(Canonical.Expense.self, [
            "id": .string("e1"), "createdAt": .string("2026-03-01"), "description": .string("a"),
            "amount": .number(1), "category": .string("other"), "date": .string("2026-03-01"),
            "notes": .string(""), "importBatchId": .string("imp_9"),
        ])!,
        NativeImportEngine.decode(Canonical.Expense.self, [
            "id": .string("e2"), "createdAt": .string("2026-03-01"), "description": .string("b"),
            "amount": .number(2), "category": .string("other"), "date": .string("2026-03-01"),
            "notes": .string(""),
        ])!,
    ]
    let remaining = NativeImportEngine.stripBatch(records, batchID: "imp_9") { expense -> String? in
        if case let .string(text)? = NativeImportEngine.fields(expense)["importBatchId"] { return text }
        return nil
    }
    expectEqual(remaining.map(\.id), ["e2"], "undo strips only the batch's own records")
}

// MARK: - run

testCustomers()
testJobs()
testInvoices()
testExpenses()
testStripBatch()

if failures == 0 {
    print("ImportEngineTests: all checks passed")
} else {
    print("ImportEngineTests: \(failures) failure(s)")
    exit(1)
}
