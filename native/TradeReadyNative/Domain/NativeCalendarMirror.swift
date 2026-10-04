import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The "TradeReady" calendar mirror (Roadmap Phase 26 Stage B), the pure
/// half. Spec: `docs/superpowers/specs/2026-10-03-calendar-sync-design.md`
/// §2.5, §4.1.
///
/// One-way: jobs → events in the owner's own calendar account; TradeReady's
/// servers are not involved. Idempotency comes from a marker line in each
/// event's notes (`tradeready-job:<ownerTag16>:<jobId>`). Reconcile only ever
/// touches events whose marker carries this account's tag, so another
/// account signed in on the same device never edits or deletes them.
///
/// `desiredEvents` produces owner-naive dates and times plus an optional zone
/// id; the EventKit adapter turns those into `Date`s and reads existing events
/// back into the same naive `Fields`, so `plan` compares like with like.
public enum NativeCalendarMirror {

    public static let windowPastDays = 30
    public static let windowFutureDays = 180
    /// A pass applies at most this many operations; the rest wait for the next.
    public static let maxOperations = 200
    public static let calendarTitle = "TradeReady"
    public static let markerPrefix = NativeCalendarBusy.mirrorMarkerPrefix
    public static let managedNote = "Managed by TradeReady. Changes made here are replaced; edit the job in TradeReady."
    static let ownerTagPrefix = "tradeready.calendar-mirror.owner.v1:"

    /// The first 16 hex characters of a one-way tag of the account (the
    /// `NativeRejectedChangeStore.ownerTag` pattern with its own prefix). It is
    /// derived from the server user id, not the device-local binding, so
    /// every device signed in to the account writes the same tag and
    /// concurrent creates converge (§4.1).
    public static func ownerTag16(subject: String) -> String {
        #if canImport(CryptoKit)
        let full = SHA256.hash(data: Data((ownerTagPrefix + subject).utf8)).map { String(format: "%02x", $0) }.joined()
        return String(full.prefix(16))
        #else
        return String(subject.prefix(16))
        #endif
    }

    // MARK: - Values

    /// An owner-naive moment: a date and minutes since its midnight (0..<1440).
    public struct NaiveDateTime: Equatable, Comparable, Sendable {
        public var date: String
        public var minutes: Int
        public init(date: String, minutes: Int) {
            self.date = date
            self.minutes = minutes
        }
        public static func < (lhs: NaiveDateTime, rhs: NaiveDateTime) -> Bool {
            lhs.date != rhs.date ? lhs.date < rhs.date : lhs.minutes < rhs.minutes
        }
    }

    /// Every mirrored field. All-day events run from (date, 0) to (date + 1, 0)
    /// with no zone; timed events carry the schedule zone or float (nil).
    public struct Fields: Equatable, Sendable {
        public var title: String
        public var location: String?
        public var notes: String
        public var url: String
        public var isAllDay: Bool
        public var start: NaiveDateTime
        public var end: NaiveDateTime
        public var timeZoneID: String?

        public init(title: String, location: String?, notes: String, url: String, isAllDay: Bool,
                    start: NaiveDateTime, end: NaiveDateTime, timeZoneID: String?) {
            self.title = title
            self.location = location
            self.notes = notes
            self.url = url
            self.isAllDay = isAllDay
            self.start = start
            self.end = end
            self.timeZoneID = timeZoneID
        }
    }

    public struct DesiredEvent: Equatable, Sendable {
        public var jobID: String
        public var fields: Fields
    }

    /// An event already in the TradeReady calendar.
    public struct Existing: Equatable, Sendable {
        public var eventID: String
        /// `calendarItemExternalIdentifier`: the same on every device.
        public var externalID: String?
        public var creationDate: Date?
        /// The raw notes (the marker is parsed from them).
        public var notes: String?
        public var fields: Fields

        public init(eventID: String, externalID: String?, creationDate: Date?, notes: String?, fields: Fields) {
            self.eventID = eventID
            self.externalID = externalID
            self.creationDate = creationDate
            self.notes = notes
            self.fields = fields
        }
    }

