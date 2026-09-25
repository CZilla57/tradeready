import Foundation

// Focused tests for task 8.09 (requirements S2, S3): the calendar UI lane's
// store seams — warn-and-save, stale-state recovery input, missing job,
// failure-keeps-draft boundary, read-only projection accessors (the exact
// untimed/minute-precision inputs the lossy UI projection cannot supply),
// and the editor's untimed/cleared admission vectors. Validation shapes
// already pinned by CalendarTests are not duplicated here.
//
// The views themselves stay thin: every behavior below is exercised through
// the same typed entry points the views call. Cancel-without-write holds by
// construction (Cancel never calls commit — Group E proves the read path
// performs no write), and the failed-save-keeps-draft half is the policy
// boundary in Group D plus the editor retaining its @State draft on .failed.

private var failures = 0

private func expect(_ actual: @autoclosure () -> Bool, _ label: String) {
    if actual() { return }
    failures += 1
    print("FAIL: \(label)")
}

private func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ label: String) {
    let value = actual()
    if value != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(value)")
    }
}

@MainActor
private final class CalendarEditorTestSubscriptionStub: NativeSubscriptionServing {
    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func loadOffering() async throws -> NativeSubscriptionOffering {
        .init(packages: [])
    }
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        .init(entitlement: .init(isActive: false, isTrialing: false), userCancelled: true)
    }
    func restore() async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func logOut() async {}
}

private func decode09Job(_ json: String) -> Canonical.Job {
    try! JSONDecoder().decode(Canonical.Job.self, from: Data(json.utf8))
}

private func job09(id: String, status: String = "approved", date: String? = "2026-09-22",
                   start: String? = "09:00", end: String? = "10:00") -> Canonical.Job {
    var json = """
    {"id":"\(id)","customerId":"c1","customerName":"Nora","title":"Panel swap",
     "description":"d","status":"\(status)","address":"1 Main",
     "estimateTotal":400,"laborHours":2,"laborRate":95,"materials":[],
     "materialMarkup":25,"overhead":10,"margin":30,"notes":"keep-me",
     "createdAt":"2026-09-01T00:00:00.000Z"
    """
    if let date { json += ",\"scheduledDate\":\"\(date)\"" }
    if let start { json += ",\"scheduledStartTime\":\"\(start)\"" }
    if let end { json += ",\"scheduledEndTime\":\"\(end)\"" }
    return decode09Job(json + "}")
}

private func settings09() -> Canonical.Settings {
    var settings = try! CanonicalUIAdapters.canonical(from: BusinessSettings())
    settings.schedule = try! JSONDecoder().decode(
        Canonical.ScheduleConfig.self,
        from: Data("""
        {"workDays":[1,2,3,4,5],"workDayStart":"08:30","workDayEnd":"17:30",
         "defaultDurationMinutes":60,"bufferMinutes":0,
         "blackouts":[{"id":"b1","start":"2026-09-23","end":"2026-09-24","reason":"Holiday"}]}
        """.utf8))
    return settings
}

@MainActor
private func seed09Store(jobs: [Canonical.Job] = [],
                         settings: Canonical.Settings? = nil,
                         tag: String = "t") throws -> (store: AppStore, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-809-\(tag)-\(UUID().uuidString)", isDirectory: true)
    let url = dir.appendingPathComponent("store.json")
    let snapshot = Canonical.Snapshot(payload: Canonical.SnapshotPayload(
        jobs: jobs, customers: [], settings: settings, bookingRequests: []))
    try Canonical.SnapshotRepository(primaryURL: url).save(snapshot)
    let store = AppStore(fileURL: url, seedIfMissing: false,
                         subscriptionService: CalendarEditorTestSubscriptionStub(),
                         secureSettingsStore: hostTestSecureSettingsStore())
    return (store, dir)
}

private func snapshot09(_ url: URL) throws -> Canonical.Snapshot {
    try Canonical.SnapshotRepository(primaryURL: url).load()!.snapshot
}

