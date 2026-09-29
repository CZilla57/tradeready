import Foundation

// Today insights tests (task 10.02, requirement S3).
//
// Pins the deterministic Today-insight rules against the React Native oracle
// `__tests__/todayInsights.test.ts`. Fixed clock throughout: Tue Aug 4 2026,
// 10:00 local → "tomorrow" is 2026-08-05 — matching the RN suite exactly, and
// run under TZ=America/Phoenix (west-of-UTC) so any accidental UTC date parse
// would surface (FA-039).

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

private func expectContains(_ haystack: String, _ needle: String, _ label: String) {
    if !haystack.contains(needle) {
        failures += 1
        print("FAIL: \(label) — expected \(haystack.debugDescription) to contain \(needle.debugDescription)")
    }
}

private func expectNotContains(_ haystack: String, _ needle: String, _ label: String) {
    if haystack.contains(needle) {
        failures += 1
        print("FAIL: \(label) — expected \(haystack.debugDescription) to NOT contain \(needle.debugDescription)")
    }
}

private let decoder = JSONDecoder()

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

/// `job()` from the oracle: in-progress Faucet repair, $1,200 estimate,
/// 2h @ $85, 15% overhead.
private func job(_ overrides: String = "") -> Canonical.Job {
    let base = """
    {"id":"j1","customerId":"c1","customerName":"Dana","title":"Faucet repair",
     "description":"","status":"in_progress","address":"","estimateTotal":1200,
     "laborHours":2,"laborRate":85,"materials":[],"materialMarkup":20,
     "overhead":15,"margin":20,"notes":"","createdAt":"2026-08-01"}
    """
    return try! decoder.decode(Canonical.Job.self, from: Data(merge(base, overrides).utf8))
}

/// `invoice()`: $850, INV-0042, due 2026-08-05, unpaid.
private func invoice(_ overrides: String = "") -> Canonical.Invoice {
    let base = """
    {"id":"i1","customer":"Dana","number":"INV-0042","amount":850,"due":"2026-08-05",
     "email":"","phone":"","desc":"","paid":false}
    """
    return try! decoder.decode(Canonical.Invoice.self, from: Data(merge(base, overrides).utf8))
}

private func expense(_ overrides: String = "") -> Canonical.Expense {
    let base = """
    {"id":"e1","createdAt":"2026-08-01","description":"Supplies","amount":100,
     "category":"materials","date":"2026-08-01","notes":""}
    """
    return try! decoder.decode(Canonical.Expense.self, from: Data(merge(base, overrides).utf8))
}

private func customer(_ overrides: String = "") -> Canonical.Customer {
    let base = """
    {"id":"c1","name":"Dana Smith","email":"","phone":"555-1234","address":"","notes":""}
    """
    return try! decoder.decode(Canonical.Customer.self, from: Data(merge(base, overrides).utf8))
}

private func recurringRule(_ overrides: String = "") -> Canonical.RecurringJob {
    let base = """
    {"id":"rj1","customerId":"c1","customerName":"","title":"","description":"","address":"",
     "notes":"","estimateTotal":0,"laborHours":0,"laborRate":0,"materials":[],"materialMarkup":0,
     "overhead":0,"margin":0,"cadence":"monthly","endCondition":"never","occurrenceCount":0,
     "nextDueDate":"2026-09-01","isActive":true,"createdAt":"2026-08-01"}
    """
    return try! decoder.decode(Canonical.RecurringJob.self, from: Data(merge(base, overrides).utf8))
}

/// JSON for an ended clock session of exactly `hours` on Aug 4 (matching the
/// oracle's fixed-clock `session()` helper), for embedding into a job's
/// `timeSessions` override.
private func sessionJSON(_ hours: Double) -> String {
    let startMs = NativeCashBasis.localDate(year: 2026, month: 7, day: 4, hour: 6).timeIntervalSince1970 * 1000
    let endMs = startMs + hours * 3_600_000
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let start = iso.string(from: Date(timeIntervalSince1970: startMs / 1000))
    let end = iso.string(from: Date(timeIntervalSince1970: endMs / 1000))
    return "{\"start\":\"\(start)\",\"end\":\"\(end)\"}"
}

