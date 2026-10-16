import Foundation

// Phase 32 quote expiration dates: the pure `NativeQuoteExpiry` policy.
// Spec: docs/superpowers/specs/2026-10-03-quote-expiration-design.md (§2.4, §3, §6.2, §8)
// The runner pins TZ=America/Phoenix (west of UTC) so any bare-date parse in
// the process zone would shift a day (FA-039).

private var failures = 0
private var checks = 0

private func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    guard (try? condition()) == true else {
        failures += 1
        print("FAIL: \(label)")
        return
    }
}

private func run(_ label: String, _ body: () throws -> Void) {
    do { try body() }
    catch {
        failures += 1
        print("FAIL: \(label) — \(error)")
    }
}

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private let phoenix = calendar("America/Phoenix")

private func instant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private func settings(validityDays: String?) throws -> Canonical.Settings {
    let days = validityDays.map { ",\"estimateValidityDays\":\($0)" } ?? ""
    let json = """
    {"businessName":"Dave Plumbing","contactName":"Dave","phone":"","email":"","address":"","trade":"plumbing","laborRate":85,"materialMarkup":20,"overheadPercent":15,"marginPercent":20,"minimumJobFee":75,"travelFeePerMile":0,"emergencyMultiplier":1.5,"paymentNotes":"","provider":"stripe","rules":[]\(days)}
    """
    return try JSONDecoder().decode(Canonical.Settings.self, from: Data(json.utf8))
}

private func job(status: String = "estimate_sent", validUntil: String? = nil) throws -> Canonical.Job {
    let date = validUntil.map { ",\"estimateValidUntil\":\"\($0)\"" } ?? ""
    let json = """
    {"id":"j1","customerId":"c1","customerName":"Dave Smith","title":"Water heater swap","description":"","status":"\(status)","address":"","estimateTotal":850,"laborHours":3,"laborRate":85,"materials":[],"materialMarkup":20,"overhead":15,"margin":20,"notes":"","invoiceId":null,"createdAt":"2026-07-01","estimateSentAt":"2026-10-01"\(date)}
    """
    return try JSONDecoder().decode(Canonical.Job.self, from: Data(json.utf8))
}

// MARK: - Constants

expect(NativeQuoteExpiry.defaultValidityDays == 30, "default validity is 30 days")
expect(NativeQuoteExpiry.maximumValidityDays == 365, "maximum validity is 365 days")
expect(NativeQuoteExpiry.expiringSoonDays == 3, "expiring-soon window is 3 days")
expect(NativeQuoteExpiry.expiredLookbackDays == 14, "expired lookback is 14 days")
expect(NativeQuoteExpiry.expiryReminderLeadDays == 2, "expiry reminder fires 2 days ahead")
expect(NativeQuoteExpiry.anywhereOnEarthZoneID == "Etc/GMT+12", "anywhere-on-Earth zone id")

// MARK: - validityDays

run("validityDays") {
    expect(NativeQuoteExpiry.validityDays(nil) == 30, "no settings reads as 30")
    expect(NativeQuoteExpiry.validityDays(try settings(validityDays: nil)) == 30, "absent key reads as 30")
    expect(NativeQuoteExpiry.validityDays(try settings(validityDays: "0")) == 0, "0 means no expiry")
    expect(NativeQuoteExpiry.validityDays(try settings(validityDays: "14")) == 14, "an in-range value is kept")
    expect(NativeQuoteExpiry.validityDays(try settings(validityDays: "365")) == 365, "365 is the inclusive maximum")
    expect(NativeQuoteExpiry.validityDays(try settings(validityDays: "366")) == 365, "above 365 clamps to 365")
    expect(NativeQuoteExpiry.validityDays(try settings(validityDays: "99999")) == 365, "a huge value clamps to 365")
    expect(NativeQuoteExpiry.validityDays(try settings(validityDays: "-5")) == 0, "a negative value clamps to 0")
}

// MARK: - Civil date math