private func queueCount09(_ dir: URL) -> Int {
    Canonical.NativeMutationQueue(
        fileURL: dir.appendingPathComponent("mutation-queue.json")).load().count
}

private func snapshotBytes09(_ dir: URL) -> Data {
    try! Data(contentsOf: dir.appendingPathComponent("store.json"))
}

@main
struct CalendarEditorTests {
    @MainActor
    static func main() async throws {
        // MARK: - A. Warn-and-save: conflicts warn, never prevent saving
        do {
            let (store, dir) = try seed09Store(
                jobs: [job09(id: "j1"), job09(id: "j2", status: "scheduled")], tag: "warn")
            let draft = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "j1", baselineDate: "2026-09-22", baselineStart: "09:00",
                baselineEnd: "10:00", baselineStatus: "approved",
                date: "2026-09-22", start: "09:30", end: "10:30")
            let outcome = store.commitScheduleOnly(draft)
            if case let .saved(conflicts) = outcome {
                expectEqual(conflicts, ["j2"], "8.09 overlapping edit warns with the affected job ID")
            } else {
                expect(false, "8.09 conflicting edit still saves (warn-only parity)")
            }
            let saved = try snapshot09(dir.appendingPathComponent("store.json")).payload.jobs!
                .first(where: { $0.id == "j1" })!
            expect(saved.scheduledStartTime == "09:30", "8.09 warned save writes the new slot")
            expect(saved.notes == "keep-me" && saved.estimateTotal == 400,
                   "8.09 warned save preserves unrelated pricing/contact fields")
            expectEqual(queueCount09(dir), 1, "8.09 warned save enqueues exactly one job upsert")
        }

