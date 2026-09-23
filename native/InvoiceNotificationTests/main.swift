import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { failures += 1; print("FAIL: \(label)") } }

private var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}
private func inv(_ id: String, due: String, paid: Bool = false, job: String? = nil, imported: Bool = false) -> NativeInvoiceNotificationInvoice {
    .init(id: id, customer: "Acme", number: "INV-\(id)", isPaid: paid, due: due, jobID: job,
          importBatchId: imported ? "imp_1" : nil)
}

// Dunning: one item per (invoice, rule), 9 a.m. local on due + days.
let now = at(2026, 9, 10)
let items = NativeInvoiceNotifications.reminders(
    invoices: [inv("a", due: "2026-09-10")],
    ruleDays: [1, 7], autoOutreachEnabled: false,
    jobStatusByID: [:], now: now, calendar: calendar)
expect(items.map(\.identifier) == ["inv_a_1d", "inv_a_7d"], "one reminder per rule with inv_ identifiers")
expect(items[0].fireDate == calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 9))!,
       "fires 9 a.m. local on due plus rule days")
expect(items[0].title == "Overdue invoice — Acme" && !items[0].opensOutreach, "plain variant copy")

// Outreach variant carries the tap-to-send copy and routing flag.
let outreach = NativeInvoiceNotifications.reminders(
    invoices: [inv("a", due: "2026-09-10")],
    ruleDays: [7], autoOutreachEnabled: true,
    jobStatusByID: [:], now: now, calendar: calendar)
expect(outreach.count == 1 && outreach[0].opensOutreach
       && outreach[0].body == "Tap to send a reminder for INV-a — 7 days past due.",
       "outreach variant copy and routing")

// Exclusions: paid, imported, pre-completion deposit, malformed due, past fire dates.
let excluded = NativeInvoiceNotifications.reminders(
    invoices: [
        inv("paid", due: "2026-09-01", paid: true),
        inv("imp", due: "2026-09-01", imported: true),
        inv("dep", due: "2026-09-01", job: "j1"),
        inv("junk", due: "not-a-date"),
    ],
    ruleDays: [1], autoOutreachEnabled: false,
    jobStatusByID: ["j1": "scheduled"], now: now, calendar: calendar)
expect(excluded.isEmpty, "paid, imported, unfinished-job and malformed rows never schedule")
let eligible = NativeInvoiceNotifications.reminders(
    invoices: [inv("done", due: "2026-09-10", job: "j2"), inv("gone", due: "2026-09-10", job: "missing")],
    ruleDays: [1], autoOutreachEnabled: false,
    jobStatusByID: ["j2": "complete"], now: now, calendar: calendar)
expect(eligible.count == 2, "done jobs and missing jobs stay eligible")
expect(NativeInvoiceNotifications.isDunningEligible(jobStatus: nil), "unlinked invoices are eligible")
expect(!NativeInvoiceNotifications.isDunningEligible(jobStatus: "in_progress"), "unfinished jobs suppress")

// A rule whose fire date already passed schedules nothing.
let past = NativeInvoiceNotifications.reminders(
    invoices: [inv("a", due: "2026-09-01")],
    ruleDays: [1], autoOutreachEnabled: false,
    jobStatusByID: [:], now: at(2026, 9, 10), calendar: calendar)
expect(past.isEmpty, "elapsed fire dates do not schedule")

// No rules, or only negative rules, schedule nothing.
expect(NativeInvoiceNotifications.reminders(invoices: [inv("a", due: "2026-09-01")], ruleDays: [],
    autoOutreachEnabled: false, jobStatusByID: [:], now: now, calendar: calendar).isEmpty, "no rules schedules nothing")
expect(NativeInvoiceNotifications.reminders(invoices: [inv("a", due: "2026-09-01")], ruleDays: [-3],
    autoOutreachEnabled: false, jobStatusByID: [:], now: now, calendar: calendar).isEmpty, "negative rules are dropped")

// Recurring: one per active rule at 9 a.m. on its next generation date.
let recurring = NativeInvoiceNotifications.recurringReminders(
    rules: [
        .init(id: "r1", customerName: "Acme", isActive: true, nextDueDate: "2026-09-20"),
        .init(id: "r2", customerName: "Bakery", isActive: false, nextDueDate: "2026-09-20"),
        .init(id: "r3", customerName: "Deli", isActive: true, nextDueDate: "2026-09-01"),
    ],
    now: now, calendar: calendar)
expect(recurring.map(\.identifier) == ["rinv_r1"], "only the active future rule schedules")
expect(recurring.first?.title == "Maintenance invoice ready — Acme", "recurring copy")

// Task 10.06 — the `inv_` and `rinv_` 9 a.m. fire-date construction share the
// same `dayDate` local-frame day parser (see NativeInvoiceNotifications.swift),
// so the two branches cannot independently drift the way the pre-2026-08-01
// bare-UTC parse did. Pin that across a US DST boundary (2026-03-08, spring
// forward) in an explicit non-UTC zone: both branches must still land at
// 9 a.m. local on the intended calendar day, not 8 a.m./10 a.m. from a
// UTC-offset slip.
var dstCalendar = Calendar(identifier: .gregorian)
dstCalendar.timeZone = TimeZone(identifier: "America/New_York")!
let beforeDST = dstCalendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 0))!
let dunning = NativeInvoiceNotifications.reminders(
    invoices: [inv("dst", due: "2026-03-07")],
    ruleDays: [1], autoOutreachEnabled: false,
    jobStatusByID: [:], now: beforeDST, calendar: dstCalendar)
let maintenance = NativeInvoiceNotifications.recurringReminders(
    rules: [.init(id: "dst", customerName: "Acme", isActive: true, nextDueDate: "2026-03-08")],
    now: beforeDST, calendar: dstCalendar)
let expectedDST = dstCalendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9))!
expect(dunning.first?.fireDate == expectedDST,
       "inv_ fires 9am America/New_York on due+1 across the spring-forward boundary")
expect(maintenance.first?.fireDate == expectedDST,
       "rinv_ fires 9am America/New_York on the same DST-boundary day as inv_ — no cross-branch drift")
expect(dunning.first?.fireDate == maintenance.first?.fireDate,
       "inv_ and rinv_ resolve the identical fire instant for the same calendar day")

print(failures == 0 ? "PASS: native invoice notification tests" : "FAILED: \(failures) native invoice notification test(s)")
if failures != 0 { exit(1) }