expect(NativeQuoteExpiry.addDays("2026-10-03", 30) == "2026-11-02", "+30 from Oct 3 is Nov 2")
expect(NativeQuoteExpiry.addDays("2026-01-31", 1) == "2026-02-01", "month end rolls over")
expect(NativeQuoteExpiry.addDays("2026-12-31", 1) == "2027-01-01", "year end rolls over")
expect(NativeQuoteExpiry.addDays("2028-02-28", 1) == "2028-02-29", "Feb 29 exists in a leap year")
expect(NativeQuoteExpiry.addDays("2028-02-29", 1) == "2028-03-01", "Feb 29 rolls into March")
expect(NativeQuoteExpiry.addDays("2027-02-28", 1) == "2027-03-01", "no Feb 29 in a common year")
expect(NativeQuoteExpiry.addDays("2027-03-01", -1) == "2027-02-28", "negative days step back over a month end")
expect(NativeQuoteExpiry.addDays("2026-11-01", 1) == "2026-11-02", "DST end day is still one civil day")
expect(NativeQuoteExpiry.addDays("2026-03-08", 1) == "2026-03-09", "DST start day is still one civil day")
expect(NativeQuoteExpiry.addDays("2026-10-03", 0) == "2026-10-03", "+0 is identity")
expect(NativeQuoteExpiry.addDays("2026-10-03", 365) == "2027-10-03", "+365 from a common year")
expect(NativeQuoteExpiry.addDays("2027-02-29", 1) == nil, "a non-existent date is rejected")
expect(NativeQuoteExpiry.addDays("2026-13-01", 1) == nil, "month 13 is rejected")
expect(NativeQuoteExpiry.addDays("2026-1-01", 1) == nil, "a short month is rejected")
expect(NativeQuoteExpiry.addDays("2026-10-03T00:00:00Z", 1) == nil, "a timestamp is not a civil date")
expect(NativeQuoteExpiry.addDays("", 1) == nil, "empty is rejected")

expect(NativeQuoteExpiry.days(from: "2026-10-03", to: "2026-11-02") == 30, "30 days Oct 3 → Nov 2")
expect(NativeQuoteExpiry.days(from: "2026-11-02", to: "2026-10-03") == -30, "negative when to is earlier")
expect(NativeQuoteExpiry.days(from: "2026-12-31", to: "2027-01-01") == 1, "across a year end")
expect(NativeQuoteExpiry.days(from: "2028-02-28", to: "2028-03-01") == 2, "across Feb 29")
expect(NativeQuoteExpiry.days(from: "2027-02-28", to: "2027-03-01") == 1, "across a common February")
expect(NativeQuoteExpiry.days(from: "2026-10-31", to: "2026-11-02") == 2, "across the DST end")
expect(NativeQuoteExpiry.days(from: "2026-10-03", to: "2026-10-03") == 0, "same day is 0")
expect(NativeQuoteExpiry.days(from: "garbage", to: "2026-10-03") == nil, "malformed from is nil")
expect(NativeQuoteExpiry.days(from: "2026-10-03", to: "2026-02-30") == nil, "malformed to is nil")

// MARK: - today (FA-039)

let lateEveningPhoenix = instant("2026-10-03T06:30:00Z") // Oct 2, 23:30 MST
let todayPhoenix = NativeQuoteExpiry.today(now: lateEveningPhoenix, calendar: phoenix)
expect(todayPhoenix == "2026-10-02", "FA-039: at 06:30Z today is Oct 2 in Phoenix, not the UTC date")
expect(NativeQuoteExpiry.addDays(todayPhoenix, 30) == "2026-11-01", "FA-039: +30 from the Phoenix today is Nov 1, not Nov 2")
expect(NativeQuoteExpiry.today(now: lateEveningPhoenix, calendar: calendar("UTC")) == "2026-10-03", "the UTC calendar reads the UTC date")
expect(NativeQuoteExpiry.today(now: lateEveningPhoenix, calendar: calendar("Pacific/Auckland")) == "2026-10-03", "Auckland is ahead")
expect(NativeQuoteExpiry.today(now: instant("2026-10-03T07:00:00Z"), calendar: phoenix) == "2026-10-03", "Phoenix midnight flips the day")

// MARK: - proposedValidUntil (§3)

