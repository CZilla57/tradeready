import Foundation

// Task 10.04 (D1, D2, D3, D6): Today selectors, stats, and routing contract.
// Oracles: screens/TodayScreen.tsx, utils/dateHelpers.ts,
// utils/storage/dailyOps.ts, utils/estimateFollowUps.ts,
// __tests__/dateHelpers.test.js, __tests__/crossTabNavigation.test.tsx.
// Run under TZ=America/Phoenix (west-of-UTC, no DST) so an accidental
// UTC-parse of a bare date string would surface (FA-039); DST-specific edge
// cases pass an explicit America/New_York calendar instead, since Phoenix
// itself never observes DST.

private var failures = 0
private let decoder = JSONDecoder()

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected { failures += 1; print("FAIL: \(label) — expected \(expected), got \(actual)") }
}

private func decodeJob(_ json: String) -> Canonical.Job {
    try! decoder.decode(Canonical.Job.self, from: Data(json.utf8))
}

private func decodeInvoice(_ json: String) -> Canonical.Invoice {
    try! decoder.decode(Canonical.Invoice.self, from: Data(json.utf8))
}

private func decodeCustomer(_ json: String) -> Canonical.Customer {
    try! decoder.decode(Canonical.Customer.self, from: Data(json.utf8))
}

private func decodeRequest(_ json: String) -> Canonical.BookingRequest {
    try! decoder.decode(Canonical.BookingRequest.self, from: Data(json.utf8))
}

private func job(
    id: String, status: String = "lead", scheduledDate: String? = nil, start: String? = nil,
    estimateTotal: Decimal = 0, createdAt: String = "2026-08-01T00:00:00.000Z",
    estimateSentAt: String? = nil
) -> Canonical.Job {
    var record = decodeJob("""
    {"id":"\(id)","customerId":"c1","customerName":"Dana Fox","title":"Job \(id)",
     "description":"","status":"\(status)","address":"","estimateTotal":\(estimateTotal),
     "laborHours":0,"laborRate":85,"materials":[],"materialMarkup":20,"overhead":15,
     "margin":20,"notes":"","createdAt":"\(createdAt)"}
    """)
    record.scheduledDate = scheduledDate
    record.scheduledStartTime = start
    record.estimateSentAt = estimateSentAt
    return record
}

private func invoice(id: String, due: String, amount: Decimal = 100, paid: Bool = false) -> Canonical.Invoice {
    decodeInvoice("""
    {"id":"\(id)","customer":"Dana Fox","number":"\(id)","amount":\(amount),"due":"\(due)",
     "email":"","phone":"","desc":"","paid":\(paid)}
    """)
}

private func customer(id: String) -> Canonical.Customer {
    decodeCustomer("""
    {"id":"\(id)","name":"Cust \(id)","email":"","phone":"","address":"","notes":""}
    """)
}

private func bookedRequest(id: String, status: String, jobRef: String? = nil, handledAt: String? = nil, portalKind: String? = nil) -> Canonical.BookingRequest {
    var request = decodeRequest("""
    {"id":"\(id)","status":"\(status)","name":"Dana Fox","phone":"","email":"","address":"",
     "details":"details","preferredTiming":"","createdAt":"2026-08-01T00:00:00.000Z"}
    """)
    request.jobRef = jobRef
    request.handledAt = handledAt
    request.portalKind = portalKind
    return request
}

// MARK: - D6: exhaustive destination mapping

expectEqual(NativeTodayBriefing.destination(for: .job(jobId: "j1")), .job(jobId: "j1"), "target job")
expectEqual(NativeTodayBriefing.destination(for: .createInvoice(jobId: "j1")), .createInvoice(jobId: "j1"), "target createInvoice")
expectEqual(NativeTodayBriefing.destination(for: .invoice(invoiceId: "i1")), .invoice(invoiceId: "i1"), "target invoice")
expectEqual(NativeTodayBriefing.destination(for: .invoices), .invoices, "target invoices")
expectEqual(NativeTodayBriefing.destination(for: .jobs), .jobs, "target jobs")
expectEqual(NativeTodayBriefing.destination(for: .schedule(jobId: "j1")), .schedule(jobId: "j1"), "target schedule")
expectEqual(NativeTodayBriefing.destination(for: .selectDate(date: "2026-07-04")), .selectDate(date: "2026-07-04"), "target selectDate")
expectEqual(NativeTodayBriefing.destination(for: .customer(customerId: "c1")), .customer(customerId: "c1"), "target customer")
expectEqual(NativeTodayBriefing.destination(for: .customers), .customers, "target customers")
expectEqual(NativeTodayBriefing.destination(for: .money), .money, "target money")

