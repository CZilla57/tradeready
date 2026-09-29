import Foundation

/// Deterministic candidate-slot engine (Phase 8 task 8.01, requirement S1).
///
/// Swift port of `utils/availability.ts` (offer computation) plus the
/// naive→UTC boundary in `backend-workers/lib/booking/availability.js`
/// (`zonedTimeToUtc`, `resolveSlotsUtc`, `nowInZone`). Any behavior change
/// here MUST land in both twins — `__tests__/availabilityParity.test.ts`
/// pins them together; add the matching Swift vector in
/// `native/AvailabilityTests`.
///
/// Discipline: pure, injected clock, owner-naive frame throughout (UTC does
/// not exist inside slot computation — the public boundary resolves offered
/// slots to instants with the owner's IANA zone). Slot starts snap to a
/// fixed 30-minute grid and the entire duration must fit. Consecutive grid
/// starts deliberately produce OVERLAPPING candidates — safe because
/// reservation is server-authoritative.
public enum NativeAvailability {

    /// Slot starts snap to this grid (fixed for v1 — owner decision D8).
    public static let slotGridMinutes = 30
    public static let dayMinutes = 24 * 60

    /** A reserved/held window the engine must treat as busy (the server
     *  passes active reservations here; the client normally omits it). */
    public struct BusyWindow: Equatable {
        public var date: String
        public var start: String
        public var end: String
        public init(date: String, start: String, end: String) {
            self.date = date
            self.start = start
            self.end = end
        }
    }

    public struct CandidateSlot: Equatable {
        public var date: String
        public var start: String
        public var end: String
        public init(date: String, start: String, end: String) {
            self.date = date
            self.start = start
            self.end = end
        }
    }

    public struct PublicSlot: Equatable {
        public var date: String
        public var start: String
        public var end: String
        public var startUtc: String
        public var endUtc: String
    }

    public struct AvailabilityInput<Job: ScheduleJobLike> {
        public var schedule: NativeSchedule.ResolvedSchedule
        public var jobs: [Job]
        public var extraBusy: [BusyWindow]
        /// First day considered (inclusive).
        public var fromDate: String
        /// Horizon length in days (schedule.slotWindowDays at call sites).
        public var days: Int
        /// Injected clock, owner-naive: local date + minutes since midnight.
        public var now: (date: String, minutes: Int)

        public init(schedule: NativeSchedule.ResolvedSchedule, jobs: [Job], extraBusy: [BusyWindow] = [],
                    fromDate: String, days: Int, now: (date: String, minutes: Int)) {
            self.schedule = schedule
            self.jobs = jobs
            self.extraBusy = extraBusy
            self.fromDate = fromDate
            self.days = days
            self.now = now
        }
    }

    // MARK: - Candidate computation (zone-free, owner-naive)

