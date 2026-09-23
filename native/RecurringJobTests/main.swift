import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ label: String) {
    let value = actual()
    guard value == expected else {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(value)")
        return
    }
}

private var utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

private func rule(
    id: String = "rj_test",
    cadence: String = "weekly",
    endCondition: String = "never",
    endCount: Int? = nil,
    endDate: String? = nil,
    occurrenceCount: Int = 1,
    lastGeneratedDate: String? = "2026-07-01",
    nextDueDate: String = "2026-07-08",
    isActive: Bool = true,
    jobCosts: String? = nil
) throws -> Canonical.RecurringJob {
    var fields = """
    "id":"\(id)","customerId":"c1","customerName":"Alice","title":"Lawn service",\
    "description":"","address":"1 Main St","notes":"","estimateTotal":100,\
    "laborHours":1,"laborRate":85,"materials":[],"materialMarkup":20,\
    "overhead":15,"margin":20,"cadence":"\(cadence)","endCondition":"\(endCondition)",\
    "occurrenceCount":\(occurrenceCount),"nextDueDate":"\(nextDueDate)",\
    "isActive":\(isActive ? "true" : "false"),"createdAt":"2026-06-01"
    """
    if let endCount { fields += ",\"endCount\":\(endCount)" }
    if let endDate { fields += ",\"endDate\":\"\(endDate)\"" }
    if let lastGeneratedDate { fields += ",\"lastGeneratedDate\":\"\(lastGeneratedDate)\"" }
    if let jobCosts { fields += ",\"jobCosts\":\(jobCosts)" }
    return try JSONDecoder().decode(Canonical.RecurringJob.self, from: Data("{\(fields)}".utf8))
}

private func existingJob(ruleID: String = "rj_test", occurrence: Int = 2) throws -> Canonical.Job {
    let data = Data("""
    {
      "id":"j1751000000000_\(ruleID)_\(occurrence)","customerId":"c1","customerName":"Alice",\
      "title":"Lawn service","description":"","status":"scheduled","address":"1 Main St",\
      "estimateTotal":100,"laborHours":1,"laborRate":85,"materials":[],\
      "materialMarkup":20,"overhead":15,"margin":20,"notes":"",\
      "scheduledDate":"2026-07-08","createdAt":"2026-07-08",\
      "recurringJobId":"\(ruleID)","occurrenceNumber":\(occurrence)
    }
    """.utf8)
    return try JSONDecoder().decode(Canonical.Job.self, from: data)
}

private func run(
    rules: [Canonical.RecurringJob],
    jobs: [Canonical.Job] = [],
    today: String
) -> NativeRecurringJobGeneration {
    NativeRecurringJobs.generate(
        rules: rules,
        jobs: jobs,
        today: today,
        makeJobID: { ruleID, occurrence in "jtest_\(ruleID)_\(occurrence)" },
        calendar: utcCalendar
    )
}

