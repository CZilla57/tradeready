import Foundation

/// Pure recurring-job occurrence generator, mirroring
/// `utils/recurringJobs.ts checkAndGenerateRecurringJobs`.
///
/// Takes the stored rules plus the stored jobs and returns every occurrence
/// due through `today`, with the rules already advanced past what was
/// generated. The caller (AppStore) commits both collections atomically and
/// queues both for sync; this type never touches persistence itself so the
/// swiftc domain harness can compile it standalone.
///
/// Behavior contract (pinned by `__tests__/recurringJobs.test.ts`):
/// - Generates all occurrences with `nextDueDate <= today` (catch-up).
/// - Dedupes by `(recurringJobId, occurrenceNumber)` so a job pulled from
///   another device is never recreated; the rule still advances so devices
///   converge to the same `nextDueDate`.
/// - Copies only the RN-authorized fields onto each occurrence: customer,
///   descriptive, pricing, materials, optional direct costs, schedule, and
///   recurrence linkage. Occurrences are `scheduled` on the due date.
/// - Advances `occurrenceCount` / `lastGeneratedDate` / `nextDueDate` per
///   occurrence and deactivates the rule at count/date boundaries.
/// - Paused rules (`isActive == false`) generate nothing.
/// - Date math retains the JavaScript setter-overflow behavior via
///   `RecurrenceRules.nextDate` (2026-01-31 + one month is 2026-03-03); it
///   must NOT be clamped with Calendar.
struct NativeRecurringJobGeneration {
    /// Occurrences created by this run, in due-date order.
    var newJobs: [Canonical.Job]
    /// Only the rules that changed (advanced or deactivated), by copy.
    /// Unchanged rules are omitted so the caller queues exactly what moved.
    var updatedRules: [Canonical.RecurringJob]
    /// Whether anything changed. When false the caller must skip its save.
    var didChange: Bool
}

enum NativeRecurringJobs {
    /// Generates every occurrence due through `today` ("YYYY-MM-DD").
    /// `makeJobID` stamps each occurrence (`ruleID`, `occurrence`) — the
    /// AppStore passes its `LocalIDGenerator.recurringJobID`, tests pass a
    /// deterministic stub.
    static func generate(
        rules: [Canonical.RecurringJob],
        jobs: [Canonical.Job],
        today: String,
        makeJobID: (String, Int) -> String,
        calendar: Calendar = .current
    ) -> NativeRecurringJobGeneration {
        var newJobs: [Canonical.Job] = []
        var updatedRules: [Canonical.RecurringJob] = []
        var seen: Set<String> = []
        seen.reserveCapacity(jobs.count)
        for job in jobs {
            guard let ruleID = job.recurringJobId, !ruleID.isEmpty,
                  let occurrence = job.occurrenceNumber
            else { continue }
            seen.insert(dedupeKey(ruleID: ruleID, occurrence: occurrence))
        }

        for var rule in rules {
            guard rule.isActive else { continue }
            var ruleChanged = false
            while rule.nextDueDate <= today {
                if isEndConditionMet(rule) {
                    rule.isActive = false
                    ruleChanged = true
                    break
                }
                guard let cadence = RecurrenceCadence(rawValue: rule.cadence) else { break }
                let occurrence = rule.occurrenceCount + 1
                let key = dedupeKey(ruleID: rule.id, occurrence: occurrence)
                if !seen.contains(key) {
                    let dueDate = rule.nextDueDate
                    newJobs.append(Canonical.Job(
                        generatedFrom: rule,
                        id: makeJobID(rule.id, occurrence),
                        occurrence: occurrence,
                        dueDate: dueDate,
                        createdAt: today
                    ))
                    seen.insert(key)
                }
                rule.occurrenceCount += 1
                rule.lastGeneratedDate = rule.nextDueDate
                let advanced = RecurrenceRules.nextDate(
                    after: rule.nextDueDate,
                    cadence: cadence,
                    calendar: calendar
                )
                // A non-advancing step would spin forever (the JS engine has
                // the same fixed-point hazard on unknown cadences); stop the
                // rule's loop rather than hang the sync pass.
                guard advanced > rule.nextDueDate else { break }
                rule.nextDueDate = advanced
                ruleChanged = true

                if isEndConditionMet(rule) {
                    rule.isActive = false
                    break
                }
            }
            if ruleChanged {
                updatedRules.append(rule)
            }
        }
        return NativeRecurringJobGeneration(
            newJobs: newJobs,
            updatedRules: updatedRules,
            didChange: !newJobs.isEmpty || !updatedRules.isEmpty
        )
    }

    /// Local-frame "YYYY-MM-DD" for `date` — the same frame the recurrence
    /// math advances in, so "due through today" never loses a day to UTC.
    static func todayString(from date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func dedupeKey(ruleID: String, occurrence: Int) -> String {
        "\(ruleID)\u{1F}\(occurrence)"
    }

    private static func isEndConditionMet(_ rule: Canonical.RecurringJob) -> Bool {
        RecurrenceRules.isEndConditionMet(RecurrenceState(
            endCondition: RecurrenceEndCondition(rawValue: rule.endCondition) ?? .never,
            endCount: rule.endCount,
            endDate: rule.endDate,
            occurrenceCount: rule.occurrenceCount,
            nextDueDate: rule.nextDueDate
        ))
    }
}

extension Canonical.Job {
    /// Builds one generated occurrence, copying only the RN-authorized
    /// fields: customer, descriptive, pricing, materials, optional direct
    /// costs (`jobCosts`), schedule, and recurrence linkage. Lifecycle,
    /// approval, time, photo, archive, and import state are never inherited.
    init(
        generatedFrom rule: Canonical.RecurringJob,
        id: String,
        occurrence: Int,
        dueDate: String,
        createdAt: String
    ) {
        self.id = id
        self.customerId = rule.customerId
        self.customerName = rule.customerName
        self.title = rule.title
        self.description = rule.description
        self.status = "scheduled"
        self.scheduledDate = dueDate
        self.scheduledStartTime = nil
        self.scheduledEndTime = nil
        self.address = rule.address
        self.estimateTotal = rule.estimateTotal
        self.laborHours = rule.laborHours
        self.laborBreakdown = nil
        self.laborRate = rule.laborRate
        self.materials = rule.materials
        self.materialMarkup = rule.materialMarkup
        self.jobCosts = rule.jobCosts
        self.overhead = rule.overhead
        self.margin = rule.margin
        self.notes = rule.notes
        self.invoiceId = nil
        self.createdAt = createdAt
        self.photos = nil
        self.timeSessions = nil
        self.recurringJobId = rule.id
        self.occurrenceNumber = occurrence
        self.estimateSentAt = nil
        self.approval = nil
        self.approvalHistory = nil
        self.changeOrders = nil
        self.archivedAt = nil
        self.importBatchId = nil
        self.preservation = Canonical.Preservation()
    }
}
