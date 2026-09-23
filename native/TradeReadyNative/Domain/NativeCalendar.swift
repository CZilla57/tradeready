import Foundation

/// Pure calendar/planning projections (Phase 8 task 8.01, requirement S2).
///
/// Swift port of `utils/calendar.ts` (day/week selectors, overlap lanes,
/// axis, unscheduled queue). Dependency-free: read-only projections over
/// `ScheduleJobLike` inputs (canonical jobs in production, stubs in tests).
/// No archive blanket filter — per-selector behavior matches RN: the queue
/// excludes archived, the day view renders terminal history.
public enum NativeCalendar {

    public struct CalendarBlock<Job: ScheduleJobLike> {
        public var job: Job
        public var startMinutes: Int
        public var endMinutes: Int
        /// Column within the overlap cluster (0-based)…
        public var lane: Int
        /// …out of this many side-by-side columns. 1 = full width.
        public var laneCount: Int
        /// Terminal-status jobs render (history matters) but never conflict.
        public var isTerminal: Bool
        /// Live-vs-live overlap, buffer-aware (AddJobScreen semantics).
        public var inConflict: Bool
    }

    public struct CalendarDay<Job: ScheduleJobLike> {
        public var date: String
        /// Blocks sorted by start, lane-assigned for side-by-side rendering.
        public var timed: [CalendarBlock<Job>]
        /// Jobs scheduled for the date with no start time (nil or "").
        public var untimed: [Job]
    }

    /// Greedy interval lane assignment; laneCount is per overlap cluster.
    /// Touching endpoints share a lane (strict overlap only clusters).
    public static func assignLanes(blocks: [(startMinutes: Int, endMinutes: Int)]) -> [(lane: Int, laneCount: Int)] {
        var out = blocks.map { _ in (lane: 0, laneCount: 1) }
        var laneEnds: [Int] = []
        var clusterStart = 0
        var clusterMaxEnd = -1

        func closeCluster(_ endIndex: Int, out: inout [(lane: Int, laneCount: Int)], laneEnds: [Int], clusterStart: Int) {
            for i in clusterStart..<endIndex { out[i].laneCount = laneEnds.count }
        }

        for (i, block) in blocks.enumerated() {
            if !laneEnds.isEmpty && block.startMinutes >= clusterMaxEnd {
                closeCluster(i, out: &out, laneEnds: laneEnds, clusterStart: clusterStart)
                laneEnds.removeAll()
                clusterStart = i
            }
            if let lane = laneEnds.firstIndex(where: { $0 <= block.startMinutes }) {
                laneEnds[lane] = block.endMinutes
                out[i].lane = lane
            } else {
                out[i].lane = laneEnds.count
                laneEnds.append(block.endMinutes)
            }
            clusterMaxEnd = max(clusterMaxEnd, block.endMinutes)
        }
        closeCluster(blocks.count, out: &out, laneEnds: laneEnds, clusterStart: clusterStart)
        return out
    }

    public static func buildCalendarDay<Job: ScheduleJobLike>(
        jobs: [Job],
        date: String,
        schedule: NativeSchedule.ResolvedSchedule
    ) -> CalendarDay<Job> {
        let dayJobs = jobs.filter { $0.scheduledDate == date }
        let untimed = dayJobs.filter { $0.scheduledStartTime?.isEmpty ?? true }
        let sized = dayJobs.compactMap { job -> (job: Job, startMinutes: Int, endMinutes: Int)? in
            guard let start = job.scheduledStartTime, !start.isEmpty,
                  let (s, e) = NativeSchedule.blockWindow(start: start, end: job.scheduledEndTime, laborHours: job.scheduleLaborHours) else { return nil }
            return (job, s, e)
        }.sorted { $0.startMinutes != $1.startMinutes ? $0.startMinutes < $1.startMinutes : $0.endMinutes < $1.endMinutes }

        let lanes = assignLanes(blocks: sized.map { ($0.startMinutes, $0.endMinutes) })
        let timed = sized.enumerated().map { i, block -> CalendarBlock<Job> in
            let isTerminal = terminalScheduleStatuses.contains(block.job.status)
            let inConflict: Bool = {
                if isTerminal { return false }
                let hits = NativeSchedule.findScheduleConflicts(jobs: dayJobs, query: NativeSchedule.ConflictQuery(
                    excludeJobId: block.job.scheduleJobId,
                    date: date,
                    start: block.job.scheduledStartTime ?? "",
                    end: block.job.scheduledEndTime,
                    laborHours: block.job.scheduleLaborHours,
                    bufferMinutes: schedule.bufferMinutes
                ))
                return !hits.isEmpty
            }()
            return CalendarBlock(job: block.job, startMinutes: block.startMinutes, endMinutes: block.endMinutes,
                                 lane: lanes[i].lane, laneCount: lanes[i].laneCount,
                                 isTerminal: isTerminal, inConflict: inConflict)
        }
        return CalendarDay(date: date, timed: timed, untimed: untimed)
    }