@main
struct RecurringJobTests {
    static func main() throws {
        // Due today: one scheduled occurrence carrying the rule's fields.
        do {
            let result = run(rules: [try rule()], today: "2026-07-08")
            expectEqual(result.newJobs.count, 1, "due rule generates one job")
            expect(result.didChange, "due rule marks didChange")
            let job = result.newJobs[0]
            expectEqual(job.scheduledDate, "2026-07-08", "occurrence is scheduled on the due date")
            expectEqual(job.status, "scheduled", "occurrence status is scheduled")
            expectEqual(job.recurringJobId, "rj_test", "occurrence links the rule")
            expectEqual(job.occurrenceNumber, 2, "occurrence number increments")
            expectEqual(job.customerId, "c1", "occurrence copies customer id")
            expectEqual(job.customerName, "Alice", "occurrence copies customer name")
            expectEqual(job.title, "Lawn service", "occurrence copies title")
            expectEqual(job.address, "1 Main St", "occurrence copies address")
            expectEqual(job.estimateTotal, Decimal(100), "occurrence copies pricing")
            expectEqual(job.laborRate, Decimal(85), "occurrence copies labor rate")
            expect(job.jobCosts == nil, "absent direct costs stay absent")
            expect(job.invoiceId == nil, "occurrence starts without an invoice")
            expect(job.scheduledStartTime == nil && job.scheduledEndTime == nil, "occurrence has no time window")
            expect(job.photos == nil && job.timeSessions == nil, "occurrence inherits no photos or time")
            expect(job.approval == nil && job.changeOrders == nil, "occurrence inherits no approvals or change orders")
            expectEqual(result.updatedRules.count, 1, "due rule reports one updated rule")
            let updated = result.updatedRules[0]
            expectEqual(updated.occurrenceCount, 2, "rule occurrence count advances")
            expectEqual(updated.lastGeneratedDate, "2026-07-08", "rule stamps last generated date")
            expectEqual(updated.nextDueDate, "2026-07-15", "weekly rule advances seven days")
            expect(updated.isActive, "never-ending rule stays active")
        }

        // Stale dedupe: another device already generated this occurrence.
        do {
            let result = run(
                rules: [try rule()],
                jobs: [try existingJob()],
                today: "2026-07-08"
            )
            expectEqual(result.newJobs.count, 0, "stale dedupe creates no duplicate")
            expect(result.didChange, "stale dedupe still advances the rule")
            expectEqual(result.updatedRules.count, 1, "stale dedupe reports the advanced rule")
            expectEqual(result.updatedRules[0].occurrenceCount, 2, "stale rule converges occurrence count")
            expectEqual(result.updatedRules[0].nextDueDate, "2026-07-15", "stale rule converges next due date")
        }

        // Catch-up: four missed weekly occurrences all generate.
        do {
            let result = run(
                rules: [try rule(nextDueDate: "2026-07-01")],
                today: "2026-07-22"
            )
            expectEqual(result.newJobs.count, 4, "catch-up generates every missed occurrence")
            expectEqual(
                result.newJobs.map { $0.scheduledDate ?? "" },
                ["2026-07-01", "2026-07-08", "2026-07-15", "2026-07-22"],
                "catch-up occurrences land on their due dates"
            )
            expectEqual(
                result.newJobs.compactMap(\.occurrenceNumber),
                [2, 3, 4, 5],
                "catch-up occurrence numbers sequence"
            )
            expectEqual(result.updatedRules[0].occurrenceCount, 5, "catch-up advances past every occurrence")
            expectEqual(result.updatedRules[0].nextDueDate, "2026-07-29", "catch-up parks past today")
        }

        // Count end: already at the limit deactivates without generating.
        do {
            let result = run(
                rules: [try rule(endCondition: "count", endCount: 3, occurrenceCount: 3)],
                today: "2026-07-08"
            )
            expectEqual(result.newJobs.count, 0, "count end generates nothing")
            expect(!result.updatedRules[0].isActive, "count end deactivates the rule")
            expect(result.didChange, "count end still persists the deactivation")
        }

        // Count end mid-catch-up: generates through the limit, then stops.
        do {
            let result = run(
                rules: [try rule(
                    endCondition: "count",
                    endCount: 4,
                    occurrenceCount: 1,
                    nextDueDate: "2026-07-01"
                )],
                today: "2026-07-22"
            )
            expectEqual(result.newJobs.count, 3, "count end generates through the limit only")
            expect(!result.updatedRules[0].isActive, "count end deactivates after the final occurrence")
            expectEqual(result.updatedRules[0].occurrenceCount, 4, "count end stops exactly at the limit")
        }

        // Date end: a past end date deactivates without generating.
        do {
            let result = run(
                rules: [try rule(endCondition: "date", endDate: "2026-07-07")],
                today: "2026-07-08"
            )
            expectEqual(result.newJobs.count, 0, "date end generates nothing")
            expect(!result.updatedRules[0].isActive, "date end deactivates the rule")
        }

        // Date end mid-catch-up: the end date itself still generates.
        do {
            let result = run(
                rules: [try rule(
                    endCondition: "date",
                    endDate: "2026-07-08",
                    occurrenceCount: 1,
                    nextDueDate: "2026-07-01"
                )],
                today: "2026-07-22"
            )
            expectEqual(
                result.newJobs.map { $0.scheduledDate ?? "" },
                ["2026-07-01", "2026-07-08"],
                "the end date itself still generates"
            )
            expect(!result.updatedRules[0].isActive, "the day after the end date deactivates")
        }

        // Paused: an inactive rule is skipped entirely.
        do {
            let result = run(rules: [try rule(isActive: false)], today: "2026-07-08")
            expectEqual(result.newJobs.count, 0, "paused rule generates nothing")
            expectEqual(result.updatedRules.count, 0, "paused rule reports no updates")
            expect(!result.didChange, "paused rule leaves no work to persist")
        }

        // Not yet due: generates nothing.
        do {
            let result = run(rules: [try rule(nextDueDate: "2026-07-15")], today: "2026-07-08")
            expect(!result.didChange, "a rule due in the future leaves no work to persist")
        }

        // Date overflow: monthly from Jan 31 keeps JS setter overflow.
        do {
            let result = run(
                rules: [try rule(
                    cadence: "monthly",
                    occurrenceCount: 0,
                    lastGeneratedDate: nil,
                    nextDueDate: "2026-01-31"
                )],
                today: "2026-01-31"
            )
            expectEqual(result.newJobs.count, 1, "overflow month still generates")
            expectEqual(result.newJobs[0].scheduledDate, "2026-01-31", "overflow occurrence keeps its due date")
            expectEqual(
                result.updatedRules[0].nextDueDate,
                "2026-03-03",
                "monthly overflow matches JS Date, never Calendar clamping"
            )
        }

        // Optional direct costs ride along only when the rule carries them.
        do {
            let withCosts = try rule(jobCosts: """
            [{"id":"jc1","label":"Filter","category":"materials","quantity":1,\
            "unitCost":12,"markupPercent":0,"markupPolicy":"none",\
            "taxable":false,"customerVisible":true}]
            """)
            let carrying = run(rules: [withCosts], today: "2026-07-08")
            expectEqual(carrying.newJobs[0].jobCosts?.count, 1, "rule direct costs copy onto the occurrence")
            let plain = run(rules: [try rule()], today: "2026-07-08")
            expect(plain.newJobs[0].jobCosts == nil, "rules without direct costs stay without them")
        }

        if failures == 0 {
            print("RecurringJobTests: PASS")
        } else {
            print("RecurringJobTests: FAIL (\(failures))")
            exit(1)
        }
    }
}
