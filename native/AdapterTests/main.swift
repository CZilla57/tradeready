import Foundation

private var failures = 0
private let decoder = JSONDecoder()
private let encoder = JSONEncoder()

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func fixture(_ name: String) throws -> [String: Canonical.JSONValue] {
    let root = ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!
    return try decoder.decode([String: Canonical.JSONValue].self,
                              from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name)))
}

private func field<T: Decodable>(_ key: String, _ source: [String: Canonical.JSONValue], as: T.Type = T.self) throws -> T {
    try decoder.decode(T.self, from: encoder.encode(source[key]!))
}

private func json<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
    try decoder.decode(Canonical.JSONValue.self, from: encoder.encode(value))
}

private func object<T: Encodable>(_ value: T) throws -> [String: Canonical.JSONValue] {
    guard case let .object(result) = try json(value) else { fatalError("expected object") }
    return result
}

private func run(_ label: String, _ body: () throws -> Void) {
    do { try body() } catch { failures += 1; print("FAIL: \(label) — \(error)") }
}

let rich = try! fixture("canonical-rich.json")
let forward = try! fixture("canonical-forward-compatible.json")

run("unedited records are lossless") {
    let customer: Canonical.Customer = try field("customer", rich)
    let job: Canonical.Job = try field("job", rich)
    let invoice: Canonical.Invoice = try field("invoice", rich)
    let expense: Canonical.Expense = try field("expense", rich)
    let settings: Canonical.Settings = try field("settings", rich)
    let customerResult = try json(CanonicalUIAdapters.canonical(from: CanonicalUIAdapters.edit(customer)))
    let jobResult = try json(CanonicalUIAdapters.canonical(from: CanonicalUIAdapters.edit(job)))
    let invoiceResult = try json(CanonicalUIAdapters.canonical(from: CanonicalUIAdapters.edit(invoice)))
    let expenseResult = try json(CanonicalUIAdapters.canonical(from: CanonicalUIAdapters.edit(expense)))
    let settingsResult = try json(CanonicalUIAdapters.canonical(from: CanonicalUIAdapters.edit(settings)))
    expect(customerResult == rich["customer"], "customer exact round trip")
    expect(jobResult == rich["job"], "job exact round trip")
    expect(invoiceResult == rich["invoice"], "invoice exact round trip")
    expect(expenseResult == rich["expense"], "expense exact round trip")
    expect(settingsResult == rich["settings"], "settings exact round trip")
}

run("customer edits preserve canonical-only fields") {
    let source: Canonical.Customer = try field("customer", rich)
    var edit = try CanonicalUIAdapters.edit(source)
    expect(edit.value.archivedAt == "2026-08-20", "customer archive projects into native UI state")
    edit.value.name = "Grace Hopper"
    edit.value.archivedAt = nil
    let result = try CanonicalUIAdapters.canonical(from: edit)
    let encoded = try object(result)
    expect(result.name == "Grace Hopper", "customer editable field merged")
    let sourceFields = try object(source)
    expect(encoded["portal"] == sourceFields["portal"], "customer portal preserved")
    expect(encoded["archivedAt"] == nil, "customer archive can be cleared without touching siblings")
}

run("job edits preserve rich and unknown fields") {
    let source: Canonical.Job = try field("job", rich)
    var edit = try CanonicalUIAdapters.edit(source)
    expect(edit.value.archivedAt == source.archivedAt, "job archive projects into native search state")
    edit.value.title = "Updated panel"
    edit.value.laborHours = 7.5
    let result = try CanonicalUIAdapters.canonical(from: edit)
    expect(result.title == "Updated panel" && result.laborHours == Decimal(string: "7.5")!, "job editable fields merged")
    let resultMaterials = try json(result.materials), sourceMaterials = try json(source.materials)
    let resultApproval = try json(result.approval), sourceApproval = try json(source.approval)
    expect(resultMaterials == sourceMaterials, "job materials preserved")
    expect(resultApproval == sourceApproval, "job approval preserved")
    expect(result.archivedAt == source.archivedAt, "untouched job archive marker is preserved")

    let future: Canonical.Job = try field("job", forward)
    var futureEdit = try CanonicalUIAdapters.edit(future)
    expect(futureEdit.value.status == .lead, "unknown status has safe UI fallback")
    futureEdit.value.title = "Still future"
    let futureResult = try CanonicalUIAdapters.canonical(from: futureEdit)
    expect(futureResult.status == "server_new_status", "unknown status retained when untouched")
    expect(futureResult.preservation.unknownFields["futureJobField"] != nil, "unknown job field retained")
}