    public enum Operation: Equatable, Sendable {
        case create(DesiredEvent)
        case update(eventID: String, DesiredEvent)
        case delete(eventID: String)
    }

    // MARK: - Jobs → desired events

    /// Mirrored: not archived, a valid `scheduledDate` in
    /// [today − 30, today + 180], status not `declined` (completed, invoiced
    /// and paid jobs stay as history).
    public static func desiredEvents<Job: MirrorJobLike>(
        jobs: [Job],
        schedule: NativeSchedule.ResolvedSchedule,
        today: String,
        ownerTag: String
    ) -> [DesiredEvent] {
        guard let lo = NativeSchedule.shiftNaiveDate(today, days: -windowPastDays),
              let hi = NativeSchedule.shiftNaiveDate(today, days: windowFutureDays) else { return [] }
        let zone = schedule.timeZone.flatMap { NativeAvailability.isValidIANAZone($0) ? $0 : nil }
        var out: [DesiredEvent] = []
        var seen = Set<String>()
        for job in jobs {
            if job.archivedAt?.isEmpty == false { continue }
            if job.status == "declined" { continue }
            guard let date = job.scheduledDate, NativeSchedule.isValidDate(date), date >= lo, date <= hi,
                  !job.scheduleJobId.isEmpty, seen.insert(job.scheduleJobId).inserted,
                  let nextDay = NativeSchedule.shiftNaiveDate(date, days: 1) else { continue }

            let title = job.mirrorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let customer = job.mirrorCustomerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = job.mirrorAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let start: NaiveDateTime
            let end: NaiveDateTime
            let isAllDay: Bool
            if let startTime = job.scheduledStartTime, let s = NativeSchedule.toMinutes(startTime), NativeSchedule.isValidTime(startTime) {
                isAllDay = false
                start = NaiveDateTime(date: date, minutes: s)
                if let endTime = job.scheduledEndTime, NativeSchedule.isValidTime(endTime),
                   let e = NativeSchedule.toMinutes(endTime), e > s {
                    end = NaiveDateTime(date: date, minutes: e)
                } else {
                    // The blockWindow rule: max(labor, 1 h), capped at midnight.
                    let e = min(Int(Double(s) + max(job.scheduleLaborHours, 1) * 60), 24 * 60)
                    end = e >= 24 * 60 ? NaiveDateTime(date: nextDay, minutes: 0) : NaiveDateTime(date: date, minutes: e)
                }
            } else {
                isAllDay = true
                start = NaiveDateTime(date: date, minutes: 0)
                end = NaiveDateTime(date: nextDay, minutes: 0)
            }
            let fields = Fields(
                title: (title.isEmpty ? "Job" : title) + (customer.isEmpty ? "" : " — \(customer)"),
                location: address.isEmpty ? nil : address,
                notes: "Status: \(statusLabel(job.status))\n\(managedNote)\n\(marker(ownerTag: ownerTag, jobID: job.scheduleJobId))",
                url: deepLink(jobID: job.scheduleJobId),
                isAllDay: isAllDay,
                start: start,
                end: end,
                timeZoneID: isAllDay ? nil : zone
            )
            out.append(DesiredEvent(jobID: job.scheduleJobId, fields: fields))
        }
        return out
    }

    public static func marker(ownerTag: String, jobID: String) -> String {
        "\(markerPrefix)\(ownerTag):\(jobID)"
    }

