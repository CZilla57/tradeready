import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// The calendar access seam for calendar sync (Roadmap Phase 26, spec
/// `docs/superpowers/specs/2026-10-03-calendar-sync-design.md` §4.2).
///
/// `NativeCalendarAccess` is what the coordinator talks to; host tests inject
/// a fake, so no test ever touches real EventKit (or its permission prompt).
/// The live adapter below maps `EKEvent`s into the pure value types of
/// `NativeCalendarBusy` and `NativeCalendarMirror` and back.
///
/// Authorization: iOS 17 access levels. `.fullAccess` is the only usable
/// state; `.writeOnly` is treated as denied (it cannot read events back and
/// cannot occur without the write-only usage key, which the app does not
/// declare); `.denied` and `.restricted` show an Open Settings link.

enum NativeCalendarAuthorization: String, Equatable, Sendable {
    case notDetermined
    case fullAccess
    case denied
    case restricted

    var isUsable: Bool { self == .fullAccess }
}

/// One calendar the owner can include or exclude.
struct NativeCalendarInfo: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case standard, birthday, subscription
    }

    let id: String
    let title: String
    /// The account it lives in ("iCloud", "Gmail", "On My iPhone").
    let accountTitle: String
    let kind: Kind
    let allowsModifications: Bool

    /// Birthday and subscribed (holiday, sports) calendars start excluded (D7).
    var excludedByDefault: Bool { kind != .standard }
}

/// Where the TradeReady mirror calendar is.
enum NativeMirrorCalendarLookup: Equatable, Sendable {
    case found(id: String, accountTitle: String)
    case missing
}

enum NativeCalendarAccessError: Error, Equatable {
    case notAuthorized
    case noWritableSource
    case calendarMissing
    case saveFailed
}

@MainActor
protocol NativeCalendarAccess: AnyObject {
    var authorization: NativeCalendarAuthorization { get }
    /// Shows the system prompt when undetermined; answers the resulting state.
    func requestFullAccess() async -> NativeCalendarAuthorization
    /// Every event calendar on the device.
    func calendars() -> [NativeCalendarInfo]
    /// Event occurrences overlapping [start, end) across every calendar
    /// (recurring events arrive expanded; the domain applies exclusions).
    func samples(start: Date, end: Date) -> [NativeCalendarBusy.Sample]
    /// Finds the mirror calendar by its stored identifier ONLY, among writable
    /// calendars. Never by title (a calendar that merely shares the title is
    /// not this account's: adoption goes through `calendars()`, `mirrorEvents`
    /// and `NativeCalendarMirror.adoptableCalendarID`). Never creates one.
    func findMirrorCalendar(storedID: String?) -> NativeMirrorCalendarLookup
    /// Creates the mirror calendar (iCloud source when present, else the
    /// default calendar's source, else Local). The title comes from
    /// `NativeCalendarMirror.newCalendarTitle`, so it never collides with an
    /// existing calendar.
    func createMirrorCalendar() throws -> NativeMirrorCalendarLookup
    /// Every event of the calendar overlapping [start, end) (any calendar id,
    /// any window; ranges over EventKit's 4-year predicate limit are read in
    /// slices). Not limited to events starting inside the window: the planner
    /// matches events to jobs by the job id in their marker.
    func mirrorEvents(calendarID: String, start: Date, end: Date) -> [NativeCalendarMirror.Existing]
    /// Applies a reconcile plan: every save with `commit: false`, then one commit.
    func apply(_ operations: [NativeCalendarMirror.Operation], calendarID: String) throws
    /// Deletes the calendar (and its events) from the account. The caller has
    /// already established, with `NativeCalendarMirror.removalDecision`, that
    /// every event in it is this account's.
    func removeMirrorCalendar(calendarID: String) throws
    /// `EKEventStoreChanged` while observing; the handler runs on the main actor.
    func startObservingChanges(_ handler: @escaping @MainActor () -> Void)
    func stopObservingChanges()
}

#if canImport(EventKit)

@MainActor
final class NativeEventKitCalendarAccess: NativeCalendarAccess {
    /// Created on first use: the launch path only reads the static status.
    private lazy var store = EKEventStore()
    private var observer: NSObjectProtocol?

