import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Calendar busy times (Roadmap Phase 26), the pure half. Spec:
/// `docs/superpowers/specs/2026-10-03-calendar-sync-design.md` §2.2–§2.4, §4.1.
///
/// - Busy rules over a value-type `Sample` (the EventKit adapter maps
///   `EKEvent`s into it; nothing here touches EventKit).
/// - `makeSnapshot` builds the wire snapshot the device pushes: only start and
///   end instants of busy periods (never titles, places, notes or guests),
///   clipped, minute-rounded, merged and capped.
/// - `gate` and `offerableSlots` are the Swift twins of the Worker's
///   `calendarBusyGate` (`backend-workers/lib/calendar/busyGate.js`) and
///   `offerableSlots` (`backend-workers/lib/booking/offerable.js`). Both sides
///   are pinned to the same vectors in
///   `native/ScheduleTests/Fixtures/scheduleVectors.json`. The in-app overlay
///   runs the same gate on a locally built snapshot, so what the owner sees
///   is what the booking page enforces.
///
/// Foundation (plus CryptoKit for the digest) only; time and zones injected.
public enum NativeCalendarBusy {

    public static let ttlHours = 48
    public static let maxTimed = 500
    public static let maxAllDay = 100
    public static let maxWindowDays = 63
    public static let maxAllDayDays = 63
    /// The longest booking window a device shares (D9; the server accepts 63).
    public static let maxShareDays = 62
    public static let maxBodyBytes = 64 * 1024
    public static let maxSkewMillis: Int64 = 10 * 60_000
    /// Pushes repeat at least this often while sharing, so a quiet calendar
    /// stays fresh (§4.4).
    public static let heartbeatSeconds: TimeInterval = 30 * 60
    /// The note marker every mirrored event carries (§2.5).
    public static let mirrorMarkerPrefix = "tradeready-job:"

    static let minuteMillis: Int64 = 60_000
    static let hourMillis: Int64 = 3_600_000
    static let dayMillis: Int64 = 86_400_000
    static let dayMinutes = 24 * 60

    // MARK: - Busy rules (§4.1)

    public enum Availability: String, Equatable, Sendable {
        case busy, free, tentative, unavailable, notSupported
    }

    public enum Status: String, Equatable, Sendable {
        case none, confirmed, tentative, canceled
    }

    /// One calendar event occurrence, as the adapter reads it.
    public struct Sample: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        public var availability: Availability
        public var status: Status
        /// The current user is an attendee who declined.
        public var ownerDeclined: Bool
        public var calendarID: String
        /// The owner tag of a well-formed mirror marker line in the event's
        /// notes, or nil. Parsed from `notes` with the mirror's own parser
        /// (`NativeCalendarMirror.parseMarker`), so busy rules and reconcile
        /// agree on what a mirrored event is; the notes are not kept.
        public var markerOwnerTag: String?