    /// The marker line in an event's notes, or nil (an unmarked event).
    public static func parseMarker(_ notes: String?) -> (ownerTag: String, jobID: String)? {
        guard let notes else { return nil }
        for line in notes.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(markerPrefix) else { continue }
            let rest = trimmed.dropFirst(markerPrefix.count)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let tag = String(rest[..<colon])
            let jobID = String(rest[rest.index(after: colon)...])
            guard !tag.isEmpty, !jobID.isEmpty else { return nil }
            return (tag, jobID)
        }
        return nil
    }

    /// `tradeready://job/<percent-encoded id>`, the existing gated deep link
    /// (the widget's encoding: `/` is escaped so it cannot add a component).
    public static func deepLink(jobID: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = jobID.addingPercentEncoding(withAllowedCharacters: allowed) ?? jobID
        return "tradeready://job/\(encoded)"
    }

    public static func statusLabel(_ status: String) -> String {
        switch status {
        case "lead": "Lead"
        case "estimate_sent": "Estimate sent"
        case "approved": "Approved"
        case "scheduled": "Scheduled"
        case "in_progress": "In progress"
        case "complete": "Complete"
        case "invoiced": "Invoiced"
        case "paid": "Paid"
        case "declined": "Declined"
        default: status.isEmpty ? "Unknown" : status
        }
    }

    // MARK: - Reconcile plan

    /// Ops that make the calendar match `desired`. Unmarked events and events
    /// marked for another owner are never touched; only events starting
    /// inside [today − 30, today + 180] are considered. Marked events are
    /// grouped by job; the survivor is the earliest `creationDate`, then the
    /// smallest `externalID`, then the smallest `eventID` (every device picks
    /// the same one), the rest are deleted. A survivor whose fields differ is
    /// updated (Calendar-app edits are restored: the mirror is one-way); one
    /// whose job is no longer desired is deleted; a desired job with no
    /// survivor is created. Deletes come first, then updates, then creates,
    /// each by start; at most 200 per pass.
    public static func plan(desired: [DesiredEvent], existing: [Existing], ownerTag: String, today: String) -> [Operation] {
        guard let lo = NativeSchedule.shiftNaiveDate(today, days: -windowPastDays),
              let hi = NativeSchedule.shiftNaiveDate(today, days: windowFutureDays) else { return [] }
        let desiredByJob = Dictionary(desired.map { ($0.jobID, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: [Existing]] = [:]
        for event in existing {
            guard let marker = parseMarker(event.notes), marker.ownerTag == ownerTag,
                  event.fields.start.date >= lo, event.fields.start.date <= hi else { continue }
            groups[marker.jobID, default: []].append(event)
        }

        var deletes: [(NaiveDateTime, String, Operation)] = []
        var updates: [(NaiveDateTime, String, Operation)] = []
        var creates: [(NaiveDateTime, String, Operation)] = []
        for (jobID, events) in groups {
            let ordered = events.sorted(by: survivorFirst)
            let survivor = ordered[0]
            for duplicate in ordered.dropFirst() {
                deletes.append((duplicate.fields.start, jobID, .delete(eventID: duplicate.eventID)))
            }
            if let wanted = desiredByJob[jobID] {
                if survivor.fields != wanted.fields {
                    updates.append((wanted.fields.start, jobID, .update(eventID: survivor.eventID, wanted)))
                }
            } else {
                deletes.append((survivor.fields.start, jobID, .delete(eventID: survivor.eventID)))
            }
        }
        for wanted in desired where groups[wanted.jobID] == nil {
            creates.append((wanted.fields.start, wanted.jobID, .create(wanted)))
        }
        func ordered(_ ops: [(NaiveDateTime, String, Operation)]) -> [Operation] {
            ops.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2)
        }
        return Array((ordered(deletes) + ordered(updates) + ordered(creates)).prefix(maxOperations))
    }

    static func survivorFirst(_ a: Existing, _ b: Existing) -> Bool {
        let ac = a.creationDate ?? .distantFuture
        let bc = b.creationDate ?? .distantFuture
        if ac != bc { return ac < bc }
        switch (a.externalID, b.externalID) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.eventID < b.eventID
        }
    }
}

/// The job surface the mirror reads. `Canonical.Job` conforms below; tests
/// use a stub.
public protocol MirrorJobLike: ScheduleJobLike {
    var mirrorTitle: String { get }
    var mirrorCustomerName: String { get }
    var mirrorAddress: String { get }
}

extension Canonical.Job: MirrorJobLike {
    public var mirrorTitle: String { title }
    public var mirrorCustomerName: String { customerName }
    public var mirrorAddress: String { address }
}
