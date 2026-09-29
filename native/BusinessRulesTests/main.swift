import Foundation

private var failures = 0

private func expect<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ label: String) {
    let value = actual()
    guard value == expected else {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(value)")
        return
    }
}

private var utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

// Recurrence vectors transcribed from __tests__/recurrence.test.ts.
expect(RecurrenceRules.nextDate(after: "2026-07-08", cadence: .daily, calendar: utcCalendar), "2026-07-09", "daily")
expect(RecurrenceRules.nextDate(after: "2026-07-08", cadence: .weekly, calendar: utcCalendar), "2026-07-15", "weekly")
expect(RecurrenceRules.nextDate(after: "2026-07-08", cadence: .monthly, calendar: utcCalendar), "2026-08-08", "monthly")
expect(RecurrenceRules.nextDate(after: "2026-07-08", cadence: .quarterly, calendar: utcCalendar), "2026-10-08", "quarterly")
expect(RecurrenceRules.nextDate(after: "2026-07-08", cadence: .annually, calendar: utcCalendar), "2027-07-08", "annually")
expect(RecurrenceRules.nextDate(after: "2026-01-31", cadence: .monthly, calendar: utcCalendar), "2026-03-03", "JS month overflow")
expect(RecurrenceRules.nextDate(after: "2024-02-29", cadence: .annually, calendar: utcCalendar), "2025-03-01", "JS year overflow")
expect(RecurrenceRules.nextDate(after: "2026-07-31", cadence: .daily, calendar: utcCalendar), "2026-08-01", "month boundary")

func recurrenceState(
    _ condition: RecurrenceEndCondition = .never,
    count: Int? = nil,
    endDate: String? = nil,
    occurrences: Int = 0,
    next: String = "2026-07-08"
) -> RecurrenceState {
    RecurrenceState(endCondition: condition, endCount: count, endDate: endDate, occurrenceCount: occurrences, nextDueDate: next)
}
expect(RecurrenceRules.isEndConditionMet(recurrenceState(.never, occurrences: 9_999)), false, "never does not end")
expect(RecurrenceRules.isEndConditionMet(recurrenceState(.count, count: 3, occurrences: 3)), true, "count boundary")
expect(RecurrenceRules.isEndConditionMet(recurrenceState(.count, count: 3, occurrences: 2)), false, "count below boundary")
expect(RecurrenceRules.isEndConditionMet(recurrenceState(.date, endDate: "2026-07-07")), true, "date past boundary")
expect(RecurrenceRules.isEndConditionMet(recurrenceState(.date, endDate: "2026-07-08")), false, "end date still generates")
expect(
    RecurrenceRules.fastForwardedInvoiceDate(
        recurrenceState(next: "2026-07-01"), cadence: .weekly, through: "2026-07-08", calendar: utcCalendar
    ),
    "2026-07-15",
    "invoice resume skips elapsed occurrences"
)
expect(
    RecurrenceRules.fastForwardedInvoiceDate(
        recurrenceState(.count, count: 2, occurrences: 2, next: "2026-07-01"),
        cadence: .monthly,
        through: "2026-09-01",
        calendar: utcCalendar
    ),
    "2026-07-01",
    "ended invoice rule is not fast-forwarded"
)

