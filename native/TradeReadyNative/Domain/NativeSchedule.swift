import Foundation

/// Pure owner-local schedule engine (Phase 8 task 8.01, requirements S1/S2).
///
/// Swift port of `utils/scheduleConfig.ts` + the time/date helpers in
/// `utils/scheduleSmarts.ts` + the week selectors in `utils/dateHelpers.ts`.
/// Dependency-free (Foundation only): no network, no store writes, no clock
/// reads — callers inject `now`. All date math is owner-naive `YYYY-MM-DD`
/// string comparison plus integer epoch-day arithmetic, so viewing on a
/// device in another zone never shifts the stored business date.
///
/// Resolving a legacy config never mutates it: `resolveSchedule` returns a
/// fresh `ResolvedSchedule` value and leaves the source
/// `Canonical.ScheduleConfig` (including its preservation bag) untouched.
public enum NativeSchedule {

    // MARK: - Resolved projection

    public static let defaultWorkDays = [1, 2, 3, 4, 5, 6] // Mon-Sat, ISO
    public static let defaultWorkDayStart = "08:00"
    public static let defaultWorkDayEnd = "17:00"
    public static let defaultDurationMinutes = 60
    public static let defaultBufferMinutes = 0
    public static let defaultSlotLeadHours = 24
    public static let defaultSlotWindowDays = 14

    public struct ResolvedSchedule: Equatable {
        /// IANA zone, or nil until the owner enables slot booking.
        public var timeZone: String?
        /// ISO weekdays 1-7 (Mon=1), deduped and sorted.
        public var workDays: [Int]
        public var workDayStart: String
        public var workDayEnd: String
        public var defaultDurationMinutes: Int
        public var bufferMinutes: Int
        public var slotLeadHours: Int
        public var slotWindowDays: Int
        public var blackouts: [ScheduleBlackout]
        public var bookableSlotsEnabled: Bool

        public static var defaults: ResolvedSchedule {
            ResolvedSchedule(
                timeZone: nil,
                workDays: NativeSchedule.defaultWorkDays,
                workDayStart: NativeSchedule.defaultWorkDayStart,
                workDayEnd: NativeSchedule.defaultWorkDayEnd,
                defaultDurationMinutes: NativeSchedule.defaultDurationMinutes,
                bufferMinutes: NativeSchedule.defaultBufferMinutes,
                slotLeadHours: NativeSchedule.defaultSlotLeadHours,
                slotWindowDays: NativeSchedule.defaultSlotWindowDays,
                blackouts: [],
                bookableSlotsEnabled: false
            )
        }
    }

    public struct ScheduleBlackout: Equatable {
        public var id: String
        public var start: String // inclusive YYYY-MM-DD
        public var end: String   // inclusive YYYY-MM-DD
        public var reason: String?

        public init(id: String, start: String, end: String, reason: String? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.reason = reason
        }
    }

    /// Mirrors `resolveSchedule`: explicit validation, never truthiness, so a
    /// valid zero lead/buffer survives while zero duration/horizon falls back.
    /// A `nil` config (absent schedule) resolves to defaults.
    public static func resolveSchedule(_ config: Canonical.ScheduleConfig?) -> ResolvedSchedule {
        guard let config else { return .defaults }
        var workDayStart = isValidTime(config.workDayStart) ? config.workDayStart! : defaultWorkDayStart
        var workDayEnd = isValidTime(config.workDayEnd) ? config.workDayEnd! : defaultWorkDayEnd
        if workDayStart >= workDayEnd {
            // A half-valid window is not a window: BOTH revert.
            workDayStart = defaultWorkDayStart
            workDayEnd = defaultWorkDayEnd
        }
        return ResolvedSchedule(
            timeZone: (config.timeZone?.isEmpty == false) ? config.timeZone : nil,
            workDays: resolveWorkDays(config.workDays),
            workDayStart: workDayStart,
            workDayEnd: workDayEnd,
            defaultDurationMinutes: resolveNumber(config.defaultDurationMinutes, fallback: defaultDurationMinutes, min: 0, allowMin: false),
            bufferMinutes: resolveNumber(config.bufferMinutes, fallback: defaultBufferMinutes, min: 0, allowMin: true),
            slotLeadHours: resolveNumber(config.slotLeadHours, fallback: defaultSlotLeadHours, min: 0, allowMin: true),
            slotWindowDays: resolveNumber(config.slotWindowDays, fallback: defaultSlotWindowDays, min: 0, allowMin: false),
            blackouts: resolveBlackouts(config.blackouts),
            bookableSlotsEnabled: config.bookableSlotsEnabled == true
        )
    }

