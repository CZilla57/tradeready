import Foundation

/// Pure port of the Today screen's day/week projection, stats, briefing
/// sections, header, first-action hero, and cross-tab routing contract (task
/// 10.04, requirements D1, D2, D3, D6, D5-pure).
///
/// Ported from `screens/TodayScreen.tsx` (week strip, stats row, hero,
/// briefing sections, `handleInsightNavigate`, `handleBookingRowPress`),
/// `utils/dateHelpers.ts`, `utils/storage/dailyOps.ts`
/// (`getExpectedEarningsForDate`, `filterOverdueInvoices`, `loadLeadJobs`),
/// and `utils/estimateFollowUps.ts` (`selectAwaitingFollowUp`,
/// `awaitingResponseLabel`, reused directly from `NativeEstimateFollowUp`,
/// task 8.0x).
///
/// No I/O, no SwiftUI, no store access. `sampleTourDone` and
/// `followUpsEnabled` are plain inputs — the setup-checklist store (10.03)
/// and the settings snapshot are resolved by the caller. This module performs
/// no routing side effects itself: `NativeTodayDestination` is the pure
/// contract 10.11 executes against the existing one-shot exact-ID routing
/// pattern (`NativeGlobalSearch`/`AppStore.routeToGlobalSearchResult`) —
/// verify the local id, change tab, install a single-use request, fail
/// closed on missing/archived.
///
/// Local-frame date semantics throughout (FA-039): every `YYYY-MM-DD` is
/// walked with `NativeSchedule`'s DST-immune epoch-day arithmetic, never
/// `Date`-parsed. Where RN's own `weekMonthLabel` builds its label via
/// `new Date(weekDates[0])` (a bare-date UTC parse), this port intentionally
/// does NOT reproduce that specific RN defect: west-of-UTC devices would
/// mislabel a week starting on the 1st of a month (e.g. a week containing
/// Jan 1 would read "Dec" locally). That is exactly the class of bug the
/// binding global constraint ("date-only strings use local-frame string
/// math, never Date-parsing to UTC") and CLAUDE.md's "no current app users:
/// choose correctness over preserving existing-user state" rule call out —
/// recorded here as an intentional, reported native difference, not an
/// oversight.
public enum NativeTodayDestination: Equatable, Hashable {
    case job(jobId: String)
    case createInvoice(jobId: String)
    case invoice(invoiceId: String)
    case invoices
    case jobs
    case schedule(jobId: String)
    case selectDate(date: String)
    case customer(customerId: String)
    case customers
    case money
    case calendar
    case search
    case settings
    case route
    case onMyWay(jobId: String)
    /// First-action hero / empty-schedule "+ Schedule a Job": Jobs → AddJob,
    /// no jobId. Named to match `NativeGlobalSearchActionID.newJob`.
    case newJob
    /// First-action hero "Add Your First Customer": Customers → AddCustomer.
    case newCustomer
}

public enum NativeTodayHeroKind: String, Equatable {
    case sampleTour
    case addCustomer
    case createJob
}

public struct NativeTodayHero: Equatable {
    public let kind: NativeTodayHeroKind
    public let title: String
    public let subtitle: String
    public let destination: NativeTodayDestination

    public init(kind: NativeTodayHeroKind, title: String, subtitle: String, destination: NativeTodayDestination) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.destination = destination
    }
}

public struct NativeWeekDay: Equatable {
    public let date: String
    public let dayNumber: Int
    public let isSelected: Bool
    public let isToday: Bool
    public let hasJobs: Bool
}

public struct NativeWeekStrip: Equatable {
    public let monthLabel: String
    public let days: [NativeWeekDay]
}

public struct NativeCappedSection<Item> {
    public let visible: [Item]
    public let extraCount: Int
    public let totalCount: Int
}

public struct NativeAwaitingEstimatesRow {
    public let jobIds: [String]
    public let label: String
}

public struct NativeTodayHeader: Equatable {
    public let greeting: String
    public let dateLabel: String
}

public struct NativeBookingRowPresentation {
    public let title: String
    public let summary: String
    public let body: String
    /// Destination for the row's "View job" action; `.jobs` when the row
    /// carries no resolvable job id (never a dead action).
    public let jobDestination: NativeTodayDestination
}

