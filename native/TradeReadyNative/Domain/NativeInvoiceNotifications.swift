import Foundation

/// Pure invoice/reminder selectors mirroring `utils/notifications.ts`
/// (the `inv_` dunning and `rinv_` maintenance-plan branches) and
/// `backend-workers/lib/selectInvoicesToRemind.js` (dunning eligibility).
///
/// Standalone-compilable (Foundation only). Fire dates are 9:00 a.m. local on
/// the rule day, built in the local frame (`date + 'T00:00:00'` parse then
/// `setHours(9, …)`) exactly like the sibling branches — the bare-UTC parse
/// that once fired a day early must not be reintroduced.
///
/// Exclusions (both branches): paid invoices, missing/malformed dues,
/// imported historical invoices (`importBatchId` — never dunned, local or
/// emailed), and pre-completion deposit invoices (a job-linked invoice whose
/// job is not done yet).
struct NativeInvoiceNotificationInvoice: Equatable {
    var id: String
    var customer: String
    var number: String
    var isPaid: Bool
    var due: String
    var jobID: String?
    var importBatchId: String?
}

struct NativeInvoiceNotificationItem: Equatable {
    /// `inv_<invoiceID>_<days>d`, matching the RN identifier scheme.
    var identifier: String
    var invoiceID: String
    var daysPastDueRule: Int
    var opensOutreach: Bool
    var title: String
    var body: String
    var fireDate: Date
}

struct NativeRecurringInvoiceNotificationRule: Equatable {
    var id: String
    var customerName: String
    var isActive: Bool
    var nextDueDate: String
}

struct NativeRecurringInvoiceNotificationItem: Equatable {
    /// `rinv_<ruleID>`, matching the RN identifier scheme.
    var identifier: String
    var ruleID: String
    var title: String
    var body: String
    var fireDate: Date
}

enum NativeInvoiceNotifications {
    /// Overdue-invoice reminders, one per (invoice, rule) in list order.
    /// `jobStatusByID` maps job IDs to lifecycle statuses; a missing job (or
    /// no linkage) is eligible — only a found-but-unfinished job suppresses.
    static func reminders(
        invoices: [NativeInvoiceNotificationInvoice],
        ruleDays: [Int],
        autoOutreachEnabled: Bool,
        jobStatusByID: [String: String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [NativeInvoiceNotificationItem] {
        let validDays = ruleDays.filter { $0 >= 0 }
        guard !validDays.isEmpty else { return [] }
        var items: [NativeInvoiceNotificationItem] = []
        for invoice in invoices {
            guard !invoice.isPaid,
                  !invoice.due.isEmpty,
                  invoice.importBatchId == nil,
                  isDunningEligible(jobStatus: invoice.jobID.flatMap { jobStatusByID[$0] })
            else { continue }
            for days in validDays {
                guard let fireDate = fireDate(fromDue: invoice.due, plusDays: days, calendar: calendar),
                      fireDate > now
                else { continue }
                if autoOutreachEnabled {
                    items.append(NativeInvoiceNotificationItem(
                        identifier: "inv_\(invoice.id)_\(days)d",
                        invoiceID: invoice.id,
                        daysPastDueRule: days,
                        opensOutreach: true,
                        title: "Follow up with \(invoice.customer)",
                        body: "Tap to send a reminder for \(invoice.number) — \(days) days past due.",
                        fireDate: fireDate))
                } else {
                    items.append(NativeInvoiceNotificationItem(
                        identifier: "inv_\(invoice.id)_\(days)d",
                        invoiceID: invoice.id,
                        daysPastDueRule: days,
                        opensOutreach: false,
                        title: "Overdue invoice — \(invoice.customer)",
                        body: "Invoice \(invoice.number) is now \(days) days past due.",
                        fireDate: fireDate))
                }
            }
        }
        return items
    }

    /// Maintenance-plan "review & send" reminders — one per active rule at
    /// 9:00 a.m. on its next generation date. Generation itself happens on
    /// foreground after sync, not here.
    static func recurringReminders(
        rules: [NativeRecurringInvoiceNotificationRule],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [NativeRecurringInvoiceNotificationItem] {
        var items: [NativeRecurringInvoiceNotificationItem] = []
        for rule in rules {
            guard rule.isActive,
                  let fireDate = nineAM(on: rule.nextDueDate, calendar: calendar),
                  fireDate > now
            else { continue }
            items.append(NativeRecurringInvoiceNotificationItem(
                identifier: "rinv_\(rule.id)",
                ruleID: rule.id,
                title: "Maintenance invoice ready — \(rule.customerName)",
                body: "Open to review & send.",
                fireDate: fireDate))
        }
        return items
    }

    /// `isJobDunningEligible` parity: a pre-work deposit invoice tied to an
    /// unfinished job must never dunn. Invoices with no linked job, or whose
    /// job can no longer be found, are eligible.
    static func isDunningEligible(jobStatus: String?) -> Bool {
        guard let jobStatus else { return true }
        return jobStatus == "complete" || jobStatus == "invoiced" || jobStatus == "paid"
    }

    static func fireDate(fromDue due: String, plusDays days: Int, calendar: Calendar = .current) -> Date? {
        guard let base = dayDate(due, calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: base)
        else { return nil }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: shifted)
    }

    static func nineAM(on day: String, calendar: Calendar = .current) -> Date? {
        guard let base = dayDate(day, calendar: calendar) else { return nil }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: base)
    }

    private static func dayDate(_ raw: String, calendar: Calendar) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }
}