// MARK: - Header: greeting cutoffs (§1.4), pinned to dateHelpers.test.js

func nyCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

func at(_ hour: Int, minute: Int = 0, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour, minute: minute))!
}

let ny = nyCalendar()
expectEqual(NativeTodayBriefing.greeting(now: at(0, calendar: ny), calendar: ny), "Good morning", "greeting midnight")
expectEqual(NativeTodayBriefing.greeting(now: at(11, minute: 59, calendar: ny), calendar: ny), "Good morning", "greeting 11:59")
expectEqual(NativeTodayBriefing.greeting(now: at(12, calendar: ny), calendar: ny), "Good afternoon", "greeting 12:00")
expectEqual(NativeTodayBriefing.greeting(now: at(16, minute: 59, calendar: ny), calendar: ny), "Good afternoon", "greeting 16:59")
expectEqual(NativeTodayBriefing.greeting(now: at(17, calendar: ny), calendar: ny), "Good evening", "greeting 17:00")
expectEqual(NativeTodayBriefing.greeting(now: at(23, calendar: ny), calendar: ny), "Good evening", "greeting 23:00")

// formatDisplayDate — pinned to dateHelpers.test.js
expectEqual(NativeTodayBriefing.formatDisplayDate("2026-07-04"), "Saturday, July 4", "formatDisplayDate Saturday")
expectEqual(NativeTodayBriefing.formatDisplayDate("2026-01-01"), "Thursday, January 1", "formatDisplayDate Thursday")

// scheduleSectionTitle
expectEqual(NativeTodayBriefing.scheduleSectionTitle(selectedDate: "2026-07-04", today: "2026-07-04"), "Today's Schedule", "scheduleSectionTitle today")
expectEqual(NativeTodayBriefing.scheduleSectionTitle(selectedDate: "2026-07-04", today: "2026-07-05"), "Saturday, Jul 4", "scheduleSectionTitle other day")

// MARK: - formatTimeRange — pinned to dateHelpers.test.js

expectEqual(NativeTodayBriefing.formatTimeRange(nil, nil), "Unscheduled", "timeRange nil/nil")
expectEqual(NativeTodayBriefing.formatTimeRange(nil, "11:00"), "Unscheduled", "timeRange nil/end")
expectEqual(NativeTodayBriefing.formatTimeRange("", nil), "Unscheduled", "timeRange empty")
expectEqual(NativeTodayBriefing.formatTimeRange("09:00", "11:00"), "9:00 AM – 11:00 AM", "timeRange 9-11")
expectEqual(NativeTodayBriefing.formatTimeRange("23:05", "23:45"), "11:05 PM – 11:45 PM", "timeRange late")
expectEqual(NativeTodayBriefing.formatTimeRange("13:30", nil), "1:30 PM", "timeRange start only")
expectEqual(NativeTodayBriefing.formatTimeRange("00:15", nil), "12:15 AM", "timeRange midnight")
expectEqual(NativeTodayBriefing.formatTimeRange("12:00", nil), "12:00 PM", "timeRange noon")

// MARK: - Week strip (§1.1), pinned to dateHelpers.test.js

expectEqual(NativeSchedule.weekDates(anchor: "2026-07-04") ?? [], [
    "2026-06-29", "2026-06-30", "2026-07-01", "2026-07-02", "2026-07-03", "2026-07-04", "2026-07-05",
], "getWeekDates Saturday anchor")
expectEqual(NativeSchedule.weekDates(anchor: "2026-07-05")?.first, "2026-06-29", "getWeekDates Sunday anchor start")
expectEqual(NativeSchedule.weekDates(anchor: "2026-06-29")?.first, "2026-06-29", "getWeekDates Monday anchor")