        // MARK: - B. Stale-state recovery: conflict keeps latest, fresh draft saves
        do {
            let (store, dir) = try seed09Store(jobs: [job09(id: "j1")], tag: "stale")
            // A concurrent edit lands first.
            let winner = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "j1", baselineDate: "2026-09-22", baselineStart: "09:00",
                baselineEnd: "10:00", baselineStatus: "approved",
                date: "2026-09-22", start: "11:00", end: "12:00")
            expect(store.commitScheduleOnly(winner) == .saved(conflictingJobIDs: []),
                   "8.09 concurrent edit saves first")
            // The stale editor draft refuses instead of replacing.
            let stale = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "j1", baselineDate: "2026-09-22", baselineStart: "09:00",
                baselineEnd: "10:00", baselineStatus: "approved",
                date: "2026-09-24", start: "08:00", end: "09:00")
            expect(store.commitScheduleOnly(stale) == .baselineConflict,
                   "8.09 stale draft refuses instead of silently replacing")
            let kept = try snapshot09(dir.appendingPathComponent("store.json")).payload.jobs!
                .first(where: { $0.id == "j1" })!
            expect(kept.scheduledStartTime == "11:00", "8.09 refused edit leaves the latest schedule untouched")
            // The editor's "Reload latest" input: a fresh draft reflects the
            // latest record and saves against it.
            let reloaded = store.scheduleOnlyDraft(jobID: "j1")!
            expectEqual(reloaded.baselineStart, "11:00", "8.09 reloaded draft pins the latest baseline")
            var retried = reloaded
            retried.date = "2026-09-24"; retried.start = "08:00"; retried.end = "09:00"
            expect(store.commitScheduleOnly(retried) == .saved(conflictingJobIDs: []),
                   "8.09 reloaded draft saves against the fresh baseline")
        }

        // MARK: - C. Missing job: exact-ID miss rejects, never recreates
        do {
            let (store, _) = try seed09Store(jobs: [job09(id: "j1")], tag: "missing")
            expect(store.commitScheduleOnly(NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "gone", date: "2026-09-24")) == .missing,
                "8.09 schedule commit on a deleted record rejects rather than recreates")
            expect(store.scheduleOnlyDraft(jobID: "gone") == nil,
                   "8.09 missing record yields no draft (the editor shows its missing state)")
            expectEqual(store.calendarJob(id: "j1")?.title, "Panel swap",
                        "8.09 exact-ID lookup hits the intended record for navigation")
        }

        // MARK: - D. Failure-keeps-draft boundary: snapshot failure publishes nothing
        do {
            var published = false
            let outcome = NativeScheduleBookingPolicy.commitLocal(
                saveSnapshot: { throw NSError(domain: "test", code: 1) },
                publishToQueue: { published = true },
                stageRecovery: {})
            expect(outcome == .snapshotFailed, "8.09 snapshot failure reports snapshotFailed")
            expect(!published, "8.09 snapshot failure never touches the queue")
        }

        // MARK: - E. Read-only accessors perform no write (cancel-safe)
        do {
            let (store, dir) = try seed09Store(jobs: [job09(id: "j1", start: "09:30")], tag: "readonly")
            let beforeBytes = snapshotBytes09(dir)
            let beforeQueue = queueCount09(dir)
            _ = store.calendarScheduleJobs()
            _ = store.calendarResolvedSchedule()
            _ = store.scheduleOnlyDraft(jobID: "j1")
            expectEqual(snapshotBytes09(dir), beforeBytes, "8.09 calendar reads leave the snapshot bytes untouched")
            expectEqual(queueCount09(dir), beforeQueue, "8.09 calendar reads enqueue nothing")
        }

        // MARK: - F. Editor admission: untimed and cleared drafts are valid
        do {
            expectEqual(NativeCalendar.validateScheduleDraft(
                NativeCalendar.ScheduleEditDraft(jobId: "j1", date: "2026-09-25", start: nil, end: nil)),
                [], "8.09 untimed dated draft is valid (not a midnight appointment)")
            expectEqual(NativeCalendar.validateScheduleDraft(
                NativeCalendar.ScheduleEditDraft(jobId: "j1", date: nil, start: nil, end: nil)),
                [], "8.09 cleared draft is valid (unscheduled)")
            expectEqual(NativeCalendar.validateScheduleDraft(
                NativeCalendar.ScheduleEditDraft(jobId: "j1", date: nil, start: "09:00", end: nil)),
                [.timeWithoutDate], "8.09 time without a date is rejected")
        }

        // MARK: - G. Projection exactness: minutes, untimed, blackouts (S2 inputs)
        do {
            let (store, _) = try seed09Store(
                jobs: [job09(id: "timed", start: "09:30", end: "10:30"),
                       job09(id: "untimed", start: nil, end: nil)],
                settings: settings09(), tag: "exact")
            let rows = store.calendarScheduleJobs()
            expectEqual(rows.first(where: { $0.id == "timed" })?.scheduledStartTime, "09:30",
                        "8.09 projection keeps minute-precise starts")
            expect(rows.first(where: { $0.id == "untimed" })?.scheduledStartTime == nil,
                   "8.09 projection keeps untimed jobs distinct from midnight")
            let schedule = store.calendarResolvedSchedule()
            expectEqual(schedule.workDayStart, "08:30", "8.09 resolved schedule keeps minute-precise hours")
            expect(NativeSchedule.isBlackoutDate(schedule, date: "2026-09-23"),
                   "8.09 resolved schedule carries time-off ranges for labels")
            expect(!NativeSchedule.isBlackoutDate(schedule, date: "2026-09-25"),
                   "8.09 non-blackout dates stay clear")
            let queue = NativeCalendar.selectUnscheduledApproved(jobs: rows)
            expect(queue.isEmpty, "8.09 scheduled jobs do not leak into the needs-scheduling queue")
        }

        if failures == 0 {
            print("PASS: native calendar editor tests")
        } else {
            print("FAILED: \(failures) native calendar editor test(s)")
            exit(1)
        }
    }
}