    var authorization: NativeCalendarAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    static func map(_ status: EKAuthorizationStatus) -> NativeCalendarAuthorization {
        switch status {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        // `.writeOnly` cannot read events back, so it is unusable (§4.2).
        case .denied, .writeOnly: .denied
        default: .denied
        }
    }

    func requestFullAccess() async -> NativeCalendarAuthorization {
        guard authorization == .notDetermined else { return authorization }
        _ = try? await store.requestFullAccessToEvents()
        store.reset()
        return authorization
    }

    func calendars() -> [NativeCalendarInfo] {
        guard authorization.isUsable else { return [] }
        return store.calendars(for: .event).map { calendar in
            let kind: NativeCalendarInfo.Kind
            switch calendar.type {
            case .birthday: kind = .birthday
            case .subscription: kind = .subscription
            default: kind = .standard
            }
            return NativeCalendarInfo(id: calendar.calendarIdentifier, title: calendar.title,
                                      accountTitle: calendar.source?.title ?? "Other",
                                      kind: kind, allowsModifications: calendar.allowsContentModifications)
        }
    }

    func samples(start: Date, end: Date) -> [NativeCalendarBusy.Sample] {
        guard authorization.isUsable, start < end else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
            let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            return NativeCalendarBusy.Sample(
                start: startDate, end: endDate, isAllDay: event.isAllDay,
                availability: Self.map(event.availability), status: Self.map(event.status),
                ownerDeclined: declined, calendarID: event.calendar?.calendarIdentifier ?? "",
                notes: event.notes)
        }
    }

    private static func map(_ availability: EKEventAvailability) -> NativeCalendarBusy.Availability {
        switch availability {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        default: .notSupported
        }
    }

    private static func map(_ status: EKEventStatus) -> NativeCalendarBusy.Status {
        switch status {
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .canceled
        default: .none
        }
    }

    // MARK: Mirror calendar

    func findMirrorCalendar(storedID: String?) -> NativeMirrorCalendarLookup {
        guard authorization.isUsable, let storedID,
              let calendar = store.calendar(withIdentifier: storedID), calendar.allowsContentModifications else { return .missing }
        return .found(id: calendar.calendarIdentifier, accountTitle: calendar.source?.title ?? "Other")
    }

    func createMirrorCalendar() throws -> NativeMirrorCalendarLookup {
        guard authorization.isUsable else { throw NativeCalendarAccessError.notAuthorized }
        let title = NativeCalendarMirror.newCalendarTitle(existingTitles: store.calendars(for: .event).map(\.title))
        let iCloud = store.sources.first { $0.sourceType == .calDAV && $0.title.lowercased() == "icloud" }
        let fallback = store.defaultCalendarForNewEvents?.source
        let local = store.sources.first { $0.sourceType == .local }
        var tried = Set<String>()
        for source in [iCloud, fallback, local].compactMap({ $0 }) where tried.insert(source.sourceIdentifier).inserted {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = title
            calendar.source = source
            do {
                try store.saveCalendar(calendar, commit: true)
                return .found(id: calendar.calendarIdentifier, accountTitle: source.title)
            } catch {
                continue
            }
        }
        throw NativeCalendarAccessError.noWritableSource
    }

    func mirrorEvents(calendarID: String, start: Date, end: Date) -> [NativeCalendarMirror.Existing] {
        guard authorization.isUsable, let calendar = store.calendar(withIdentifier: calendarID), start < end else { return [] }
        // EventKit truncates a predicate to 4 years: read longer ranges in slices.
        let slice: TimeInterval = 3 * 365 * 86_400
        var seen = Set<String>()
        var out: [NativeCalendarMirror.Existing] = []
        var from = start
        while from < end {
            let to = min(from.addingTimeInterval(slice), end)
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
            for event in store.events(matching: predicate) {
                guard let startDate = event.startDate, let fields = Self.fields(of: event),
                      let eventID = event.eventIdentifier, !eventID.isEmpty,
                      seen.insert("\(eventID)|\(startDate.timeIntervalSince1970)").inserted else { continue }
                out.append(NativeCalendarMirror.Existing(
                    eventID: eventID,
                    externalID: event.calendarItemExternalIdentifier,
                    creationDate: event.creationDate,
                    notes: event.notes,
                    fields: fields))
            }
            from = to
        }
        return out
    }

    /// Reads an event back into the planner's naive fields: zoned events in
    /// their own zone, floating and all-day events in the device zone.
    private static func fields(of event: EKEvent) -> NativeCalendarMirror.Fields? {
        guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = (event.isAllDay ? nil : event.timeZone) ?? .current
        func naive(_ date: Date) -> NativeCalendarMirror.NaiveDateTime {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return .init(date: String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                         minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }
        let start: NativeCalendarMirror.NaiveDateTime
        let end: NativeCalendarMirror.NaiveDateTime
        if event.isAllDay {
            // EventKit may report the last day's end either as the next
            // midnight or as 23:59:59; endDate − 1 s lands on the last day.
            let first = naive(startDate).date
            let last = naive(endDate.addingTimeInterval(-1)).date
            start = .init(date: first, minutes: 0)
            end = .init(date: NativeSchedule.shiftNaiveDate(last, days: 1) ?? last, minutes: 0)
        } else {
            start = naive(startDate)
            end = naive(endDate)
        }
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NativeCalendarMirror.Fields(
            title: event.title ?? "",
            location: (location?.isEmpty ?? true) ? nil : location,
            notes: event.notes ?? "",
            url: event.url?.absoluteString ?? "",
            isAllDay: event.isAllDay,
            start: start,
            end: end,
            timeZoneID: event.isAllDay ? nil : event.timeZone?.identifier)
    }

    func apply(_ operations: [NativeCalendarMirror.Operation], calendarID: String) throws {
        guard authorization.isUsable else { throw NativeCalendarAccessError.notAuthorized }
        guard let calendar = store.calendar(withIdentifier: calendarID) else { throw NativeCalendarAccessError.calendarMissing }
        do {
            for operation in operations {
                switch operation {
                case let .create(desired):
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    Self.write(desired.fields, to: event)
                    try store.save(event, span: .thisEvent, commit: false)
                case let .update(eventID, desired):
                    guard let event = store.event(withIdentifier: eventID), Self.isMirrorEvent(event, in: calendarID) else { continue }
                    Self.write(desired.fields, to: event)
                    try store.save(event, span: .thisEvent, commit: false)
                case let .delete(eventID):
                    guard let event = store.event(withIdentifier: eventID), Self.isMirrorEvent(event, in: calendarID) else { continue }
                    try store.remove(event, span: .thisEvent, commit: false)
                }
            }
            try store.commit()
        } catch {
            store.reset()
            throw NativeCalendarAccessError.saveFailed
        }
    }

    /// Last line of defence before an edit or delete: the event is in the
    /// mirror calendar and carries a mirror marker. The planner already
    /// limits every operation to events with this account's tag.
    private static func isMirrorEvent(_ event: EKEvent, in calendarID: String) -> Bool {
        event.calendar?.calendarIdentifier == calendarID && NativeCalendarMirror.parseMarker(event.notes) != nil
    }

    private static func write(_ fields: NativeCalendarMirror.Fields, to event: EKEvent) {
        let zone = fields.timeZoneID.flatMap(TimeZone.init(identifier:))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = (fields.isAllDay ? nil : zone) ?? .current
        func date(_ value: NativeCalendarMirror.NaiveDateTime) -> Date? {
            guard let (y, m, d) = NativeSchedule.parseDateComponents(value.date) else { return nil }
            return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: value.minutes / 60, minute: value.minutes % 60))
        }
        event.title = fields.title
        event.location = fields.location
        event.notes = fields.notes
        event.url = URL(string: fields.url)
        event.isAllDay = fields.isAllDay
        // Floating (nil) unless the schedule zone pins it (§2.5).
        event.timeZone = fields.isAllDay ? nil : zone
        if let start = date(fields.start) { event.startDate = start }
        if let end = date(fields.end) { event.endDate = end }
        event.availability = .busy
        // The app's own appointment reminders already exist (§2.5).
        event.alarms = nil
    }

    func removeMirrorCalendar(calendarID: String) throws {
        guard authorization.isUsable else { throw NativeCalendarAccessError.notAuthorized }
        guard let calendar = store.calendar(withIdentifier: calendarID) else { return }
        do {
            try store.removeCalendar(calendar, commit: true)
        } catch {
            throw NativeCalendarAccessError.saveFailed
        }
    }

    // MARK: Change observation

    func startObservingChanges(_ handler: @escaping @MainActor () -> Void) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in handler() }
        }
    }

    func stopObservingChanges() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

#endif