if let strip = NativeTodayBriefing.weekStrip(selectedDate: "2026-07-04", today: "2026-07-04", jobDates: ["2026-07-01"]) {
    expectEqual(strip.monthLabel, "Jun – Jul 2026", "weekMonthLabel cross-month")
    expectEqual(strip.days.count, 7, "weekStrip day count")
    expect(strip.days.first { $0.date == "2026-07-04" }?.isSelected == true, "weekStrip selected flag")
    expect(strip.days.first { $0.date == "2026-07-04" }?.isToday == true, "weekStrip today flag")
    expect(strip.days.first { $0.date == "2026-07-01" }?.hasJobs == true, "weekStrip hasJobs flag")
    expect(strip.days.first { $0.date == "2026-07-02" }?.hasJobs == false, "weekStrip no-jobs flag")
} else {
    failures += 1; print("FAIL: weekStrip cross-month returned nil")
}

if let strip = NativeTodayBriefing.weekStrip(selectedDate: "2026-07-15", today: "2026-07-15", jobDates: []) {
    expectEqual(strip.monthLabel, "Jul 2026", "weekMonthLabel single-month")
} else {
    failures += 1; print("FAIL: weekStrip single-month returned nil")
}

// Week boundary: DST spring-forward week (America/New_York DST starts
// 2026-03-08) is pure epoch-day string math with no wall-clock dependency —
// confirms the week strip is unaffected by the transition.
expectEqual(NativeSchedule.weekDates(anchor: "2026-03-08") ?? [], [
    "2026-03-02", "2026-03-03", "2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07", "2026-03-08",
], "getWeekDates across DST spring-forward")

// shiftDate — pinned to dateHelpers.test.js
expectEqual(NativeTodayBriefing.shiftDate("2026-07-04", days: 1), "2026-07-05", "shiftDate +1")
expectEqual(NativeTodayBriefing.shiftDate("2026-07-04", days: -1), "2026-07-03", "shiftDate -1")
expectEqual(NativeTodayBriefing.shiftDate("2026-07-04", days: 7), "2026-07-11", "shiftDate +7")
expectEqual(NativeTodayBriefing.shiftDate("2026-07-31", days: 1), "2026-08-01", "shiftDate month rollover")
expectEqual(NativeTodayBriefing.shiftDate("2026-01-01", days: -1), "2025-12-31", "shiftDate year rollover")

// MARK: - Per-day schedule rows: unscheduled-last (§1.1)

let scheduleJobs = [
    job(id: "unscheduled1", scheduledDate: "2026-07-04", start: nil),
    job(id: "at-1000", scheduledDate: "2026-07-04", start: "10:00"),
    job(id: "at-0800", scheduledDate: "2026-07-04", start: "08:00"),
    job(id: "unscheduled2", scheduledDate: "2026-07-04", start: nil),
    job(id: "other-day", scheduledDate: "2026-07-05", start: "09:00"),
]
let rows = NativeTodayBriefing.scheduleRows(scheduleJobs, date: "2026-07-04")
expectEqual(rows.map(\.id), ["at-0800", "at-1000", "unscheduled1", "unscheduled2"], "scheduleRows unscheduled-last ordering")

// Day with no jobs — empty, not an error.
expect(NativeTodayBriefing.scheduleRows(scheduleJobs, date: "2026-09-01").isEmpty, "scheduleRows empty day")

// MARK: - Earnings for a date (§1.2) — not filtered by status

let earningsJobs = [
    job(id: "lead-scheduled", status: "lead", scheduledDate: "2026-07-04", estimateTotal: 200),
    job(id: "approved-scheduled", status: "approved", scheduledDate: "2026-07-04", estimateTotal: 300),
    job(id: "other-day", status: "approved", scheduledDate: "2026-07-05", estimateTotal: 999),
]
expectEqual(NativeTodayBriefing.earnings(for: "2026-07-04", jobs: earningsJobs), Decimal(500), "earnings includes leads, excludes other days")
expectEqual(NativeTodayBriefing.earnings(for: "2026-09-01", jobs: earningsJobs), Decimal(0), "earnings zero for empty day")