// Invoice-number vectors transcribed from __tests__/invoiceNumber.test.ts.
expect(InvoiceNumberRules.nextNumber(existingNumbers: []), "INV-0001", "empty invoice sequence")
expect(InvoiceNumberRules.nextNumber(existingNumbers: ["INV-0002", "INV-0007"]), "INV-0008", "invoice max plus one")
expect(InvoiceNumberRules.nextNumber(existingNumbers: ["DRAFT", "INV-0003"]), "INV-0004", "ignore nonnumeric invoice")
expect(InvoiceNumberRules.nextNumber(existingNumbers: ["DRAFT", "FINAL"]), "INV-0001", "all nonnumeric")
expect(InvoiceNumberRules.nextNumber(existingNumbers: [nil, "INV-0002"]), "INV-0003", "legacy missing number")
expect(InvoiceNumberRules.nextNumber(existingNumbers: ["INV-9999"]), "INV-10000", "grow past padding")
expect(InvoiceNumberRules.nextNumber(existingNumbers: ["A1B2"]), "INV-0013", "concatenate digit runs")
expect(
    InvoiceNumberRules.nextNumber(existingNumbers: ["job-0004"], options: .init(prefix: "JOB")),
    "JOB-0005",
    "case-insensitive custom prefix"
)
expect(InvoiceNumberRules.nextNumber(existingNumbers: [], options: .init(prefix: "  ")), "INV-0001", "blank prefix")
expect(InvoiceNumberRules.nextNumber(existingNumbers: [], options: .init(prefix: "JOB- ")), "JOB-0001", "strip prefix suffix")
expect(InvoiceNumberRules.nextNumber(existingNumbers: [], options: .init(startingNumber: 500)), "INV-0500", "start floor")
expect(
    InvoiceNumberRules.nextNumber(existingNumbers: ["INV-0800"], options: .init(startingNumber: 500)),
    "INV-0801",
    "existing beats start floor"
)
expect(InvoiceNumberRules.nextNumber(existingNumbers: [], options: .init(startingNumber: 12.9)), "INV-0012", "fractional start floor")
expect(
    InvoiceNumberRules.nextNumber(existingNumbers: ["2026-0005"], options: .init(prefix: "2026")),
    "2026-0006",
    "digit-bearing prefix"
)
expect(
    InvoiceNumberRules.nextNumber(existingNumbers: ["INV-0007"], options: .init(prefix: "2026")),
    "2026-0008",
    "legacy sequence under new prefix"
)

// Lifecycle vectors transcribed from __tests__/jobStatus.test.js and
// __tests__/jobDunningParity.test.js.
expect(JobLifecycleRules.statusAfterScheduling(.approved, hasSchedule: true), .scheduled, "approved schedule transition")
for status in JobLifecycleStatus.allCases where status != .approved {
    expect(JobLifecycleRules.statusAfterScheduling(status, hasSchedule: true), status, "schedule no-regress \(status.rawValue)")
}
expect(JobLifecycleRules.canSendEstimate(status: .lead, estimateTotal: 1200), true, "lead can send priced estimate")
expect(JobLifecycleRules.canSendEstimate(status: .estimateSent, estimateTotal: 1200), true, "sent estimate can resend")
expect(JobLifecycleRules.canSendEstimate(status: .lead, estimateTotal: 0), false, "zero estimate cannot send")
expect(JobLifecycleRules.statusAfterEstimateDecision(.estimateSent, decision: .approved), .approved, "approval transition")
expect(JobLifecycleRules.statusAfterEstimateDecision(.lead, decision: .declined), .declined, "decline branch")
expect(JobLifecycleRules.statusAfterEstimateDecision(.scheduled, decision: .declined), .scheduled, "decision no-regress")
expect(JobLifecycleRules.canRequestDeposit(status: .approved), true, "approved deposit")
expect(JobLifecycleRules.canRequestDeposit(status: .scheduled), true, "scheduled deposit")
expect(JobLifecycleRules.canRequestDeposit(status: .inProgress), true, "in-progress deposit")
expect(JobLifecycleRules.canRequestDeposit(status: .complete), false, "complete deposit denied")
expect(JobLifecycleRules.invoiceScreenMode(status: .complete, hasInvoice: false), .create, "create invoice mode")
expect(JobLifecycleRules.invoiceScreenMode(status: .complete, hasInvoice: true), .finalize, "finalize invoice mode")
expect(JobLifecycleRules.invoiceScreenMode(status: .approved, hasInvoice: false), .requestDeposit, "deposit invoice mode")
expect(JobLifecycleRules.invoiceScreenMode(status: .approved, hasInvoice: true), nil, "existing deposit has no creation mode")
expect(
    JobLifecycleRules.changesAfterInvoiceSave(mode: .requestDeposit, invoiceID: "inv123", invoicePaid: true),
    JobInvoiceChanges(status: nil, invoiceID: "inv123"),
    "deposit never advances status"
)
expect(
    JobLifecycleRules.changesAfterInvoiceSave(mode: .finalize, invoiceID: "inv123", invoicePaid: true),
    JobInvoiceChanges(status: .paid, invoiceID: "inv123"),
    "paid final invoice"
)
for status in JobLifecycleStatus.allCases {
    let expected = status == .complete || status == .invoiced || status == .paid
    expect(JobLifecycleRules.isDunningEligible(status: status), expected, "dunning \(status.rawValue)")
}
expect(JobLifecycleRules.isDunningEligible(status: nil), true, "missing linked job is dunning eligible")

