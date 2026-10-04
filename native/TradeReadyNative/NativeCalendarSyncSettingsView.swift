import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings › Calendar sync (Roadmap Phase 26, spec
/// `docs/superpowers/specs/2026-10-03-calendar-sync-design.md` §4.5).
///
/// Thin view over `AppStore.calendarSync` (the coordinator owns every rule).
/// Two sections: "Calendar checks" (personal busy times block booking slots;
/// only start and end times leave the device) and "Add jobs to my calendar"
/// (the one-way TradeReady calendar). Every async action disables the
/// controls while it runs, turning things off confirms first, refusals are
/// text alerts, and denied or restricted calendar access is explained in text
/// with an Open Settings link.
struct NativeCalendarSyncSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL

    @State private var showingExplainer = false
    @State private var confirmingChecksOff = false
    @State private var confirmingMirrorOff = false
    @State private var confirmingTakeover = false
    @State private var confirmingRemoteOff = false
    @State private var deniedAfterRequest = false
    @State private var alertMessage: String?
    /// Set before an action's task starts, so a second tap cannot queue a
    /// second action (the coordinator's own busy flag follows).
    @State private var actionInFlight = false

    private var sync: NativeCalendarSyncCoordinator { store.calendarSync }
    private var isBusy: Bool { sync.isBusy || actionInFlight }
    private var authorization: NativeCalendarAuthorization { sync.authorization }
    private var accessBlocked: Bool { authorization == .denied || authorization == .restricted }
    private var schedule: NativeSchedule.ResolvedSchedule { store.calendarResolvedSchedule() }

    var body: some View {
        Form {
            noticeSection
            checksSection
            if sync.checksEnabled && !accessBlocked && !sync.selectableCalendars.isEmpty {
                calendarsSection
            }
            if showsAccessHelp {
                accessSection
            }
            mirrorSection
        }
        .nativeContentColumn(.list)
        .navigationTitle("Calendar Sync")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .disabled(isBusy)
        .overlay {
            if isBusy {
                ProgressView()
                    .accessibilityLabel("Updating calendar sync")
            }
        }
        .task { await sync.run(.settingsScreen) }
        .refreshable { await sync.run(.settingsScreen) }
        .sheet(isPresented: $showingExplainer) {
            NativeCalendarChecksExplainer {
                showingExplainer = false
                perform { await enableChecks() }
            } onCancel: {
                showingExplainer = false
            }
        }
        .confirmationDialog("Turn off calendar checks?", isPresented: $confirmingChecksOff, titleVisibility: .visible) {
            Button("Turn off calendar checks", role: .destructive) { perform { await disableChecks() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your booking page will stop checking your personal calendar. Busy times already shared are deleted from TradeReady.")
        }
        .confirmationDialog("Turn off calendar checks everywhere?", isPresented: $confirmingRemoteOff, titleVisibility: .visible) {
            Button("Turn off calendar checks", role: .destructive) { perform { await disableChecks() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your booking page will stop checking your personal calendar on every device. Busy times already shared are deleted from TradeReady.")
        }
        .confirmationDialog("Use this device for calendar checks?", isPresented: $confirmingTakeover, titleVisibility: .visible) {
            Button("Use this device") { perform { await useThisDevice() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Calendar checks run on another device. Your booking page will check this device's calendars instead.")
        }
        .confirmationDialog("Stop adding jobs to your calendar?", isPresented: $confirmingMirrorOff, titleVisibility: .visible) {
            Button("Remove calendar", role: .destructive) { perform { await disableMirror(remove: true) } }
            Button("Keep calendar") { perform { await disableMirror(remove: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove calendar deletes the TradeReady calendar and its events from every device on that calendar account. Keep calendar leaves it as it is, without further updates.")
        }
        .alert("Calendar sync", isPresented: alertBinding) {
            Button("OK", role: .cancel) { alertMessage = nil; sync.clearError() }
        } message: {
            Text(alertMessage ?? sync.errorMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil || sync.errorMessage != nil },
            set: { if !$0 { alertMessage = nil; sync.clearError() } }
        )
    }

    // MARK: - Notice

    @ViewBuilder private var noticeSection: some View {
        if let notice = sync.notice {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(Self.noticeText(notice), systemImage: "info.circle.fill")
                        .font(.subheadline)
                    Button("Dismiss") { sync.dismissNotice() }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHint("Hides this notice")
                }
                .padding(.vertical, 2)
            }
        }
    }

    static func noticeText(_ notice: NativeCalendarSyncLocalState.Notice) -> String {
        switch notice {
        case .mirrorCalendarDeleted:
            "The TradeReady calendar was deleted, so adding jobs to your calendar is now off. Turn it on again to create a new one."
        case .checksMovedToAnotherDevice:
            "Calendar checks moved to another device. This device no longer shares busy times."
        case .checksTurnedOffElsewhere:
            "Calendar checks were turned off on another device, so they are off here too."
        }
    }

    // MARK: - Calendar checks

    private var checksSection: some View {
        Section {
            Toggle("Check my calendars for busy times", isOn: checksBinding)
                .accessibilityHint(sync.checksEnabled
                    ? "Turns off calendar checks after you confirm"
                    : "Asks for calendar access, then shares only busy start and end times with your booking page")
            if let line = sync.statusLine {
                statusRow(line)
            }
            if !sync.checksEnabled, let status = sync.serverStatus, status.enabled, !status.thisDevice {
                remoteChecksRows(status)
            }
            if sync.checksEnabled, schedule.slotWindowDays > NativeCalendarBusy.maxShareDays {
                Text("While calendar checks are on, online booking looks at most \(NativeCalendarBusy.maxShareDays) days ahead.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Calendar checks")
        } footer: {
            Text("Only start and end times are sent to TradeReady, never event names, places, notes or guests. All-day events block booking only when they're marked Busy; add vacations under Schedule › Time off. Google calendars appear here only after you add your Google account in iOS Settings › Apps › Calendar › Calendar Accounts.")
        }
    }

    private var checksBinding: Binding<Bool> {
        Binding(
            get: { sync.checksEnabled },
            set: { wanted in
                guard !isBusy else { return }
                if wanted {
                    if sync.explainerShown && authorization != .notDetermined {
                        perform { await enableChecks() }
                    } else {
                        showingExplainer = true
                    }
                } else {
                    confirmingChecksOff = true
                }
            }
        )
    }

    private func statusRow(_ line: NativeCalendarBusy.StatusLine) -> some View {
        let text = NativeCalendarBusy.statusText(line, now: Date())
        return VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: Self.statusSymbol(line))
                .font(.subheadline)
                .foregroundStyle(Self.statusIsWarning(line) ? Color.tradeWarningText : Color.primary)
            if case .otherDevice = line {
                Button("Use this device") { confirmingTakeover = true }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHint("Makes this device the one that checks your calendars")
            }
            if case .notShared = line {
                Text("Turn on Bookable time slots under Schedule to share busy times.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status: \(text)")
    }

    static func statusSymbol(_ line: NativeCalendarBusy.StatusLine) -> String {
        switch line {
        case .shared: "checkmark.circle"
        case .notShared: "pause.circle"
        case .otherDevice: "iphone"
        case .outOfDate, .accessNeeded: "exclamationmark.triangle.fill"
        case .unavailable: "clock"
        case .waiting: "arrow.triangle.2.circlepath"
        }
    }

    static func statusIsWarning(_ line: NativeCalendarBusy.StatusLine) -> Bool {
        switch line {
        case .outOfDate, .accessNeeded: true
        default: false
        }
    }

    /// Checks run on another device and this one has none: offer to take
    /// over, or to turn them off for every device.
    private func remoteChecksRows(_ status: NativeCalendarBusy.ServerStatus) -> some View {
        let text = NativeCalendarBusy.statusText(.otherDevice(lastUpdate: status.lastRunAt), now: Date())
        return VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "iphone").font(.subheadline)
            Button("Use this device") { confirmingTakeover = true }
                .font(.subheadline.weight(.semibold))
                .accessibilityHint("Asks for calendar access, then makes this device the one that checks your calendars")
            Button(role: .destructive) { confirmingRemoteOff = true } label: {
                Text("Turn off calendar checks").nativeDestructiveText()
            }
            .font(.subheadline)
            .accessibilityHint("Stops calendar checks on every device after you confirm")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Calendar list

    private var calendarsSection: some View {
        let groups = Dictionary(grouping: sync.selectableCalendars, by: \.accountTitle)
            .sorted { $0.key < $1.key }
        return Section {
            ForEach(groups, id: \.key) { account, calendars in
                Text(account)
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(calendars) { calendar in
                    calendarRow(calendar)
                }
            }
        } header: {
            Text("Calendars to check")
        } footer: {
            Text("New calendars are checked automatically. Birthday and subscribed calendars, such as holidays or sports, start unchecked.")
        }
    }

    private func calendarRow(_ calendar: NativeCalendarInfo) -> some View {
        let included = sync.isCalendarIncluded(calendar.id)
        return Button {
            perform { await sync.setCalendar(calendar.id, included: !included) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(included ? Color.tradeReady : Color.secondary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(calendar.title).foregroundStyle(.primary)
                    Text(Self.calendarDetail(calendar, included: included))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(calendar.title), \(calendar.accountTitle)")
        .accessibilityValue(included ? "Checked" : "Not checked")
        .accessibilityHint(included ? "Stops checking this calendar for busy times" : "Checks this calendar for busy times")
    }

    static func calendarDetail(_ calendar: NativeCalendarInfo, included: Bool) -> String {
        let state = included ? "Checked" : "Not checked"
        switch calendar.kind {
        case .birthday: return "\(state) · birthdays"
        case .subscription: return "\(state) · subscribed calendar"
        case .standard: return state
        }
    }

    // MARK: - Access help

    private var showsAccessHelp: Bool {
        (sync.checksEnabled || sync.mirrorEnabled || deniedAfterRequest) && accessBlocked
    }

    private var accessSection: some View {
        Section(header: Text("Calendar access")) {
            Label(authorization == .restricted
                  ? "Calendar access is restricted on this device, for example by Screen Time or a device profile, so TradeReady can't read or add calendar events."
                  : "Calendar access is off for TradeReady, so busy times can't be checked and jobs can't be added to your calendar. Your booking page takes requests only until calendar checks run again.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Color.tradeWarningText)
            Button("Open Settings") { openSystemSettings() }
                .font(.subheadline.weight(.semibold))
                .accessibilityHint(authorization == .restricted
                    ? "Opens TradeReady in the Settings app; Screen Time or your device manager controls calendar access"
                    : "Opens TradeReady in the Settings app, where you can choose Full Access for Calendars")
        }
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #endif
    }

    // MARK: - Mirror (Stage B)

    private var mirrorSection: some View {
        Section {
            Toggle("Add my jobs to a TradeReady calendar", isOn: mirrorBinding)
                .accessibilityHint(sync.mirrorEnabled
                    ? "Asks whether to remove or keep the TradeReady calendar"
                    : "Asks for calendar access, then adds your scheduled jobs to a calendar named TradeReady")
            if sync.mirrorEnabled {
                Text("Calendar account: \(sync.mirrorAccountTitle ?? "On this device")")
                    .font(.subheadline)
                if let error = sync.mirrorError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(Color.tradeWarningText)
                }
            }
        } header: {
            Text("Add jobs to my calendar")
        } footer: {
            Text("Jobs from 30 days ago to 6 months ahead appear with their time, customer and address. The calendar is one-way: edits made in the Calendar app are replaced, so change jobs in TradeReady. Turn this on for one device only, so jobs aren't added twice while devices catch up.")
        }
    }

    private var mirrorBinding: Binding<Bool> {
        Binding(
            get: { sync.mirrorEnabled },
            set: { wanted in
                guard !isBusy else { return }
                if wanted {
                    perform { await enableMirror() }
                } else {
                    confirmingMirrorOff = true
                }
            }
        )
    }

    // MARK: - Actions

    private func perform(_ work: @escaping @MainActor () async -> Void) {
        guard !actionInFlight else { return }
        actionInFlight = true
        Task { @MainActor in
            await work()
            actionInFlight = false
        }
    }

    private func enableChecks() async {
        switch await sync.enableChecks() {
        case .enabled:
            deniedAfterRequest = false
        case .denied:
            deniedAfterRequest = true
        case .unavailableOnDevice:
            alertMessage = "Calendar checks aren't available in this build."
        }
    }

    private func disableChecks() async {
        await sync.disableChecks()
    }

    private func useThisDevice() async {
        let tookOver = await sync.useThisDevice()
        if !tookOver, accessBlocked { deniedAfterRequest = true }
    }

    private func enableMirror() async {
        switch await sync.enableMirror() {
        case .enabled:
            deniedAfterRequest = false
        case .denied:
            deniedAfterRequest = true
        case .failed:
            if sync.errorMessage == nil {
                alertMessage = "Jobs couldn't be added to a TradeReady calendar on this device."
            }
        }
    }

    private func disableMirror(remove: Bool) async {
        await sync.disableMirror(removeCalendar: remove)
    }
}

/// The first-enable explainer (§4.5): what is read, what leaves the device,
/// and that Google calendars must be added in iOS Settings. Continue then
/// shows the system prompt.
struct NativeCalendarChecksExplainer: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Check your calendars for busy times")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    explainerPoint("eye", "TradeReady reads the calendars you choose on this device to find when you're busy.")
                    explainerPoint("lock.shield", "Only start and end times of busy periods in your booking window are sent to TradeReady. Event names, places, notes and guests never leave your device.")
                    explainerPoint("calendar.badge.clock", "Your booking page then won't offer those times. All-day events count only when they're marked Busy, so birthdays and holidays don't block a day.")
                    explainerPoint("person.crop.circle.badge.plus", "Google calendars appear only after you add your Google account in iOS Settings › Apps › Calendar › Calendar Accounts.")
                    explainerPoint("arrow.triangle.2.circlepath", "If TradeReady can't check for 48 hours, your booking page takes requests only until it checks again.")
                    Button(action: onContinue) {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .tradeReadyProminentButtonStyle()
                    .accessibilityHint("Then iOS asks for access to your calendars")
                    .padding(.top, 8)
                }
                .padding()
            }
            .nativeContentColumn(.scroll)
            .navigationTitle("Calendar checks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now", action: onCancel).keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private func explainerPoint(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.tradeReady)
        }
        .font(.body)
    }
}

/// The Today attention row (§4.5): booking is request-only because calendar
/// checks are stale. Opens Settings › Calendar sync; it cannot be muted.
struct NativeTodayCalendarChecksRow: View {
    let message: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.subheadline).foregroundStyle(Color.tradeWarningText)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.tradeWarningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("›").font(.title3).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.tradeWarningText.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message)
        .accessibilityHint("Opens calendar sync settings")
    }
}