// MARK: - Overdue invoices (§1.4) — due-today is NOT overdue

let phoenix: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
    return calendar
}()
let nowJuly4 = phoenix.date(from: DateComponents(year: 2026, month: 7, day: 4, hour: 12))!

expectEqual(NativeTodayBriefing.daysPastDue("2026-07-04", now: nowJuly4, calendar: phoenix), 0, "daysPastDue due today is zero")
expectEqual(NativeTodayBriefing.daysPastDue("2026-07-03", now: nowJuly4, calendar: phoenix), 1, "daysPastDue due yesterday is one")
expectEqual(NativeTodayBriefing.daysPastDue("2026-07-05", now: nowJuly4, calendar: phoenix), -1, "daysPastDue due tomorrow is negative")

let overdueFixture = [
    invoice(id: "due-today", due: "2026-07-04"),
    invoice(id: "due-yesterday", due: "2026-07-03"),
    invoice(id: "due-long-ago", due: "2026-06-01"),
    invoice(id: "paid-overdue", due: "2026-06-01", paid: true),
]
let overdue = NativeTodayBriefing.overdueInvoices(overdueFixture, now: nowJuly4, calendar: phoenix)
expectEqual(overdue.map(\.id), ["due-long-ago", "due-yesterday"], "overdueInvoices excludes due-today and paid, sorted oldest first")

// DST edge: a due date the day AFTER America/New_York's fall-back (2026-11-01)
// must still count as exactly one day overdue when "now" is the next day,
// local-frame epoch-day math only (no wall-clock 24h assumption).
let nyFallBackCalendar = nyCalendar()
let dayAfterFallBack = nyFallBackCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
expectEqual(
    NativeTodayBriefing.daysPastDue("2026-11-01", now: dayAfterFallBack, calendar: nyFallBackCalendar),
    1,
    "daysPastDue across DST fall-back is exactly one day"
)

// MARK: - Leads (§1.4)

let leadJobsFixture = [
    job(id: "lead-new", status: "lead", createdAt: "2026-08-03T00:00:00.000Z"),
    job(id: "lead-old", status: "lead", createdAt: "2026-08-01T00:00:00.000Z"),
    job(id: "not-a-lead", status: "approved", createdAt: "2026-08-02T00:00:00.000Z"),
]
expectEqual(NativeTodayBriefing.leadJobs(leadJobsFixture).map(\.id), ["lead-old", "lead-new"], "leadJobs sorted oldest first, non-leads excluded")

// MARK: - Section caps: exactly-at-limit and one-over (§1.4)

let exactlyThree = ["a", "b", "c"]
let oneOver = ["a", "b", "c", "d"]
let cappedExact = NativeTodayBriefing.capped(exactlyThree, limit: NativeTodayBriefing.invoiceLimit)
expectEqual(cappedExact.visible, exactlyThree, "capped exact-limit visible")
expectEqual(cappedExact.extraCount, 0, "capped exact-limit no see-more")

let cappedOver = NativeTodayBriefing.capped(oneOver, limit: NativeTodayBriefing.leadLimit)
expectEqual(cappedOver.visible, ["a", "b", "c"], "capped one-over visible truncates to limit")
expectEqual(cappedOver.extraCount, 1, "capped one-over see-more count")

// MARK: - Estimates awaiting response (§2a) — FOLLOW_UP_DAYS boundary + toggle

let sentThreeDaysAgo = phoenix.date(byAdding: .day, value: -3, to: nowJuly4)!
let sentThreeDaysAgoStamp = { () -> String in
    let parts = phoenix.dateComponents([.year, .month, .day], from: sentThreeDaysAgo)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}()
