import SwiftUI

/// Phase 8 task 8.09 calendar UI (requirements S2, S3).
///
/// Thin view over the 8.01 pure planners (`NativeSchedule`,
/// `NativeCalendar`) and the 8.08 schedule-only commit
/// (`commitScheduleOnly`). No business policy lives here: day/week
/// navigation is owner-naive string arithmetic, every projection delegates
/// to the pure domain, and every write goes through the typed store entry
/// point. Cached canonical rows stay on screen through refresh errors; a
/// diagnostic banner explains the stale state instead of clearing data.
struct NativeCalendarView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case day, week
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @State private var mode: Mode = .day
    @State private var selectedDate: String = Self.todayString()
    @State private var anchorDate: String = Self.todayString()
    @State private var isRefreshing = false
    @State private var editorJobID: String?
    @State private var navigatedJobID: String?

    private var rows: [Canonical.Job] {
        // Touch the published projection so the view invalidates on every
        // store publish, then render the canonical rows the UI projection
        // cannot represent (untimed dates, minute-precise times).
        _ = store.jobs
        _ = store.syncStatus
        return store.calendarScheduleJobs()
    }

    private var schedule: NativeSchedule.ResolvedSchedule {
        store.calendarResolvedSchedule()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
                .nativeContentColumnFrame()

                navigationBar

                if mode == .day {
                    dayView
                } else {
                    weekView
                }
            }
            .navigationTitle("Calendar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .refreshable { await refresh() }
            .sheet(item: editorBinding) { job in
                NativeScheduleEditorView(jobID: job.id) {}
            }
        }
        .nativeAnalyticsScreen(.calendar)
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack {
            Button { shift(by: mode == .day ? -1 : -7) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel(mode == .day ? "Previous day" : "Previous week")
            Spacer()
            Button("Today") { resetToToday() }
                .accessibilityLabel("Go to today")
                .accessibilityHint("Resets the calendar to the current day")
            Spacer()
            Button { shift(by: mode == .day ? 1 : 7) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel(mode == .day ? "Next day" : "Next week")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .nativeContentColumnFrame()
    }

    private func shift(by days: Int) {
        if mode == .day {
            selectedDate = NativeSchedule.shiftNaiveDate(selectedDate, days: days) ?? selectedDate
            anchorDate = selectedDate
        } else {
            anchorDate = NativeSchedule.shiftNaiveDate(anchorDate, days: days) ?? anchorDate
        }
    }

    private func resetToToday() {
        selectedDate = Self.todayString()
        anchorDate = selectedDate
    }

    // MARK: - Refresh (cache stays usable through errors)

    private var syncBanner: some View {
        Group {
            if isRefreshing {
                Label("Refreshing…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityLabel("Refreshing schedule")
            } else if let code = store.syncStatus.diagnosticCode {
                Label("Could not refresh — showing your saved schedule (\(code)).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                    .accessibilityLabel("Refresh failed. Showing your saved schedule.")
                    .accessibilityHint("Diagnostic code \(code). Your saved schedule is unchanged.")
            } else if store.syncStatus.pendingCount > 0 {
                Label("\(store.syncStatus.pendingCount) change(s) waiting to sync.",
                      systemImage: "icloud.and.arrow.up.fill")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityLabel("\(store.syncStatus.pendingCount) changes waiting to sync")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await store.syncNowAndWait(trigger: .manual)
    }

    // MARK: - Day view

    private var dayView: some View {
        let day: NativeCalendar.CalendarDay<Canonical.Job> = NativeCalendar.buildCalendarDay(
            jobs: rows, date: selectedDate, schedule: schedule)
        return List {
            syncBanner
                .listRowSeparator(.hidden)

            Section(header: Text(Self.dayTitle(selectedDate))) {
                dayStatusRows(date: selectedDate)
                gapSuggestionRow(date: selectedDate)
            }

            if !day.timed.isEmpty {
                Section(header: Text("Schedule")) {
                    NativeCalendarTimeline(day: day, schedule: schedule)
                        .listRowInsets(EdgeInsets())
                        .accessibilityHidden(true)
                    ForEach(day.timed, id: \.job.id) { block in
                        blockRow(block, date: selectedDate)
                    }
                }
            } else {
                Section(header: Text("Schedule")) {
                    Text("Nothing scheduled this day.")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Nothing scheduled on \(Self.dayTitle(selectedDate))")
                }
            }

            if !day.untimed.isEmpty {
                Section(header: Text("Untimed")) {
                    ForEach(day.untimed, id: \.id) { job in
                        untimedRow(job)
                    }
                }
            }

            queueSection
        }
        .nativeContentColumn(.list)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    /// Working-day, blackout and nonworking-day labels for one date.
    private func dayStatusRows(date: String) -> some View {
        Group {
            if !NativeSchedule.isWorkDay(schedule, date: date) {
                Label("Non-working day", systemImage: "moon.fill")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityLabel("\(Self.dayTitle(date)) is a non-working day")
            }
            ForEach(schedule.blackouts.filter { $0.start <= date && date <= $0.end }, id: \.id) { blackout in
                Label(blackout.reason?.isEmpty == false ? "Time off: \(blackout.reason!)" : "Time off",
                      systemImage: "palmtree.fill")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityLabel("Time off on \(Self.dayTitle(date))\(blackout.reason.map { ": \($0)" } ?? "")")
            }
        }
    }

    /// RN advisory helper, explicitly labeled a suggestion — never a
    /// guaranteed reservable or fitting appointment.
    private func gapSuggestionRow(date: String) -> some View {
        Group {
            if let gap = NativeSchedule.largestFreeGap(jobs: rows, date: date),
               gap.minutes >= 30 {
                Label("Gap suggestion: \(gap.start) (\(gap.minutes) min) — advisory, not a guaranteed slot.",
                      systemImage: "lightbulb")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityLabel("Gap suggestion at \(gap.start), \(gap.minutes) minutes. Advisory only.")
            }
        }
    }

    private func blockRow(_ block: NativeCalendar.CalendarBlock<Canonical.Job>, date: String) -> some View {
        let job = block.job
        let time = "\(Self.minutesLabel(block.startMinutes))–\(Self.minutesLabel(block.endMinutes))"
        return Button { navigateToJob(job.id) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).fontWeight(.semibold)
                    Text("\(time) · \(job.customerName)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if block.laneCount > 1 {
                        Text("Overlaps \(block.laneCount - 1) other(s) — lane \(block.lane + 1) of \(block.laneCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if block.isTerminal {
                        Text(Self.terminalLabel(job.status))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if block.inConflict {
                        conflictLabel(for: job, date: date)
                    }
                }
                Spacer()
                Button { editorJobID = job.id } label: {
                    Image(systemName: "clock.arrow.2.circlepath")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reschedule \(job.title)")
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.blockAccessibilityLabel(block))
        .accessibilityHint("Opens the job. Use Reschedule to change its time.")
    }

    private func untimedRow(_ job: Canonical.Job) -> some View {
        Button { navigateToJob(job.id) } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(job.title).fontWeight(.semibold)
                    Text(job.customerName).font(.subheadline).foregroundStyle(.secondary)
                    if terminalScheduleStatuses.contains(job.status) {
                        Text(Self.terminalLabel(job.status)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { editorJobID = job.id } label: {
                    Image(systemName: "clock.arrow.2.circlepath")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Schedule a time for \(job.title)")
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Untimed: \(job.title) for \(job.customerName)")
        .accessibilityHint("Opens the job")
    }

    private func conflictLabel(for job: Canonical.Job, date: String) -> some View {
        let hits = NativeSchedule.findScheduleConflicts(
            jobs: rows,
            query: NativeSchedule.ConflictQuery(
                excludeJobId: job.id, date: date,
                start: job.scheduledStartTime ?? "", end: job.scheduledEndTime,
                laborHours: (job.laborHours as NSDecimalNumber).doubleValue,
                bufferMinutes: schedule.bufferMinutes))
        return Label("Overlaps \(hits.map(\.title).joined(separator: ", "))",
                     systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .accessibilityLabel("Schedule conflict with \(hits.map(\.title).joined(separator: ", "))")
    }

    // MARK: - Week view

    private var weekView: some View {
        let days: [NativeCalendar.CalendarDay<Canonical.Job>] =
            NativeCalendar.buildCalendarWeek(jobs: rows, anchorDate: anchorDate, schedule: schedule) ?? []
        return List {
            syncBanner
                .listRowSeparator(.hidden)

            Section(header: Text("Week of \(Self.dayTitle(days.first?.date ?? anchorDate))")) {
                ForEach(days, id: \.date) { day in
                    let conflicts = day.timed.filter(\.inConflict).count
                    Button {
                        selectedDate = day.date
                        anchorDate = day.date
                        mode = .day
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(Self.dayTitle(day.date)).fontWeight(.semibold)
                                Text(weekDaySummary(day))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if !NativeSchedule.isWorkDay(schedule, date: day.date) {
                                    Text("Non-working day").font(.caption).foregroundStyle(.secondary)
                                }
                                if conflicts > 0 {
                                    Label("\(conflicts) conflict(s)", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Self.dayTitle(day.date)): \(weekDaySummary(day))\(conflicts > 0 ? ", \(conflicts) conflicts" : "")")
                    .accessibilityHint("Shows the day schedule")
                }
            }

            queueSection
        }
        .nativeContentColumn(.list)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func weekDaySummary(_ day: NativeCalendar.CalendarDay<Canonical.Job>) -> String {
        var parts: [String] = []
        if !day.timed.isEmpty { parts.append("\(day.timed.count) timed") }
        if !day.untimed.isEmpty { parts.append("\(day.untimed.count) untimed") }
        return parts.isEmpty ? "Nothing scheduled" : parts.joined(separator: " · ")
    }

    // MARK: - Unscheduled queue

    private var queueSection: some View {
        let queue = NativeCalendar.selectUnscheduledApproved(jobs: rows)
        return Group {
            if !queue.isEmpty {
                Section(header: Text("Needs scheduling")) {
                    ForEach(queue, id: \.id) { job in
                        Button { editorJobID = job.id } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(job.title).fontWeight(.semibold)
                                    Text(job.customerName).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Schedule").font(.subheadline.weight(.semibold))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Needs scheduling: \(job.title) for \(job.customerName)")
                        .accessibilityHint("Opens the schedule editor")
                    }
                }
            }
        }
    }

    // MARK: - Exact-job navigation

    private func navigateToJob(_ id: String) {
        // Exact-ID routing onto the existing Jobs destination; the detail
        // shows its own recoverable state if the record was just deleted.
        store.selectedTab = .jobs
        store.deepLinkedJobID = id
        navigatedJobID = id
        dismiss()
    }

    private var editorBinding: Binding<NativeCalendarEditorJob?> {
        Binding(
            get: { editorJobID.map(NativeCalendarEditorJob.init(id:)) },
            set: { editorJobID = $0?.id }
        )
    }

    // MARK: - Formatting

    static func todayString(calendar: Calendar = .current, now: Date = .now) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func dayTitle(_ date: String) -> String {
        guard let (y, m, d) = NativeSchedule.parseDateComponents(date) else { return date }
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        guard let day = Calendar.current.date(from: components) else { return date }
        let formatter = DateFormatter()
        formatter.dateFormat = "E, MMM d"
        return formatter.string(from: day)
    }

    static func minutesLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func terminalLabel(_ status: String) -> String {
        switch status {
        case "complete": "Completed"
        case "invoiced": "Invoiced"
        case "paid": "Paid"
        case "declined": "Declined"
        default: status
        }
    }

    static func blockAccessibilityLabel(_ block: NativeCalendar.CalendarBlock<Canonical.Job>) -> String {
        var label = "\(minutesLabel(block.startMinutes)) to \(minutesLabel(block.endMinutes)), \(block.job.title) for \(block.job.customerName)"
        if block.isTerminal { label += ", \(terminalLabel(block.job.status))" }
        if block.inConflict { label += ", has a schedule conflict" }
        if block.laneCount > 1 { label += ", lane \(block.lane + 1) of \(block.laneCount)" }
        return label
    }
}

private struct NativeCalendarEditorJob: Identifiable {
    var id: String
}

/// Visual day grid: working-hour axis plus positioned overlap lanes.
/// The accessible list of the same blocks follows directly below; this grid
/// is hidden from assistive technology to avoid double announcement.
private struct NativeCalendarTimeline<Job: ScheduleJobLike>: View {
    var day: NativeCalendar.CalendarDay<Job>
    var schedule: NativeSchedule.ResolvedSchedule

    private let pointsPerHour: CGFloat = 44

    var body: some View {
        if let axis = NativeCalendar.dayAxis(day: day, schedule: schedule) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(hourMarks(axis: axis), id: \.self) { minutes in
                        HStack(spacing: 6) {
                            Text(NativeCalendarView.minutesLabel(minutes))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
                        }
                        .offset(y: yOffset(for: minutes, axis: axis))
                    }
                    ForEach(day.timed, id: \.job.scheduleJobId) { block in
                        timelineBlock(block, width: width, axis: axis)
                    }
                }
            }
            .frame(height: CGFloat(axis.1 - axis.0) / 60 * pointsPerHour + 16)
            .padding(.vertical, 8)
        }
    }

    private func timelineBlock(_ block: NativeCalendar.CalendarBlock<Job>, width: CGFloat, axis: (startMinutes: Int, endMinutes: Int)) -> some View {
        let laneWidth: CGFloat = (width - 52) / CGFloat(max(block.laneCount, 1))
        let height: CGFloat = max(CGFloat(block.endMinutes - block.startMinutes) / 60 * pointsPerHour - 2, 14)
        let fill: Color = block.inConflict ? Color.orange.opacity(0.35) : Color.accentColor.opacity(0.25)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fill)
            .frame(width: laneWidth - 4, height: height)
            .offset(x: 52 + CGFloat(block.lane) * laneWidth,
                    y: yOffset(for: block.startMinutes, axis: axis))
    }

    private func yOffset(for minutes: Int, axis: (startMinutes: Int, endMinutes: Int)) -> CGFloat {
        CGFloat(minutes - axis.startMinutes) / 60 * pointsPerHour
    }

    private func hourMarks(axis: (startMinutes: Int, endMinutes: Int)) -> [Int] {
        stride(from: (axis.startMinutes / 60) * 60, through: axis.endMinutes, by: 60).map { $0 }
    }
}
