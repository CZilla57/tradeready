import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// Calendar sync coordinator (Roadmap Phase 26, spec
/// `docs/superpowers/specs/2026-10-03-calendar-sync-design.md` §2.1, §4.4,
/// §4.7). Owned by `AppStore` (which only calls hooks); talks to the device
/// calendar through `NativeCalendarAccess`, to the Worker through
/// `NativeCalendarSyncTransporting`, and keeps its device-local state in
/// standard `UserDefaults` (never in the canonical snapshot, never synced).
///
/// Inbound (this device is the source): while checks are on, bookable slots
/// are on and the zone is valid, the device builds the busy snapshot and
/// pushes it when its digest changed or the last push is 30 minutes old. Off
/// that condition it sends one `snapshot: null` on the transition, so busy
/// times never sit on the server while slots are off and booking fails
/// closed until a device shares again. One source device per owner: a
/// `source_mismatch` stops pushing until the owner chooses "Use this device".
///
/// Outbound (Stage B): after each trigger the TradeReady calendar is found
/// by its stored id (never silently recreated), the mirror window read,
/// planned and applied. A calendar is adopted or deleted only on proof that
/// every event in it is this account's mirror (`NativeCalendarMirror`'s
/// ownership rules); the adapter only executes those decisions.

struct NativeCalendarSyncOwner: Equatable, Sendable {
    /// The verified, device-local account binding (keys the local state).
    let binding: String
    /// The server user id (the mirror's cross-device owner tag).
    let subject: String
}

@MainActor
protocol NativeCalendarSyncHost: AnyObject {
    /// The verified owner, or nil while signed out, at an account boundary or
    /// with writes blocked.
    func calendarSyncOwner() -> NativeCalendarSyncOwner?
    func calendarSyncSchedule() -> NativeSchedule.ResolvedSchedule
    func calendarSyncJobs() -> [Canonical.Job]
    func calendarSyncCredentials() -> NativeCalendarSyncCredentials?
    func calendarSyncDidChange()
}

// MARK: - Device-local state (§2.1)

/// The §2.1 keys, kept together as one document under `calendarSync.state`
/// so an account scrub wipes them atomically.
struct NativeCalendarSyncLocalState: Codable, Equatable {
    struct LastPush: Codable, Equatable {
        var digest: String?
        var at: Date
        /// False for a `snapshot: null` put.
        var shared: Bool
        var days: Int?
    }

    enum Notice: String, Codable, Equatable {
        case mirrorCalendarDeleted
        case checksMovedToAnotherDevice
        case checksTurnedOffElsewhere
    }

    /// `calendarSync.sourceId`: a random UUIDv4 identifying this install.
    var sourceID: String?
    /// `calendarSync.checksEnabled`.
    var checksEnabled = false
    /// `calendarSync.excludedCalendarIDs`: an exclusion list, so calendars
    /// added later are checked by default (conservative, D7).
    var excludedCalendarIDs: [String] = []
    /// Calendars already offered the birthday/subscribed default.
    var seenCalendarIDs: [String] = []
    /// `calendarSync.lastPush`.
    var lastPush: LastPush?
    /// A `source_mismatch` was answered: another device is the source.
    var otherDeviceActive = false
    /// `calendarSync.mirrorEnabled`, `calendarSync.mirrorCalendarID`.
    var mirrorEnabled = false
    var mirrorCalendarID: String?
    var mirrorAccountTitle: String?
    /// `calendarSync.notice`: shown once.
    var notice: Notice?
    var explainerShown = false
}

protocol NativeCalendarSyncStateBacking: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: NativeCalendarSyncStateBacking {}

/// In-memory backing: host tests and the inert default coordinator.
final class NativeCalendarSyncMemoryBacking: NativeCalendarSyncStateBacking {
    private(set) var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? Data }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// Owner-scoped: the document carries a one-way tag of the account binding
/// (never the binding itself), and another owner reads the defaults.
struct NativeCalendarSyncStateStore {
    static let key = "calendarSync.state"
    static let schemaVersion = 1
    static let ownerTagPrefix = "tradeready.calendar-sync.owner.v1:"

    let backing: NativeCalendarSyncStateBacking

    private struct Document: Codable {
        var schemaVersion: Int
        var ownerTag: String
        var state: NativeCalendarSyncLocalState
    }

    static func ownerTag(binding: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data((ownerTagPrefix + binding).utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return binding
        #endif
    }

    func load(binding: String) -> NativeCalendarSyncLocalState {
        guard let data = backing.data(forKey: Self.key),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == Self.schemaVersion,
              document.ownerTag == Self.ownerTag(binding: binding)
        else { return NativeCalendarSyncLocalState() }
        return document.state
    }

    func save(_ state: NativeCalendarSyncLocalState, binding: String) {
        let document = Document(schemaVersion: Self.schemaVersion, ownerTag: Self.ownerTag(binding: binding), state: state)
        guard let data = try? JSONEncoder().encode(document) else { return }
        backing.set(data, forKey: Self.key)
    }

    func removeAll() {
        backing.removeObject(forKey: Self.key)
    }

    var hasStoredState: Bool { backing.data(forKey: Self.key) != nil }
}

// MARK: - Coordinator

@MainActor
final class NativeCalendarSyncCoordinator {
    enum Trigger: String, Sendable {
        case foreground, background, calendarChanged, scheduleSaved, canonicalWrite, settingsScreen, userAction
    }