let awaitingJobs = [
    job(id: "silent-3d", status: "estimate_sent", estimateSentAt: sentThreeDaysAgoStamp),
]
let awaitingOn = NativeTodayBriefing.awaitingEstimatesRow(jobs: awaitingJobs, now: nowJuly4, followUpsEnabled: true, calendar: phoenix)
expect(awaitingOn != nil, "awaitingEstimatesRow fires at the 3-day boundary")
expectEqual(awaitingOn?.label, "1 estimate awaiting response", "awaitingResponseLabel singular")

let awaitingOff = NativeTodayBriefing.awaitingEstimatesRow(jobs: awaitingJobs, now: nowJuly4, followUpsEnabled: false, calendar: phoenix)
expect(awaitingOff == nil, "awaitingEstimatesRow respects the follow-up toggle")

let sentTwoDaysAgo = phoenix.date(byAdding: .day, value: -2, to: nowJuly4)!
let sentTwoDaysAgoStamp = { () -> String in
    let parts = phoenix.dateComponents([.year, .month, .day], from: sentTwoDaysAgo)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}()
let notYetJobs = [job(id: "silent-2d", status: "estimate_sent", estimateSentAt: sentTwoDaysAgoStamp)]
let notYet = NativeTodayBriefing.awaitingEstimatesRow(jobs: notYetJobs, now: nowJuly4, followUpsEnabled: true, calendar: phoenix)
expect(notYet == nil, "awaitingEstimatesRow does not fire before the 3-day boundary")

// MARK: - First-action hero (§1.5, D5)

let sampleJobWithDate = job(id: "j1", scheduledDate: "2026-07-10")
let sampleJobNoDate = job(id: "j2")
let realJob = job(id: "real-job-1")

let heroSample = NativeTodayBriefing.hero(jobs: [sampleJobWithDate, sampleJobNoDate], customers: [], sampleTourDone: false)
expectEqual(heroSample?.kind, .sampleTour, "hero: sample tour when sample jobs exist, no real customers, tour not done")
expectEqual(heroSample?.destination, .job(jobId: "j1"), "hero: sample tour opens the scheduled sample job")

let heroSampleFallback = NativeTodayBriefing.hero(jobs: [sampleJobNoDate], customers: [], sampleTourDone: false)
expectEqual(heroSampleFallback?.destination, .job(jobId: "j2"), "hero: sample tour falls back to first sample job with no scheduled date")

let heroTourDone = NativeTodayBriefing.hero(jobs: [sampleJobWithDate], customers: [], sampleTourDone: true)
expect(heroTourDone == nil, "hero: no hero once the sample tour is done (not a fallthrough to create-job)")

let heroSampleWithRealCustomer = NativeTodayBriefing.hero(jobs: [sampleJobWithDate], customers: [customer(id: "real-cust")], sampleTourDone: false)
expect(heroSampleWithRealCustomer == nil, "hero: sample jobs + a real customer show NO hero (RN nested logic, not the contract's flattened pseudocode)")

let heroAddCustomer = NativeTodayBriefing.hero(jobs: [], customers: [], sampleTourDone: false)
expectEqual(heroAddCustomer?.kind, .addCustomer, "hero: add customer when no sample jobs and no real customers")
expectEqual(heroAddCustomer?.destination, .newCustomer, "hero: add customer destination")

let heroCreateJob = NativeTodayBriefing.hero(jobs: [], customers: [customer(id: "real-cust")], sampleTourDone: false)
expectEqual(heroCreateJob?.kind, .createJob, "hero: create job when no sample jobs and a real customer exists")
expectEqual(heroCreateJob?.destination, .newJob, "hero: create job destination")

let heroWithRealJob = NativeTodayBriefing.hero(jobs: [realJob], customers: [], sampleTourDone: false)
expect(heroWithRealJob == nil, "hero: no hero once any real job exists")

// MARK: - Booking attention presentation (§2.3, D3)

let rescheduleRow = NativeBookingAttention.Row(
    kind: .rescheduleRequested,
    request: bookedRequest(id: "bk1", status: "reschedule_requested"),
    jobID: "j1",
    note: "please move to Friday"
)
let reschedulePresentation = NativeTodayBriefing.bookingRowPresentation(rescheduleRow)
expectEqual(reschedulePresentation.title, "Dana Fox asked to reschedule", "booking row title: reschedule")
expectEqual(reschedulePresentation.jobDestination, .job(jobId: "j1"), "booking row destination: reschedule has a job")