run("job duplication carries only the production whitelist") {
    let source: Canonical.Job = try field("job", rich)
    let sourceBefore = try json(source)
    let createdAt = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
    let draft = try CanonicalUIAdapters.duplicateJob(
        source,
        id: "j999",
        createdAt: createdAt
    )
    let duplicate = draft.canonicalTemplate

    expect(duplicate.id == "j999" && duplicate.status == "lead", "duplicate gets a fresh ID and lead status")
    expect(duplicate.customerId == source.customerId
           && duplicate.customerName == source.customerName
           && duplicate.title == source.title
           && duplicate.description == source.description
           && duplicate.address == source.address
           && duplicate.notes == source.notes,
           "duplicate carries customer and descriptive fields")
    let duplicateMaterials = try json(duplicate.materials)
    let sourceMaterials = try json(source.materials)
    expect(duplicate.estimateTotal == source.estimateTotal
           && duplicate.laborHours == source.laborHours
           && duplicate.laborRate == source.laborRate
           && duplicate.materialMarkup == source.materialMarkup
           && duplicate.overhead == source.overhead
           && duplicate.margin == source.margin
           && duplicateMaterials == sourceMaterials,
           "duplicate carries the exact priced estimate and material records")
    expect(duplicate.scheduledDate == nil
           && duplicate.scheduledStartTime == nil
           && duplicate.scheduledEndTime == nil
           && duplicate.laborBreakdown == nil
           && duplicate.jobCosts == nil
           && duplicate.invoiceId == nil
           && duplicate.photos == nil
           && duplicate.timeSessions == nil
           && duplicate.recurringJobId == nil
           && duplicate.occurrenceNumber == nil
           && duplicate.estimateSentAt == nil
           && duplicate.approval == nil
           && duplicate.changeOrders == nil
           && duplicate.archivedAt == nil
           && duplicate.importBatchId == nil,
           "duplicate clears schedule, lifecycle, recurrence, field-work, cost, and sync metadata")
    let duplicateFields = try object(duplicate)
    expect(duplicateFields["invoiceId"] == .null, "duplicate writes the React Native null invoice link")
    let sourceAfter = try json(source)
    expect(sourceAfter == sourceBefore, "building or editing a duplicate never mutates its source")

    var editedDraft = try CanonicalUIAdapters.edit(duplicate)
    editedDraft.value.title = "Edited duplicate"
    let editedDuplicate = try CanonicalUIAdapters.canonical(from: editedDraft)
    let editedDuplicateMaterials = try json(editedDuplicate.materials)
    expect(editedDuplicateMaterials == sourceMaterials,
           "duplicate editor merge retains hidden carried materials")

    let forwardSource: Canonical.Job = try field("job", forward)
    let forwardDraft = try CanonicalUIAdapters.duplicateJob(
        forwardSource,
        id: "j1000",
        createdAt: createdAt
    )
    expect(forwardDraft.canonicalTemplate.preservation.unknownFields["futureJobField"] == nil,
           "source-level unknown fields are not copied into a new job lifecycle")
}