        public init(start: Date, end: Date, isAllDay: Bool = false, availability: Availability = .busy,
                    status: Status = .confirmed, ownerDeclined: Bool = false, calendarID: String,
                    notes: String? = nil) {
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.availability = availability
            self.status = status
            self.ownerDeclined = ownerDeclined
            self.calendarID = calendarID
            self.markerOwnerTag = NativeCalendarMirror.parseMarker(notes)?.ownerTag
        }
    }

    /// The §4.1 table. Timed events count when busy, unavailable, tentative
    /// or notSupported; all-day events only when busy or unavailable, so
    /// birthdays and holidays never wipe out a day (vacations belong in
    /// Schedule › Time off).
    ///
    /// An event outside the mirror calendar is skipped as a mirrored job only
    /// when its marker parses and carries this account's `mirrorOwnerTag`
    /// (`NativeCalendarMirror.ownerTag16`), the same test reconcile uses. A
    /// loose `tradeready-job:` substring (an invite's or a pasted note's free
    /// text), a malformed marker or another owner's tag still counts, so a
    /// really busy period is never shown as free. A nil tag skips none.
    public static func countsAsBusy(_ sample: Sample, excludedCalendarIDs: Set<String>, mirrorCalendarID: String?,
                                    mirrorOwnerTag: String?) -> Bool {
        if excludedCalendarIDs.contains(sample.calendarID) { return false }
        if let mirrorCalendarID, sample.calendarID == mirrorCalendarID { return false }
        if isOwnMirrorEvent(sample, mirrorOwnerTag: mirrorOwnerTag) { return false }
        if sample.status == .canceled || sample.ownerDeclined { return false }
        if sample.end <= sample.start { return false }
        if sample.isAllDay {
            return sample.availability == .busy || sample.availability == .unavailable
        }
        return sample.availability != .free
    }

    public static func busySamples(_ samples: [Sample], excludedCalendarIDs: Set<String>, mirrorCalendarID: String?,
                                   mirrorOwnerTag: String?) -> [Sample] {
        samples.filter {
            countsAsBusy($0, excludedCalendarIDs: excludedCalendarIDs, mirrorCalendarID: mirrorCalendarID,
                         mirrorOwnerTag: mirrorOwnerTag)
        }
    }

    /// A job this account mirrored (its marker carries `mirrorOwnerTag`).
    public static func isOwnMirrorEvent(_ sample: Sample, mirrorOwnerTag: String?) -> Bool {
        guard let mirrorOwnerTag, !mirrorOwnerTag.isEmpty, let tag = sample.markerOwnerTag else { return false }
        return tag == mirrorOwnerTag
    }

    // MARK: - Window (§2.2)

    /// The shared window: from the start of today in the owner's zone, for
    /// `min(slotWindowDays, 62)` days, computed zone-aware (DST-safe).
    public struct Window: Equatable, Sendable {
        public var start: Date
        public var end: Date
        /// Owner-naive first and last covered dates (all-day ranges clip here).
        public var firstDate: String
        public var lastDate: String
        public var timeZoneID: String
    }

    public static func window(now: Date, timeZoneID: String, days: Int) -> Window? {
        guard let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let span = max(1, min(days, maxShareDays))
        let start = calendar.startOfDay(for: now)
        guard let shifted = calendar.date(byAdding: .day, value: span, to: start) else { return nil }
        let end = calendar.startOfDay(for: shifted)
        return Window(start: start, end: end,
                      firstDate: naiveDate(start, calendar: calendar),
                      lastDate: naiveDate(end.addingTimeInterval(-1), calendar: calendar),
                      timeZoneID: timeZoneID)
    }

    // MARK: - Snapshot (§2.2)

    /// The wire snapshot. `timed` holds `[start, end]` instant pairs and
    /// `allDay` inclusive `[firstDate, lastDate]` ranges.
    public struct Snapshot: Equatable, Sendable {
        public var v: Int
        public var computedAt: String
        public var windowStart: String
        public var windowEnd: String
        public var timed: [[String]]
        public var allDay: [[String]]

        public init(v: Int = 1, computedAt: String, windowStart: String, windowEnd: String,
                    timed: [[String]] = [], allDay: [[String]] = []) {
            self.v = v
            self.computedAt = computedAt
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.timed = timed
            self.allDay = allDay
        }
    }

    /// Builds the snapshot from busy samples (filter with `busySamples`
    /// first). Timed blocks are clipped to the window, starts floored and ends
    /// ceiled to the minute, sorted and merged (touching blocks merge). Past
    /// 500 blocks the first 500 are kept and `windowEnd` is pulled back to the
    /// 501st block's start, so the dropped tail is uncovered (busy). All-day
    /// dates come from `startDate` and `endDate − 1 s` in the injected
    /// `calendar` (the device zone: all-day events float), clipped to the
    /// window's owner dates and merged when they overlap or touch.
    public static func makeSnapshot(samples: [Sample], window: Window, computedAt: Date, calendar: Calendar) -> Snapshot {
        var windowEndMillis = millis(window.end)
        let windowStartMillis = millis(window.start)

        // All-day ranges, merged (adjacent dates merge too).
        var ranges: [(Int, Int)] = []
        let firstDay = NativeSchedule.epochDays(window.firstDate) ?? 0
        let lastDay = NativeSchedule.epochDays(window.lastDate) ?? 0
        for sample in samples where sample.isAllDay {
            guard let d1 = NativeSchedule.epochDays(naiveDate(sample.start, calendar: calendar)),
                  let d2 = NativeSchedule.epochDays(naiveDate(sample.end.addingTimeInterval(-1), calendar: calendar)),
                  d1 <= d2 else { continue }
            let clipped = (max(d1, firstDay), min(d2, lastDay))
            if clipped.0 <= clipped.1 { ranges.append(clipped) }
        }
        ranges.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var mergedRanges: [(Int, Int)] = []
        for range in ranges {
            if let last = mergedRanges.last, range.0 <= last.1 + 1 {
                mergedRanges[mergedRanges.count - 1].1 = max(last.1, range.1)
            } else {
                mergedRanges.append(range)
            }
        }
        if mergedRanges.count > maxAllDay {
            // Unreachable inside a 62-day window once adjacent dates merge
            // (at most 31 ranges); kept so the cap can never be exceeded.
            let first = mergedRanges[maxAllDay].0
            if let zone = TimeZone(identifier: window.timeZoneID) {
                var owner = Calendar(identifier: .gregorian)
                owner.timeZone = zone
                let (y, m, d) = NativeSchedule.civilFromEpochDays(first)
                if let noon = owner.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) {
                    windowEndMillis = min(windowEndMillis, millis(owner.startOfDay(for: noon)))
                }
            }
            mergedRanges = Array(mergedRanges.prefix(maxAllDay))
        }

        // Timed blocks.
        var blocks: [(Int64, Int64)] = []
        for sample in samples where !sample.isAllDay {
            let s = floorMinute(max(millis(sample.start), windowStartMillis))
            let e = ceilMinute(min(millis(sample.end), windowEndMillis))
            if s < e { blocks.append((s, min(e, windowEndMillis))) }
        }
        blocks.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var merged: [(Int64, Int64)] = []
        for block in blocks {
            if let last = merged.last, block.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, block.1)
            } else {
                merged.append(block)
            }
        }
        if merged.count > maxTimed {
            windowEndMillis = merged[maxTimed].0
            merged = Array(merged.prefix(maxTimed))
        }

        return Snapshot(
            computedAt: instant(floorMinute(millis(computedAt))),
            windowStart: instant(windowStartMillis),
            windowEnd: instant(windowEndMillis),
            timed: merged.map { [instant($0.0), instant($0.1)] },
            allDay: mergedRanges.map { [dateString($0.0), dateString($0.1)] }
        )
    }

    /// The exact wire JSON (`v`, `computedAt`, `windowStart`, `windowEnd`,
    /// `timed`, `allDay`, in that order). Every value is a fixed-alphabet
    /// instant or date, so no escaping is needed.
    public static func encode(_ snapshot: Snapshot) -> String {
        "{\"v\":\(snapshot.v),\"computedAt\":\"\(snapshot.computedAt)\",\"windowStart\":\"\(snapshot.windowStart)\","
            + "\"windowEnd\":\"\(snapshot.windowEnd)\",\"timed\":\(pairs(snapshot.timed)),\"allDay\":\(pairs(snapshot.allDay))}"
    }

    /// SHA-256 (lowercase hex) of `{windowEnd, timed, allDay}`: what the push
    /// decision compares. `computedAt` is left out so an unchanged calendar
    /// does not look changed every minute.
    public static func digest(_ snapshot: Snapshot) -> String {
        let canonical = "{\"windowEnd\":\"\(snapshot.windowEnd)\",\"timed\":\(pairs(snapshot.timed)),\"allDay\":\(pairs(snapshot.allDay))}"
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return canonical
        #endif
    }

    private static func pairs(_ values: [[String]]) -> String {
        "[" + values.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" }.joined(separator: ",") + "]"
    }

    // MARK: - Stored row (the calendar_busy column shape)

    public struct StoredSnapshot: Equatable, Sendable {
        public var v: Int
        public var timed: [[String]]
        public var allDay: [[String]]
        public init(v: Int, timed: [[String]], allDay: [[String]]) {
            self.v = v
            self.timed = timed
            self.allDay = allDay
        }
    }

    public struct StoredRow: Equatable, Sendable {
        public var sourceID: String?
        /// Nil: checks are on but nothing is shared.
        public var snapshot: StoredSnapshot?
        public var computedAt: String?
        public var windowStart: String?
        public var windowEnd: String?
        public var receivedAt: String?

        public init(sourceID: String?, snapshot: StoredSnapshot?, computedAt: String?, windowStart: String?,
                    windowEnd: String?, receivedAt: String?) {
            self.sourceID = sourceID
            self.snapshot = snapshot
            self.computedAt = computedAt
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.receivedAt = receivedAt
        }

        /// The row a just-built snapshot would be stored as (the overlay's input).
        public init(snapshot: Snapshot, receivedAt: String) {
            self.init(sourceID: nil, snapshot: StoredSnapshot(v: snapshot.v, timed: snapshot.timed, allDay: snapshot.allDay),
                      computedAt: snapshot.computedAt, windowStart: snapshot.windowStart,
                      windowEnd: snapshot.windowEnd, receivedAt: receivedAt)
        }

        /// A row from its JSON object form (`source_id`, `snapshot`, …), as
        /// the shared fixture and PostgREST spell it. Nil when the shape is
        /// not a row at all.
        public init?(jsonObject: Any?) {
            guard let object = jsonObject as? [String: Any] else { return nil }
            var stored: StoredSnapshot?
            if let snap = object["snapshot"] as? [String: Any] {
                guard let v = snap["v"] as? Int,
                      let timed = snap["timed"] as? [[String]],
                      let allDay = snap["allDay"] as? [[String]] else { return nil }
                stored = StoredSnapshot(v: v, timed: timed, allDay: allDay)
            }
            self.init(sourceID: object["source_id"] as? String, snapshot: stored,
                      computedAt: object["computed_at"] as? String, windowStart: object["window_start"] as? String,
                      windowEnd: object["window_end"] as? String, receivedAt: object["received_at"] as? String)
        }
    }

    // MARK: - Validation (twin of busyGate.js validateSnapshot)

    public struct Parsed: Equatable {
        public var computedAtMillis: Int64
        public var windowStartMillis: Int64
        public var windowEndMillis: Int64
        public var timed: [[Int64]]
        public var allDay: [[Int]]
    }

    public static func validate(_ snapshot: Snapshot, nowMillis: Int64) -> Parsed? {
        guard snapshot.v == 1,
              let computedAt = parseInstant(snapshot.computedAt),
              let windowStart = parseInstant(snapshot.windowStart),
              let windowEnd = parseInstant(snapshot.windowEnd),
              windowStart <= computedAt, windowStart < windowEnd,
              windowEnd - windowStart <= Int64(maxWindowDays) * dayMillis,
              computedAt <= nowMillis + maxSkewMillis, windowStart <= nowMillis + maxSkewMillis,
              snapshot.timed.count <= maxTimed, snapshot.allDay.count <= maxAllDay
        else { return nil }
        var timed: [[Int64]] = []
        var previousEnd = Int64.min
        for pair in snapshot.timed {
            guard pair.count == 2, let s = parseInstant(pair[0]), let e = parseInstant(pair[1]),
                  s < e, s >= windowStart, e <= windowEnd, s > previousEnd else { return nil }
            previousEnd = e
            timed.append([s, e])
        }
        var allDay: [[Int]] = []
        var previousLast = Int.min
        for range in snapshot.allDay {
            guard range.count == 2, let d1 = parseDateDays(range[0]), let d2 = parseDateDays(range[1]),
                  d1 <= d2, d2 - d1 + 1 <= maxAllDayDays, d1 > previousLast else { return nil }
            previousLast = d2
            allDay.append([d1, d2])
        }
        return Parsed(computedAtMillis: computedAt, windowStartMillis: windowStart, windowEndMillis: windowEnd,
                      timed: timed, allDay: allDay)
    }

    // MARK: - Gate twin (§2.4)

    public enum GateState: String, Equatable, Sendable {
        case off, stale, fresh
    }

    public enum Freshness: Equatable {
        case off
        case stale
        case fresh(Parsed)

        public var state: GateState {
            switch self {
            case .off: .off
            case .stale: .stale
            case .fresh: .fresh
            }
        }
    }

    public enum GateResult: Equatable {
        case off
        case stale
        case fresh(windows: [NativeAvailability.BusyWindow], lastCoveredDate: String)

        public var state: GateState {
            switch self {
            case .off: .off
            case .stale: .stale
            case .fresh: .fresh
            }
        }
    }

    /// Steps 1–3: no row is `off`; a null, invalid, too-old (from
    /// `min(computedAt, receivedAt)`) or past-window row is `stale`.
    public static func freshness(_ stored: StoredRow?, nowMillis: Int64, ttlHours: Int = ttlHours) -> Freshness {
        guard let stored else { return .off }
        guard let snap = stored.snapshot,
              let computedAt = stored.computedAt.flatMap(normalizeInstant),
              let windowStart = stored.windowStart.flatMap(normalizeInstant),
              let windowEnd = stored.windowEnd.flatMap(normalizeInstant)
        else { return .stale }
        let wire = Snapshot(v: snap.v, computedAt: computedAt, windowStart: windowStart, windowEnd: windowEnd,
                            timed: snap.timed, allDay: snap.allDay)
        guard let parsed = validate(wire, nowMillis: nowMillis),
              let received = stored.receivedAt.flatMap(parseAnyInstant) else { return .stale }
        let effective = min(parsed.computedAtMillis, received)
        if nowMillis - effective > Int64(ttlHours) * hourMillis { return .stale }
        if parsed.windowEndMillis <= nowMillis { return .stale }
        return .fresh(parsed)
    }

    /// `calendarBusyGate`: owner-naive busy windows plus the last covered
    /// date. Timed pair [s, e) → local span [s + min(offS, offE),
    /// e + max(offS, offE)) split per date; a day's end of 24:00 is "23:59";
    /// all-day ranges block 00:00–23:59; before windowStart and from windowEnd
    /// on is busy (edge readings probe the offset at the instant and one hour
    /// before/after). Sorted by (date, start, end), not merged.
    public static func gate(_ stored: StoredRow?, timeZoneID: String, nowMillis: Int64, ttlHours: Int = ttlHours) -> GateResult {
        let checked = freshness(stored, nowMillis: nowMillis, ttlHours: ttlHours)
        guard case let .fresh(parsed) = checked else { return checked == .off ? .off : .stale }
        guard let zone = TimeZone(identifier: timeZoneID) else { return .stale }
        func offset(_ ms: Int64) -> Int64 {
            Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000))) / 60
        }
        var windows: [NativeAvailability.BusyWindow] = []
        for pair in parsed.timed {
            let (s, e) = (pair[0], pair[1])
            let offS = offset(s), offE = offset(e)
            pushLocalSpan(&windows, start: s / minuteMillis + min(offS, offE), end: e / minuteMillis + max(offS, offE))
        }
        for range in parsed.allDay {
            for day in range[0]...range[1] {
                windows.append(.init(date: dateString(day), start: "00:00", end: "23:59"))
            }
        }

        let w = parsed.windowStartMillis
        let headMin = w / minuteMillis + max(offset(w - hourMillis), offset(w))
        let headDay = floorDiv(headMin, Int64(dayMinutes))
        let headMinute = Int(headMin - headDay * Int64(dayMinutes))
        if headMinute > 0 {
            windows.append(.init(date: dateString(Int(headDay)), start: "00:00", end: minutesString(headMinute)))
        }
        if let today = NativeAvailability.nowInZone(timeZoneID: timeZoneID, utcMillis: nowMillis),
           let todayDays = NativeSchedule.epochDays(today.date), Int64(todayDays) < headDay {
            for day in todayDays..<Int(headDay) {
                windows.append(.init(date: dateString(day), start: "00:00", end: "23:59"))
            }
        }

        let e = parsed.windowEndMillis
        let tailMin = e / minuteMillis + min(offset(e), offset(e + hourMillis))
        let tailDay = floorDiv(tailMin, Int64(dayMinutes))
        let tailMinute = Int(tailMin - tailDay * Int64(dayMinutes))
        let lastCovered: Int
        if tailMinute == 0 {
            lastCovered = Int(tailDay) - 1
        } else {
            lastCovered = Int(tailDay)
            if tailMinute < dayMinutes - 1 {
                windows.append(.init(date: dateString(Int(tailDay)), start: minutesString(tailMinute), end: "23:59"))
            }
        }
        windows.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            if a.start != b.start { return a.start < b.start }
            return a.end < b.end
        }
        return .fresh(windows: windows, lastCoveredDate: dateString(lastCovered))
    }

    private static func pushLocalSpan(_ out: inout [NativeAvailability.BusyWindow], start: Int64, end: Int64) {
        var day = floorDiv(start, Int64(dayMinutes))
        while day * Int64(dayMinutes) < end {
            let base = day * Int64(dayMinutes)
            let s = Int(max(start, base) - base)
            var e = Int(min(end, base + Int64(dayMinutes)) - base)
            if e == dayMinutes { e = dayMinutes - 1 }
            if s < e { out.append(.init(date: dateString(Int(day)), start: minutesString(s), end: minutesString(e))) }
            day += 1
        }
    }

    // MARK: - Offer pipeline twin

    /// `offerableSlots`: `off` is exactly today's computation; `stale` offers
    /// nothing; `fresh` adds the gate's windows to the reservations and cuts
    /// the horizon at the last covered date. The engine and its buffer are
    /// unchanged.
    public static func offerableSlots<Job: ScheduleJobLike>(
        schedule: NativeSchedule.ResolvedSchedule,
        jobs: [Job],
        reservations: [NativeAvailability.BusyWindow],
        stored: StoredRow?,
        nowMillis: Int64
    ) -> (state: GateState, slots: [NativeAvailability.PublicSlot]) {
        guard let zone = schedule.timeZone,
              let now = NativeAvailability.nowInZone(timeZoneID: zone, utcMillis: nowMillis) else { return (.stale, []) }
        var extraBusy = reservations
        var days = schedule.slotWindowDays
        let result = gate(stored, timeZoneID: zone, nowMillis: nowMillis)
        switch result {
        case .stale:
            return (.stale, [])
        case let .fresh(windows, lastCoveredDate):
            extraBusy.append(contentsOf: windows)
            if let last = NativeSchedule.epochDays(lastCoveredDate), let today = NativeSchedule.epochDays(now.date) {
                days = max(0, min(days, last - today + 1))
            }
        case .off:
            break
        }
        let candidates = NativeAvailability.computeCandidateSlots(input: NativeAvailability.AvailabilityInput(
            schedule: schedule, jobs: jobs, extraBusy: extraBusy, fromDate: now.date, days: days, now: now))
        return (result.state, NativeAvailability.resolveSlotsUtc(slots: candidates, timeZoneID: zone))
    }

    /// The in-app overlay: the gate run on a locally built snapshot, as if the
    /// server had just received it. Empty unless fresh.
    public static func overlayWindows(_ snapshot: Snapshot, timeZoneID: String, nowMillis: Int64) -> [NativeAvailability.BusyWindow] {
        let stored = StoredRow(snapshot: snapshot, receivedAt: snapshot.computedAt)
        guard case let .fresh(windows, _) = gate(stored, timeZoneID: timeZoneID, nowMillis: nowMillis) else { return [] }
        return windows
    }

    // MARK: - Status presentation (§4.5)

    /// The server's view (POST /api/calendar/busy `status`).
    public struct ServerStatus: Equatable, Sendable {
        public var enabled: Bool
        public var thisDevice: Bool
        public var shared: Bool
        public var fresh: Bool
        public var computedAt: Date?
        public var receivedAt: Date?

        public init(enabled: Bool, thisDevice: Bool, shared: Bool, fresh: Bool, computedAt: Date?, receivedAt: Date?) {
            self.enabled = enabled
            self.thisDevice = thisDevice
            self.shared = shared
            self.fresh = fresh
            self.computedAt = computedAt
            self.receivedAt = receivedAt
        }

        /// When checks last ran: the earlier of the two clocks (§1.4).
        public var lastRunAt: Date? {
            switch (computedAt, receivedAt) {
            case let (c?, r?): min(c, r)
            case let (c?, nil): c
            case let (nil, r?): r
            default: nil
            }
        }
    }

    /// The settings page's status row.
    public enum StatusLine: Equatable, Sendable {
        case accessNeeded
        case unavailable
        case notShared
        case shared(updatedAt: Date, days: Int)
        case otherDevice(lastUpdate: Date?)
        case outOfDate
        case waiting
    }

    public static func statusText(_ line: StatusLine, now: Date) -> String {
        switch line {
        case .accessNeeded:
            "Calendar access is off, so busy times can't be checked."
        case .unavailable:
            "Calendar checks aren't available yet."
        case .notShared:
            "Not shared: bookable time slots are off"
        case let .shared(updatedAt, days):
            "Booking page updated \(relativeAge(from: updatedAt, to: now)) · busy times for the next \(days) day\(days == 1 ? "" : "s")"
        case let .otherDevice(lastUpdate):
            "Runs on another device" + (lastUpdate.map { " · last update \(relativeAge(from: $0, to: now))" } ?? "")
        case .outOfDate:
            "Out of date: your booking page takes requests only until TradeReady checks again"
        case .waiting:
            "Waiting to share busy times with your booking page"
        }
    }

    /// "just now", "5 min ago", "3 h ago", "2 days ago".
    public static func relativeAge(from earlier: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(earlier))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h ago" }
        return "\(hours / 24) days ago"
    }

    // MARK: - Instants and dates

    /// "YYYY-MM-DDTHH:MM:00Z" → epoch ms; nil for any other form or an
    /// impossible date.
    public static func parseInstant(_ value: String) -> Int64? {
        let chars = Array(value.utf8)
        guard chars.count == 20, chars[4] == 0x2D, chars[7] == 0x2D, chars[10] == 0x54, chars[13] == 0x3A,
              chars[16] == 0x3A, chars[17] == 0x30, chars[18] == 0x30, chars[19] == 0x5A else { return nil }
        let date = String(decoding: chars[0..<10], as: UTF8.self)
        guard date.range(of: NativeSchedule.datePattern, options: .regularExpression) != nil,
              let days = NativeSchedule.epochDays(date),
              let h = Int(String(decoding: chars[11..<13], as: UTF8.self)),
              let m = Int(String(decoding: chars[14..<16], as: UTF8.self)),
              chars[11..<13].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              chars[14..<16].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return Int64(days) * dayMillis + Int64(h) * hourMillis + Int64(m) * minuteMillis
    }

    public static func parseDateDays(_ value: String) -> Int? {
        guard value.range(of: NativeSchedule.datePattern, options: .regularExpression) != nil else { return nil }
        return NativeSchedule.epochDays(value)
    }

    /// A wire instant, or any ISO 8601 timestamp at minute precision (a
    /// PostgREST timestamptz), in wire form.
    public static func normalizeInstant(_ value: String) -> String? {
        if parseInstant(value) != nil { return value }
        guard let ms = parseAnyInstant(value), ms % minuteMillis == 0 else { return nil }
        return instant(ms)
    }

    public static func parseAnyInstant(_ value: String) -> Int64? {
        if let ms = parseInstant(value) { return ms }
        for formatter in [isoFractional, isoPlain] {
            if let date = formatter.date(from: value) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        }
        return nil
    }

    public static func parseAnyDate(_ value: String?) -> Date? {
        guard let value, let ms = parseAnyInstant(value) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func instant(_ ms: Int64) -> String {
        let days = floorDiv(ms, dayMillis)
        let rest = ms - days * dayMillis
        let minutes = Int(rest / minuteMillis)
        return "\(dateString(Int(days)))T\(minutesString(minutes)):00Z"
    }

    public static func instant(_ date: Date) -> String {
        instant(floorMinute(millis(date)))
    }

    static func dateString(_ epochDays: Int) -> String {
        let (y, m, d) = NativeSchedule.civilFromEpochDays(epochDays)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func minutesString(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    public static func naiveDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func floorMinute(_ ms: Int64) -> Int64 {
        floorDiv(ms, minuteMillis) * minuteMillis
    }

    static func ceilMinute(_ ms: Int64) -> Int64 {
        let floored = floorMinute(ms)
        return floored == ms ? ms : floored + minuteMillis
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