run("proposedValidUntil") {
    let today = "2026-10-03"
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(status: "lead"), validityDays: 30, today: today) == "2026-11-02",
           "a lead proposes today + validityDays")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(status: "lead"), validityDays: 0, today: today) == nil,
           "validityDays 0 proposes no date")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(status: "lead", validUntil: "2026-12-25"), validityDays: 30, today: today) == "2026-11-02",
           "a stale date on a lead is ignored (a revised estimate is a new offer)")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(status: "lead", validUntil: "2026-12-25"), validityDays: 0, today: today) == nil,
           "a stale lead date is ignored even with validityDays 0")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(validUntil: "2026-10-20"), validityDays: 30, today: today) == "2026-10-20",
           "a re-send keeps a still-valid date")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(validUntil: "2026-10-03"), validityDays: 30, today: today) == "2026-10-03",
           "a re-send keeps a date that is today (inclusive)")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(validUntil: "2026-10-20"), validityDays: 0, today: today) == "2026-10-20",
           "a still-valid date is kept even when the default is now 0")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(validUntil: "2026-10-02"), validityDays: 30, today: today) == "2026-11-02",
           "a re-send with a past date gets a fresh proposal")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(validUntil: "2026-10-02"), validityDays: 0, today: today) == nil,
           "a past date with validityDays 0 proposes no date")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(), validityDays: 14, today: today) == "2026-10-17",
           "a re-send without a date gets a fresh proposal")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(validUntil: "not-a-date"), validityDays: 30, today: today) == "2026-11-02",
           "a malformed stored date gets a fresh proposal")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(validUntil: "2028-01-01"), validityDays: 30, today: today) == "2026-11-02",
           "a stored date beyond today+365 is not selectable and gets a fresh proposal")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(status: "lead"), validityDays: 999, today: today) == "2027-10-03",
           "a proposal clamps validityDays to 365")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(status: "lead"), validityDays: -3, today: today) == nil,
           "a negative validityDays proposes no date")
    expect(NativeQuoteExpiry.proposedValidUntil(job: try job(status: "lead"), validityDays: 30, today: "2026-12-15") == "2027-01-14",
           "a proposal crosses the year end")
}

// MARK: - isSelectable

expect(NativeQuoteExpiry.isSelectable(nil, today: "2026-10-03"), "Doesn't expire is selectable")
expect(NativeQuoteExpiry.isSelectable("2026-10-03", today: "2026-10-03"), "today is selectable")
expect(!NativeQuoteExpiry.isSelectable("2026-10-02", today: "2026-10-03"), "yesterday is not selectable")
expect(NativeQuoteExpiry.isSelectable("2027-10-03", today: "2026-10-03"), "today+365 is selectable")
expect(!NativeQuoteExpiry.isSelectable("2027-10-04", today: "2026-10-03"), "today+366 is not selectable")
expect(!NativeQuoteExpiry.isSelectable("2026-02-30", today: "2026-01-03"), "a non-existent date is not selectable")
expect(!NativeQuoteExpiry.isSelectable("", today: "2026-10-03"), "empty is not selectable")

// MARK: - state

run("state") {
    let today = "2026-10-03"
    expect(NativeQuoteExpiry.state(job: try job(validUntil: "2026-10-06"), today: today) == .open(validUntil: "2026-10-06", daysLeft: 3),
           "open with days left")
    expect(NativeQuoteExpiry.state(job: try job(validUntil: "2026-10-03"), today: today) == .open(validUntil: "2026-10-03", daysLeft: 0),
           "the last valid day is open with 0 days left")
    expect(NativeQuoteExpiry.state(job: try job(validUntil: "2026-10-02"), today: today) == .expired(validUntil: "2026-10-02", daysAgo: 1),
           "the day after is expired 1 day ago")
    expect(NativeQuoteExpiry.state(job: try job(validUntil: "2026-09-19"), today: today) == .expired(validUntil: "2026-09-19", daysAgo: 14),
           "two weeks ago")
    expect(NativeQuoteExpiry.state(job: try job(), today: today) == nil, "no date has no state")
    expect(NativeQuoteExpiry.state(job: try job(validUntil: "garbage"), today: today) == nil, "a malformed date has no state")
    expect(NativeQuoteExpiry.state(job: try job(status: "lead", validUntil: "2026-10-02"), today: today) == nil,
           "a lead has no state even with a stale date")
    expect(NativeQuoteExpiry.state(job: try job(status: "scheduled", validUntil: "2026-10-02"), today: today) == nil,
           "a scheduled job has no state")
    expect(NativeQuoteExpiry.state(job: try job(status: "approved", validUntil: "2026-10-02"), today: today) == nil,
           "an approved job has no state")
}