let paidInvoice = LedgerInvoice(id: "inv1", amount: 500, due: "2026-01-01", paid: true)
let jobs = [
    LifecycleJob(id: "j1", status: .invoiced, invoiceID: "inv1"),
    LifecycleJob(id: "j2", status: .scheduled, invoiceID: "inv1"),
]
expect(JobLifecycleRules.advancePaidInvoiceJobs(jobs, invoices: [paidInvoice]).map(\.status), [.paid, .scheduled], "paid invoice advances only invoiced job")

// Archive vectors transcribed from __tests__/archive.test.ts.
struct TestRecord: ArchivableRecord, Equatable { var id: String; var archivedAt: String? }
let active = TestRecord(id: "x", archivedAt: nil)
expect(ArchiveRules.isArchived(active), false, "absent archive date is active")
expect(ArchiveRules.isArchived(TestRecord(id: "empty", archivedAt: "")), false, "empty archive date is active")
let archived = ArchiveRules.settingArchive(active, archived: true, today: "2026-08-02")
expect(archived.archivedAt, "2026-08-02", "archive stamp")
expect(active.archivedAt, nil, "archive copies value")
expect(ArchiveRules.settingArchive(archived, archived: false, today: "2026-08-03").archivedAt, nil, "restore clears stamp")
expect(ArchiveRules.countArchived([active, archived, active]), 1, "archive count")

// ID format and same-millisecond collision vectors from the corresponding JS suites.
let ids = LocalIDGenerator(nowMilliseconds: { 1_754_435_200_123 }, randomBase36: { "abc123" })
expect(ids.customerID(), "c1754435200123_1", "customer id")
expect(ids.customerID(), "c1754435200123_2", "customer counter")
expect(ids.paymentID(), "p1754435200123_1", "payment id")
expect(ids.changeOrderID(), "co1754435200123_1", "change-order id")
expect(ids.importBatchID(), "imp_1754435200123_1", "import batch id")
expect(ids.importedJobID(), "j1754435200123_1", "imported job id")
expect(ids.importedExpenseID(), "e1754435200123_1", "imported expense id")
expect(ids.jobID(), "j1754435200123", "manual job id")
expect(ids.jobID(), "j1754435200124", "manual job monotonic bump")
expect(ids.materialID(), "m1754435200123", "material id")
expect(ids.materialID(), "m1754435200124", "material id monotonic bump")
expect(ids.jobCostID(), "jc1754435200123", "job-cost id")
expect(ids.jobCostID(), "jc1754435200124", "job-cost id monotonic bump")
expect(ids.manualInvoiceID(), "1754435200123", "manual invoice id")
expect(ids.manualInvoiceID(), "1754435200124", "manual invoice monotonic bump")
expect(ids.generatedInvoiceID(), "inv1754435200123", "generated invoice id")
expect(ids.generatedInvoiceID(), "inv1754435200124", "generated invoice monotonic bump")
expect(ids.recurringJobID(ruleID: "rj_7", occurrence: 3), "j1754435200123_rj_7_3", "recurring job id")
expect(ids.expenseID(), "1754435200123abc12", "expense id")
expect(ids.tripID(), "1754435200123abc12", "trip id")
expect(ids.photoID(), "p1754435200123_abc123", "photo id")

if failures == 0 {
    print("PASS: native non-financial business-rule golden tests")
} else {
    print("FAILED: \(failures) native non-financial business-rule golden test(s)")
    exit(1)
}