let missingJobRow = NativeBookingAttention.Row(
    kind: .missingJob,
    request: bookedRequest(id: "bk2", status: "cancelled", jobRef: "gone"),
    jobID: "gone",
    note: nil
)
expectEqual(NativeTodayBriefing.bookingRowPresentation(missingJobRow).jobDestination, .jobs, "booking row destination: missingJob falls back to Jobs tab")

let portalChangeRow = NativeBookingAttention.Row(
    kind: .portalChange,
    request: bookedRequest(id: "bk3", status: "portal_change_requested", jobRef: nil, portalKind: "cancel"),
    jobID: nil,
    note: "customer note"
)
let portalPresentation = NativeTodayBriefing.bookingRowPresentation(portalChangeRow)
expectEqual(portalPresentation.title, "Dana Fox asked to cancel", "booking row title: portal change cancel verb")
expectEqual(portalPresentation.jobDestination, .jobs, "booking row destination: no jobID falls back to Jobs tab (never a dead action)")

// MARK: - bookingRowLabel (task 10.11 fix round 1 — moved out of view code)
//
// Short date-only form, distinct from `bookingRowPresentation(_:).summary`'s
// time-inclusive `when` used for the tap alert.

func bookedRequestWithSlot(id: String, status: String) -> Canonical.BookingRequest {
    decodeRequest("""
    {"id":"\(id)","status":"\(status)","name":"Dana Fox","phone":"","email":"","address":"",
     "details":"details","preferredTiming":"","createdAt":"2026-08-01T00:00:00.000Z",
     "slot":{"date":"2026-07-04","start":"09:00","end":"11:00","timeZone":"America/Phoenix",
     "startUtc":"","endUtc":""}}
    """)
}

let rescheduleRowWithSlot = NativeBookingAttention.Row(
    kind: .rescheduleRequested, request: bookedRequestWithSlot(id: "bk-slot", status: "reschedule_requested"),
    jobID: "j1", note: nil
)
expectEqual(
    NativeTodayBriefing.bookingRowLabel(rescheduleRowWithSlot),
    "Dana Fox asked to reschedule Saturday, July 4",
    "bookingRowLabel: reschedule uses the short date-only form"
)

let cancelledRow = NativeBookingAttention.Row(
    kind: .cancelled, request: bookedRequestWithSlot(id: "bk-cancel", status: "cancelled"), jobID: "j1", note: nil
)
expectEqual(
    NativeTodayBriefing.bookingRowLabel(cancelledRow),
    "Booking cancelled — Dana Fox, Saturday, July 4",
    "bookingRowLabel: cancelled uses the short date-only form"
)

expectEqual(
    NativeTodayBriefing.bookingRowLabel(portalChangeRow),
    "Dana Fox asked to cancel an appointment",
    "bookingRowLabel: portal change ignores the slot date entirely, mirrors the cancel/reschedule verb"
)

expectEqual(
    NativeTodayBriefing.bookingRowLabel(missingJobRow),
    NativeTodayBriefing.bookingRowPresentation(missingJobRow).summary,
    "bookingRowLabel: native-only missingJob falls back to the presentation summary"
)

// MARK: - isSampleId (utils/sampleData.ts SAMPLE_ID_RE port)

expect(NativeTodayBriefing.isSampleId("j1"), "isSampleId j1")
expect(NativeTodayBriefing.isSampleId("c3"), "isSampleId c3")
expect(NativeTodayBriefing.isSampleId("2"), "isSampleId bare digit")
expect(NativeTodayBriefing.isSampleId("j1-sabc123"), "isSampleId namespaced")
expect(!NativeTodayBriefing.isSampleId("j4"), "isSampleId j4 is out of range")
expect(!NativeTodayBriefing.isSampleId("c1734567890123_4"), "isSampleId real id is never a false positive")

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
} else {
    print("All NativeTodayBriefing tests passed")
}