run("pricing draft updates only calculator-owned canonical fields") {
    let source: Canonical.Job = try field("job", rich)
    let settings: Canonical.Settings = try field("settings", rich)
    var draft = NativeJobPricingDraft(job: source, settings: settings)
    draft.laborHours = 8
    draft.laborRate = 150
    draft.materialMarkup = 25
    draft.overheadPercent = 10
    draft.marginPercent = 20
    draft.travelMiles = 12
    draft.travelFeePerMile = 2
    draft.taxPercent = 5
    draft.laborBreakdown = try CanonicalUIAdapters.newLaborBreakdown(onSiteHours: 6)
    draft.laborBreakdown?.driveHours = 1
    draft.laborBreakdown?.supplyRunHours = Decimal(string: "0.5")!
    draft.laborBreakdown?.setupCleanupHours = Decimal(string: "0.5")!
    draft.laborBreakdown?.nonBillableNote = "Waiting for cure"
    var firstMaterial = draft.materials[0]
    firstMaterial.quantity = 3
    draft.materials[0] = firstMaterial
    draft.materials.append(try CanonicalUIAdapters.newPricingMaterial(id: "m-new"))
    draft.jobCosts.append(try CanonicalUIAdapters.newPricingJobCost(id: "jc-new"))

    let result = try CanonicalUIAdapters.canonical(from: draft, baseline: source)
    expect(result.laborHours == 8
           && result.laborBreakdown?.onSiteHours == 6
           && result.laborBreakdown?.driveHours == 1
           && result.laborBreakdown?.nonBillableNote == "Waiting for cure"
           && result.laborRate == 150
           && result.materials.count == 2
           && result.jobCosts?.count == 3
           && result.estimateTotal == PricingEngine.calculate(draft.input).total,
           "pricing save carries the full Decimal calculator block and computed total")
    expect(result.status == source.status
           && result.scheduledDate == source.scheduledDate
           && result.invoiceId == source.invoiceId
           && result.approval?.token == source.approval?.token
           && result.changeOrders?.count == source.changeOrders?.count
           && result.recurringJobId == source.recurringJobId
           && result.photos == source.photos
           && result.timeSessions?.count == source.timeSessions?.count
           && result.archivedAt == source.archivedAt
           && result.importBatchId == source.importBatchId,
           "pricing save preserves lifecycle, approval, recurrence, field, and archive metadata")
    expect(result.jobCosts?.first?.notes == "Paid at counter",
           "editing pricing retains unknown nested direct-cost metadata")
}

run("estimate approval snapshot freezes only customer-facing saved values") {
    let source: Canonical.Job = try field("job", rich)
    let settings: Canonical.Settings = try field("settings", rich)
    expect(CanonicalUIAdapters.canonicalJobsMatch(source, source),
           "exact canonical job comparison accepts an unchanged revision baseline")
    var changedJob = source
    changedJob.notes = "concurrent owner edit"
    expect(!CanonicalUIAdapters.canonicalJobsMatch(source, changedJob),
           "revision baseline comparison detects unrelated concurrent job changes")
    let snapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: source,
        customerName: "Customer record name",
        businessName: settings.businessName
    )
    expect(snapshot.businessName == "Ada Electric"
           && snapshot.customerName == "Customer record name"
           && snapshot.jobTitle == "Panel upgrade"
           && snapshot.total == source.estimateTotal
           && snapshot.currency == "USD",
           "estimate snapshot freezes business, customer, title, total, and currency")
    expect(snapshot.lineItems.first?.label == "Labor (6.25 hrs @ $125.125/hr)"
           && snapshot.lineItems.first?.amount == Decimal(string: "782.03125")!,
           "estimate snapshot labor line uses exact saved Decimal inputs")
    expect(snapshot.lineItems.contains(where: { $0.label == "Materials (1 item)" }),
           "estimate snapshot includes the material aggregate")
    expect(snapshot.lineItems.contains(where: { $0.label == "City permit" && $0.amount == Decimal(string: "87.65")! }),
           "estimate snapshot includes visible direct costs")
    expect(!snapshot.lineItems.contains(where: { $0.label == "Lift rental" }),
           "estimate snapshot never exposes hidden direct costs")
    expect(snapshot.lineItems.last?.label == "Overhead & operating costs",
           "estimate snapshot folds the residual into the customer operating-cost line")

    var exact = source
    exact.estimateTotal = exact.laborHours * exact.laborRate
        + exact.materials.reduce(Decimal.zero) { $0 + $1.quantity * $1.unitCost }
            * (1 + exact.materialMarkup / 100)
        + Decimal(string: "87.65")!
    let noResidual = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: exact,
        customerName: nil,
        businessName: ""
    )
    expect(noResidual.businessName == "Your tradesperson"
           && noResidual.customerName == source.customerName,
           "estimate snapshot uses React Native identity fallbacks")
    expect(!noResidual.lineItems.contains(where: { $0.label == "Overhead & operating costs" }),
           "non-positive residual operating cost is omitted")

    var futurePolicy = source
    futurePolicy.jobCosts?[0].markupPercent = 50
    futurePolicy.jobCosts?[0].markupPolicy = "future_server_policy"
    let futurePolicySnapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: futurePolicy,
        customerName: nil,
        businessName: settings.businessName
    )
    expect(futurePolicySnapshot.lineItems.contains(where: {
        $0.label == "City permit" && $0.amount == Decimal(string: "87.65")!
    }), "unknown direct-cost policy remains pass-through in the frozen estimate")

    let freshApproval = try CanonicalUIAdapters.estimateApprovalAfterLink(
        existing: nil,
        snapshot: snapshot,
        token: String(repeating: "a", count: 48),
        sentAt: "2026-09-15T12:00:00.000Z"
    )
    expect(freshApproval.snapshot.total == snapshot.total
           && freshApproval.decision == nil,
           "fresh approval attaches the exact reviewed snapshot without inventing a decision")

    let approved = try CanonicalUIAdapters.estimateApprovalAfterLink(
        existing: source.approval,
        snapshot: noResidual,
        token: source.approval!.token,
        sentAt: "later"
    )
    expect(approved.snapshot.total == source.approval?.snapshot.total
           && approved.sentAt == source.approval?.sentAt
           && approved.signerName == "Ada",
           "approved estimate snapshot and consent metadata remain frozen")

    var declined = source.approval!
    declined.decision = "declined"
    let refreshed = try CanonicalUIAdapters.estimateApprovalAfterLink(
        existing: declined,
        snapshot: noResidual,
        token: declined.token,
        sentAt: "2026-09-15T13:00:00.000Z"
    )
    expect(refreshed.snapshot.total == noResidual.total
           && refreshed.sentAt == "2026-09-15T13:00:00.000Z"
           && refreshed.decision == "declined",
           "non-approved link refresh matches the backend while retaining additive metadata")
    expect(CanonicalUIAdapters.estimateApprovalsMatch(declined, declined),
           "archived declined approval exact-match includes consent metadata")
    var alteredDecline = declined
    alteredDecline.declineReason = "A different reason"
    expect(!CanonicalUIAdapters.estimateApprovalsMatch(declined, alteredDecline),
           "revision validation rejects rewritten customer consent metadata")

    expect(CanonicalUIAdapters.estimateApprovalSnapshotsMatch(snapshot, snapshot),
           "an unchanged reviewed estimate remains eligible after sync")
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(snapshot, noResidual),
           "a post-review canonical estimate change blocks stale approval-link minting")
    var changedLine = snapshot
    changedLine.lineItems[0].amount += 1
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(snapshot, changedLine),
           "line-item changes are part of the exact post-sync approval comparison")
}