// MARK: - displayDate and relativePhrase

expect(NativeQuoteExpiry.displayDate("2026-11-02", style: .long) == "November 2, 2026", "long style")
expect(NativeQuoteExpiry.displayDate("2026-11-02", style: .medium) == "Nov 2, 2026", "medium style")
expect(NativeQuoteExpiry.displayDate("2026-11-02", style: .short) == "Nov 2", "short style")
expect(NativeQuoteExpiry.displayDate("2027-01-01", style: .long) == "January 1, 2027", "Jan 1 does not shift to Dec 31 west of UTC")
expect(NativeQuoteExpiry.displayDate("2028-02-29", style: .medium) == "Feb 29, 2028", "Feb 29 displays")
expect(NativeQuoteExpiry.displayDate("garbage", style: .long) == "garbage", "a malformed date is returned unchanged")
expect(ProcessInfo.processInfo.environment["TZ"] != nil, "the runner pins a process time zone")
run("displayDate under every process zone") {
    // Builds from components and formats in UTC, so no process or device zone shifts the day.
    let original = TimeZone.current
    defer { NSTimeZone.default = original }
    for zone in ["America/Phoenix", "Pacific/Honolulu", "Pacific/Kiritimati", "Etc/GMT+12", "UTC"] {
        NSTimeZone.default = TimeZone(identifier: zone)!
        expect(NativeQuoteExpiry.displayDate("2026-11-02", style: .medium) == "Nov 2, 2026", "Nov 2 stays Nov 2 in \(zone)")
    }
}

expect(NativeQuoteExpiry.relativePhrase(daysLeft: 0) == "today", "0 days is today")
expect(NativeQuoteExpiry.relativePhrase(daysLeft: 1) == "tomorrow", "1 day is tomorrow")
expect(NativeQuoteExpiry.relativePhrase(daysLeft: 3) == "in 3 days", "3 days")
expect(NativeQuoteExpiry.relativePhrase(daysLeft: 2) == "in 2 days", "2 days")

// MARK: - isExpired: shared parity vectors (§2.4)