    enum EnableOutcome: Equatable {
        case enabled
        case denied
        case unavailableOnDevice
    }

    enum MirrorEnableOutcome: Equatable {
        case enabled(accountTitle: String)
        case denied
        case failed
    }

    /// The window the in-app overlay covers (the share window is the
    /// booking horizon, at most 62 days).
    static let overlayDays = 62
    static let statusInterval: TimeInterval = 30 * 60
    static let settingsStatusInterval: TimeInterval = 60
    static let ownCommitQuietSeconds: TimeInterval = 2
    /// Days added each side of the mirror window when existing events are
    /// fetched (zones are at most 26 hours apart).
    static let fetchMarginDays = 2

    weak var host: NativeCalendarSyncHost?
    private(set) var access: NativeCalendarAccess?
    private(set) var transport: NativeCalendarSyncTransporting?
    private var stateStore: NativeCalendarSyncStateStore
    private var now: () -> Date
    private var deviceCalendar: () -> Calendar
    var mirrorDebounceNanoseconds: UInt64 = 2_000_000_000
    var changeDebounceNanoseconds: UInt64 = 5_000_000_000

    private(set) var state = NativeCalendarSyncLocalState()
    private(set) var stateBinding: String?
    private(set) var serverStatus: NativeCalendarBusy.ServerStatus?
    private(set) var statusFetchedAt: Date?
    private(set) var isUnavailable = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var mirrorError: String?
    private(set) var overlay: [NativeAvailability.BusyWindow] = []
    private(set) var calendarList: [NativeCalendarInfo] = []
    private(set) var isObserving = false

    private var runInFlight = false
    private var rerunTrigger: Trigger?
    private var mirrorTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var lastCommitAt: Date?

    init(access: NativeCalendarAccess? = nil,
         transport: NativeCalendarSyncTransporting? = nil,
         stateBacking: NativeCalendarSyncStateBacking = NativeCalendarSyncMemoryBacking(),
         now: @escaping () -> Date = Date.init,
         deviceCalendar: @escaping () -> Calendar = { Calendar.current }) {
        self.access = access
        self.transport = transport
        self.stateStore = NativeCalendarSyncStateStore(backing: stateBacking)
        self.now = now
        self.deviceCalendar = deviceCalendar
    }

    /// Swaps the dependencies (production install, host-test fakes). Clears
    /// in-memory state; the next run reloads the owner's stored state.
    func install(access: NativeCalendarAccess?, transport: NativeCalendarSyncTransporting?,
                 stateBacking: NativeCalendarSyncStateBacking, now: (() -> Date)? = nil,
                 deviceCalendar: (() -> Calendar)? = nil) {
        stopObserving()
        resetMemory()
        self.access = access
        self.transport = transport
        self.stateStore = NativeCalendarSyncStateStore(backing: stateBacking)
        if let now { self.now = now }
        if let deviceCalendar { self.deviceCalendar = deviceCalendar }
    }

    var authorization: NativeCalendarAuthorization { access?.authorization ?? .denied }
    var hasCalendarAccessAdapter: Bool { access != nil }

    // MARK: Triggers

    /// Foreground, BG refresh, `EKEventStoreChanged`, schedule save, a user
    /// action, or (mirror only) a debounced canonical write. Runs are
    /// serialized: one arriving mid-run queues a rerun.
    func run(_ trigger: Trigger) async {
        guard let owner = host?.calendarSyncOwner() else { return }
        if runInFlight {
            rerunTrigger = Self.merge(rerunTrigger, trigger)
            return
        }
        runInFlight = true
        defer { runInFlight = false }
        var next: Trigger? = trigger
        while let current = next {
            rerunTrigger = nil
            guard host?.calendarSyncOwner() == owner else { break }
            await runOnce(current, owner: owner)
            next = rerunTrigger
        }
        notify()
    }

    private static func merge(_ queued: Trigger?, _ incoming: Trigger) -> Trigger {
        // A full run covers a mirror-only one.
        guard let queued else { return incoming }
        return queued == .canonicalWrite ? incoming : queued
    }

    private func runOnce(_ trigger: Trigger, owner: NativeCalendarSyncOwner) async {
        activate(owner)
        refreshCalendarList()
        if trigger == .foreground || trigger == .userAction { startObservingIfNeeded() }
        if trigger != .canonicalWrite {
            await syncInbound(owner: owner, force: false, scheduleOverride: nil)
            guard isCurrent(owner) else { return }
            await refreshStatusIfDue(owner: owner, trigger: trigger)
            guard isCurrent(owner) else { return }
        }
        await syncMirror(owner: owner)
    }