    /// Hour-aligned axis range for a day view: the work window, stretched to
    /// cover any out-of-hours block, never past midnight.
    public static func dayAxis<Job: ScheduleJobLike>(
        day: CalendarDay<Job>,
        schedule: NativeSchedule.ResolvedSchedule
    ) -> (startMinutes: Int, endMinutes: Int)? {
        guard let start = NativeSchedule.toMinutes(schedule.workDayStart),
              let end = NativeSchedule.toMinutes(schedule.workDayEnd) else { return nil }
        var axisStart = start
        var axisEnd = end
        for block in day.timed {
            axisStart = min(axisStart, block.startMinutes)
            axisEnd = max(axisEnd, block.endMinutes)
        }
        return ((axisStart / 60) * 60, min(((axisEnd + 59) / 60) * 60, 24 * 60))
    }

    /// The 7 Mon–Sun days containing `anchorDate`.
    public static func buildCalendarWeek<Job: ScheduleJobLike>(
        jobs: [Job],
        anchorDate: String,
        schedule: NativeSchedule.ResolvedSchedule
    ) -> [CalendarDay<Job>]? {
        guard let dates = NativeSchedule.weekDates(anchor: anchorDate) else { return nil }
        return dates.map { buildCalendarDay(jobs: jobs, date: $0, schedule: schedule) }
    }

    /// The unscheduled approved-work queue: approved, no date (nil or ""),
    /// not archived — oldest first so long-waiting work surfaces at the top.
    public static func selectUnscheduledApproved<Job: ScheduleJobLike>(jobs: [Job]) -> [Job] {
        jobs.filter { $0.status == "approved" && ($0.scheduledDate?.isEmpty ?? true) && ($0.archivedAt?.isEmpty ?? true) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Immutable schedule edit draft (S3 input boundary)

    /// Schedule-only draft carried by the calendar editor. A value type:
    /// every edit produces a new draft; nothing here writes to a store.
    /// Commit (latest-ID re-resolution, field-scoped canonical merge) is
    /// owned by the AppStore integration lane (task 8.08), not this module.
    public struct ScheduleEditDraft: Equatable {
        public var jobId: String
        public var baselineDate: String?
        public var baselineStart: String?
        public var baselineEnd: String?
        public var baselineStatus: String
        /// Desired date; nil/"" clears the schedule (unscheduled).
        public var date: String?
        /// Desired start; nil/"" with a date means an untimed job —
        /// explicitly NOT a midnight appointment.
        public var start: String?
        public var end: String?

        public init(jobId: String, baselineDate: String? = nil, baselineStart: String? = nil,
                    baselineEnd: String? = nil, baselineStatus: String = "",
                    date: String? = nil, start: String? = nil, end: String? = nil) {
            self.jobId = jobId
            self.baselineDate = baselineDate
            self.baselineStart = baselineStart
            self.baselineEnd = baselineEnd
            self.baselineStatus = baselineStatus
            self.date = date
            self.start = start
            self.end = end
        }
    }

    public enum ScheduleEditIssue: Equatable {
        case invalidDate(String)
        case invalidTime(String)
        case timeWithoutDate
        case endWithoutStart
        case endNotAfterStart
    }

    /// RN-editor constraints: valid date/time shapes, no time without a
    /// date, no end without a start, end strictly after start. Clearing
    /// date/time and untimed jobs are explicitly valid.
    public static func validateScheduleDraft(_ draft: ScheduleEditDraft) -> [ScheduleEditIssue] {
        var issues: [ScheduleEditIssue] = []
        let date = (draft.date?.isEmpty == false) ? draft.date : nil
        let start = (draft.start?.isEmpty == false) ? draft.start : nil
        let end = (draft.end?.isEmpty == false) ? draft.end : nil
        if let rawDate = draft.date, !rawDate.isEmpty, !NativeSchedule.isValidDate(rawDate) {
            issues.append(.invalidDate(rawDate))
        }
        if let rawStart = draft.start, !rawStart.isEmpty, !NativeSchedule.isValidTime(rawStart) {
            issues.append(.invalidTime(rawStart))
        }
        if let rawEnd = draft.end, !rawEnd.isEmpty, !NativeSchedule.isValidTime(rawEnd) {
            issues.append(.invalidTime(rawEnd))
        }
        if date == nil, start != nil { issues.append(.timeWithoutDate) }
        if start == nil, end != nil { issues.append(.endWithoutStart) }
        if let start, let end,
           let s = NativeSchedule.toMinutes(start), let e = NativeSchedule.toMinutes(end), e <= s {
            issues.append(.endNotAfterStart)
        }
        _ = date
        return issues
    }

    public struct ScheduleFieldChanges: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let date = ScheduleFieldChanges(rawValue: 1 << 0)
        public static let start = ScheduleFieldChanges(rawValue: 1 << 1)
        public static let end = ScheduleFieldChanges(rawValue: 1 << 2)
    }

    /// Which schedule fields differ from the baseline (nil/"" normalized).
    /// Only these fields may be merged by the commit lane.
    public static func changedScheduleFields(_ draft: ScheduleEditDraft) -> ScheduleFieldChanges {
        var out = ScheduleFieldChanges()
        let norm: (String?) -> String? = { ($0?.isEmpty == false) ? $0 : nil }
        if norm(draft.date) != norm(draft.baselineDate) { out.insert(.date) }
        if norm(draft.start) != norm(draft.baselineStart) { out.insert(.start) }
        if norm(draft.end) != norm(draft.baselineEnd) { out.insert(.end) }
        return out
    }
}
