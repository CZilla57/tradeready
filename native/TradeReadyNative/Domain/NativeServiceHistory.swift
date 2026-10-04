import Foundation

// MARK: - Phase 33: shared service history (spec §5.3, D6)
//
// The one definition of "last service" and of the guards around it, shared by
// the `maintenance_due` Today insight (`NativeTodayInsights`) and campaign
// segments (`NativeCampaignSegments`), so the insight and the "Due for
// maintenance" preset always agree on who qualifies. Extracted unchanged from
// `selectMaintenanceDue`; the TodayInsights vectors guard the refactor.
//
// Month math is pure component arithmetic over the local `YYYY-MM-DD`
// (`NativeSchedule.parseDateComponents`, `NativeCashBasis.localComponents`),
// never `Date`-parsing a bare date (FA-039).

enum NativeServiceHistory {
    /// The `maintenance_due` cadence (a constant, not a setting), shared with
    /// the "Due for maintenance" campaign preset.
    static let maintenanceDueMonths = 6
    /// Statuses that count as delivered work.
    static let deliveredStatuses: Set<String> = ["complete", "invoiced", "paid"]
    /// Non-archived jobs in these statuses are open work.
    static let activePipelineStatuses: Set<String> = [
        "lead", "estimate_sent", "approved", "scheduled", "in_progress",
    ]

    struct LastService: Equatable {
        /// Local `YYYY-MM-DD`: the latest `scheduledDate` of a delivered job.
        let date: String
        /// That job's title.
        let title: String
    }

    /// Jobs grouped by `customerId` (input order kept), so a pass over every
    /// customer is linear.
    static func jobsByCustomer(_ jobs: [Canonical.Job]) -> [String: [Canonical.Job]] {
        Dictionary(grouping: jobs, by: \.customerId)
    }

    /// `maintenance_due`'s rule exactly: jobs linked by `customerId` only,
    /// delivered statuses, the max non-empty `scheduledDate` (the first job
    /// wins a tie) and its title. Archived delivered jobs still count as
    /// history. `nil` when no delivered job is dated.
    static func lastService(customerID: String, jobsByCustomer: [String: [Canonical.Job]]) -> LastService? {
        var lastDate = ""
        var lastTitle = ""
        for job in jobsByCustomer[customerID] ?? [] {
            guard deliveredStatuses.contains(job.status), let scheduledDate = job.scheduledDate, !scheduledDate.isEmpty
            else { continue }
            if scheduledDate > lastDate {
                lastDate = scheduledDate
                lastTitle = job.title
            }
        }
        return lastDate.isEmpty ? nil : LastService(date: lastDate, title: lastTitle)
    }

    /// Any delivered job at all, dated or not.
    static func hasDeliveredJob(customerID: String, jobsByCustomer: [String: [Canonical.Job]]) -> Bool {
        (jobsByCustomer[customerID] ?? []).contains { deliveredStatuses.contains($0.status) }
    }

    /// The titles of the customer's delivered jobs, in input order.
    static func deliveredTitles(customerID: String, jobsByCustomer: [String: [Canonical.Job]]) -> [String] {
        (jobsByCustomer[customerID] ?? []).filter { deliveredStatuses.contains($0.status) }.map(\.title)
    }

    /// A non-archived job in the active pipeline.
    static func hasOpenWork(customerID: String, jobsByCustomer: [String: [Canonical.Job]]) -> Bool {
        (jobsByCustomer[customerID] ?? []).contains {
            activePipelineStatuses.contains($0.status) && ($0.archivedAt ?? "").isEmpty
        }
    }

    /// An active recurring job (maintenance plan) for the customer.
    static func hasActiveMaintenancePlan(customerID: String, recurringJobs: [Canonical.RecurringJob]) -> Bool {
        recurringJobs.contains { $0.isActive && $0.customerId == customerID }
    }

    /// Whole calendar months elapsed from a local `YYYY-MM-DD` to `now` in the
    /// device's zone: the day of month must be reached for the month to
    /// count. A malformed date reads as 0.
    static func monthsBetween(from: String, now: Date) -> Int {
        guard let (y, m, d) = NativeSchedule.parseDateComponents(from) else { return 0 }
        let (ny, nmZeroBased, nd) = NativeCashBasis.localComponents(now)
        var months = (ny - y) * 12 + (nmZeroBased + 1 - m)
        if nd < d { months -= 1 }
        return months
    }
}