run("invoice and payment edits preserve payment metadata") {
    let source: Canonical.Invoice = try field("invoice", rich)
    var edit = try CanonicalUIAdapters.edit(source)
    edit.value.description = "Updated description"
    edit.value.payments[1].amount = 75
    let result = try CanonicalUIAdapters.canonical(from: edit)
    expect(result.desc == "Updated description", "invoice description merged")
    expect(result.depositRequest != nil && result.lineItems?.count == 2, "invoice-only fields preserved")
    expect(result.payments?[1].stripeSessionId == "cs_test", "payment stripe session preserved")
    expect(result.payments?[1].method == "stripe", "unknown payment method retained")

    let future: Canonical.Invoice = try field("invoice", forward)
    var futureEdit = try CanonicalUIAdapters.edit(future)
    futureEdit.value.number = "F-2"
    let futureResult = try CanonicalUIAdapters.canonical(from: futureEdit)
    expect(futureResult.preservation.unknownFields["futureInvoiceField"] == .number(1), "unknown invoice field retained")
    expect(futureResult.payments?.first?.preservation.unknownFields["futurePaymentField"] == .bool(true), "unknown payment field retained")
}

run("legacy paid invoice displays paid and survives unrelated edits") {
    var fields = try object(try field("invoice", forward, as: Canonical.Invoice.self))
    fields["paid"] = .bool(true)
    fields["paidAt"] = .string("2021-02-03")
    fields.removeValue(forKey: "payments")
    let source: Canonical.Invoice = try decoder.decode(Canonical.Invoice.self, from: encoder.encode(fields))
    var edit = try CanonicalUIAdapters.edit(source)
    expect(edit.value.isPaid && edit.value.balance == 0 && edit.value.amountPaid == edit.value.amount,
           "legacy paid flag represented by UI")
    expect(edit.value.legacyPaidAt?.dateOnlyString == "2021-02-03",
           "legacy paid date is projected for accurate history")
    expect(edit.value.effectivePayments.first?.date.dateOnlyString == "2021-02-03",
           "legacy history materializes on the original settlement date")
    edit.value.description = "Unrelated edit"
    let result = try CanonicalUIAdapters.canonical(from: edit)
    expect(result.paid && result.paidAt == "2021-02-03" && result.payments == nil,
           "legacy paid state, date, and absent ledger preserved")

    let corrected = edit.value.voidingPayment(id: "legacy_\(edit.value.id)", on: edit.value.due)
    var correctionEdit = try CanonicalUIAdapters.edit(source)
    correctionEdit.value = corrected
    let correction = try CanonicalUIAdapters.canonical(from: correctionEdit)
    expect(correction.payments?.first?.voidedAt != nil && !correction.paid,
           "voiding legacy history materializes a retained correction entry")
}