    /// `snapshot.didSet` (job writes, pulls): the mirror, debounced 2 s.
    func snapshotDidChange() {
        guard stateBinding != nil, state.mirrorEnabled, access != nil else { return }
        mirrorTask?.cancel()
        let delay = mirrorDebounceNanoseconds
        mirrorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.run(.canonicalWrite)
        }
    }

    /// `EKEventStoreChanged`, debounced 5 s; our own commits are ignored for 2 s.
    func calendarStoreChanged() {
        if let at = lastCommitAt, now().timeIntervalSince(at) < Self.ownCommitQuietSeconds { return }
        changeTask?.cancel()
        let delay = changeDebounceNanoseconds
        changeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.run(.calendarChanged)
        }
    }

    func appDidEnterBackground() {
        stopObserving()
    }

    // MARK: Account boundary (§4.7)

    /// Sign-out, account switch and every scrub path: stop both directions
    /// and wipe the device-local keys. The server row stays and goes stale
    /// (booking fails closed); the TradeReady calendar stays (the owner's data).
    func scrubForAccountBoundary() {
        stateStore.removeAll()
        resetForAccountBoundary()
    }

    /// In-memory only (a completed sign-out's teardown).
    func resetForAccountBoundary() {
        stopObserving()
        resetMemory()
    }

    /// Account deletion, best effort, before the scrub: removes the
    /// TradeReady calendar when the mirror was on and every event in it is
    /// this account's; otherwise only this account's events go (the same rule
    /// as "Remove calendar").
    func removeMirrorCalendarForAccountDeletion() {
        guard let owner = host?.calendarSyncOwner() else { return }
        activate(owner)
        guard state.mirrorEnabled, let id = state.mirrorCalendarID, let access, access.authorization.isUsable else { return }
        _ = removeMirrorContents(access: access, calendarID: id, owner: owner)
    }

    // MARK: Presentation

    /// Loads the owner's state if it is not loaded yet (no I/O beyond defaults).
    func activateIfNeeded() {
        if let owner = host?.calendarSyncOwner() { activate(owner) }
    }

    var checksEnabled: Bool { activateIfNeeded(); return state.checksEnabled }
    var mirrorEnabled: Bool { activateIfNeeded(); return state.mirrorEnabled }
    var notice: NativeCalendarSyncLocalState.Notice? { activateIfNeeded(); return state.notice }
    var explainerShown: Bool { activateIfNeeded(); return state.explainerShown }
    var otherDeviceActive: Bool { activateIfNeeded(); return state.otherDeviceActive }
    var mirrorAccountTitle: String? { activateIfNeeded(); return state.mirrorAccountTitle }

    /// The calendar list for the settings page. Only this account's mirror
    /// calendar (by its stored id) is hidden: a calendar that merely shares
    /// the title is the owner's, and its events count as busy, so it can be
    /// unchecked.
    var selectableCalendars: [NativeCalendarInfo] {
        activateIfNeeded()
        return calendarList.filter { $0.id != state.mirrorCalendarID }
    }

    func isCalendarIncluded(_ id: String) -> Bool {
        activateIfNeeded()
        return !state.excludedCalendarIDs.contains(id)
    }

    /// The status row (§4.5); nil while checks are off.
    var statusLine: NativeCalendarBusy.StatusLine? {
        activateIfNeeded()
        guard state.checksEnabled else { return nil }
        if !authorization.isUsable { return .accessNeeded }
        if isUnavailable { return .unavailable }
        if state.otherDeviceActive { return .otherDevice(lastUpdate: serverStatus?.lastRunAt) }
        guard let host else { return .waiting }
        let schedule = host.calendarSyncSchedule()
        if !schedule.bookableSlotsEnabled || Self.validZone(schedule) == nil { return .notShared }
        if let push = state.lastPush, push.shared {
            if now().timeIntervalSince(push.at) <= Double(NativeCalendarBusy.ttlHours) * 3600 {
                return .shared(updatedAt: push.at, days: push.days ?? min(schedule.slotWindowDays, NativeCalendarBusy.maxShareDays))
            }
            return .outOfDate
        }
        if let status = serverStatus, status.enabled, !effectiveFresh(status) { return .outOfDate }
        return .waiting
    }

    /// The Settings hub subtitle; `warning` marks a state that needs the owner.
    var hubSubtitle: (text: String, warning: Bool) {
        activateIfNeeded()
        if state.checksEnabled {
            switch statusLine {
            case .accessNeeded?: return ("Calendar access is off", true)
            case .shared?: return ("Busy times shared", false)
            case .outOfDate?: return ("Out of date: booking is request-only", true)
            case .otherDevice?: return ("Checks run on another device", false)
            case .notShared?: return ("On · not shared while time slots are off", false)
            case .unavailable?: return ("Not available yet", false)
            case .waiting?, nil: return ("On", false)
            }
        }
        if state.mirrorEnabled {
            return authorization.isUsable ? ("Jobs added to your calendar", false) : ("Calendar access is off", true)
        }
        return ("Off", false)
    }

    /// The Today row (§4.5): only while slots are on and the server says
    /// checks are enabled but not fresh.
    var staleTodayMessage: String? {
        activateIfNeeded()
        guard let host, let status = serverStatus else { return nil }
        return NativeTodayBriefing.calendarChecksStaleMessage(
            slotsOn: host.calendarSyncSchedule().bookableSlotsEnabled,
            checksEnabled: status.enabled,
            fresh: effectiveFresh(status),
            lastRunAt: status.lastRunAt)
    }

    /// Server freshness, re-checked against the clock (a cached status ages).
    func effectiveFresh(_ status: NativeCalendarBusy.ServerStatus) -> Bool {
        guard status.fresh, let last = status.lastRunAt else { return false }
        return now().timeIntervalSince(last) <= Double(NativeCalendarBusy.ttlHours) * 3600
    }

    /// Personal busy blocks for the in-app calendar (no titles); empty unless
    /// checks are on and calendar access is granted.
    func personalBusyBlocks() -> [NativeCalendar.PersonalBusyBlock] {
        activateIfNeeded()
        guard state.checksEnabled, authorization.isUsable else { return [] }
        return overlay.compactMap { window in
            guard let s = NativeSchedule.toMinutes(window.start), let e = NativeSchedule.toMinutes(window.end) else { return nil }
            // The gate encodes a day's end of 24:00 as 23:59; show it as midnight.
            return NativeCalendar.PersonalBusyBlock(date: window.date, startMinutes: s, endMinutes: e == 23 * 60 + 59 ? 24 * 60 : e)
        }
    }

    func clearError() {
        errorMessage = nil
        notify()
    }

    func dismissNotice() {
        activateIfNeeded()
        guard state.notice != nil else { return }
        state.notice = nil
        persist()
        notify()
    }

    // MARK: User actions (the settings page confirms before calling)

    /// "Check my calendars for busy times": the system prompt, the
    /// birthday/subscribed defaults, a new install id, then a push.
    func enableChecks() async -> EnableOutcome {
        guard let owner = host?.calendarSyncOwner(), let access else { return .unavailableOnDevice }
        activate(owner)
        beginBusy()
        defer { endBusy() }
        let granted = await access.requestFullAccess()
        guard isCurrent(owner) else { return .denied }
        state.explainerShown = true
        guard granted.isUsable else {
            persist()
            return .denied
        }
        refreshCalendarList()
        state.checksEnabled = true
        state.otherDeviceActive = false
        state.lastPush = nil
        if state.notice == .checksTurnedOffElsewhere || state.notice == .checksMovedToAnotherDevice { state.notice = nil }
        ensureSourceID()
        persist()
        startObservingIfNeeded()
        await syncInbound(owner: owner, force: true, scheduleOverride: nil)
        return .enabled
    }

    /// Turning checks off (after "Your booking page will stop checking your
    /// personal calendar"): `disable` deletes the owner's row from any device.
    @discardableResult
    func disableChecks() async -> Bool {
        guard let owner = host?.calendarSyncOwner() else { return false }
        activate(owner)
        beginBusy()
        defer { endBusy() }
        if let transport, let credentials = host?.calendarSyncCredentials() {
            let result = await transport.disable(credentials: credentials)
            guard isCurrent(owner) else { return false }
            switch result {
            case .ok, .unavailable:
                break
            default:
                errorMessage = "Calendar checks couldn't be turned off. Check your connection and try again."
                return false
            }
        }
        state.checksEnabled = false
        state.lastPush = nil
        state.otherDeviceActive = false
        overlay = []
        serverStatus = serverStatus.map {
            .init(enabled: false, thisDevice: false, shared: false, fresh: false, computedAt: nil, receivedAt: $0.receivedAt)
        }
        persist()
        stopObservingIfIdle()
        return true
    }

    /// "Use this device": takes over as the source (`takeOver: true`).
    @discardableResult
    func useThisDevice() async -> Bool {
        guard let owner = host?.calendarSyncOwner(), access != nil else { return false }
        activate(owner)
        if !state.checksEnabled || !authorization.isUsable {
            guard await enableChecks() == .enabled else { return false }
        }
        guard isCurrent(owner), let host, let credentials = host.calendarSyncCredentials() else { return false }
        beginBusy()
        defer { endBusy() }
        let schedule = host.calendarSyncSchedule()
        let built = buildSnapshots(schedule: schedule, owner: owner)
        let sharing = built.share != nil && schedule.bookableSlotsEnabled
        let result = await push(owner: owner, snapshot: sharing ? built.share : nil, takeOver: true, credentials: credentials)
        guard case .ok = result else {
            if errorMessage == nil {
                errorMessage = "This device couldn't take over calendar checks. Check your connection and try again."
            }
            return false
        }
        if state.notice == .checksMovedToAnotherDevice { state.notice = nil; persist() }
        return true
    }

    /// Include or exclude one calendar, then push.
    func setCalendar(_ id: String, included: Bool) async {
        guard let owner = host?.calendarSyncOwner() else { return }
        activate(owner)
        var excluded = Set(state.excludedCalendarIDs)
        if included { excluded.remove(id) } else { excluded.insert(id) }
        state.excludedCalendarIDs = excluded.sorted()
        persist()
        notify()
        await syncInbound(owner: owner, force: false, scheduleOverride: nil)
        notify()
    }

    /// "Add my jobs to a TradeReady calendar".
    func enableMirror() async -> MirrorEnableOutcome {
        guard let owner = host?.calendarSyncOwner(), let access else { return .failed }
        activate(owner)
        beginBusy()
        defer { endBusy() }
        let granted = await access.requestFullAccess()
        guard isCurrent(owner) else { return .failed }
        guard granted.isUsable else { return .denied }
        var lookup = access.findMirrorCalendar(storedID: state.mirrorCalendarID)
        if lookup == .missing {
            // No calendars readable (for example, protected data unavailable):
            // adopting or creating now could duplicate or mis-adopt.
            guard !access.calendars().isEmpty else {
                errorMessage = "Calendars couldn't be read right now. Try again in a moment."
                return .failed
            }
            if let adopted = adoptableMirrorCalendar(access: access, owner: owner) {
                lookup = adopted
            } else {
                do { lookup = try access.createMirrorCalendar() } catch {
                    errorMessage = "The TradeReady calendar couldn't be created. Check that a calendar account on this device accepts new calendars."
                    return .failed
                }
            }
        }
        guard case let .found(id, accountTitle) = lookup else { return .failed }
        state.mirrorEnabled = true
        state.mirrorCalendarID = id
        state.mirrorAccountTitle = accountTitle
        if state.notice == .mirrorCalendarDeleted { state.notice = nil }
        persist()
        startObservingIfNeeded()
        await syncMirror(owner: owner)
        return .enabled(accountTitle: accountTitle)
    }

    /// Turning the mirror off: "Remove calendar" (the default; removes it from
    /// every device on that account) or "Keep calendar".
    @discardableResult
    func disableMirror(removeCalendar: Bool) async -> Bool {
        guard let owner = host?.calendarSyncOwner() else { return false }
        activate(owner)
        beginBusy()
        defer { endBusy() }
        if removeCalendar, let id = state.mirrorCalendarID, let access {
            switch removeMirrorContents(access: access, calendarID: id, owner: owner) {
            case .removedCalendar:
                break
            case .removedOwnEventsOnly:
                errorMessage = "TradeReady removed the jobs it added. The calendar was kept because it also holds events TradeReady didn't add."
            case .unreadable:
                errorMessage = "The TradeReady calendar couldn't be removed because calendars couldn't be read right now. Try again in a moment."
                return false
            case .failed:
                errorMessage = "The TradeReady calendar couldn't be removed. Check calendar access in Settings and try again."
                return false
            }
        }
        state.mirrorEnabled = false
        mirrorError = nil
        if removeCalendar {
            state.mirrorCalendarID = nil
            state.mirrorAccountTitle = nil
        }
        persist()
        stopObservingIfIdle()
        return true
    }

    /// Order on enable (§4.4): a schedule save that turns slots on awaits a
    /// push for the new schedule before the settings change is queued.
    /// Offline, both queue (R6).
    func prepareForSlotsEnable(schedule: NativeSchedule.ResolvedSchedule) async {
        guard let owner = host?.calendarSyncOwner() else { return }
        activate(owner)
        guard state.checksEnabled, authorization.isUsable else { return }
        await syncInbound(owner: owner, force: true, scheduleOverride: schedule)
        notify()
    }

    /// Whether a schedule save must wait for a push (checks on here).
    var wantsPushBeforeSlotsEnable: Bool {
        activateIfNeeded()
        return state.checksEnabled && !state.otherDeviceActive && authorization.isUsable && transport != nil
    }

    // MARK: Inbound

    private func syncInbound(owner: NativeCalendarSyncOwner, force: Bool,
                             scheduleOverride: NativeSchedule.ResolvedSchedule?) async {
        guard state.checksEnabled, let host else {
            overlay = []
            return
        }
        let schedule = scheduleOverride ?? host.calendarSyncSchedule()
        let built = buildSnapshots(schedule: schedule, owner: owner)
        overlay = built.overlay
        // Access granted but no calendars readable (for example, protected
        // data not yet available): keep the last snapshot and let it age out
        // (fail closed) rather than share an empty, all-free calendar.
        if authorization.isUsable && !built.readable { return }
        guard transport != nil, !state.otherDeviceActive, let credentials = host.calendarSyncCredentials() else { return }
        ensureSourceID()
        let sharing = schedule.bookableSlotsEnabled && built.share != nil
        if sharing, let snapshot = built.share {
            let digest = NativeCalendarBusy.digest(snapshot)
            let last = state.lastPush
            let due = force || last?.shared != true || last?.digest != digest
                || (last.map { now().timeIntervalSince($0.at) >= NativeCalendarBusy.heartbeatSeconds } ?? true)
            guard due else { return }
            _ = await push(owner: owner, snapshot: snapshot, takeOver: false, credentials: credentials)
        } else {
            // One null put on the transition (and on a forced enable).
            guard force || state.lastPush?.shared != false else { return }
            _ = await push(owner: owner, snapshot: nil, takeOver: false, credentials: credentials)
        }
    }

    /// The share snapshot (nil unless the owner zone is valid and access is
    /// granted) and the overlay windows, from one EventKit read. `readable`
    /// is false when access is granted but no calendar can be read. Only
    /// `owner`'s own mirrored jobs are left out (by their marker's tag).
    private func buildSnapshots(schedule: NativeSchedule.ResolvedSchedule, owner: NativeCalendarSyncOwner)
        -> (share: NativeCalendarBusy.Snapshot?, overlay: [NativeAvailability.BusyWindow], readable: Bool) {
        guard let access, access.authorization.isUsable else { return (nil, [], false) }
        guard !access.calendars().isEmpty else { return (nil, [], false) }
        let shareZone = Self.validZone(schedule)
        let overlayZone = shareZone ?? TimeZone.current.identifier
        let current = now()
        guard let overlayWindow = NativeCalendarBusy.window(now: current, timeZoneID: overlayZone, days: Self.overlayDays) else {
            return (nil, [], true)
        }
        let samples = NativeCalendarBusy.busySamples(
            access.samples(start: overlayWindow.start, end: overlayWindow.end),
            excludedCalendarIDs: Set(state.excludedCalendarIDs),
            mirrorCalendarID: state.mirrorCalendarID,
            mirrorOwnerTag: NativeCalendarMirror.ownerTag16(subject: owner.subject))
        let calendar = deviceCalendar()
        let overlaySnapshot = NativeCalendarBusy.makeSnapshot(samples: samples, window: overlayWindow, computedAt: current, calendar: calendar)
        let nowMillis = Int64((current.timeIntervalSince1970 * 1000).rounded(.down))
        let overlay = NativeCalendarBusy.overlayWindows(overlaySnapshot, timeZoneID: overlayZone, nowMillis: nowMillis)
        guard let shareZone,
              let shareWindow = NativeCalendarBusy.window(now: current, timeZoneID: shareZone, days: schedule.slotWindowDays)
        else { return (nil, overlay, true) }
        return (NativeCalendarBusy.makeSnapshot(samples: samples, window: shareWindow, computedAt: current, calendar: calendar), overlay, true)
    }

    private func push(owner: NativeCalendarSyncOwner, snapshot: NativeCalendarBusy.Snapshot?, takeOver: Bool,
                      credentials: NativeCalendarSyncCredentials) async -> NativeCalendarSyncOutcome<NativeCalendarPutResult> {
        guard let transport else { return .invalid }
        let sourceID = ensureSourceID()
        let hadPushed = state.lastPush != nil
        let result = await transport.put(sourceID: sourceID, snapshotJSON: snapshot.map(NativeCalendarBusy.encode),
                                         takeOver: takeOver, credentials: credentials)
        guard isCurrent(owner) else { return result }
        switch result {
        case let .ok(put):
            isUnavailable = false
            if put.created && hadPushed && !takeOver {
                // The row this device kept was removed elsewhere since its last
                // put: checks were turned off on another device. Honor that.
                _ = await transport.disable(credentials: credentials)
                guard isCurrent(owner) else { return result }
                state.checksEnabled = false
                state.lastPush = nil
                state.otherDeviceActive = false
                state.notice = .checksTurnedOffElsewhere
                overlay = []
                serverStatus = nil
            } else {
                let at = now()
                let days = snapshot.flatMap { snap -> Int? in
                    guard let s = NativeCalendarBusy.parseInstant(snap.windowStart), let e = NativeCalendarBusy.parseInstant(snap.windowEnd) else { return nil }
                    return Int((e - s) / 86_400_000)
                }
                state.lastPush = .init(digest: snapshot.map(NativeCalendarBusy.digest), at: at, shared: snapshot != nil, days: days)
                state.otherDeviceActive = false
                serverStatus = .init(enabled: true, thisDevice: true, shared: snapshot != nil, fresh: snapshot != nil,
                                     computedAt: snapshot != nil ? at : nil, receivedAt: put.receivedAt ?? at)
                statusFetchedAt = at
            }
            persist()
        case let .sourceMismatch(receivedAt):
            state.otherDeviceActive = true
            persist()
            serverStatus = .init(enabled: true, thisDevice: false, shared: serverStatus?.shared ?? true,
                                 fresh: serverStatus?.fresh ?? true, computedAt: serverStatus?.computedAt, receivedAt: receivedAt)
            statusFetchedAt = nil
        case .unavailable:
            isUnavailable = true
        case .invalid:
            errorMessage = "TradeReady couldn't share your busy times. It will try again later."
        case .offline, .unauthorized:
            break
        }
        return result
    }

    // MARK: Status

    private func refreshStatusIfDue(owner: NativeCalendarSyncOwner, trigger: Trigger) async {
        guard let host, let transport, host.calendarSyncSchedule().bookableSlotsEnabled else { return }
        let interval: TimeInterval
        switch trigger {
        case .foreground: interval = Self.statusInterval
        case .settingsScreen, .userAction: interval = Self.settingsStatusInterval
        default: return
        }
        if let at = statusFetchedAt, now().timeIntervalSince(at) < interval { return }
        guard let credentials = host.calendarSyncCredentials() else { return }
        statusFetchedAt = now()
        let result = await transport.status(sourceID: state.sourceID, credentials: credentials)
        guard isCurrent(owner) else { return }
        switch result {
        case let .ok(status):
            isUnavailable = false
            serverStatus = status
            if !status.enabled, state.checksEnabled, state.lastPush != nil || state.otherDeviceActive {
                state.checksEnabled = false
                state.lastPush = nil
                state.otherDeviceActive = false
                state.notice = .checksTurnedOffElsewhere
                overlay = []
                persist()
            } else if status.enabled, !status.thisDevice, state.checksEnabled, !state.otherDeviceActive, state.lastPush != nil {
                state.otherDeviceActive = true
                state.notice = .checksMovedToAnotherDevice
                persist()
            }
        case .unavailable:
            isUnavailable = true
        default:
            statusFetchedAt = nil
        }
    }

    // MARK: Mirror (Stage B)

    private func syncMirror(owner: NativeCalendarSyncOwner) async {
        guard state.mirrorEnabled, let access, access.authorization.isUsable, let host else { return }
        switch access.findMirrorCalendar(storedID: state.mirrorCalendarID) {
        case .missing:
            // No calendars readable (for example, protected data not yet
            // available) is temporary: keep the mirror on and try again.
            let readable = access.calendars()
            guard !readable.isEmpty else { return }
            // Present but not writable: not deleted, so it stays on.
            if let id = state.mirrorCalendarID, readable.contains(where: { $0.id == id }) {
                mirrorError = "The TradeReady calendar can't be edited right now. TradeReady will try again."
                return
            }
            // Readable and the stored id is genuinely absent: deleted outside
            // the app. The mirror turns off with a notice and is never
            // silently recreated (D15).
            state.mirrorEnabled = false
            state.mirrorCalendarID = nil
            state.mirrorAccountTitle = nil
            state.notice = .mirrorCalendarDeleted
            persist()
            stopObservingIfIdle()
        case let .found(id, accountTitle):
            if state.mirrorCalendarID != id || state.mirrorAccountTitle != accountTitle {
                state.mirrorCalendarID = id
                state.mirrorAccountTitle = accountTitle
                persist()
            }
            let calendar = deviceCalendar()
            let current = now()
            let today = NativeCalendarBusy.naiveDate(current, calendar: calendar)
            let midnight = calendar.startOfDay(for: current)
            // Jobs are wanted by schedule-zone date but fetched by device-zone
            // instants. Two zones are at most 26 hours apart, so a day of
            // margin is not enough: widen by `fetchMarginDays` each side. The
            // planner matches by job id, so extra events do no harm.
            let margin = Self.fetchMarginDays
            guard let start = calendar.date(byAdding: .day, value: -(NativeCalendarMirror.windowPastDays + margin), to: midnight),
                  let end = calendar.date(byAdding: .day, value: NativeCalendarMirror.windowFutureDays + 1 + margin, to: midnight) else { return }
            let ownerTag = NativeCalendarMirror.ownerTag16(subject: owner.subject)
            let existing = access.mirrorEvents(calendarID: id, start: start, end: end)
            let desired = NativeCalendarMirror.desiredEvents(
                jobs: host.calendarSyncJobs(), schedule: host.calendarSyncSchedule(), today: today, ownerTag: ownerTag)
            let operations = NativeCalendarMirror.plan(desired: desired, existing: existing, ownerTag: ownerTag, today: today)
            guard !operations.isEmpty else {
                mirrorError = nil
                return
            }
            do {
                try access.apply(operations, calendarID: id)
                lastCommitAt = now()
                mirrorError = nil
                if operations.count >= NativeCalendarMirror.maxOperations { snapshotDidChange() }
            } catch {
                mirrorError = "Some jobs couldn't be added to the TradeReady calendar. TradeReady will try again."
            }
        }
    }

    // MARK: Mirror ownership (adopt / remove)

    /// The existing calendar this account may adopt, or nil. Nothing is
    /// adopted by title: every candidate's events are read and
    /// `NativeCalendarMirror.adoptableCalendarID` accepts one only when all of
    /// them carry this account's tag.
    private func adoptableMirrorCalendar(access: NativeCalendarAccess, owner: NativeCalendarSyncOwner) -> NativeMirrorCalendarLookup? {
        let (from, to) = ownershipScanWindow()
        let infos = access.calendars().filter { $0.allowsModifications && NativeCalendarMirror.isMirrorCalendarTitle($0.title) }
        let candidates = infos.map {
            NativeCalendarMirror.CalendarCandidate(
                id: $0.id, title: $0.title, allowsModifications: $0.allowsModifications,
                events: access.mirrorEvents(calendarID: $0.id, start: from, end: to))
        }
        guard let id = NativeCalendarMirror.adoptableCalendarID(
            candidates: candidates, ownerTag: NativeCalendarMirror.ownerTag16(subject: owner.subject)),
            let info = infos.first(where: { $0.id == id }) else { return nil }
        return .found(id: id, accountTitle: info.accountTitle)
    }

    private enum MirrorRemoval {
        case removedCalendar
        case removedOwnEventsOnly
        case unreadable
        case failed
    }

    /// "Remove calendar" and account deletion: the whole calendar goes only
    /// when every event in it carries this account's tag. Otherwise only this
    /// account's events are deleted and the calendar stays. Calendars that
    /// can't be read right now remove nothing.
    private func removeMirrorContents(access: NativeCalendarAccess, calendarID: String, owner: NativeCalendarSyncOwner) -> MirrorRemoval {
        guard !access.calendars().isEmpty else { return .unreadable }
        let (from, to) = ownershipScanWindow()
        let events = access.mirrorEvents(calendarID: calendarID, start: from, end: to)
        do {
            switch NativeCalendarMirror.removalDecision(events: events, ownerTag: NativeCalendarMirror.ownerTag16(subject: owner.subject)) {
            case .removeCalendar:
                try access.removeMirrorCalendar(calendarID: calendarID)
                return .removedCalendar
            case let .deleteEvents(ids):
                if !ids.isEmpty {
                    try access.apply(ids.map { .delete(eventID: $0) }, calendarID: calendarID)
                    lastCommitAt = now()
                }
                return .removedOwnEventsOnly
            }
        } catch {
            return .failed
        }
    }

    private func ownershipScanWindow() -> (Date, Date) {
        let current = now()
        let span = Double(NativeCalendarMirror.ownershipScanYears) * 366 * 86_400
        return (current.addingTimeInterval(-span), current.addingTimeInterval(span))
    }

    // MARK: Helpers

    private func activate(_ owner: NativeCalendarSyncOwner) {
        guard stateBinding != owner.binding else { return }
        resetMemory()
        stateBinding = owner.binding
        state = stateStore.load(binding: owner.binding)
    }

    private func resetMemory() {
        mirrorTask?.cancel()
        changeTask?.cancel()
        mirrorTask = nil
        changeTask = nil
        state = NativeCalendarSyncLocalState()
        stateBinding = nil
        serverStatus = nil
        statusFetchedAt = nil
        isUnavailable = false
        errorMessage = nil
        mirrorError = nil
        overlay = []
        calendarList = []
        lastCommitAt = nil
        rerunTrigger = nil
    }

    private func isCurrent(_ owner: NativeCalendarSyncOwner) -> Bool {
        host?.calendarSyncOwner() == owner && stateBinding == owner.binding
    }

    private func persist() {
        guard let stateBinding else { return }
        stateStore.save(state, binding: stateBinding)
    }

    private func notify() {
        host?.calendarSyncDidChange()
    }

    private func beginBusy() {
        isBusy = true
        errorMessage = nil
        notify()
    }

    private func endBusy() {
        isBusy = false
        notify()
    }

    /// Refreshes the calendar list and applies the birthday/subscribed
    /// default to calendars seen for the first time.
    private func refreshCalendarList() {
        guard let access, access.authorization.isUsable else {
            calendarList = []
            return
        }
        calendarList = access.calendars().sorted {
            $0.accountTitle != $1.accountTitle ? $0.accountTitle < $1.accountTitle : $0.title < $1.title
        }
        guard stateBinding != nil else { return }
        var seen = Set(state.seenCalendarIDs)
        var excluded = Set(state.excludedCalendarIDs)
        var changed = false
        for calendar in calendarList where !seen.contains(calendar.id) {
            seen.insert(calendar.id)
            if calendar.excludedByDefault { excluded.insert(calendar.id) }
            changed = true
        }
        if changed {
            state.seenCalendarIDs = seen.sorted()
            state.excludedCalendarIDs = excluded.sorted()
            persist()
        }
    }

    @discardableResult
    private func ensureSourceID() -> String {
        if let id = state.sourceID, NativeCalendarSyncTransport.isSourceID(id) { return id }
        let id = Self.makeSourceID()
        state.sourceID = id
        persist()
        return id
    }

    /// A random UUIDv4 from `SecRandomCopyBytes` (§2.1): never derived from
    /// device or user data.
    static func makeSourceID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        #if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return UUID().uuidString.lowercased()
        }
        #else
        return UUID().uuidString.lowercased()
        #endif
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let i = hex.startIndex
        func part(_ a: Int, _ b: Int) -> Substring { hex[hex.index(i, offsetBy: a)..<hex.index(i, offsetBy: b)] }
        return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
    }

    static func validZone(_ schedule: NativeSchedule.ResolvedSchedule) -> String? {
        guard let zone = schedule.timeZone, NativeAvailability.isValidIANAZone(zone) else { return nil }
        return zone
    }

    private func startObservingIfNeeded() {
        guard !isObserving, state.checksEnabled || state.mirrorEnabled, let access, access.authorization.isUsable else { return }
        isObserving = true
        access.startObservingChanges { [weak self] in self?.calendarStoreChanged() }
    }

    private func stopObservingIfIdle() {
        if !state.checksEnabled && !state.mirrorEnabled { stopObserving() }
    }

    private func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        access?.stopObservingChanges()
    }
}