public enum NativeTodayBriefing {
    public static let invoiceLimit = 3
    public static let leadLimit = 3

    // MARK: - D6: destination mapping (exhaustive over NativeInsightTarget)

    /// Maps every `NativeInsightTarget` case (10.02) onto the Today routing
    /// contract. No `default:` — a new insight target fails this switch at
    /// compile time.
    public static func destination(for target: NativeInsightTarget) -> NativeTodayDestination {
        switch target {
        case .job(let jobId):
            return .job(jobId: jobId)
        case .createInvoice(let jobId):
            return .createInvoice(jobId: jobId)
        case .invoice(let invoiceId):
            return .invoice(invoiceId: invoiceId)
        case .invoices:
            return .invoices
        case .jobs:
            return .jobs
        case .schedule(let jobId):
            return .schedule(jobId: jobId)
        case .selectDate(let date):
            return .selectDate(date: date)
        case .customer(let customerId):
            return .customer(customerId: customerId)
        case .customers:
            return .customers
        case .money:
            return .money
        }
    }

    // MARK: - Header (§1.4)

    /// `getGreeting`: morning < 12:00, afternoon < 17:00, else evening.
    public static func greeting(now: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    /// `getTodayDateString`: local "YYYY-MM-DD" for `now`, never `toISOString`.
    public static func todayDateString(now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return ymd(parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// `formatDisplayDate`: "Saturday, July 4" — long weekday + long month,
    /// no year.
    public static func formatDisplayDate(_ dateString: String) -> String {
        guard let (_, month, day) = NativeSchedule.parseDateComponents(dateString),
              let weekday = NativeSchedule.isoWeekday(dateString)
        else { return dateString }
        return "\(weekdayNamesLong[weekday - 1]), \(monthNamesLong[month - 1]) \(day)"
    }

    /// The schedule-section title for a non-today selected date: "Thursday,
    /// Jul 4" — long weekday, short month, no year. `"Today's Schedule"` when
    /// `selectedDate == today`.
    public static func scheduleSectionTitle(selectedDate: String, today: String) -> String {
        guard selectedDate != today else { return "Today's Schedule" }
        guard let (_, month, day) = NativeSchedule.parseDateComponents(selectedDate),
              let weekday = NativeSchedule.isoWeekday(selectedDate)
        else { return selectedDate }
        return "\(weekdayNamesLong[weekday - 1]), \(monthNamesShort[month - 1]) \(day)"
    }

    public static func header(now: Date, todayDateString: String, calendar: Calendar = .current) -> NativeTodayHeader {
        .init(greeting: greeting(now: now, calendar: calendar), dateLabel: formatDisplayDate(todayDateString))
    }

    // MARK: - Week strip (§1.1)

    /// The Mon–Sun week containing `selectedDate`, with per-day selection/
    /// today/has-jobs flags and the month label. `nil` only for a malformed
    /// `selectedDate` (never produced by `todayDateString`/`shiftDate`).
    public static func weekStrip(selectedDate: String, today: String, jobDates: Set<String>) -> NativeWeekStrip? {
        guard let dates = NativeSchedule.weekDates(anchor: selectedDate) else { return nil }
        let days: [NativeWeekDay] = dates.compactMap { date in
            guard let (_, _, day) = NativeSchedule.parseDateComponents(date) else { return nil }
            return NativeWeekDay(
                date: date,
                dayNumber: day,
                isSelected: date == selectedDate,
                isToday: date == today,
                hasJobs: jobDates.contains(date)
            )
        }
        guard days.count == dates.count else { return nil }
        return NativeWeekStrip(monthLabel: monthLabel(for: dates), days: days)
    }

    /// `weekMonthLabel`, computed from local-frame date components (see the
    /// type doc comment for why this intentionally does not reproduce RN's
    /// `new Date(weekDates[0])` UTC-parse defect).
    static func monthLabel(for weekDates: [String]) -> String {
        guard let first = weekDates.first, let last = weekDates.last,
              let (firstYear, firstMonth, _) = NativeSchedule.parseDateComponents(first),
              let (lastYear, lastMonth, _) = NativeSchedule.parseDateComponents(last)
        else { return "" }
        if firstMonth == lastMonth {
            return "\(monthNamesShort[firstMonth - 1]) \(firstYear)"
        }
        return "\(monthNamesShort[firstMonth - 1]) – \(monthNamesShort[lastMonth - 1]) \(lastYear)"
    }

    /// `shiftDate` — DST-immune epoch-day shift.
    public static func shiftDate(_ date: String, days: Int) -> String? {
        NativeSchedule.shiftDate(date, days: days)
    }

    // MARK: - Per-day schedule + earnings (§1.1, §1.2)

    /// `allJobs.filter(scheduledDate === date).sort(unscheduled-last)`.
    public static func scheduleRows(_ jobs: [Canonical.Job], date: String) -> [Canonical.Job] {
        jobs
            .filter { $0.scheduledDate == date }
            .sorted { compareScheduleOrder($0, $1) < 0 }
    }

    /// JS 3-way comparator semantics preserved exactly (unscheduled rows
    /// always sort after any scheduled row; two unscheduled rows are left in
    /// their relative input order by Swift's guaranteed-stable sort, matching
    /// V8's stable sort for the same non-total-order comparator).
    private static func compareScheduleOrder(_ a: Canonical.Job, _ b: Canonical.Job) -> Int {
        let aStart = a.scheduledStartTime, bStart = b.scheduledStartTime
        if aStart == nil || aStart!.isEmpty { return 1 }
        if bStart == nil || bStart!.isEmpty { return -1 }
        if aStart! == bStart! { return 0 }
        return aStart! < bStart! ? -1 : 1
    }

    /// `getExpectedEarningsForDate`: sum of `jobBillableTotal` (estimate +
    /// approved change orders) over that day's rows — not filtered by
    /// status, so a scheduled lead still counts toward "expected".
    public static func earnings(for date: String, jobs: [Canonical.Job]) -> Decimal {
        jobs
            .filter { $0.scheduledDate == date }
            .reduce(Decimal.zero) { $0 + NativeChangeOrders.billableTotal(for: $1) }
    }

    /// Every scheduled date with at least one job — the week strip's dots.
    public static func jobDates(_ jobs: [Canonical.Job]) -> Set<String> {
        Set(jobs.compactMap { $0.scheduledDate })
    }

    // MARK: - Overdue invoices (§1.4)

    /// `daysPastDue`: local-frame whole-day difference via `NativeSchedule`'s
    /// DST-immune epoch-day arithmetic — safer than the JS-mirroring
    /// millisecond-diff-then-round approach, and fully injectable (`due` is a
    /// naive date-only string; only `now`'s local Y/M/D read depends on
    /// `calendar`, so a caller can pin an explicit `TimeZone` regardless of
    /// process `TZ`).
    public static func daysPastDue(_ due: String, now: Date, calendar: Calendar = .current) -> Int {
        guard let (year, month, day) = NativeSchedule.parseDateComponents(due) else { return 0 }
        let dueEpoch = NativeSchedule.epochDays(year: year, month: month, day: day)
        let nowParts = calendar.dateComponents([.year, .month, .day], from: now)
        let nowEpoch = NativeSchedule.epochDays(
            year: nowParts.year ?? year, month: nowParts.month ?? month, day: nowParts.day ?? day
        )
        return nowEpoch - dueEpoch
    }

    /// `filterOverdueInvoices`: unpaid, `daysPastDue >= 1` (due-today is NOT
    /// overdue), oldest due date first.
    public static func overdueInvoices(_ invoices: [Canonical.Invoice], now: Date, calendar: Calendar = .current) -> [Canonical.Invoice] {
        invoices
            .filter { invoice in
                let ledger = NativeCashBasis.ledgerInvoice(invoice)
                guard !PaymentLedger.isFullyPaid(ledger) else { return false }
                return daysPastDue(invoice.due, now: now, calendar: calendar) >= 1
            }
            .sorted { $0.due < $1.due }
    }

    public static func overdueTotal(_ invoices: [Canonical.Invoice]) -> Decimal {
        invoices.reduce(Decimal.zero) { $0 + PaymentLedger.balanceDue(NativeCashBasis.ledgerInvoice($1)) }
    }

    // MARK: - Leads / follow-up (§1.4)

    /// `loadLeadJobs`: `status === "lead"`, oldest lead first.
    public static func leadJobs(_ jobs: [Canonical.Job]) -> [Canonical.Job] {
        jobs
            .filter { $0.status == "lead" }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Section caps (§1.4)

    /// `INVOICE_LIMIT`/`LEAD_LIMIT` caps: `visible = items.prefix(limit)`,
    /// `extraCount = max(0, total - limit)`.
    public static func capped<Item>(_ items: [Item], limit: Int) -> NativeCappedSection<Item> {
        let total = items.count
        let visible = Array(items.prefix(max(0, limit)))
        return NativeCappedSection(visible: visible, extraCount: max(0, total - limit), totalCount: total)
    }

    // MARK: - Estimates awaiting response (§1.4, 2a)

    /// `selectAwaitingFollowUp` + `awaitingResponseLabel`, gated on the
    /// follow-up toggle. Reuses `NativeEstimateFollowUp` (task 8.0x) directly
    /// rather than re-deriving the `FOLLOW_UP_DAYS` boundary.
    public static func awaitingEstimatesRow(
        jobs: [Canonical.Job],
        now: Date,
        followUpsEnabled: Bool,
        calendar: Calendar = .current
    ) -> NativeAwaitingEstimatesRow? {
        guard followUpsEnabled else { return nil }
        let matches = NativeEstimateFollowUp.awaitingResponse(jobs: jobs, now: now, calendar: calendar)
        guard !matches.isEmpty else { return nil }
        return NativeAwaitingEstimatesRow(
            jobIds: matches.map(\.id),
            label: NativeEstimateFollowUp.awaitingResponseLabel(count: matches.count)
        )
    }

    // MARK: - First-action hero (§1.5, D5)

    /// Legacy sample-data id pattern (`utils/sampleData.ts` `SAMPLE_ID_RE`):
    /// `c[1-3]`, `j[1-3]`, or `[1-4]`, optionally suffixed `-s<namespace>`.
    static let sampleIDPattern = try! NSRegularExpression(pattern: "^(c[1-3]|j[1-3]|[1-4])(-s[a-z0-9]+)?$")

    public static func isSampleId(_ id: String) -> Bool {
        sampleIDPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    /// Derived hero for brand-new accounts. `sampleTourDone` is a plain input
    /// (10.03's checklist store owns persistence); this performs no
    /// analytics/tracking and no store writes — 10.12 owns those on tap.
    ///
    /// Ported exactly from `TodayScreen.tsx`'s NESTED conditional (not the
    /// contract's flattened pseudocode in §1.5, which collapses to the same
    /// result in every case except one: when `sampleJobs.count > 0` AND
    /// (`realCustomers.count > 0` OR `sampleTourDone`), RN shows NO hero at
    /// all — it does not fall through to "Create Your First Job". See the
    /// task report for this discrepancy.
    public static func hero(
        jobs: [Canonical.Job],
        customers: [Canonical.Customer],
        sampleTourDone: Bool
    ) -> NativeTodayHero? {
        let realJobs = jobs.filter { !isSampleId($0.id) }
        guard realJobs.isEmpty else { return nil }

        let sampleJobs = jobs.filter { isSampleId($0.id) }
        let realCustomers = customers.filter { !isSampleId($0.id) }

        if !sampleJobs.isEmpty {
            guard realCustomers.isEmpty, !sampleTourDone else { return nil }
            let target = sampleJobs.first { ($0.scheduledDate ?? "").isEmpty == false } ?? sampleJobs[0]
            return NativeTodayHero(
                kind: .sampleTour,
                title: "Explore a Sample Job",
                subtitle: "See how a job flows from lead to paid.",
                destination: .job(jobId: target.id)
            )
        }
        if realCustomers.isEmpty {
            return NativeTodayHero(
                kind: .addCustomer,
                title: "Add Your First Customer",
                subtitle: "Jobs, estimates, and invoices all start here.",
                destination: .newCustomer
            )
        }
        return NativeTodayHero(
            kind: .createJob,
            title: "Create Your First Job",
            subtitle: "Track it from lead to paid.",
            destination: .newJob
        )
    }

    // MARK: - Booking attention presentation (§2, D3)

    /// `formatTimeRange`: "9:00 AM – 11:00 AM", or just the start, or
    /// "Unscheduled" with no start.
    public static func formatTimeRange(_ startTime: String?, _ endTime: String?) -> String {
        guard let startTime, !startTime.isEmpty else { return "Unscheduled" }
        func format(_ time: String) -> String {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return time }
            let period = parts[0] >= 12 ? "PM" : "AM"
            let hour = parts[0] % 12 == 0 ? 12 : parts[0] % 12
            return String(format: "%d:%02d %@", hour, parts[1], period)
        }
        guard let endTime, !endTime.isEmpty else { return format(startTime) }
        return "\(format(startTime)) – \(format(endTime))"
    }

    /// Row title/body/"View job" destination for every `NativeBookingAttention`
    /// kind, including the native-only `missingJob`/`unconvertedActive` rows
    /// (Phase 8 addition; RN has no copy for these, so this is a documented
    /// native choice, not an RN mirror). "View job" always falls back to the
    /// Jobs tab rather than a dead action.
    public static func bookingRowPresentation(_ row: NativeBookingAttention.Row) -> NativeBookingRowPresentation {
        let request = row.request
        let jobDestination: NativeTodayDestination = row.jobID.map { .job(jobId: $0) } ?? .jobs
        let when = request.slot.map { "\(formatDisplayDate($0.date)), \(formatTimeRange($0.start, $0.end))" }

        switch row.kind {
        case .rescheduleRequested:
            let note = row.note.map { "\n\n\u{201C}\($0)\u{201D}" } ?? ""
            return NativeBookingRowPresentation(
                title: "\(request.name) asked to reschedule",
                summary: "\(request.name) asked to reschedule \(when ?? "")".trimmingCharacters(in: .whitespaces),
                body: "\(when ?? "")\(note)",
                jobDestination: jobDestination
            )
        case .portalChange:
            let verb = request.portalKind == "cancel" ? "cancel" : "reschedule"
            return NativeBookingRowPresentation(
                title: "\(request.name) asked to \(verb)",
                summary: "\(request.name) asked to \(verb) an appointment",
                body: row.note ?? "",
                jobDestination: jobDestination
            )
        case .cancelled:
            return NativeBookingRowPresentation(
                title: "\(request.name) cancelled their booking",
                summary: "Booking cancelled — \(request.name), \(when ?? "")".trimmingCharacters(in: .whitespaces),
                body: "\(when ?? "") is free again. Clear or reuse the time on the job.",
                jobDestination: jobDestination
            )
        case .missingJob:
            return NativeBookingRowPresentation(
                title: "\(request.name)'s booking needs attention",
                summary: "\(request.name)'s booking needs attention",
                body: "The linked job could not be found. It may have been deleted on another device.",
                jobDestination: .jobs
            )
        case .unconvertedActive:
            return NativeBookingRowPresentation(
                title: "\(request.name) is waiting to be scheduled",
                summary: "\(request.name) is waiting to be scheduled",
                body: when.map { "Requested for \($0)." } ?? "This request has not been converted to a job yet.",
                jobDestination: .jobs
            )
        }
    }

    /// RN's `bookingRowLabel` — the SHORT date-only form used for both the
    /// row's visible text and its accessibility label. Deliberately distinct
    /// from `bookingRowPresentation(_:).summary`, which carries a
    /// time-inclusive `when` meant for the tap alert, not this row.
    public static func bookingRowLabel(_ row: NativeBookingAttention.Row) -> String {
        let request = row.request
        if row.kind == .portalChange {
            let verb = request.portalKind == "cancel" ? "cancel" : "reschedule"
            return "\(request.name) asked to \(verb) an appointment"
        }
        let when = request.slot.map { formatDisplayDate($0.date) } ?? ""
        switch row.kind {
        case .rescheduleRequested:
            return "\(request.name) asked to reschedule \(when)".trimmingCharacters(in: .whitespaces)
        case .cancelled:
            return "Booking cancelled — \(request.name), \(when)".trimmingCharacters(in: .whitespaces)
        case .missingJob, .unconvertedActive:
            return bookingRowPresentation(row).summary
        case .portalChange:
            return ""
        }
    }

    // MARK: - Private formatting tables

    private static let weekdayNamesLong = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]
    private static let monthNamesLong = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    private static let monthNamesShort = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    private static func ymd(_ year: Int, _ month: Int, _ day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}
