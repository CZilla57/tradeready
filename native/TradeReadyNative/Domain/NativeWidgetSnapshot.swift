import Foundation

// MARK: - Widget snapshot projection (task 11.01, requirement W1)
//
// Pure port of RN `buildWidgetSnapshot` / `selectNextJob` / `selectActiveTimer`
// (`utils/widgetBridge.ts`), producing the shared `WidgetSnapshot` schema
// (`N/Widgets/Shared/WidgetSnapshot.swift`). Contract:
// docs/native-phase-11-platform-hardening-contract-decisions.md §2.2–2.3.
//
// App target only: it reads canonical records. `now` and the calendar are
// injected so fixtures are deterministic. `outstandingTotal` is never summed
// here: it is the 10.01 `NativeBusinessSnapshot.outstandingTotal`, rounded to
// dollars-and-cents by `FinancialDecimal.cents`.

enum NativeWidgetSnapshotProjection {
    /// RN `DONE_STATUSES`: finished (or never-happening) work is history, not
    /// the answer to "when is my next job?".
    static let doneStatuses: Set<String> = ["complete", "invoiced", "paid", "declined"]

    /// `buildWidgetSnapshot`. The result carries no `ownerTag`; the writer
    /// stamps it from the owner binding it re-checks under the lock.
    static func project(
        jobs: [Canonical.Job],
        business: NativeBusinessSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            version: WidgetSnapshot.currentVersion,
            updatedAt: WidgetSnapshot.isoTimestamp(now),
            nextJob: nextJob(jobs: jobs, now: now, calendar: calendar),
            timer: activeTimer(jobs: jobs),
            outstandingTotal: outstandingTotal(business),
            ownerTag: nil
        )
    }

    /// `selectNextJob`: the earliest candidate by `scheduledDate`, then by
    /// `scheduledStartTime` with no-time jobs last. Candidates are not
    /// archived, have a `scheduledDate >= ` local today (string compare, never
    /// parsed — FA-039), and are not in `doneStatuses`. Today's job stays
    /// "next" after its start time passes. Ties keep input order (JS
    /// `Array.prototype.sort` is stable).
    static func nextJob(
        jobs: [Canonical.Job],
        now: Date,
        calendar: Calendar = .current
    ) -> WidgetSnapshot.NextJob? {
        let today = localDateString(now, calendar: calendar)
        let candidates = jobs.enumerated().compactMap { index, job -> (Int, Canonical.Job, String)? in
            guard !isArchived(job),
                  let date = job.scheduledDate,
                  date >= today,
                  !doneStatuses.contains(job.status)
            else { return nil }
            return (index, job, date)
        }
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            let lhsTime = startTime(lhs.1)
            let rhsTime = startTime(rhs.1)
            switch (lhsTime, rhsTime) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.0 < rhs.0
            }
        }
        guard let (_, job, date) = ordered.first else { return nil }
        return WidgetSnapshot.NextJob(
            id: job.id,
            customerName: job.customerName,
            title: job.title,
            scheduledDate: date,
            scheduledStartTime: startTime(job),
            address: job.address
        )
    }

    /// `selectActiveTimer`: the open session (`NativeTimeTracking.activeSession`,
    /// the last session with no end) with the latest `start` across all jobs;
    /// on a tie the first job wins (RN's strict `>`). Archived jobs are not
    /// filtered, so a running clock is never hidden (§2.2 parity).
    static func activeTimer(jobs: [Canonical.Job]) -> WidgetSnapshot.TimerState? {
        var best: WidgetSnapshot.TimerState?
        for job in jobs {
            let sessions = (job.timeSessions ?? []).map { NativeTimeSession(start: $0.start, end: $0.end) }
            guard let active = NativeTimeTracking.activeSession(in: sessions) else { continue }
            if best == nil || active.start > best!.startedAt {
                best = WidgetSnapshot.TimerState(
                    jobId: job.id,
                    jobTitle: job.title,
                    customerName: job.customerName,
                    startedAt: active.start
                )
            }
        }
        return best
    }

    /// `roundToCents(summarizeInvoices(invoices).outstanding)`, sourced from
    /// the 10.01 business snapshot — never a re-derived sum (§2.2).
    /// `FinancialDecimal.cents` returns dollars rounded to 2 dp.
    static func outstandingTotal(_ business: NativeBusinessSnapshot) -> Double {
        let rounded = FinancialDecimal.cents(business.outstandingTotal)
        return Double(NSDecimalNumber(decimal: rounded).stringValue) ?? 0
    }

    // MARK: Helpers

    /// RN `!j.archivedAt`: an empty string is not archived.
    private static func isArchived(_ job: Canonical.Job) -> Bool {
        guard let archivedAt = job.archivedAt else { return false }
        return !archivedAt.isEmpty
    }

    /// RN treats a falsy start time (`null` or `""`) as "no time". The
    /// snapshot writes nil for both, so the widget's local-frame parse never
    /// sees `"yyyy-MM-dd "`.
    private static func startTime(_ job: Canonical.Job) -> String? {
        guard let time = job.scheduledStartTime, !time.isEmpty else { return nil }
        return time
    }

    /// `getTodayDateString`: local `YYYY-MM-DD`, never `toISOString`.
    static func localDateString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

// The owner tag (`NativeWidgetOwnerTag`, contract §2.3/§2.5) lives in
// `N/NativeWidgetOwnerGate.swift` with the replay owner gate (task 11.05).