/// Tue Aug 4 2026, 10:00 local — the oracle's pinned clock.
private let now = NativeCashBasis.localDate(year: 2026, month: 7, day: 4, hour: 10)

private func select(
    jobs: [Canonical.Job] = [],
    invoices: [Canonical.Invoice] = [],
    schedule: NativeSchedule.ResolvedSchedule = .defaults,
    targetMarginPercent: Double = 20,
    customers: [Canonical.Customer] = [],
    recurringJobs: [Canonical.RecurringJob] = [],
    expenses: [Canonical.Expense] = []
) -> [NativeTodayInsight] {
    NativeTodayInsights.select(
        jobs: jobs, invoices: invoices, now: now, schedule: schedule,
        targetMarginPercent: targetMarginPercent, customers: customers,
        recurringJobs: recurringJobs, expenses: expenses
    )
}

private func anomalyInsights(_ expenses: [Canonical.Expense]) -> [NativeTodayInsight] {
    select(expenses: expenses).filter { $0.kind == .expenseAnomaly }
}

// MARK: - labor_overrun

do {
    let insights = select(jobs: [job(#"{"timeSessions":[\#(sessionJSON(2.25))]}"#)])
    expectEqual(insights.first?.kind, .laborOverrun, "labor_overrun fires")
    expectEqual(insights.first?.title, "'Faucet repair' is 15m over its 2h labor estimate", "labor_overrun title")
    expectEqual(insights.first?.target, .job(jobId: "j1"), "labor_overrun target")
}

do {
    let insights = select(jobs: [job(#"{"timeSessions":[\#(sessionJSON(2 + 14.0/60))]}"#)])
    expectEqual(insights.count, 0, "14 minutes over is silent (quarter-hour floor)")
}

do {
    let insights = select(jobs: [job(#"{"timeSessions":[\#(sessionJSON(3.5))]}"#)])
    let prompt = insights.first?.coachPrompt ?? ""
    expectContains(prompt, "3h 30m", "overrun coachPrompt tracked time")
    expectContains(prompt, "2h labor estimate", "overrun coachPrompt estimate")
    expectContains(prompt, "$85.00/hr", "overrun coachPrompt rate")
    expectContains(prompt, "$1,200", "overrun coachPrompt total")
}

do {
    let sessions = "[\(sessionJSON(5))]"
    expectEqual(select(jobs: [job(#"{"status":"complete","invoiceId":"i9","timeSessions":\#(sessions)}"#)]).count, 0, "completed jobs excluded from labor_overrun")
    expectEqual(select(jobs: [job(#"{"archivedAt":"2026-08-03","timeSessions":\#(sessions)}"#)]).count, 0, "archived jobs excluded from labor_overrun")
    expectEqual(select(jobs: [job(#"{"laborHours":0,"timeSessions":\#(sessions)}"#)]).count, 0, "zero-estimate jobs excluded from labor_overrun")
}

// MARK: - uninvoiced_complete

do {
    let insights = select(jobs: [job(#"{"status":"complete"}"#)])
    expectEqual(insights.first?.kind, .uninvoicedComplete, "uninvoiced_complete fires")
    expectEqual(insights.first?.title, "'Faucet repair' is complete but not invoiced", "uninvoiced_complete title")
    expectEqual(insights.first?.detail, "$1,200 to bill", "uninvoiced_complete detail")
    expectEqual(insights.first?.target, .createInvoice(jobId: "j1"), "uninvoiced_complete target")
}

do {
    let changeOrderJSON = #"[{"id":"co1","title":"Extra work","amount":300,"createdAt":"2026-08-01","manualDecision":{"decision":"approved","decidedAt":"2026-08-02"}}]"#
    let insights = select(jobs: [job(#"{"status":"complete","changeOrders":\#(changeOrderJSON)}"#)])
    expectEqual(insights.first?.detail, "$1,500 to bill", "uninvoiced_complete detail includes approved change orders")
}

do {
    let insights = select(jobs: [
        job(#"{"id":"a","status":"complete"}"#),
        job(#"{"id":"b","status":"complete","title":"Deck repair"}"#),
    ])
    expectEqual(insights.first?.title, "2 completed jobs haven't been invoiced", "uninvoiced_complete aggregate title")
    expectEqual(insights.first?.target, .jobs, "uninvoiced_complete aggregate target")
}

do {
    expectEqual(select(jobs: [job(#"{"status":"complete","invoiceId":"i1"}"#)]).count, 0, "invoiced jobs excluded")
    expectEqual(select(jobs: [job(#"{"status":"complete","archivedAt":"2026-08-01"}"#)]).count, 0, "archived complete jobs excluded")
}

// MARK: - due_soon

for (due, label) in [("2026-08-04", "today"), ("2026-08-05", "tomorrow"), ("2026-08-06", "in 2 days")] {
    let insights = select(invoices: [invoice(#"{"due":"\#(due)"}"#)])
    expectEqual(insights.first?.kind, .dueSoon, "due_soon fires for \(due)")
    expectEqual(insights.first?.title, "Invoice INV-0042 ($850.00) is due \(label)", "due_soon title for \(due)")
    expectEqual(insights.first?.target, .invoice(invoiceId: "i1"), "due_soon target for \(due)")
}

do {
    expectEqual(select(invoices: [invoice(#"{"due":"2026-08-07"}"#)]).count, 0, "3 days out is silent")
    expectEqual(select(invoices: [invoice(#"{"due":"2026-08-03"}"#)]).count, 0, "already-overdue is silent")
}

do {
    expectEqual(select(invoices: [invoice(#"{"paid":true}"#)]).count, 0, "fully paid invoices silent")
    let invoices = [
        invoice(#"{"id":"a","amount":850}"#),
        invoice(#"{"id":"b","number":"INV-0043","amount":600,"due":"2026-08-06","payments":[{"id":"p1","amount":100,"date":"2026-08-01","method":"cash"}]}"#),
    ]
    let insights = select(invoices: invoices)
    expectEqual(insights.first?.title, "$1,350.00 across 2 invoices is due within 2 days", "due_soon aggregate title")
    expectEqual(insights.first?.target, .invoices, "due_soon aggregate target")
}

// MARK: - open_slot / unscheduled_approved

let tomorrowJob = job(#"{"id":"sched","status":"scheduled","scheduledDate":"2026-08-05","scheduledStartTime":"09:00","scheduledEndTime":"11:00"}"#)

do {
    let insights = select(jobs: [tomorrowJob])
    expectEqual(insights.first?.kind, .openSlot, "open_slot fires")
    expectEqual(insights.first?.title, "Tomorrow has a 6h open slot", "open_slot title")
    expectEqual(insights.first?.target, .selectDate(date: "2026-08-05"), "open_slot target")
}

do {
    let jobs = [
        tomorrowJob,
        job(#"{"id":"fitS","status":"approved","title":"Small fix","laborHours":1}"#),
        job(#"{"id":"fitL","status":"approved","title":"Fence gate","laborHours":4}"#),
        job(#"{"id":"huge","status":"approved","title":"Full remodel","laborHours":9}"#),
    ]
    let insights = select(jobs: jobs)
    expectEqual(insights.first?.title, "Tomorrow has a 6h open slot — 'Fence gate' (4h) would fit", "open_slot names the best-fit job")
    expectEqual(insights.first?.target, .schedule(jobId: "fitL"), "open_slot target is the fitted job's schedule")
}

do {
    expectEqual(select(jobs: [job(#"{"status":"approved"}"#)]).filter { $0.kind == .openSlot }.count, 0, "empty tomorrow is silent")
    let packed = [
        job(#"{"id":"a","status":"scheduled","scheduledDate":"2026-08-05","scheduledStartTime":"08:00","scheduledEndTime":"12:01"}"#),
        job(#"{"id":"b","status":"scheduled","scheduledDate":"2026-08-05","scheduledStartTime":"14:00","scheduledEndTime":"17:00"}"#),
    ]
    expectEqual(select(jobs: packed).filter { $0.kind == .openSlot }.count, 0, "sub-2h gap (119 min) is silent")
}

do {
    var short = NativeSchedule.ResolvedSchedule.defaults
    short.workDayEnd = "11:00"
    expectEqual(select(jobs: [tomorrowJob], schedule: short).filter { $0.kind == .openSlot }.count, 0, "custom work window shrinks the gap below threshold")
}

do {
    var off = NativeSchedule.ResolvedSchedule.defaults
    off.blackouts = [NativeSchedule.ScheduleBlackout(id: "b1", start: "2026-08-05", end: "2026-08-05")]
    expectEqual(select(jobs: [tomorrowJob], schedule: off).filter { $0.kind == .openSlot }.count, 0, "blackout on tomorrow suppresses open_slot")
}

do {
    var monOnly = NativeSchedule.ResolvedSchedule.defaults
    monOnly.workDays = [1]
    expectEqual(select(jobs: [tomorrowJob], schedule: monOnly).filter { $0.kind == .openSlot }.count, 0, "non-workday tomorrow suppresses open_slot")
}

do {
    let jobs = [
        job(#"{"id":"a","status":"scheduled","scheduledDate":"2026-08-05","scheduledStartTime":"08:00","scheduledEndTime":"12:00"}"#),
        job(#"{"id":"b","status":"scheduled","scheduledDate":"2026-08-05","scheduledStartTime":"14:00","scheduledEndTime":"17:00"}"#),
    ]
    expectEqual(select(jobs: jobs).first?.title, "Tomorrow has a 2h open slot", "exactly 120 minutes fires")
}

do {
    let jobs = [
        tomorrowJob,
        job(#"{"id":"first","status":"approved","title":"First fix","laborHours":3}"#),
        job(#"{"id":"second","status":"approved","title":"Second fix","laborHours":3}"#),
    ]
    let insights = select(jobs: jobs)
    expectEqual(insights.first?.title, "Tomorrow has a 6h open slot — 'First fix' (3h) would fit", "ties on laborHours keep array order")
    expectEqual(insights.first?.target, .schedule(jobId: "first"), "tie-break keeps the earlier job")
}

do {
    let single = select(jobs: [job(#"{"id":"u1","status":"approved","title":"Fence gate"}"#)])
    expectEqual(single.first?.kind, .unscheduledApproved, "unscheduled_approved single fires")
    expectEqual(single.first?.title, "'Fence gate' is approved but not scheduled", "unscheduled_approved single title")
    expectEqual(single.first?.target, .schedule(jobId: "u1"), "unscheduled_approved single target")

    let multi = select(jobs: [
        job(#"{"id":"u1","status":"approved"}"#),
        job(#"{"id":"u2","status":"approved"}"#),
    ])
    expectEqual(multi.first?.title, "2 approved jobs aren't on the schedule yet", "unscheduled_approved aggregate title")
    expectEqual(multi.first?.target, .jobs, "unscheduled_approved aggregate target")
}

do {
    let jobs = [
        job(#"{"id":"sched","status":"scheduled","scheduledDate":"2026-08-05","scheduledStartTime":"09:00","scheduledEndTime":"11:00"}"#),
        job(#"{"id":"fit","status":"approved","title":"Fence gate","laborHours":4}"#),
        job(#"{"id":"left","status":"approved","title":"Gutter clean","laborHours":9}"#),
    ]
    let insights = select(jobs: jobs)
    expectEqual(insights.map(\.kind), [.openSlot, .unscheduledApproved], "the job consumed by open_slot never double-counts")
    expectEqual(insights.count > 1 ? insights[1].title : "", "'Gutter clean' is approved but not scheduled", "remaining unscheduled job after open_slot fit")
}

// MARK: - priority order

do {
    let jobs = [
        job(#"{"id":"over","timeSessions":[\#(sessionJSON(5))]}"#),
        job(#"{"id":"done","status":"complete"}"#),
        job(#"{"id":"sched","status":"scheduled","scheduledDate":"2026-08-05","scheduledStartTime":"09:00","scheduledEndTime":"11:00"}"#),
        job(#"{"id":"fit","status":"approved","laborHours":2}"#),
        job(#"{"id":"left","status":"approved","laborHours":9}"#),
    ]
    let kinds = select(jobs: jobs, invoices: [invoice()]).map(\.kind)
    expectEqual(kinds, [.laborOverrun, .uninvoicedComplete, .dueSoon, .openSlot, .unscheduledApproved], "all five kinds arrive in spec order")
}

// MARK: - low_margin_estimate

private func lowJob(_ overrides: String = "") -> Canonical.Job {
    job(merge(#"{"status":"lead","laborHours":10,"laborRate":100,"materials":[],"overhead":0}"#, overrides))
}

do {
    let atBoundary = select(jobs: [lowJob(#"{"estimateTotal":1170}"#)])
    expectEqual(atBoundary.count, 1, "low_margin fires at exactly target-3 points")
    expectEqual(atBoundary.first?.kind, .lowMarginEstimate, "low_margin kind")
    expectEqual(atBoundary.first?.title, "'Faucet repair' is priced 3 points under your 20% margin", "low_margin boundary title")
    expectEqual(atBoundary.first?.detail, "$170 profit on $1,170", "low_margin boundary detail")
    expectEqual(atBoundary.first?.target, .job(jobId: "j1"), "low_margin target")
    expectEqual(select(jobs: [lowJob(#"{"estimateTotal":1171}"#)]).count, 0, "a tenth above the boundary is silent")
}

do {
    let insight = select(jobs: [lowJob(#"{"estimateTotal":950}"#)]).first
    expectEqual(insight?.title, "'Faucet repair' is priced below your costs and overhead", "severe low_margin title")
    expectEqual(insight?.detail, "$50 short of break-even", "severe low_margin detail")
}

do {
    let insight = select(jobs: [lowJob(#"{"estimateTotal":1200,"overhead":15}"#)]).first
    expectContains(insight?.reason ?? "", "overhead at 15% ($150)", "low_margin reason overhead allocation")
    expectContains(insight?.reason ?? "", "4.3%", "low_margin reason implied percent")
}

do {
    let materialsJSON = #"[{"id":"m1","name":"Pipe","quantity":2,"unitCost":100}]"#
    let insight = select(jobs: [lowJob(#"{"estimateTotal":1300,"materials":\#(materialsJSON),"materialMarkup":20}"#)]).first
    expectContains(insight?.reason ?? "", "materials $240", "low_margin reason includes marked-up materials")
    expectEqual(insight?.detail, "$60 profit on $1,300", "low_margin detail with materials")
}

do {
    expectEqual(select(jobs: [lowJob(#"{"estimateTotal":1000,"status":"approved"}"#)]).map(\.kind).contains(.lowMarginEstimate), false, "approved jobs are contracted, not repriced")
    expectEqual(select(jobs: [lowJob(#"{"estimateTotal":1000,"status":"estimate_sent"}"#)]).map(\.kind), [.lowMarginEstimate], "estimate_sent jobs qualify")
}

do {
    expectEqual(select(jobs: [lowJob(#"{"estimateTotal":1000,"laborHours":0}"#)]).count, 0, "zero labor hours excluded")
    expectEqual(select(jobs: [lowJob(#"{"estimateTotal":1000,"laborRate":0}"#)]).count, 0, "zero labor rate excluded")
    expectEqual(select(jobs: [lowJob(#"{"estimateTotal":0}"#)]).count, 0, "zero estimate excluded")
}

do {
    let insights = select(jobs: [
        lowJob(#"{"id":"mild","title":"Mild","estimateTotal":1100}"#),
        lowJob(#"{"id":"bad","title":"Bad","estimateTotal":900}"#),
    ])
    expectEqual(insights.count, 1, "low_margin collapses to one row")
    expectContains(insights.first?.title ?? "", "'Bad'", "low_margin shows the worst offender")
    expectContains(insights.first?.detail ?? "", "· 1 more under target", "low_margin detail counts the rest")
}

do {
    expectEqual(select(jobs: [lowJob(#"{"estimateTotal":1400}"#)]).count, 0, "default 20% target is not tripped at 40% implied")
    expectEqual(select(jobs: [lowJob(#"{"estimateTotal":1400}"#)], targetMarginPercent: 50).count, 1, "custom margin target trips the same job")
}

do {
    let insight = select(jobs: [lowJob(#"{"estimateTotal":1170}"#)]).first
    expectEqual(insight?.id, "low_margin_estimate:j1:1170", "id embeds the price")
}

do {
    let prompt = select(jobs: [lowJob(#"{"estimateTotal":1170}"#)]).first?.coachPrompt ?? ""
    expectContains(prompt, "$1,170", "low_margin coachPrompt total")
    expectContains(prompt, "labor $1,000", "low_margin coachPrompt labor")
    expectContains(prompt, "20% target", "low_margin coachPrompt target")
    expectNotContains(prompt, "Dana", "low_margin coachPrompt carries no customer identity")
}

do {
    let jobs = [
        job(#"{"id":"over","timeSessions":[\#(sessionJSON(5))]}"#),
        lowJob(#"{"id":"cheap","estimateTotal":1000}"#),
        job(#"{"id":"done","status":"complete"}"#),
    ]
    expectEqual(select(jobs: jobs).map(\.kind), [.laborOverrun, .lowMarginEstimate, .uninvoicedComplete], "low_margin slots after labor_overrun")
}

// MARK: - maintenance_due

private func historyJob(_ overrides: String = "") -> Canonical.Job {
    job(merge(#"{"id":"h1","status":"paid","scheduledDate":"2026-02-04","title":"Furnace tune-up"}"#, overrides))
}

do {
    let due = select(jobs: [historyJob()], customers: [customer()])
    expectEqual(due.count, 1, "maintenance_due fires at exactly 6 months")
    expectEqual(due.first?.kind, .maintenanceDue, "maintenance_due kind")
    expectEqual(due.first?.id, "maintenance_due:c1", "maintenance_due id")
    expectEqual(due.first?.title, "It's been 6 months since you worked for Dana Smith", "maintenance_due title")
    expectEqual(due.first?.detail, "Last job: Furnace tune-up", "maintenance_due detail")
    expectEqual(due.first?.target, .customer(customerId: "c1"), "maintenance_due target")

    let short = select(jobs: [historyJob(#"{"scheduledDate":"2026-02-05"}"#)], customers: [customer()])
    expectEqual(short.count, 0, "a day short of 6 months is silent")
}

do {
    let insight = select(jobs: [historyJob()], customers: [customer()]).first
    expectContains(insight?.coachPrompt ?? "", "Dana", "maintenance_due coachPrompt uses first name")
    expectNotContains(insight?.coachPrompt ?? "", "Smith", "maintenance_due coachPrompt omits last name")
    expectContains(insight?.reason ?? "", "2026-02-04", "maintenance_due reason carries the date")
    expectContains(insight?.reason ?? "", "threshold: 6", "maintenance_due reason carries the threshold")
}

do {
    expectEqual(select(jobs: [historyJob()], customers: [customer(#"{"phone":" ","email":""}"#)]).count, 0, "customer without contact excluded")
    expectEqual(select(jobs: [historyJob()], customers: [customer(#"{"archivedAt":"2026-07-01"}"#)]).count, 0, "archived customer excluded")
}

do {
    let inMotion = [historyJob(), job(#"{"id":"j2","status":"scheduled","scheduledDate":null}"#)]
    expectEqual(select(jobs: inMotion, customers: [customer()]).map(\.kind).contains(.maintenanceDue), false, "active pipeline job suppresses maintenance_due")

    let archived = [historyJob(), job(#"{"id":"j2","status":"in_progress","archivedAt":"2026-07-01"}"#)]
    expectEqual(select(jobs: archived, customers: [customer()]).map(\.kind).contains(.maintenanceDue), true, "an archived in-motion job does not suppress")
}

do {
    expectEqual(select(jobs: [historyJob()], customers: [customer()], recurringJobs: [recurringRule()]).count, 0, "active recurring rule suppresses")
    expectEqual(select(jobs: [historyJob()], customers: [customer()], recurringJobs: [recurringRule(#"{"isActive":false}"#)]).count, 1, "inactive recurring rule does not suppress")
}

do {
    expectEqual(select(jobs: [historyJob(#"{"status":"lead"}"#)], customers: [customer()]).map(\.kind).contains(.maintenanceDue), false, "lead-only history never fires")
    expectEqual(select(jobs: [historyJob(#"{"customerId":""}"#)], customers: [customer()]).count, 0, "unlinked history (empty customerId) never fires")
    expectEqual(select(jobs: [historyJob(#"{"scheduledDate":null}"#)], customers: [customer()]).count, 0, "delivered job with no date never fires")
    expectEqual(select(customers: [customer()]).count, 0, "no jobs at all never fires")
}

do {
    let insights = select(
        jobs: [historyJob(), historyJob(#"{"id":"h2","customerId":"c2","scheduledDate":"2025-11-01"}"#)],
        customers: [customer(), customer(#"{"id":"c2","name":"Bob Reyes"}"#)]
    )
    expectEqual(insights.count, 1, "several due customers collapse to one row")
    expectEqual(insights.first?.id, "maintenance_due:all", "maintenance_due aggregate id")
    expectEqual(insights.first?.title, "2 customers haven't been serviced in 6+ months", "maintenance_due aggregate title")
    expectEqual(insights.first?.target, .customers, "maintenance_due aggregate target")
}

do {
    let jobs = [job(#"{"id":"left","status":"approved","laborHours":9,"customerId":"c2"}"#), historyJob()]
    expectEqual(select(jobs: jobs, customers: [customer()]).map(\.kind), [.unscheduledApproved, .maintenanceDue], "maintenance_due rides last in priority order")
}

// MARK: - insight identity and reasons

do {
    let jobs = [
        job(#"{"id":"over","timeSessions":[\#(sessionJSON(5))]}"#),
        job(#"{"id":"done","status":"complete"}"#),
        job(#"{"id":"sched","status":"scheduled","scheduledDate":"2026-08-05","scheduledStartTime":"09:00","scheduledEndTime":"11:00"}"#),
        job(#"{"id":"fit","status":"approved","laborHours":2}"#),
        job(#"{"id":"left","status":"approved","laborHours":9}"#),
    ]
    for insight in select(jobs: jobs, invoices: [invoice()]) {
        expect(!insight.id.isEmpty, "insight id is non-empty for \(insight.kind)")
        expect(!insight.reason.isEmpty, "insight reason is non-empty for \(insight.kind)")
    }
}

do {
    let one = select(jobs: [job(#"{"id":"done1","status":"complete"}"#)])
    expectEqual(one.first?.id, "uninvoiced_complete:done1", "single-record row keys on the record id")

    let many = select(jobs: [job(#"{"id":"done1","status":"complete"}"#), job(#"{"id":"done2","status":"complete"}"#)])
    expectEqual(many.first?.id, "uninvoiced_complete:all", "aggregate row keys on :all")

    let dueOne = select(invoices: [invoice(#"{"id":"i9"}"#)])
    expectEqual(dueOne.first?.id, "due_soon:i9", "due_soon single row keys on the invoice id")
}

do {
    let jobs = [
        job(#"{"id":"over","timeSessions":[\#(sessionJSON(5))]}"#),
        job(#"{"id":"sched","status":"scheduled","scheduledDate":"2026-08-05","scheduledStartTime":"09:00","scheduledEndTime":"11:00"}"#),
        job(#"{"id":"left","status":"approved","laborHours":9,"title":"Gutter clean"}"#),
    ]
    let ids = select(jobs: jobs).map(\.id)
    expectEqual(ids, ["labor_overrun:over", "open_slot:2026-08-05", "unscheduled_approved:left"], "id shapes: record id, date, record id")
}

do {
    let overrun = select(jobs: [job(#"{"timeSessions":[\#(sessionJSON(3.5))]}"#)]).first
    expectContains(overrun?.reason ?? "", "3h 30m", "overrun reason carries tracked time")
    expectContains(overrun?.reason ?? "", "2h labor estimate", "overrun reason carries the estimate")

    let due = select(invoices: [invoice(#"{"id":"i9"}"#)]).first
    expectContains(due?.reason ?? "", "INV-0042", "due_soon reason carries the invoice number")
    expectContains(due?.reason ?? "", "due tomorrow", "due_soon reason carries the due label")
}

// MARK: - expense_anomaly

let priorEven = [
    expense(#"{"id":"p1","date":"2026-07-15","amount":1000}"#),
    expense(#"{"id":"p2","date":"2026-06-15","amount":1000}"#),
    expense(#"{"id":"p3","date":"2026-05-15","amount":1000}"#),
]

do {
    let insight = anomalyInsights(priorEven + [expense(#"{"id":"m","date":"2026-08-02","amount":1600}"#)]).first
    expectEqual(insight?.kind, .expenseAnomaly, "expense_anomaly fires above 1.5x")
    expectEqual(insight?.id, "expense_anomaly:2026-08", "expense_anomaly id")
    expectContains(insight?.title ?? "", "60%", "expense_anomaly title percent")
    expectEqual(insight?.detail, "$1,600.00 so far vs $1,000.00 average", "expense_anomaly detail")
    expectEqual(insight?.target, .money, "expense_anomaly target")
}

do {
    expectEqual(anomalyInsights(priorEven + [expense(#"{"id":"m","date":"2026-08-01","amount":1500}"#)]).count, 0, "exactly 1.5x is silent")
    expectEqual(anomalyInsights(priorEven + [expense(#"{"id":"m","date":"2026-08-01","amount":1501}"#)]).count, 1, "just above 1.5x fires")
}

do {
    let prior = [
        expense(#"{"id":"p1","date":"2026-07-15","amount":100}"#),
        expense(#"{"id":"p2","date":"2026-06-15","amount":100}"#),
        expense(#"{"id":"p3","date":"2026-05-15","amount":100}"#),
    ]
    expectEqual(anomalyInsights(prior + [expense(#"{"id":"m","date":"2026-08-01","amount":199}"#)]).count, 0, "below $200 MTD floor never fires")
    expectEqual(anomalyInsights(prior + [expense(#"{"id":"m","date":"2026-08-01","amount":200}"#)]).count, 1, "at $200 MTD floor fires")
}

do {
    let twoMonths = [
        expense(#"{"id":"p1","date":"2026-07-15","amount":1000}"#),
        expense(#"{"id":"p2","date":"2026-06-15","amount":1000}"#),
        expense(#"{"id":"m","date":"2026-08-01","amount":5000}"#),
    ]
    expectEqual(anomalyInsights(twoMonths).count, 0, "a missing prior month silences it")
}

do {
    expectEqual(anomalyInsights([]).count, 0, "empty history is silent")
    expectEqual(anomalyInsights([expense(#"{"date":"2026-07-15","amount":1000}"#)]).count, 0, "thin history is silent")
}

do {
    let withFuture = priorEven + [
        expense(#"{"id":"now","date":"2026-08-02","amount":1400}"#),
        expense(#"{"id":"future","date":"2026-08-20","amount":1000}"#),
    ]
    expectEqual(anomalyInsights(withFuture).count, 0, "a future-dated current-month expense is excluded from MTD")
}

do {
    func perMonth(_ ym: String) -> [Canonical.Expense] {
        [
            expense(#"{"id":"mat-\#(ym)","date":"\#(ym)-15","amount":900,"category":"materials"}"#),
            expense(#"{"id":"fuel-\#(ym)","date":"\#(ym)-15","amount":100,"category":"fuel"}"#),
        ]
    }
    let expenses = perMonth("2026-07") + perMonth("2026-06") + perMonth("2026-05") + [
        expense(#"{"id":"mat-08","date":"2026-08-02","amount":900,"category":"materials"}"#),
        expense(#"{"id":"fuel-08","date":"2026-08-02","amount":1200,"category":"fuel"}"#),
    ]
    let insight = anomalyInsights(expenses).first
    expect(insight != nil, "biggest-driver anomaly fires")
    expectContains(insight?.reason ?? "", "Fuel & Transport", "reason names the biggest-driver category")
}

do {
    let overrunJob = job(#"{"timeSessions":[\#(sessionJSON(3.5))]}"#)
    let insights = select(jobs: [overrunJob], expenses: priorEven + [expense(#"{"id":"m","date":"2026-08-02","amount":1600}"#)])
    expect(insights.count > 1, "expense_anomaly rides alongside other kinds")
    expectEqual(insights.first?.kind, .laborOverrun, "labor_overrun stays first")
    expectEqual(insights.last?.kind, .expenseAnomaly, "expense_anomaly rides last")
}

// MARK: - month/date pure helpers (FA-039 guards)

expectEqual(NativeTodayInsights.monthsBetween(from: "2026-02-04", now: now), 6, "monthsBetween: exact boundary")
expectEqual(NativeTodayInsights.monthsBetween(from: "2026-02-05", now: now), 5, "monthsBetween: a day short")
expectEqual(NativeTodayInsights.shiftMonth("2026-08", offset: 1), "2026-07", "shiftMonth: one month back")
expectEqual(NativeTodayInsights.shiftMonth("2026-01", offset: 1), "2025-12", "shiftMonth: crosses a year boundary")

if failures == 0 {
    print("All NativeTodayInsights tests passed.")
} else {
    print("\(failures) NativeTodayInsights test(s) failed.")
    exit(1)
}