    /// Busy [start, end) windows for one day: live jobs + extra windows,
    /// each padded by the buffer, merged into disjoint sorted intervals.
    public static func busyWindowsFor<Job: ScheduleJobLike>(
        date: String,
        jobs: [Job],
        extraBusy: [BusyWindow],
        bufferMinutes: Int
    ) -> [(Int, Int)] {
        var raw: [(Int, Int)] = []
        for job in jobs {
            if job.scheduledDate != date { continue }
            guard let jobStart = job.scheduledStartTime, !jobStart.isEmpty else { continue }
            if terminalScheduleStatuses.contains(job.status) { continue }
            guard let window = NativeSchedule.blockWindow(start: jobStart, end: job.scheduledEndTime, laborHours: job.scheduleLaborHours) else { continue }
            raw.append(window)
        }
        for window in extraBusy {
            if window.date != date { continue }
            guard let s = NativeSchedule.toMinutes(window.start), let e = NativeSchedule.toMinutes(window.end) else { continue }
            raw.append((s, e))
        }
        let padded = raw.compactMap { (s, e) -> (Int, Int)? in
            let window = (max(0, s - bufferMinutes), min(dayMinutes, e + bufferMinutes))
            return window.0 < window.1 ? window : nil
        }.sorted { $0.0 < $1.0 }
        var merged: [(Int, Int)] = []
        for window in padded {
            if let last = merged.last, window.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, window.1)
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    public static func computeCandidateSlots<Job: ScheduleJobLike>(input: AvailabilityInput<Job>) -> [CandidateSlot] {
        let schedule = input.schedule
        let duration = schedule.defaultDurationMinutes
        guard let workStart = NativeSchedule.toMinutes(schedule.workDayStart),
              let workEnd = NativeSchedule.toMinutes(schedule.workDayEnd),
              let nowEpoch = NativeSchedule.epochDays(input.now.date) else { return [] }
        let earliestAbs = nowEpoch * dayMinutes + input.now.minutes + schedule.slotLeadHours * 60

        var out: [CandidateSlot] = []
        for i in 0..<input.days {
            guard let date = NativeSchedule.shiftNaiveDate(input.fromDate, days: i) else { continue }
            if !NativeSchedule.isWorkDay(schedule, date: date) { continue }
            if NativeSchedule.isBlackoutDate(schedule, date: date) { continue }
            guard let dayEpoch = NativeSchedule.epochDays(date) else { continue }
            let dayAbs = dayEpoch * dayMinutes
            let busy = busyWindowsFor(date: date, jobs: input.jobs, extraBusy: input.extraBusy, bufferMinutes: schedule.bufferMinutes)

            // Free gaps clipped to the work window.
            var gaps: [(Int, Int)] = []
            var cursor = workStart
            for window in busy {
                if window.0 > cursor { gaps.append((cursor, min(window.0, workEnd))) }
                cursor = max(cursor, window.1)
                if cursor >= workEnd { break }
            }
            if cursor < workEnd { gaps.append((cursor, workEnd)) }

            for gap in gaps {
                var start = Int(ceil(Double(gap.0) / Double(slotGridMinutes))) * slotGridMinutes
                while start + duration <= gap.1 {
                    if dayAbs + start >= earliestAbs {
                        out.append(CandidateSlot(
                            date: date,
                            start: NativeSchedule.minutesToTime(start),
                            end: NativeSchedule.minutesToTime(start + duration)
                        ))
                    }
                    start += slotGridMinutes
                }
            }
        }
        // Construction order is already (date asc, start asc).
        return out
    }

    // MARK: - Slot configuration gate (S1)

    public enum SlotConfigurationError: Equatable {
        /// Slots are enabled but no usable IANA zone is configured. Surface a
        /// configuration error — never fabricate offers.
        case invalidTimeZone
    }

    /// New zone edits must validate as IANA zones before enabling slots;
    /// an existing invalid zone stays recoverable and surfaces
    /// `.invalidTimeZone` instead of offers.
    public static func validateSlotConfiguration(_ schedule: NativeSchedule.ResolvedSchedule) -> SlotConfigurationError? {
        guard schedule.bookableSlotsEnabled else { return nil }
        guard let zone = schedule.timeZone, isValidIANAZone(zone) else { return .invalidTimeZone }
        return nil
    }

    public static func isValidIANAZone(_ identifier: String) -> Bool {
        TimeZone(identifier: identifier) != nil
    }

    // MARK: - Naive → UTC boundary (owner IANA zone)

    static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func isoString(millis: Int64) -> String {
        utcFormatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000.0))
    }

    /**
     * Resolve an owner-naive date+time to a UTC instant in `timeZoneID`.
     * Returns nil when the local time does not exist (spring-forward gap).
     * An ambiguous fall-back time resolves to the FIRST occurrence (the
     * earlier UTC instant — mirrors the JS Intl offset-probe exactly).
     */
    public static func zonedTimeToUtc(date: String, time: String, timeZoneID: String) -> String? {
        guard let zone = TimeZone(identifier: timeZoneID),
              let (y, mo, d) = NativeSchedule.parseDateComponents(date),
              let hm = NativeSchedule.toMinutes(time) else { return nil }
        let naiveMs = Int64(NativeSchedule.epochDays(year: y, month: mo, day: d)) * 86_400_000
            + Int64(hm) * 60_000
        var offsets = Set<Int>()
        for probe in [naiveMs - 86_400_000, naiveMs, naiveMs + 86_400_000] {
            offsets.insert(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(probe) / 1000.0)))
        }
        var matches: [Int64] = []
        for offset in offsets {
            let utcMs = naiveMs - Int64(offset) * 1000
            if zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(utcMs) / 1000.0)) == offset {
                matches.append(utcMs)
            }
        }
        guard let best = matches.min() else { return nil }
        return isoString(millis: best)
    }

    /**
     * Map candidate slots to public offers carrying UTC instants. A slot
     * whose START does not exist locally is dropped; an end inside a
     * spring-forward gap falls back to the start instant plus the naive
     * duration so the offer still carries a usable window.
     */
    public static func resolveSlotsUtc(slots: [CandidateSlot], timeZoneID: String) -> [PublicSlot] {
        var out: [PublicSlot] = []
        for slot in slots {
            guard let startUtc = zonedTimeToUtc(date: slot.date, time: slot.start, timeZoneID: timeZoneID) else { continue }
            let endUtc: String
            if let resolved = zonedTimeToUtc(date: slot.date, time: slot.end, timeZoneID: timeZoneID) {
                endUtc = resolved
            } else {
                guard let s = NativeSchedule.toMinutes(slot.start), let e = NativeSchedule.toMinutes(slot.end) else { continue }
                let durationMs = Int64(e - s) * 60_000
                let startMs = Int64((iso8601ToMillis(startUtc) ?? 0))
                endUtc = isoString(millis: startMs + durationMs)
            }
            out.append(PublicSlot(date: slot.date, start: slot.start, end: slot.end, startUtc: startUtc, endUtc: endUtc))
        }
        return out
    }

    /// The owner-naive clock ({date, minutes}) for a UTC instant in
    /// `timeZoneID` — what the engine's injected `now` expects at the public
    /// boundary. Nil for unknown zones.
    public static func nowInZone(timeZoneID: String, utcMillis: Int64) -> (date: String, minutes: Int)? {
        guard let zone = TimeZone(identifier: timeZoneID) else { return nil }
        let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(utcMillis) / 1000.0))
        let localMs = utcMillis + Int64(offset) * 1000
        let days = localMs >= 0 ? localMs / 86_400_000 : (localMs - 86_400_000 + 1) / 86_400_000
        let (y, mo, d) = NativeSchedule.civilFromEpochDays(Int(days))
        let minutes = Int((localMs - days * 86_400_000) / 60_000)
        return (String(format: "%04d-%02d-%02d", y, mo, d), minutes)
    }

    static func iso8601ToMillis(_ iso: String) -> Int64? {
        guard let date = utcFormatter.date(from: iso) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }
}