run("expense edits preserve linkage and creation metadata") {
    let source: Canonical.Expense = try field("expense", rich)
    var edit = try CanonicalUIAdapters.edit(source)
    edit.value.merchant = "Supply House"
    let result = try CanonicalUIAdapters.canonical(from: edit)
    expect(result.description == "Supply House", "expense description mapped to merchant")
    expect(result.createdAt == source.createdAt && result.receiptUri == source.receiptUri && result.jobId == source.jobId,
           "expense canonical-only fields preserved")
}

run("settings edits merge nested schedule without loss") {
    let source: Canonical.Settings = try field("settings", forward)
    var edit = try CanonicalUIAdapters.edit(source)
    expect(edit.value.appointmentConfirmTemplate == source.appointmentConfirmTemplate
           && edit.value.onMyWayTemplate == source.onMyWayTemplate,
           "appointment templates project into native settings")
    edit.value.laborRate = 125
    edit.value.workDayStart = 7
    edit.value.onMyWayTemplate = "Hi {customerName}, heading your way."
    let result = try CanonicalUIAdapters.canonical(from: edit)
    expect(result.laborRate == 125, "settings scalar merged")
    expect(result.provider == "wire_transfer", "unknown provider retained")
    expect(result.schedule?.blackouts?.count == 1, "schedule blackout retained")
    expect(result.schedule?.preservation.unknownFields["futureScheduleField"] == .string("ignored"), "unknown nested schedule field retained")
    expect(result.preservation.unknownFields["futureSettingsField"] == .bool(true), "unknown settings field retained")
    expect(result.appointmentConfirmTemplate == source.appointmentConfirmTemplate
           && result.onMyWayTemplate == "Hi {customerName}, heading your way.",
           "appointment template edit merges without changing its sibling")
}


run("booking toggle cannot fabricate canonical token") {
    let source: Canonical.Settings = try field("settings", forward)
    var edit = try CanonicalUIAdapters.edit(source)
    expect(source.bookingLink == nil, "fixture starts without booking link")
    edit.value.bookingEnabled = true
    let result = try CanonicalUIAdapters.canonical(from: edit)
    expect(result.bookingLink == nil, "UI-only booking toggle does not create canonical credentials")
}

run("invalid canonical dates fail explicitly") {
    var fields = try object(try field("expense", rich, as: Canonical.Expense.self))
    fields["date"] = .string("not-a-date")
    let invalid: Canonical.Expense = try decoder.decode(Canonical.Expense.self, from: encoder.encode(fields))
    do {
        _ = try CanonicalUIAdapters.edit(invalid)
        expect(false, "invalid date should throw")
    } catch CanonicalUIAdapterError.invalidDate(let field, let value) {
        expect(field == "expense.date" && value == "not-a-date", "invalid date error includes context")
    }
}

