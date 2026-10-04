import Foundation

/// Phase 32 (quote expiration dates, spec 2026-10-03 §2, §3, §6.2): the one
/// pure policy for an estimate's inclusive valid-until date.
///
/// Dates are civil `YYYY-MM-DD` strings. Day arithmetic runs in a UTC
/// gregorian calendar on parsed components, and `displayDate` formats those
/// components in UTC with `en_US`, so no path ever parses a bare date in the
/// device zone (FA-039). Only `today(now:calendar:)`, `isExpired` and the
/// `NativeValidUntilPicker` bridge read a zone, and each reads exactly the
/// one it is given.
///
/// Every civil date is Gregorian (review fix 2026-10-03): the stored
/// `YYYY-MM-DD` is the date the Worker enforces and the customer reads, so a
/// device whose Calendar setting is Buddhist or Japanese (`Calendar.current`
/// then counts 2569 or Reiwa 8) must still produce `2026-…`. Those entry
/// points read only the time zone of the calendar they are handed.
///
/// Foundation and the canonical models only: no app-file dependencies, so
/// every host runner can compile it next to its own sources.
enum NativeQuoteExpiry {
    static let defaultValidityDays = 30, maximumValidityDays = 365
    static let expiringSoonDays = 3, expiredLookbackDays = 14, expiryReminderLeadDays = 2
    /// "Anywhere on Earth" (UTC−12): an unknown zone never expires early.
    static let anywhereOnEarthZoneID = "Etc/GMT+12"

    enum DisplayStyle: Equatable, Sendable {
        /// "November 2, 2026"
        case long
        /// "Nov 2, 2026"
        case medium
        /// "Nov 2"
        case short
    }

    enum State: Equatable {
        case open(validUntil: String, daysLeft: Int)
        case expired(validUntil: String, daysAgo: Int)
    }

    // MARK: - Settings

    /// `settings.estimateValidityDays`: absent (or no settings) = 30, and a
    /// malformed stored value is clamped into 0…365. 0 = no expiry.
    static func validityDays(_ settings: Canonical.Settings?) -> Int {
        clampedValidityDays(settings?.estimateValidityDays ?? defaultValidityDays)
    }

    // MARK: - Civil dates

    /// The device's calendar for civil dates: Gregorian in the current time
    /// zone. Never `Calendar.current`, which follows the user's Calendar
    /// setting.
    static var localCalendar: Calendar { gregorian(in: .current) }

