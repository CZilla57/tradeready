import SwiftUI

/// Phase 8 task 8.10 schedule settings UI (requirement S4).
///
/// Thin view over the 8.01 pure schedule projection
/// (`calendarResolvedSchedule`) and the 8.08 settings commit
/// (`commitScheduleSettings`). No business policy lives here: every
/// validation delegates to `NativeSchedule`/`NativeAvailability`, every
/// write merges only owned schedule fields through the typed store entry
/// point, and booking credentials plus unknown fields survive by
/// construction. Cancel never writes; a failed save keeps the draft open;
/// a concurrent owned-field change surfaces baseline-conflict recovery
/// (reload, never silent replacement). A local save is never presented as
/// public publication — pending sync is labeled as waiting, not published.
struct NativeScheduleSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    // MARK: - Draft state (all local until Save)

    @State private var workDays: Set<Int> = []
    @State private var startText = ""
    @State private var endText = ""
    @State private var durationText = ""
    @State private var bufferText = ""
    @State private var leadText = ""
    @State private var horizonText = ""
    @State private var timeZoneText = ""
    @State private var slotsEnabled = false
    @State private var blackouts: [NativeSchedule.ScheduleBlackout] = []
    @State private var baseline: Canonical.ScheduleConfig?
    @State private var didLoad = false

    // Blackout Add-only inputs (only Add inserts; Remove deletes by stable ID).
    @State private var newBlackoutStart = ""
    @State private var newBlackoutEnd = ""
    @State private var newBlackoutReason = ""

    @State private var isSaving = false
    @State private var notice: String?
    @State private var failureMessage: String?
    @State private var staleConflict = false

    /// ISO weekday labels: Monday = 1 … Sunday = 7 (spec §2 hazard: the old
    /// prototype assumed Sunday = 1).
    static let isoDayLabels: [(day: Int, label: String)] = [
        (1, "Mon"), (2, "Tue"), (3, "Wed"), (4, "Thu"),
        (5, "Fri"), (6, "Sat"), (7, "Sun"),
    ]

    var body: some View {
        Group {
            if !didLoad {
                ProgressView("Loading schedule settings…")
                    .accessibilityLabel("Loading schedule settings")
                    .onAppear(perform: load)
            } else {
                settingsForm
            }
        }
        .navigationTitle("Schedule")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityLabel("Discard schedule changes")
                    .accessibilityHint("Closes without saving anything")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!didLoad || isSaving || !validationErrors.isEmpty)
                    .accessibilityHint("Saves schedule settings on this device. Sync publishes them; nothing here claims public publication.")
            }
        }
        .nativeAnalyticsScreen(.settingsSchedule)
    }

    // MARK: - Form

    private var settingsForm: some View {
        Form {
            if let notice {
                Section {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityLabel(notice)
                }
            }
            if staleConflict {
                Section(header: Text("Needs review")) {
                    Text("Schedule settings changed on another device. Review the latest settings before saving.")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("Reload latest into this draft") { load(); staleConflict = false }
                        .accessibilityHint("Re-reads the latest settings but keeps nothing you typed")
                }
            }
            if let failure = failureMessage {
                Section {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                        .accessibilityLabel("Save failed: \(failure)")
                }
            }

            Section(header: Text("Working days")) {
                HStack {
                    ForEach(Self.isoDayLabels, id: \.day) { day, label in
                        Button { toggle(day: day) } label: {
                            Text(label)
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity).frame(height: 36)
                                .background(
                                    workDays.contains(day) ? Color.tradeReady : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .foregroundStyle(workDays.contains(day) ? .white : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(workDays == [day])
                        .accessibilityLabel("\(label), ISO day \(day)")
                        .accessibilityHint(workDays == [day]
                            ? "This is the last working day and cannot be removed"
                            : (workDays.contains(day) ? "Removes \(label)" : "Adds \(label)"))
                    }
                }
                Text("These days drive calendar availability. The final working day cannot be removed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(header: Text("Working hours")) {
                LabeledContent("Day starts (HH:MM)") {
                    TextField("08:00", text: $startText)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .autocorrectionDisabled()
                        .accessibilityLabel("Work day starts, hours and minutes")
                }
                LabeledContent("Day ends (HH:MM)") {
                    TextField("17:00", text: $endText)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .autocorrectionDisabled()
                        .accessibilityLabel("Work day ends, hours and minutes")
                }
                Text("Minutes are preserved exactly — saving never rounds working hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(header: Text("Appointments")) {
                LabeledContent("Default length (min)") {
                    TextField("60", text: $durationText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Default appointment length in minutes")
                }
                LabeledContent("Buffer (min)") {
                    TextField("0", text: $bufferText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Buffer between appointments in minutes")
                }
                LabeledContent("Lead time (hours)") {
                    TextField("24", text: $leadText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Booking lead time in hours")
                }
                LabeledContent("Horizon (days)") {
                    TextField("14", text: $horizonText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Booking horizon in days")
                }
            }

            Section(header: Text("Time zone")) {
                Toggle("Bookable time slots", isOn: $slotsEnabled)
                    .accessibilityHint("Slot availability is separate from whether the booking link accepts requests")
                LabeledContent("IANA zone") {
                    TextField("America/Phoenix", text: $timeZoneText)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Owner IANA time zone")
                }
                if slotsEnabled, !NativeAvailability.isValidIANAZone(timeZoneText) {
                    Label("Enter a valid IANA zone before saving with slots enabled — slots stay off until then.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Enabling slots keeps your existing valid zone, or stamps this device's zone (UTC fallback). Slot availability is separate from link enablement.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(header: Text("Time off")) {
                if blackouts.isEmpty {
                    Text("No upcoming time off").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(blackouts, id: \.id) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(entry.start) – \(entry.end)").font(.body.monospacedDigit())
                                if let reason = entry.reason, !reason.isEmpty {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { removeBlackout(id: entry.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove time off \(entry.start) to \(entry.end)")
                            .accessibilityHint("Removing one entry preserves all others")
                        }
                    }
                }
                LabeledContent("Starts (YYYY-MM-DD)") {
                    TextField("2026-12-24", text: $newBlackoutStart)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                LabeledContent("Ends (YYYY-MM-DD)") {
                    TextField("2026-12-26", text: $newBlackoutEnd)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                LabeledContent("Reason (optional)") {
                    TextField("Holidays", text: $newBlackoutReason)
                        .multilineTextAlignment(.trailing)
                }
                Button { addBlackout() } label: {
                    Label("Add time off", systemImage: "plus.circle")
                }
                .disabled(!canAddBlackout)
                .accessibilityHint("Only Add inserts a time-off entry")
            }

            if !validationErrors.isEmpty {
                Section(header: Text("Check before saving")) {
                    ForEach(validationErrors, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
                }
            }

            Section {
                Text("Saving updates this device and queues sync — it does not claim public publication. The booking link token is preserved untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            // Touch the published sync state so the pending-sync notice
            // invalidates when the queue drains.
            _ = store.syncStatus
        }
    }

    // MARK: - Load / save

    private func load() {
        let resolved = store.calendarResolvedSchedule()
        baseline = store.scheduleSettingsBaseline()
        workDays = Set(resolved.workDays)
        startText = resolved.workDayStart
        endText = resolved.workDayEnd
        durationText = String(resolved.defaultDurationMinutes)
        bufferText = String(resolved.bufferMinutes)
        leadText = String(resolved.slotLeadHours)
        horizonText = String(resolved.slotWindowDays)
        timeZoneText = resolved.timeZone ?? ""
        slotsEnabled = resolved.bookableSlotsEnabled
        // Seed time off from the raw baseline, not the resolved projection
        // (which drops invalid entries): saving must preserve entries it
        // does not own, including ones the calendar cannot render.
        blackouts = (baseline?.blackouts ?? []).map {
            NativeSchedule.ScheduleBlackout(id: $0.id, start: $0.start, end: $0.end, reason: $0.reason)
        }
        failureMessage = nil
        didLoad = true
    }

    private func toggle(day: Int) {
        // The final working day cannot be removed (the button is disabled,
        // this guard is the backstop).
        if workDays.contains(day), workDays.count <= 1 { return }
        if workDays.contains(day) { workDays.remove(day) } else { workDays.insert(day) }
    }

    private var validationErrors: [String] {
        Self.validate(
            workDays: workDays, startText: startText, endText: endText,
            durationText: durationText, bufferText: bufferText,
            leadText: leadText, horizonText: horizonText,
            slotsEnabled: slotsEnabled, timeZoneText: timeZoneText)
    }

    /// Pure validation over the draft fields, shared with the focused host
    /// tests through the same rules the Save button enforces.
    static func validate(
        workDays: Set<Int>, startText: String, endText: String,
        durationText: String, bufferText: String,
        leadText: String, horizonText: String,
        slotsEnabled: Bool, timeZoneText: String
    ) -> [String] {
        var errors: [String] = []
        if workDays.isEmpty { errors.append("Keep at least one working day.") }
        if !NativeSchedule.isValidTime(startText) { errors.append("Day starts must be HH:MM (00:00–23:59).") }
        if !NativeSchedule.isValidTime(endText) { errors.append("Day ends must be HH:MM (00:00–23:59).") }
        if NativeSchedule.isValidTime(startText), NativeSchedule.isValidTime(endText),
           startText >= endText {
            errors.append("Day starts must be before day ends.")
        }
        if (Int(durationText) ?? 0) <= 0 { errors.append("Default length must be at least 1 minute.") }
        if (Int(bufferText) ?? -1) < 0 { errors.append("Buffer must be 0 minutes or more.") }
        if (Int(leadText) ?? -1) < 0 { errors.append("Lead time must be 0 hours or more.") }
        if (Int(horizonText) ?? 0) <= 0 { errors.append("Horizon must be at least 1 day.") }
        if slotsEnabled, !NativeAvailability.isValidIANAZone(timeZoneText) {
            errors.append("A valid IANA zone is required before enabling slots.")
        }
        return errors
    }

    private var canAddBlackout: Bool {
        NativeSchedule.isValidDate(newBlackoutStart)
            && NativeSchedule.isValidDate(newBlackoutEnd)
            && newBlackoutStart <= newBlackoutEnd
    }

    private func addBlackout() {
        // Add-only: a fresh stable ID never replaces an existing entry.
        guard canAddBlackout else { return }
        let entry = NativeSchedule.ScheduleBlackout(
            id: "blk_\(UUID().uuidString)",
            start: newBlackoutStart, end: newBlackoutEnd,
            reason: newBlackoutReason.isEmpty ? nil : newBlackoutReason)
        blackouts.append(entry)
        newBlackoutStart = ""
        newBlackoutEnd = ""
        newBlackoutReason = ""
    }

    private func removeBlackout(id: String) {
        // Remove-by-ID preserves every other entry.
        blackouts.removeAll { $0.id == id }
    }

    private func save() {
        guard validationErrors.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        // Enabling slots preserves the existing valid zone; otherwise stamp
        // the device zone with a UTC fallback (never a fabricated offer —
        // an invalid zone still refuses via the validator above).
        var zone = timeZoneText
        if slotsEnabled, !NativeAvailability.isValidIANAZone(zone) {
            zone = TimeZone.current.identifier
            if !NativeAvailability.isValidIANAZone(zone) { zone = "UTC" }
            timeZoneText = zone
        }
        let draft = NativeScheduleBookingPolicy.ScheduleSettingsDraft(
            baselineSchedule: baseline,
            workDays: workDays.sorted(),
            workDayStart: startText,
            workDayEnd: endText,
            defaultDurationMinutes: Int(durationText),
            bufferMinutes: Int(bufferText),
            slotLeadHours: Int(leadText),
            slotWindowDays: Int(horizonText),
            timeZone: .some(zone.isEmpty ? nil : zone),
            bookableSlotsEnabled: slotsEnabled,
            blackoutsToAdd: blackouts.map(Self.canonicalBlackout).compactMap { $0 },
            blackoutIDsToRemove: removedBlackoutIDs())
        switch store.commitScheduleSettings(draft) {
        case .saved:
            // Offline changes do not claim public publication: label the
            // pending-sync state instead of a published state.
            if store.syncStatus.pendingCount > 0 {
                notice = "Saved on this device. \(store.syncStatus.pendingCount) change(s) waiting to sync — not yet published."
            } else if store.syncStatus.diagnosticCode != nil {
                notice = "Saved on this device. Sync needs attention before this is published."
            } else {
                notice = "Saved."
            }
            baseline = store.scheduleSettingsBaseline()
            failureMessage = nil
            staleConflict = false
            dismiss()
        case .baselineConflict:
            staleConflict = true
            failureMessage = nil
        case .failed:
            failureMessage = store.migrationMessage ?? "Could not save schedule settings."
        }
    }

    /// IDs present at load but absent now: remove-by-ID, preserving the rest.
    /// Computed from the raw baseline (not the resolved projection, which
    /// drops invalid entries) so saving never cleans up data it cannot see.
    private func removedBlackoutIDs() -> [String] {
        let baselineIDs = Set(baseline?.blackouts?.map(\.id) ?? [])
        let currentIDs = Set(blackouts.map(\.id))
        return Array(baselineIDs.subtracting(currentIDs))
    }

    /// Bridges the 8.01 blackout value into the canonical shape the settings
    /// draft owns. Unknown nested fields ride the canonical preservation bag
    /// (a settings save never rewrites what it does not own).
    static func canonicalBlackout(_ entry: NativeSchedule.ScheduleBlackout) -> Canonical.ScheduleBlackout? {
        let fields: [String: Canonical.JSONValue] = [
            "id": .string(entry.id),
            "start": .string(entry.start),
            "end": .string(entry.end),
            "reason": entry.reason.map(Canonical.JSONValue.string) ?? .null,
        ]
        guard let data = try? JSONEncoder().encode(fields) else { return nil }
        return try? JSONDecoder().decode(Canonical.ScheduleBlackout.self, from: data)
    }
}