    // MARK: - Date predicates (local frame)

    /// Inclusive on both bounds; pure string comparison (local-frame dates).
    public static func isBlackoutDate(_ schedule: ResolvedSchedule, date: String) -> Bool {
        schedule.blackouts.contains { $0.start <= date && date <= $0.end }
    }

    public static func isWorkDay(_ schedule: ResolvedSchedule, date: String) -> Bool {
        guard let weekday = isoWeekday(date) else { return false }
        return schedule.workDays.contains(weekday)
    }

    // MARK: - Time helpers (minutes since midnight)

    public static let timePattern = "^([01][0-9]|2[0-3]):[0-5][0-9]$"
    public static let datePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"

    public static func isValidTime(_ value: String?) -> Bool {
        guard let value else { return false }
        guard value.range(of: timePattern, options: .regularExpression) != nil else { return false }
        return true
    }

    public static func isValidDate(_ value: String?) -> Bool {
        guard let value, value.range(of: datePattern, options: .regularExpression) != nil else { return false }
        return parseDateComponents(value) != nil
    }

    /// Strict "HH:MM" parse; nil for anything outside 00:00-23:59.
    public static func toMinutes(_ time: String) -> Int? {
        let pieces = time.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, let h = Int(pieces[0]), let m = Int(pieces[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    public static func minutesToTime(_ minutes: Int) -> String {
        let clamped = min(max(minutes, 0), 23 * 60 + 59)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// Minutes-since-midnight to axis label (no clamp — 1440 is "24:00").
    public static func minutesToLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// start + laborHours, rounded UP to the next 15-minute boundary, clamped
    /// to 23:59 — the schedule has no multi-day window.
    public static func addLaborToStart(_ start: String, laborHours: Double) -> String? {
        guard let base = toMinutes(start) else { return nil }
        let raw = Double(base) + laborHours * 60
        return minutesToTime(Int(ceil(raw / 15.0)) * 15)
    }

    /// Picker-open default when Start is empty: 08:00 for any non-today date,
    /// otherwise the next half-hour boundary from `now`, clamped to 23:30.
    public static func defaultStartTime(scheduledDate: String, now: (date: String, minutes: Int)) -> String {
        if !scheduledDate.isEmpty && scheduledDate != now.date { return "08:00" }
        let next = Int(ceil(Double(now.minutes) / 30.0)) * 30
        return minutesToTime(min(next, 23 * 60 + 30))
    }

    /// Picker-open default when End is empty but Start is set.
    public static func defaultEndTime(start: String, laborHours: Double) -> String? {
        addLaborToStart(start, laborHours: laborHours > 0 ? laborHours : 1)
    }

    /// 2 → "2h", 2.5 → "2h 30m", 0.25 → "15m" (schedule hint row).
    public static func formatLaborHint(_ laborHours: Double) -> String {
        let totalMinutes = Int((laborHours * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    // MARK: - Job windows, conflicts, gaps

    /// [startMinutes, endMinutes); a missing end blocks max(labor, 1h),
    /// capped at midnight. Single home for the block-size rule.
    public static func blockWindow(start: String, end: String?, laborHours: Double) -> (Int, Int)? {
        guard let s = toMinutes(start) else { return nil }
        if let end, !end.isEmpty {
            guard let e = toMinutes(end) else { return nil }
            return (s, e)
        }
        return (s, min(Int(Double(s) + max(laborHours, 1) * 60), 24 * 60))
    }

    public struct ConflictQuery {
        public var excludeJobId: String?
        public var date: String
        public var start: String
        public var end: String?
        public var laborHours: Double
        /// Required gap between appointments. Pads the CANDIDATE window
        /// symmetrically: a gap smaller than the buffer conflicts, a gap
        /// exactly equal to it is legal (strict-touch preserved).
        public var bufferMinutes: Int

        public init(excludeJobId: String? = nil, date: String, start: String, end: String? = nil, laborHours: Double, bufferMinutes: Int = 0) {
            self.excludeJobId = excludeJobId
            self.date = date
            self.start = start
            self.end = end
            self.laborHours = laborHours
            self.bufferMinutes = bufferMinutes
        }
    }

    /// Other jobs whose window overlaps the candidate window on the same date.
    /// Strict overlap — merely touching windows do not conflict.
    /// Warning-only by design: callers must never block saving on this.
    public static func findScheduleConflicts<Job: ScheduleJobLike>(jobs: [Job], query: ConflictQuery) -> [Job] {
        guard !query.date.isEmpty, !query.start.isEmpty,
              let (rawStart, rawEnd) = blockWindow(start: query.start, end: query.end, laborHours: query.laborHours) else { return [] }
        let qStart = max(0, rawStart - query.bufferMinutes)
        let qEnd = min(24 * 60, rawEnd + query.bufferMinutes)
        return jobs.filter { job in
            if let exclude = query.excludeJobId, job.scheduleJobId == exclude { return false }
            if job.scheduledDate != query.date { return false }
            guard let jobStart = job.scheduledStartTime, !jobStart.isEmpty else { return false }
            if terminalStatuses.contains(job.status) { return false }
            guard let (s, e) = blockWindow(start: jobStart, end: job.scheduledEndTime, laborHours: job.scheduleLaborHours) else { return false }
            return qStart < e && s < qEnd
        }
    }

    public struct FreeGap: Equatable {
        public var start: String
        public var minutes: Int
    }

    /// Largest free gap inside [dayStart, dayEnd) on `date`. Advisory only:
    /// no buffer/blackout/workday filtering, nil on empty days, earlier equal
    /// gap wins. Label it a gap suggestion, never a guaranteed reservable slot.
    public static func largestFreeGap<Job: ScheduleJobLike>(jobs: [Job], date: String, dayStart: String = "08:00", dayEnd: String = "17:00") -> FreeGap? {
        guard let startMin = toMinutes(dayStart), let endMin = toMinutes(dayEnd) else { return nil }
        let dayJobs = jobs.filter {
            $0.scheduledDate == date && ($0.scheduledStartTime?.isEmpty == false) && !terminalStatuses.contains($0.status)
        }
        if dayJobs.isEmpty { return nil }
        var busy: [(Int, Int)] = []
        for job in dayJobs {
            guard let jobStart = job.scheduledStartTime,
                  let (s, e) = blockWindow(start: jobStart, end: job.scheduledEndTime, laborHours: job.scheduleLaborHours) else { continue }
            let clipped = (max(s, startMin), min(e, endMin))
            if clipped.0 < clipped.1 { busy.append(clipped) }
        }
        busy.sort { $0.0 < $1.0 }
        var merged: [(Int, Int)] = []
        for window in busy {
            if let last = merged.last, window.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, window.1)
            } else {
                merged.append(window)
            }
        }
        var best: FreeGap?
        var cursor = startMin
        for window in merged {
            if window.0 - cursor > (best?.minutes ?? 0) {
                best = FreeGap(start: minutesToTime(cursor), minutes: window.0 - cursor)
            }
            cursor = max(cursor, window.1)
        }
        if endMin - cursor > (best?.minutes ?? 0) {
            best = FreeGap(start: minutesToTime(cursor), minutes: endMin - cursor)
        }
        return best
    }

    // MARK: - Owner-naive date arithmetic (DST-immune integer math)

    /// UTC-epoch day index from components (Howard Hinnant days_from_civil).
    /// Pure integer math — no Date construction, immune to DST-length days.
    public static func epochDays(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public static func epochDays(_ date: String) -> Int? {
        guard let (y, m, d) = parseDateComponents(date) else { return nil }
        return epochDays(year: y, month: m, day: d)
    }

    public static func civilFromEpochDays(_ z: Int) -> (year: Int, month: Int, day: Int) {
        let zz = z + 719468
        let era = (zz >= 0 ? zz : zz - 146096) / 146097
        let doe = zz - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        y += (m <= 2 ? 1 : 0)
        return (y, m, d)
    }

    public static func shiftNaiveDate(_ date: String, days: Int) -> String? {
        guard let base = epochDays(date) else { return nil }
        let (y, m, d) = civilFromEpochDays(base + days)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// ISO weekday 1-7 (Mon=1); nil for malformed dates.
    public static func isoWeekday(_ date: String) -> Int? {
        guard let epoch = epochDays(date) else { return nil }
        return ((epoch + 3) % 7 + 7) % 7 + 1
    }

    /// The 7 Mon-Sun local date strings for the week containing `anchor`.
    public static func weekDates(anchor: String) -> [String]? {
        guard let weekday = isoWeekday(anchor) else { return nil }
        var out: [String] = []
        for offset in (1 - weekday)...(7 - weekday) {
            guard let shifted = shiftNaiveDate(anchor, days: offset) else { return nil }
            out.append(shifted)
        }
        return out
    }

    /// Shift a YYYY-MM-DD string by ±days.
    public static func shiftDate(_ date: String, days: Int) -> String? {
        shiftNaiveDate(date, days: days)
    }

    public static func parseDateComponents(_ date: String) -> (year: Int, month: Int, day: Int)? {
        let pieces = date.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, let y = Int(pieces[0]), let m = Int(pieces[1]), let d = Int(pieces[2]),
              (1...12).contains(m), (1...31).contains(d), y >= 0 else { return nil }
        // Round-trip through epoch math to reject impossible days (Feb 30…).
        let epoch = epochDays(year: y, month: m, day: d)
        let round = civilFromEpochDays(epoch)
        guard round.year == y && round.month == m && round.day == d else { return nil }
        return (y, m, d)
    }

    // MARK: - Private resolution helpers

    private static func resolveNumber(_ raw: Int?, fallback: Int, min: Int, allowMin: Bool) -> Int {
        guard let raw else { return fallback }
        if allowMin ? raw < min : raw <= min { return fallback }
        return raw
    }

    private static func resolveWorkDays(_ raw: [Int]?) -> [Int] {
        guard let raw else { return defaultWorkDays }
        let days = Array(Set(raw.filter { (1...7).contains($0) })).sorted()
        return days.isEmpty ? defaultWorkDays : days
    }

    private static func resolveBlackouts(_ raw: [Canonical.ScheduleBlackout]?) -> [ScheduleBlackout] {
        guard let raw else { return [] }
        var out: [ScheduleBlackout] = []
        for entry in raw {
            if entry.id.isEmpty { continue }
            guard isValidDate(entry.start), isValidDate(entry.end) else { continue }
            if entry.end < entry.start { continue }
            out.append(ScheduleBlackout(id: entry.id, start: entry.start, end: entry.end, reason: entry.reason))
        }
        return out
    }
}

/// Job statuses whose schedules are history — never flagged as conflicts. A
/// job declined via the estimate-approval loop keeps its schedule fields, but
/// its slot is dead — warning against it would mislead.
public let terminalScheduleStatuses: Set<String> = ["complete", "invoiced", "paid", "declined"]

extension NativeSchedule {
    static var terminalStatuses: Set<String> { terminalScheduleStatuses }
}

/// Minimal schedule surface shared by the pure planners. `Canonical.Job`
/// conforms below so planning always reads canonical data; tests use a
/// lightweight stub. Unknown/concurrent server fields on the canonical record
/// are never touched by these read-only projections.
public protocol ScheduleJobLike {
    var scheduleJobId: String { get }
    var scheduledDate: String? { get }
    var scheduledStartTime: String? { get }
    var scheduledEndTime: String? { get }
    var scheduleLaborHours: Double { get }
    var status: String { get }
    var createdAt: String { get }
    var archivedAt: String? { get }
}

extension Canonical.Job: ScheduleJobLike {
    public var scheduleJobId: String { id }
    public var scheduleLaborHours: Double { (laborHours as NSDecimalNumber).doubleValue }
}