    /// A Gregorian calendar in `timeZone`.
    static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The local Gregorian `YYYY-MM-DD` for `now` in `calendar`'s time zone.
    /// Only the zone is read: a Buddhist or Japanese `calendar` still gives
    /// the Gregorian date.
    static func today(now: Date, calendar: Calendar) -> String {
        let parts = gregorian(in: calendar.timeZone).dateComponents([.year, .month, .day], from: now)
        return format(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// `ymd` plus `days` calendar days, or `nil` when `ymd` is not a real date.
    static func addDays(_ ymd: String, _ days: Int) -> String? {
        guard let date = utcDate(ymd),
              let moved = utcCalendar.date(byAdding: .day, value: days, to: date)
        else { return nil }
        return today(now: moved, calendar: utcCalendar)
    }

    /// Whole calendar days from `from` to `to` (negative when `to` is
    /// earlier), or `nil` when either is not a real date.
    static func days(from: String, to: String) -> Int? {
        guard let start = utcDate(from), let end = utcDate(to) else { return nil }
        return utcCalendar.dateComponents([.day], from: start, to: end).day
    }

    // MARK: - Lifecycle (§3)

    /// The date a review sheet proposes:
    /// - `estimate_sent` (re-send / re-issue): keeps a stored date that is
    ///   still selectable (today…today+365); a past, absent or malformed one
    ///   gets a fresh proposal.
    /// - Any other status (a lead, a revised estimate): a fresh proposal; any
    ///   stale stored date is ignored because a revised estimate is a new offer.
    /// - A fresh proposal is `today + validityDays`, or `nil` (doesn't expire)
    ///   when `validityDays` is 0.
    static func proposedValidUntil(job: Canonical.Job, validityDays: Int, today: String) -> String? {
        if job.status == "estimate_sent",
           let stored = job.estimateValidUntil,
           isSelectable(stored, today: today) {
            return stored
        }
        let days = clampedValidityDays(validityDays)
        guard days > 0 else { return nil }
        return addDays(today, days)
    }

    /// `nil` ("Doesn't expire") or a real date in today…today+365.
    static func isSelectable(_ ymd: String?, today: String) -> Bool {
        guard let ymd else { return true }
        guard let offset = days(from: today, to: ymd) else { return false }
        return offset >= 0 && offset <= maximumValidityDays
    }

    /// The owner-side state of a sent estimate, or `nil` unless the job is
    /// `estimate_sent` with a real `estimateValidUntil`.
    static func state(job: Canonical.Job, today: String) -> State? {
        guard job.status == "estimate_sent",
              let validUntil = job.estimateValidUntil,
              let offset = days(from: today, to: validUntil)
        else { return nil }
        return offset >= 0
            ? .open(validUntil: validUntil, daysLeft: offset)
            : .expired(validUntil: validUntil, daysAgo: -offset)
    }

    // MARK: - Enforcement parity (§2.4)

    /// Expired iff `today(now, zone) > validUntil`, where `zone` is
    /// `timeZoneID` when it resolves, else anywhere-on-Earth. The same rule
    /// the Worker enforces; parity vectors live in
    /// `native/QuoteExpiryTests/Fixtures/quote-expiry-vectors.json`.
    /// A `validUntil` that is not a real date never expires.
    static func isExpired(validUntil: String, timeZoneID: String?, now: Date) -> Bool {
        guard utcDate(validUntil) != nil else { return false }
        return today(now: now, calendar: gregorian(in: resolvedZone(timeZoneID))) > validUntil
    }

    // MARK: - Copy

    /// "November 2, 2026" / "Nov 2, 2026" / "Nov 2". Built from the parsed
    /// components and formatted in UTC with `en_US`, so the day never shifts
    /// with the device zone. A malformed input is returned unchanged.
    static func displayDate(_ ymd: String, style: DisplayStyle) -> String {
        guard let date = utcDate(ymd) else { return ymd }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = utcCalendar
        formatter.timeZone = utcCalendar.timeZone
        switch style {
        case .long:
            formatter.dateStyle = .long
            formatter.timeStyle = .none
        case .medium:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case .short:
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }

    /// "today" / "tomorrow" / "in 3 days".
    static func relativePhrase(daysLeft: Int) -> String {
        switch daysLeft {
        case ...0: return "today"
        case 1: return "tomorrow"
        default: return "in \(daysLeft) days"
        }
    }

    // MARK: - Internals

    private static func clampedValidityDays(_ days: Int) -> Int {
        min(max(days, 0), maximumValidityDays)
    }

    private static func resolvedZone(_ identifier: String?) -> TimeZone {
        if let identifier, !identifier.isEmpty, let zone = TimeZone(identifier: identifier) {
            return zone
        }
        return TimeZone(identifier: anywhereOnEarthZoneID) ?? TimeZone(secondsFromGMT: -12 * 3_600)!
    }

    private static let utcCalendar = gregorian(in: TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!)

    /// Strict `YYYY-MM-DD` that names a real calendar day, as UTC midnight.
    private static func utcDate(_ ymd: String) -> Date? {
        let scalars = Array(ymd.utf8)
        guard scalars.count == 10, scalars[4] == UInt8(ascii: "-"), scalars[7] == UInt8(ascii: "-") else { return nil }
        let digitIndexes = [0, 1, 2, 3, 5, 6, 8, 9]
        guard digitIndexes.allSatisfy({ scalars[$0] >= UInt8(ascii: "0") && scalars[$0] <= UInt8(ascii: "9") }) else {
            return nil
        }
        let parts = ymd.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        let roundTrip = utcCalendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return date
    }

    private static func format(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// Phase 32 (spec 2026-10-03 §6.4, §6.5): bridges a civil `YYYY-MM-DD`
/// valid-until date and the `Date` a `DatePicker` edits. The picker shows
/// the instant in the device's own calendar; the bridge builds and reads it
/// as a Gregorian day in the device zone, the calendar
/// `NativeQuoteExpiry.today` reads, so the day the owner picks is the day
/// stored whatever the Calendar setting; nothing parses a bare date in UTC
/// (FA-039). Shared by the review sheet and the job-detail editor, and kept
/// here (Foundation only) so the host suite pins the round trip. A
/// `calendar` passed in contributes only its time zone.
enum NativeValidUntilPicker {
    /// Noon local on that day (clear of any DST transition), or `nil` when
    /// `ymd` is not a real date.
    static func date(from ymd: String, calendar: Calendar = NativeQuoteExpiry.localCalendar) -> Date? {
        guard NativeQuoteExpiry.addDays(ymd, 0) != nil else { return nil }
        let parts = ymd.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return NativeQuoteExpiry.gregorian(in: calendar.timeZone)
            .date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    static func ymd(from date: Date, calendar: Calendar = NativeQuoteExpiry.localCalendar) -> String {
        NativeQuoteExpiry.today(now: date, calendar: calendar)
    }

    /// Today through today + 365, inclusive of the whole last day.
    static func range(today: String, calendar: Calendar = NativeQuoteExpiry.localCalendar) -> ClosedRange<Date> {
        let calendar = NativeQuoteExpiry.gregorian(in: calendar.timeZone)
        let lower = date(from: today, calendar: calendar).map { calendar.startOfDay(for: $0) } ?? Date()
        let lastDay = NativeQuoteExpiry.addDays(today, NativeQuoteExpiry.maximumValidityDays) ?? today
        let upper = date(from: lastDay, calendar: calendar)
            .flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
            .map { $0.addingTimeInterval(-1) } ?? lower
        return lower...max(lower, upper)
    }

    /// The date a "Doesn't expire" toggle switches back to: the last date
    /// chosen while it is still selectable, else today + the default
    /// validity (30 days when the setting is 0).
    static func fallback(lastChosen: String?, validityDays: Int, today: String) -> String {
        if let lastChosen, NativeQuoteExpiry.isSelectable(lastChosen, today: today) { return lastChosen }
        let days = validityDays > 0
            ? min(validityDays, NativeQuoteExpiry.maximumValidityDays)
            : NativeQuoteExpiry.defaultValidityDays
        return NativeQuoteExpiry.addDays(today, days) ?? today
    }
}