run("isExpired shared vectors") {
    guard let path = ProcessInfo.processInfo.environment["QUOTE_EXPIRY_VECTORS"] else {
        throw NSError(domain: "QuoteExpiryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "QUOTE_EXPIRY_VECTORS is not set"])
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let vectors = root["vectors"] as? [[String: Any]]
    else { throw NSError(domain: "QuoteExpiryTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "malformed vectors file"]) }
    expect(vectors.count >= 5, "the shared fixture carries the §8 vectors")
    var asserted = 0
    for vector in vectors {
        guard let name = vector["name"] as? String,
              let nowText = vector["now"] as? String,
              let now = ISO8601DateFormatter().date(from: nowText),
              let expected = vector["expired"] as? Bool
        else {
            expect(false, "vector is well formed: \(vector)")
            continue
        }
        let validUntil = vector["validUntil"] as? String
        let zone = vector["timeZone"] as? String
        let actual = validUntil.map { NativeQuoteExpiry.isExpired(validUntil: $0, timeZoneID: zone, now: now) } ?? false
        expect(actual == expected, "vector '\(name)': expected expired=\(expected), got \(actual)")
        asserted += 1
    }
    expect(asserted == vectors.count, "every shared vector was asserted")
}

expect(!NativeQuoteExpiry.isExpired(validUntil: "garbage", timeZoneID: "America/Phoenix", now: instant("2099-01-01T00:00:00Z")),
       "a malformed date never expires")
expect(!NativeQuoteExpiry.isExpired(validUntil: "2026-11-02", timeZoneID: "", now: instant("2026-11-03T11:59:59Z")),
       "an empty zone uses anywhere on Earth (still valid)")
expect(NativeQuoteExpiry.isExpired(validUntil: "2026-11-02", timeZoneID: "", now: instant("2026-11-03T12:00:00Z")),
       "an empty zone uses anywhere on Earth (expired)")
expect(!NativeQuoteExpiry.isExpired(validUntil: "2026-11-02", timeZoneID: "America/Phoenix", now: instant("2026-11-02T12:00:00Z")),
       "the validUntil day itself is valid")

// MARK: - NativeValidUntilPicker (the DatePicker bridge, §6.4 / §6.5)

run("picker round trip") {
    // The day the owner picks is the day stored, in the zone the picker
    // shows — west of UTC, across both US DST changes, and far east.
    let newYork = calendar("America/New_York")
    let auckland = calendar("Pacific/Auckland")
    for (name, cal) in [("Phoenix", phoenix), ("New York", newYork), ("Auckland", auckland)] {
        for ymd in ["2026-11-01", "2026-11-02", "2027-03-14", "2027-01-01", "2028-02-29", "2026-12-31"] {
            guard let picked = NativeValidUntilPicker.date(from: ymd, calendar: cal) else {
                expect(false, "picker: \(ymd) builds a date in \(name)"); continue
            }
            expect(NativeValidUntilPicker.ymd(from: picked, calendar: cal) == ymd, "picker: \(ymd) round-trips in \(name)")
            expect(cal.component(.hour, from: picked) == 12, "picker: \(ymd) is noon local in \(name)")
        }
    }
    expect(NativeValidUntilPicker.date(from: "2026-02-30", calendar: phoenix) == nil, "picker: a non-existent date builds nothing")
    expect(NativeValidUntilPicker.date(from: "garbage", calendar: phoenix) == nil, "picker: garbage builds nothing")

    // The range is today 00:00 through the last second of today + 365, local.
    let range = NativeValidUntilPicker.range(today: "2026-10-03", calendar: phoenix)
    expect(range.lowerBound == instant("2026-10-03T07:00:00Z"), "picker: the range starts at local midnight today")
    expect(range.upperBound == instant("2027-10-04T06:59:59Z"), "picker: the range ends at 23:59:59 local on today + 365")
    expect(NativeValidUntilPicker.ymd(from: range.lowerBound, calendar: phoenix) == "2026-10-03"
           && NativeValidUntilPicker.ymd(from: range.upperBound, calendar: phoenix) == "2027-10-03",
           "picker: both bounds read back as selectable days")
    let dstRange = NativeValidUntilPicker.range(today: "2026-03-08", calendar: newYork)
    expect(NativeValidUntilPicker.ymd(from: dstRange.lowerBound, calendar: newYork) == "2026-03-08",
           "picker: the range starts on today on a DST-change day")

    // "Doesn't expire" switched off: the last chosen date while selectable,
    // else today + the default (30 when the setting is 0).
    expect(NativeValidUntilPicker.fallback(lastChosen: "2026-12-15", validityDays: 30, today: "2026-10-03") == "2026-12-15",
           "picker: a still-selectable last choice comes back")
    expect(NativeValidUntilPicker.fallback(lastChosen: "2026-10-02", validityDays: 14, today: "2026-10-03") == "2026-10-17",
           "picker: a passed last choice falls back to today + validity")
    expect(NativeValidUntilPicker.fallback(lastChosen: nil, validityDays: 0, today: "2026-10-03") == "2026-11-02",
           "picker: validity 0 falls back to today + 30")
    expect(NativeValidUntilPicker.fallback(lastChosen: nil, validityDays: 999, today: "2026-10-03") == "2027-10-03",
           "picker: the fallback is capped at today + 365")
}

// MARK: - Non-Gregorian device calendars (review fix 2026-10-03, finding 1)

/// `Calendar.current` on an iPhone whose Settings › General › Language &
/// Region › Calendar is Buddhist or Japanese, in Phoenix. The stored date is
/// a Gregorian `YYYY-MM-DD` the Worker and the customer page read, so every
/// civil date must come out Gregorian whatever the device calendar is.
private func deviceCalendar(_ identifier: Calendar.Identifier) -> Calendar {
    var calendar = Calendar(identifier: identifier)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
    return calendar
}

let noonPhoenix = instant("2026-10-03T19:00:00Z") // Oct 3, 12:00 MST
run("non-Gregorian device calendars") {
    for (name, device) in [("Buddhist", deviceCalendar(.buddhist)), ("Japanese", deviceCalendar(.japanese))] {
        expect(device.component(.year, from: noonPhoenix) != 2026,
               "\(name): the device calendar's own year is not the Gregorian one (the case under test)")
        let today = NativeQuoteExpiry.today(now: noonPhoenix, calendar: device)
        expect(today == "2026-10-03", "\(name): today is the Gregorian date (got \(today))")
        expect(NativeQuoteExpiry.today(now: lateEveningPhoenix, calendar: device) == "2026-10-02",
               "\(name): today still reads the calendar's zone (FA-039)")
        expect(NativeQuoteExpiry.proposedValidUntil(job: try job(status: "lead"), validityDays: 30, today: today) == "2026-11-02",
               "\(name): the default proposal is Gregorian today + 30")
        expect(NativeQuoteExpiry.isSelectable("2026-11-02", today: today), "\(name): today + 30 is selectable")
        expect(NativeQuoteExpiry.state(job: try job(validUntil: "2026-11-02"), today: today)
               == .open(validUntil: "2026-11-02", daysLeft: 30), "\(name): a Gregorian date 30 days out is open")

        // The DatePicker bridge with the device calendar handed in.
        let picked = NativeValidUntilPicker.date(from: "2026-11-02", calendar: device)
        expect(picked == instant("2026-11-02T19:00:00Z"),
               "\(name): the picker builds noon Phoenix on the Gregorian day (got \(picked.map { "\($0)" } ?? "nil"))")
        expect(NativeValidUntilPicker.ymd(from: instant("2026-11-02T19:00:00Z"), calendar: device) == "2026-11-02",
               "\(name): the picker reads the Gregorian day back")
        let range = NativeValidUntilPicker.range(today: "2026-10-03", calendar: device)
        expect(range.lowerBound == instant("2026-10-03T07:00:00Z") && range.upperBound == instant("2027-10-04T06:59:59Z"),
               "\(name): the picker range is today…today+365 in Gregorian days")
    }
}

// The defaults. The runner runs this binary twice more with
// `-AppleLocale en_US@calendar=buddhist|japanese`, so there `Calendar.current`
// itself is the non-Gregorian calendar the review sheet and editor see.
run("defaults never use Calendar.current's calendar") {
    if let expected = ProcessInfo.processInfo.environment["QUOTE_EXPIRY_DEVICE_CALENDAR"] {
        expect("\(Calendar.current.identifier)" == expected,
               "the runner set Calendar.current to \(expected) (got \(Calendar.current.identifier))")
    }
    expect(NativeQuoteExpiry.today(now: noonPhoenix, calendar: .current) == "2026-10-03",
           "today with Calendar.current is the Gregorian date")
    expect(NativeValidUntilPicker.date(from: "2026-11-02") == instant("2026-11-02T19:00:00Z"),
           "the picker's default calendar builds the Gregorian day")
    expect(NativeValidUntilPicker.ymd(from: instant("2026-11-02T19:00:00Z")) == "2026-11-02",
           "the picker's default calendar reads the Gregorian day")
    let range = NativeValidUntilPicker.range(today: "2026-10-03")
    expect(range.lowerBound == instant("2026-10-03T07:00:00Z") && range.upperBound == instant("2027-10-04T06:59:59Z"),
           "the picker's default range is in Gregorian days")
}

if failures == 0 {
    print("PASS: native quote expiry tests (\(checks) checks)")
} else {
    print("FAILED: \(failures) native quote expiry test(s)")
    exit(1)
}