run("local calendar dates do not shift in Phoenix") {
    var phoenix = Calendar(identifier: .gregorian)
    phoenix.timeZone = TimeZone(identifier: "America/Phoenix")!

    var jobFields = try object(try field("job", rich, as: Canonical.Job.self))
    jobFields["scheduledDate"] = .string("2026-07-08")
    jobFields["scheduledStartTime"] = .string("09:00")
    let job: Canonical.Job = try decoder.decode(Canonical.Job.self, from: encoder.encode(jobFields))
    let jobEdit = try CanonicalUIAdapters.edit(job, calendar: phoenix)
    let scheduled = phoenix.dateComponents([.year, .month, .day, .hour, .minute], from: jobEdit.value.scheduledAt!)
    expect(scheduled.year == 2026 && scheduled.month == 7 && scheduled.day == 8 && scheduled.hour == 9 && scheduled.minute == 0,
           "scheduled date and time project as local wall-clock values")
    let mergedJobJSON = try json(CanonicalUIAdapters.canonical(from: jobEdit)), sourceJobJSON = try json(job)
    expect(mergedJobJSON == sourceJobJSON, "untouched local schedule merges back exactly")

    var invoiceFields = try object(try field("invoice", rich, as: Canonical.Invoice.self))
    invoiceFields["due"] = .string("2026-07-08")
    let invoice: Canonical.Invoice = try decoder.decode(Canonical.Invoice.self, from: encoder.encode(invoiceFields))
    let invoiceEdit = try CanonicalUIAdapters.edit(invoice, calendar: phoenix)
    let due = phoenix.dateComponents([.year, .month, .day, .hour], from: invoiceEdit.value.due)
    expect(due.year == 2026 && due.month == 7 && due.day == 8 && due.hour == 0,
           "invoice date-only due date projects at local midnight")
    let mergedInvoiceJSON = try json(CanonicalUIAdapters.canonical(from: invoiceEdit)), sourceInvoiceJSON = try json(invoice)
    expect(mergedInvoiceJSON == sourceInvoiceJSON, "untouched invoice date merges back exactly")

    var expenseFields = try object(try field("expense", rich, as: Canonical.Expense.self))
    expenseFields["date"] = .string("2026-07-08")
    let expense: Canonical.Expense = try decoder.decode(Canonical.Expense.self, from: encoder.encode(expenseFields))
    let expenseEdit = try CanonicalUIAdapters.edit(expense, calendar: phoenix)
    let expenseDay = phoenix.dateComponents([.year, .month, .day, .hour], from: expenseEdit.value.date)
    expect(expenseDay.year == 2026 && expenseDay.month == 7 && expenseDay.day == 8 && expenseDay.hour == 0,
           "expense date-only value projects at local midnight")
    let mergedExpenseJSON = try json(CanonicalUIAdapters.canonical(from: expenseEdit)), sourceExpenseJSON = try json(expense)
    expect(mergedExpenseJSON == sourceExpenseJSON, "untouched expense date merges back exactly")
}

run("React Native blank and ISO schedule values project without loss") {
    var phoenix = Calendar(identifier: .gregorian)
    phoenix.timeZone = TimeZone(identifier: "America/Phoenix")!

    var blankFields = try object(try field("job", rich, as: Canonical.Job.self))
    blankFields["scheduledDate"] = .string("")
    blankFields["scheduledStartTime"] = .string("")
    blankFields["scheduledEndTime"] = .string("")
    let blankJob: Canonical.Job = try decoder.decode(Canonical.Job.self, from: encoder.encode(blankFields))
    let blankEdit = try CanonicalUIAdapters.edit(blankJob, calendar: phoenix)
    expect(blankEdit.value.scheduledAt == nil && blankEdit.value.scheduledEnd == nil,
           "blank RN schedule strings project as unscheduled")
    let mergedBlankJSON = try json(CanonicalUIAdapters.canonical(from: blankEdit))
    let sourceBlankJSON = try json(blankJob)
    expect(mergedBlankJSON == sourceBlankJSON,
           "untouched blank RN schedule strings survive canonical merge")

    var isoFields = try object(try field("job", rich, as: Canonical.Job.self))
    isoFields["scheduledDate"] = .string("2026-07-08T00:00:00.000Z")
    isoFields["scheduledStartTime"] = .string("09:05")
    let isoJob: Canonical.Job = try decoder.decode(Canonical.Job.self, from: encoder.encode(isoFields))
    let isoEdit = try CanonicalUIAdapters.edit(isoJob, calendar: phoenix)
    let projected = phoenix.dateComponents([.year, .month, .day, .hour, .minute], from: isoEdit.value.scheduledAt!)
    expect(projected.year == 2026 && projected.month == 7 && projected.day == 8
           && projected.hour == 9 && projected.minute == 5,
           "ISO legacy schedule keeps its intended local day and clock time")
    let mergedISOJSON = try json(CanonicalUIAdapters.canonical(from: isoEdit))
    let sourceISOJSON = try json(isoJob)
    expect(mergedISOJSON == sourceISOJSON,
           "untouched ISO legacy schedule survives canonical merge")
}

if failures == 0 { print("PASS: canonical SwiftUI adapter tests") }
else { print("\(failures) adapter test(s) failed"); exit(1) }
