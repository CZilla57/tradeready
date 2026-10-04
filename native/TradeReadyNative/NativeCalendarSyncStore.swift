import Foundation

/// Phase 26 (calendar sync): the `AppStore` API the settings page, the
/// calendar overlay, the schedule editor warning and the Today row build on.
/// Spec: `docs/superpowers/specs/2026-10-03-calendar-sync-design.md` §4.4–§4.7.
///
/// AppStore.swift holds only hooks (foreground, BG refresh, snapshot writes,
/// scene background, the account boundaries) and the two primitives that need
/// its private state (`calendarSyncOwner`, `calendarSyncCredentials`).
extension AppStore: NativeCalendarSyncHost {
    func calendarSyncSchedule() -> NativeSchedule.ResolvedSchedule {
        calendarResolvedSchedule()
    }

    func calendarSyncJobs() -> [Canonical.Job] {
        calendarScheduleJobs()
    }

    func calendarSyncDidChange() {
        objectWillChange.send()
    }

    // MARK: Install

    /// Production: EventKit, the Worker transport and standard defaults
    /// (already declared under CA92.1 in the privacy manifest).
    func installLiveCalendarSync() {
        #if canImport(EventKit)
        let access: NativeCalendarAccess? = NativeEventKitCalendarAccess()
        #else
        let access: NativeCalendarAccess? = nil
        #endif
        calendarSync.install(access: access, transport: NativeCalendarSyncTransport.live(), stateBacking: UserDefaults.standard)
    }

    /// Host tests: fakes for the device calendar and the Worker.
    func installCalendarSync(access: NativeCalendarAccess?, transport: NativeCalendarSyncTransporting?,
                             stateBacking: NativeCalendarSyncStateBacking, now: (() -> Date)? = nil,
                             deviceCalendar: (() -> Calendar)? = nil) {
        calendarSync.install(access: access, transport: transport, stateBacking: stateBacking,
                             now: now, deviceCalendar: deviceCalendar)
    }

    // MARK: Schedule save (§4.4 "Order on enable")

    /// The schedule settings save. When it turns bookable slots on while
    /// calendar checks are on here, a push for the new schedule is awaited
    /// before the settings change is queued, so booking never runs on jobs
    /// alone once the change syncs (offline, both queue: R6).
    func commitScheduleSettingsAwaitingCalendar(
        _ draft: NativeScheduleBookingPolicy.ScheduleSettingsDraft
    ) async -> ScheduleSettingsOutcome {
        let current = calendarResolvedSchedule()
        if draft.bookableSlotsEnabled == true, !current.bookableSlotsEnabled, calendarSync.wantsPushBeforeSlotsEnable {
            var target = current
            target.bookableSlotsEnabled = true
            if let zone = draft.timeZone { target.timeZone = zone }
            if let days = draft.slotWindowDays, days > 0 { target.slotWindowDays = days }
            await calendarSync.prepareForSlotsEnable(schedule: target)
        }
        let outcome = commitScheduleSettings(draft)
        if outcome == .saved {
            Task { [weak self] in await self?.calendarSync.run(.scheduleSaved) }
        }
        return outcome
    }

    // MARK: Reads for the UI

    /// Personal busy blocks (no titles) for the in-app calendar and the
    /// schedule editor; empty unless calendar checks are on.
    func calendarPersonalBusy() -> [NativeCalendar.PersonalBusyBlock] {
        calendarSync.personalBusyBlocks()
    }

    /// The Today attention row, or nil.
    var calendarChecksStaleMessage: String? {
        calendarSync.staleTodayMessage
    }

    /// The Settings hub row's subtitle.
    var calendarSyncHubSubtitle: String {
        calendarSync.hubSubtitle.text
    }
}
