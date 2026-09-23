import SwiftUI

/// Phase 8 task 8.09 schedule editor (requirement S3).
///
/// Thin view over the 8.01 draft boundary (`validateScheduleDraft`) and the
/// 8.08 schedule-only commit (`commitScheduleOnly`). The draft is a value
/// held in view state: Cancel never writes, a failed save keeps the draft
/// open, a concurrent schedule/lifecycle change surfaces stale-state
/// recovery (current values + explicit reload, never silent replacement),
/// and a deleted record shows its missing state. Conflicts warn and never
/// prevent saving.
struct NativeScheduleEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var jobID: String
    var onSaved: () -> Void = {}

    @State private var dateText = ""
    @State private var startText = ""
    @State private var endText = ""
    @State private var baselineDate: String?
    @State private var baselineStart: String?
    @State private var baselineEnd: String?
    @State private var baselineStatus = ""
    @State private var didLoad = false
    @State private var isMissing = false
    @State private var isSaving = false
    @State private var staleCurrent: (date: String?, start: String?, status: String)?
    @State private var failureMessage: String?
    @State private var savedConflicts: [String]?

    private var currentJob: Canonical.Job? {
        store.calendarJob(id: jobID)
    }

    private var validationDraft: NativeCalendar.ScheduleEditDraft {
        NativeCalendar.ScheduleEditDraft(
            jobId: jobID,
            baselineDate: baselineDate, baselineStart: baselineStart,
            baselineEnd: baselineEnd, baselineStatus: baselineStatus,
            date: dateText.isEmpty ? nil : dateText,
            start: startText.isEmpty ? nil : startText,
            end: endText.isEmpty ? nil : endText)
    }

    private var issues: [NativeCalendar.ScheduleEditIssue] {
        NativeCalendar.validateScheduleDraft(validationDraft)
    }

    private var conflictTitles: [String] {
        guard let job = currentJob, !dateText.isEmpty, !startText.isEmpty else { return [] }
        let rows = store.calendarScheduleJobs()
        let schedule = store.calendarResolvedSchedule()
        return NativeSchedule.findScheduleConflicts(
            jobs: rows,
            query: NativeSchedule.ConflictQuery(
                excludeJobId: jobID, date: dateText, start: startText,
                end: endText.isEmpty ? nil : endText,
                laborHours: (job.laborHours as NSDecimalNumber).doubleValue,
                bufferMinutes: schedule.bufferMinutes)
        ).map(\.title)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isMissing {
                    missingView
                } else if !didLoad {
                    ProgressView("Loading schedule…")
                        .accessibilityLabel("Loading schedule")
                } else {
                    editorForm
                }
            }
            .navigationTitle("Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel without saving")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!didLoad || isMissing || isSaving || !issues.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Form

    private var editorForm: some View {
        Form {
            if let saved = savedConflicts {
                Section {
                    Label(saved.isEmpty
                          ? "Saved."
                          : "Saved with \(saved.count) conflict(s): \(saved.joined(separator: ", ")).",
                          systemImage: saved.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(saved.isEmpty ? .green : .orange)
                        .accessibilityLabel(saved.isEmpty ? "Saved" : "Saved with conflicts: \(saved.joined(separator: ", "))")
                }
            }
            if let stale = staleCurrent {
                Section(header: Text("Needs review")) {
                    Text("The job changed while this schedule was open. Review the latest schedule before saving.")
                        .font(.footnote).foregroundStyle(.orange)
                    LabeledContent("Latest date", value: stale.date ?? "Unscheduled")
                    LabeledContent("Latest start", value: stale.start ?? "Untimed")
                    LabeledContent("Latest status", value: stale.status)
                    Button("Reload latest into this draft") { reloadLatest() }
                        .accessibilityHint("Keeps what you typed but re-checks it against the latest schedule")
                }
            }
            if let failure = failureMessage {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                        .accessibilityLabel("Save failed: \(failure). Your draft was kept.")
                }
            }

            Section(header: Text("Date and time")) {
                TextField("Date (YYYY-MM-DD)", text: $dateText)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Scheduled date")
                    .accessibilityHint("Year month day. Empty means unscheduled.")
                TextField("Start (HH:MM)", text: $startText)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Start time")
                    .accessibilityHint("Empty with a date means an untimed job, not midnight.")
                TextField("End (HH:MM, optional)", text: $endText)
                    .autocorrectionDisabled()
                    .accessibilityLabel("End time")
                HStack {
                    Button("Today") { dateText = NativeCalendarView.todayString() }
                    Spacer()
                    Button("Clear time") { startText = ""; endText = "" }
                        .accessibilityHint("Makes this an untimed dated job")
                    Spacer()
                    Button("Clear date") { dateText = ""; startText = ""; endText = "" }
                        .accessibilityHint("Makes this unscheduled")
                }
                .font(.footnote)
            }

            if let job = currentJob {
                Section(header: Text("Job")) {
                    LabeledContent("Title", value: job.title)
                    LabeledContent("Customer", value: job.customerName)
                    LabeledContent("Status", value: job.status)
                    LabeledContent("Estimate", value: NativeSchedule.formatLaborHint(
                        (job.laborHours as NSDecimalNumber).doubleValue))
                }
            }

            if !issues.isEmpty {
                Section(header: Text("Check these")) {
                    ForEach(issues.indices, id: \.self) { index in
                        Text(issueText(issues[index])).font(.footnote).foregroundStyle(.red)
                    }
                }
            }

            if !conflictTitles.isEmpty {
                Section(header: Text("Conflicts (warning only)")) {
                    Label("Overlaps \(conflictTitles.joined(separator: ", ")). Saving is still allowed.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityLabel("Warning: overlaps \(conflictTitles.joined(separator: ", ")). Saving is still allowed.")
                }
            }
        }
        .disabled(isSaving)
    }

    private var missingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("This job no longer exists.")
                .font(.headline)
                .accessibilityLabel("This job no longer exists. Nothing was saved.")
            Text("It may have been deleted on another device. Nothing was saved.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
        }
        .padding()
    }

    // MARK: - Commit

    private func load() {
        guard !didLoad else { return }
        guard let draft = store.scheduleOnlyDraft(jobID: jobID) else {
            isMissing = true
            didLoad = true
            return
        }
        baselineDate = draft.baselineDate
        baselineStart = draft.baselineStart
        baselineEnd = draft.baselineEnd
        baselineStatus = draft.baselineStatus
        dateText = draft.date ?? ""
        startText = draft.start ?? ""
        endText = draft.end ?? ""
        didLoad = true
    }

    private func save() {
        failureMessage = nil
        savedConflicts = nil
        isSaving = true
        defer { isSaving = false }
        let draft = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
            jobID: jobID,
            baselineDate: baselineDate, baselineStart: baselineStart,
            baselineEnd: baselineEnd, baselineStatus: baselineStatus,
            date: dateText.isEmpty ? nil : dateText,
            start: startText.isEmpty ? nil : startText,
            end: endText.isEmpty ? nil : endText)
        switch store.commitScheduleOnly(draft) {
        case let .saved(conflictingJobIDs):
            staleCurrent = nil
            // Resolve conflict IDs to current titles for the confirmation.
            let titles = Dictionary(
                uniqueKeysWithValues: store.calendarScheduleJobs().map { ($0.id, $0.title) })
            savedConflicts = conflictingJobIDs.map { titles[$0] ?? $0 }
            onSaved()
            dismiss()
        case .baselineConflict:
            // Stale-state recovery: keep the typed draft, surface the latest
            // record, and require an explicit reload before the next save.
            if let current = currentJob {
                staleCurrent = (current.scheduledDate, current.scheduledStartTime, current.status)
            } else {
                isMissing = true
            }
        case .missing:
            isMissing = true
        case .failed:
            // Failure keeps the draft: the sheet stays open with every typed
            // field intact and the store's message names the cause.
            failureMessage = store.migrationMessage ?? "Could not save this schedule."
        }
    }

    /// Re-pins the baselines to the latest record while keeping what the
    /// owner typed. The next Save re-checks against the fresh baseline.
    private func reloadLatest() {
        guard let draft = store.scheduleOnlyDraft(jobID: jobID) else {
            isMissing = true
            staleCurrent = nil
            return
        }
        baselineDate = draft.baselineDate
        baselineStart = draft.baselineStart
        baselineEnd = draft.baselineEnd
        baselineStatus = draft.baselineStatus
        staleCurrent = nil
        failureMessage = nil
    }

    private func issueText(_ issue: NativeCalendar.ScheduleEditIssue) -> String {
        switch issue {
        case let .invalidDate(value): "“\(value)” is not a valid date (YYYY-MM-DD)."
        case let .invalidTime(value): "“\(value)” is not a valid time (HH:MM)."
        case .timeWithoutDate: "A start time needs a date first."
        case .endWithoutStart: "An end time needs a start time first."
        case .endNotAfterStart: "The end time must be after the start time."
        }
    }
}
