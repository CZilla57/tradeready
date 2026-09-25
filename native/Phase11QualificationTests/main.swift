import Foundation

// Phase 11 cross-client and platform qualification (task 11.13).
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md,
// "17. Cross-client qualification (11.13)". Each focused 11.01–11.12 runner
// already proves its own area; this suite adds only the cross-client fixtures
// they lacked and cites the rest:
//
//   Q1  Widget snapshot: RN `BridgeSnapshot` (targets/widget/Widgets.swift) and
//       RN `SiriSnapshot` (targets/widget/_shared/SiriIntents.swift), both
//       extracted from the working tree by the runner, decode F1–F6 and the
//       native writer's output. Cited: WidgetSnapshotTests (schema, projection,
//       writer, lock), NextJobWidgetTests, JobTimerWidgetTests.
//   Q2  Action replay: every RN `__tests__/widgetActions.test.js` vector through
//       the real planner and replayer. Cited: WidgetActionReplayTests (claim WAL,
//       coordinator), AppIntentQueueTests (native writer → replay → AppStore),
//       WidgetOwnerGatingTests (untagged/foreign drop).
//   Q3  Deep links: every RN `__tests__/deepLinks.test.js` vector through
//       `NativeDeepLinkParser`. Cited: DeepLinkRoutingTests (auth/owner/record
//       gates), AppGroupPendingOpenURLTests (cold-launch consumer).
//   Q4  Analytics: the RN `track(` call sites equal the §9.5 catalog, and every
//       catalog event has a reachable native emission or a named exclusion.
//       Cited: AnalyticsEventTests (payload parity), AnalyticsTransportTests.
//   Q5  Redaction: RN `SECURE_FIELDS` and the §10.1 deny table through the
//       analytics policy, the crash redactor and the widget snapshot. Cited:
//       ErrorRedactionTests, AnalyticsTransportTests, AIProviderKeyTests.
//   Q6  Accessibility/layout: no §12.1 row is still open. Cited:
//       AccessibilityAuditTests (including A30, fixed in 11.13),
//       LayoutMetricsTests.
//
// Native differences asserted here, not re-litigated: the planner rejects a
// whole batch on one invalid action (§4.3; RN drops only that action), and
// `parsePendingOpenURL` vets the URL grammar at the same boundary (§6.3; RN
// returns the raw URL and leaves the grammar to `parseWidgetDeepLink`).

private var failures = 0
private var checks = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T?, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(String(describing: expected)), got \(String(describing: actual))")
    }
}

private func readOrFail(_ root: URL, _ path: String) -> String {
    guard let text = read(root, path) else {
        expect(false, "\(path) readable")
        return ""
    }
    return text
}

private func matches(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
        (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }
}

/// `base` with `overrides` (a JSON object body without braces) applied key by
/// key, so an override replaces a default instead of duplicating the key.
private func merged(_ base: String, _ overrides: String) -> Data {
    let object = { (json: String) -> [String: Any] in
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }
    let result = object(base).merging(overrides.isEmpty ? [:] : object("{\(overrides)}")) { $1 }
    return try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
}

// MARK: - Q1 Widget snapshot (contract §2)

private let fixtureF1 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":null,"timer":null,"outstandingTotal":0}"#
private let fixtureF2 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":{"id":"j9","customerName":"Alice Johnson","title":"Fence repair","scheduledDate":"2026-08-04","scheduledStartTime":"10:30","address":"12 Oak St"},"timer":{"jobId":"j2","jobTitle":"Deck build","customerName":"Bob Smith","startedAt":"2026-08-03T10:00:00.000Z"},"outstandingTotal":160}"#
private let fixtureF3 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":{"id":"j5","customerName":"Dana Lee","title":"Gutter clean","scheduledDate":"2026-08-05","scheduledStartTime":null,"address":""},"timer":null,"outstandingTotal":1234.56}"#
private let fixtureF4 = #"{"nextJob":{"address":"1420 Maple Ave","customerName":"Alex Morgan","id":"sample","scheduledDate":"2026-01-01","scheduledStartTime":"09:00","title":"Water heater replacement"},"outstandingTotal":0,"ownerTag":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","timer":null,"updatedAt":"2026-01-01T08:00:00.000Z","version":1}"#
private let fixtureF5 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":null,"timer":null,"futureField":{"x":1}}"#
private let fixtureF6 = #"{"version":1,"updatedAt":"2026-08-03T19:00:00.000Z","nextJob":{"id":"j5","customerName":"Dana Lee","title":"Gutter clean","scheduledDate":"2026-08-05","scheduledStartTime":null,"address":null},"timer":null,"outstandingTotal":0}"#

private func rnWidget(_ json: String) -> BridgeSnapshot? {
    try? JSONDecoder().decode(BridgeSnapshot.self, from: Data(json.utf8))
}

private func rnSiri(_ json: String) -> SiriSnapshot? {
    try? JSONDecoder().decode(SiriSnapshot.self, from: Data(json.utf8))
}

private let jsonDecoder = JSONDecoder()

/// RN `job()` from `__tests__/widgetBridge.test.js`, with overrides.
private let baseJobJSON = """
{"id":"j1","customerId":"c1","customerName":"Alice Johnson","title":"Fence repair","description":"",
 "status":"scheduled","scheduledDate":null,"scheduledStartTime":null,"scheduledEndTime":null,
 "address":"12 Oak St","estimateTotal":0,"laborHours":0,"laborRate":0,"materials":[],
 "materialMarkup":0,"overhead":0,"margin":0,"notes":"","invoiceId":null,"createdAt":"2026-08-01"}
"""

private func canonicalJob(_ fields: String) -> Canonical.Job {
    try! jsonDecoder.decode(Canonical.Job.self, from: merged(baseJobJSON, fields))
}

private func canonicalInvoice(_ fields: String) -> Canonical.Invoice {
    let base = """
    {"id":"i1","customer":"Alice Johnson","number":"INV-0001","amount":100,"due":"2026-08-10",
     "email":"","phone":"","desc":"","paid":false}
    """
    return try! jsonDecoder.decode(Canonical.Invoice.self, from: merged(base, fields))
}

/// RN `NOW` in `TZ=America/Phoenix` as an absolute instant (see WidgetSnapshotTests).
private let snapshotNow = ISO8601DateFormatter().date(from: "2026-08-03T19:00:00Z")!
private let phoenix: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
    return calendar
}()

private func projectSnapshot(_ jobs: [Canonical.Job], invoices: [Canonical.Invoice] = []) -> WidgetSnapshot {
    let business = NativeBusinessSnapshotEngine.make(
        invoices: invoices, jobs: jobs, customers: [], expenses: [], trips: [],
        values: NativeTaxSettingsValues(), mileageRate: 0.7, now: snapshotNow
    )
    return NativeWidgetSnapshotProjection.project(jobs: jobs, business: business, now: snapshotNow, calendar: phoenix)
}

private struct RecordingReloader: NativeWidgetTimelineReloading {
    func reloadAllTimelines() {}
}

/// `var name: Type` stored-property lines of a struct text, whitespace-normalized.
private func storedProperties(_ text: String) -> [String] {
    matches(#"(?m)^\s*(?:public\s+)?var (\w+): ([\w?.]+)\s*$"#, in: text).map { "\($0[1]): \($0[2])" }.sorted()
}

private func testWidgetSnapshot(root: URL, sources: [SourceFile]) throws {
    // F1–F6 through both RN decoders and the native one.
    for (name, fixture) in [("F1", fixtureF1), ("F2", fixtureF2), ("F3", fixtureF3), ("F4", fixtureF4), ("F5", fixtureF5)] {
        expect(rnWidget(fixture) != nil, "Q1 RN BridgeSnapshot decodes \(name)")
        expect(rnSiri(fixture) != nil, "Q1 RN SiriSnapshot decodes \(name)")
        expect(WidgetSnapshot.decode(json: fixture) != nil, "Q1 native WidgetSnapshot decodes \(name)")
    }
    expect(rnWidget(fixtureF6) == nil, "Q1 RN BridgeSnapshot rejects F6 (address: null)")
    expect(WidgetSnapshot.decode(json: fixtureF6) == nil, "Q1 native rejects F6, like the RN widget")
    let siriF6 = rnSiri(fixtureF6)
    expect(siriF6 != nil && siriF6?.nextJob?.address == nil,
           "Q1 RN SiriSnapshot degrades F6 to no address (its address is optional)")

    // Native projections, as stored by the real mirror writer, decode with both RN decoders.
    let projections: [(String, WidgetSnapshot)] = [
        ("empty", projectSnapshot([])),
        ("next job + timer (F2 shape)", projectSnapshot([
            canonicalJob(#""id":"j9","scheduledDate":"2026-08-04","scheduledStartTime":"10:30","notes":"gate code 4471 sk_live_planted""#),
            canonicalJob(#""id":"j2","title":"Deck build","customerName":"Bob Smith","timeSessions":[{"start":"2026-08-03T10:00:00.000Z"}]"#),
        ], invoices: [canonicalInvoice(#""id":"unpaid""#), canonicalInvoice(#""id":"u2","amount":60"#)])),
        ("no start time, empty address (F3 shape)", projectSnapshot([
            canonicalJob(#""id":"j5","customerName":"Dana Lee","title":"Gutter clean","scheduledDate":"2026-08-05","address":"""#),
        ])),
    ]
    let suiteName = "com.tradeready.phase11-qualification.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-1113-\(UUID().uuidString)", isDirectory: true)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
    let mirror = NativeWidgetMirror(
        defaults: defaults,
        lockFile: directory.appendingPathComponent(WidgetAppGroup.lockFileName),
        reloader: RecordingReloader()
    )
    let binding = "bind-11.13"
    for (name, projection) in projections {
        expectEqual(mirror.write(projection: projection, ownerBinding: binding, isCurrentOwner: { $0 == binding },
                                 force: true, now: snapshotNow),
                    .written, "Q1 mirror writes the \(name) projection")
        guard let stored = defaults.string(forKey: WidgetAppGroup.snapshotKey) else {
            expect(false, "Q1 \(name) stored"); continue
        }
        let widget = rnWidget(stored)
        let siri = rnSiri(stored)
        expect(widget != nil, "Q1 RN BridgeSnapshot decodes the stored \(name) snapshot")
        expect(siri != nil, "Q1 RN SiriSnapshot decodes the stored \(name) snapshot")
        expectEqual(widget?.version, projection.version, "Q1 \(name): version")
        expectEqual(widget?.updatedAt, projection.updatedAt, "Q1 \(name): updatedAt")
        expectEqual(widget?.outstandingTotal, projection.outstandingTotal, "Q1 \(name): outstandingTotal")
        expectEqual(siri?.outstandingTotal, projection.outstandingTotal, "Q1 \(name): Siri outstandingTotal")
        expectEqual(widget?.nextJob?.id, projection.nextJob?.id, "Q1 \(name): nextJob.id")
        expectEqual(widget?.nextJob?.customerName, projection.nextJob?.customerName, "Q1 \(name): nextJob.customerName")
        expectEqual(widget?.nextJob?.title, projection.nextJob?.title, "Q1 \(name): nextJob.title")
        expectEqual(widget?.nextJob?.scheduledDate, projection.nextJob?.scheduledDate, "Q1 \(name): nextJob.scheduledDate")
        expectEqual(widget?.nextJob?.scheduledStartTime, projection.nextJob?.scheduledStartTime,
                    "Q1 \(name): nextJob.scheduledStartTime")
        expectEqual(widget?.nextJob?.address, projection.nextJob?.address, "Q1 \(name): nextJob.address")
        expectEqual(siri?.nextJob?.address, projection.nextJob?.address, "Q1 \(name): Siri nextJob.address")
        expectEqual(siri?.nextJob?.id, projection.nextJob?.id, "Q1 \(name): Siri nextJob.id")
        expectEqual(widget?.timer?.jobId, projection.timer?.jobId, "Q1 \(name): timer.jobId")
        expectEqual(widget?.timer?.jobTitle, projection.timer?.jobTitle, "Q1 \(name): timer.jobTitle")
        expectEqual(widget?.timer?.customerName, projection.timer?.customerName, "Q1 \(name): timer.customerName")
        expectEqual(widget?.timer?.startedAt, projection.timer?.startedAt, "Q1 \(name): timer.startedAt")
        expectEqual(siri?.timer?.jobId, projection.timer?.jobId, "Q1 \(name): Siri timer.jobId")
        expect((siri?.timer == nil) == (projection.timer == nil),
               "Q1 \(name): Siri's on-the-clock answer (timer != nil) matches the projection")
        expect(!stored.contains("gate code") && !stored.contains("sk_live_"),
               "Q1 \(name): job notes (and a secret planted in them) never reach the snapshot")
    }
    let f2Shape = projections[1].1
    expect(f2Shape.nextJob?.id == "j9" && f2Shape.timer?.jobId == "j2" && f2Shape.outstandingTotal == 160,
           "Q1 the F2-shape projection carries a next job, a timer and the outstanding total")

    // Native schema = RN schema + ownerTag, field for field.
    let rnWidgetText = readOrFail(root, "targets/widget/Widgets.swift")
    let rnStruct = matches(#"(?s)struct BridgeSnapshot: Decodable \{.*?\n\}"#, in: rnWidgetText).first?.first ?? ""
    let nativeFile = sources.first { $0.relativePath == "Widgets/Shared/WidgetSnapshot.swift" }
    let nativeStruct = nativeFile.map { structText($0, "WidgetSnapshot") } ?? ""
    let rnFields = storedProperties(rnStruct)
    let nativeFields = storedProperties(nativeStruct)
    expect(rnFields.count == 15, "Q1 RN BridgeSnapshot has 15 stored fields (\(rnFields.count))")
    var nativeOnly = nativeFields
    for field in rnFields {
        if let index = nativeOnly.firstIndex(of: field) { nativeOnly.remove(at: index) } else {
            expect(false, "Q1 native WidgetSnapshot carries RN field `\(field)` with RN's optionality")
        }
    }
    expectEqual(nativeOnly, ["ownerTag: String?"], "Q1 the only native-only field is the optional ownerTag (§2.3)")

    // The verbatim copy inside WidgetSnapshotTests has not drifted from the working tree.
    let copyText = readOrFail(root, "native/WidgetSnapshotTests/main.swift")
    let copyStruct = matches(#"(?s)private struct RNBridgeSnapshot: Decodable \{.*?\n\}"#, in: copyText).first?.first ?? ""
    expectEqual(storedProperties(copyStruct), rnFields,
                "Q1 WidgetSnapshotTests' RNBridgeSnapshot copy matches targets/widget/Widgets.swift")
}

// MARK: - Q2 Action replay (contract §4)

private let planningBinding = String(repeating: "a", count: 64)
private let ownerTag = NativeWidgetOwnerTag.make(binding: planningBinding)

private func snapshot(jobs: [String] = [], trips: String = "[]", expenses: String = "[]") -> Canonical.Snapshot {
    let jobJSON = jobs.map { fields -> String in
        let withSessions = fields.contains(#""timeSessions""#) ? fields
            : (fields.isEmpty ? #""timeSessions":[]"# : fields + #","timeSessions":[]"#)
        return String(decoding: merged(baseJobJSON, withSessions), as: UTF8.self)
    }.joined(separator: ",")
    let json = #"{"schemaVersion":1,"payload":{"jobs":[\#(jobJSON)],"trips":\#(trips),"expenses":\#(expenses)}}"#
    return try! Canonical.SnapshotCodec.decode(Data(json.utf8))
}

/// Tags each action object (a JSON object body without braces) for the planning owner.
private func queue(_ actions: [String]) -> String {
    "[" + actions.map { #"{"ownerTag":"\#(ownerTag)",\#($0)}"# }.joined(separator: ",") + "]"
}

private func replay(_ actions: [String], on source: Canonical.Snapshot) -> NativeWidgetActionReplayResult? {
    guard let batch = try? NativeWidgetActionBatchPlanner.prepare(
        rawValue: queue(actions), verifiedAccountBinding: planningBinding
    ) else { return nil }
    return try? NativeWidgetActionReplayer.apply(batch, to: source)
}

private func planError(_ raw: String) -> NativeWidgetActionBatchError? {
    do {
        _ = try NativeWidgetActionBatchPlanner.prepare(rawValue: raw, verifiedAccountBinding: planningBinding)
        return nil
    } catch let error as NativeWidgetActionBatchError {
        return error
    } catch {
        return nil
    }
}

private func encoded(_ snapshot: Canonical.Snapshot) -> Data? {
    try? Canonical.SnapshotCodec.encode(snapshot)
}

private let startJ1 = #""id":"a1","type":"timer_start","at":"2026-08-03T09:00:00.000Z","jobId":"j1""#

private func testActionReplay(root: URL) {
    // applyTimerActions
    let scheduled = snapshot(jobs: [#""id":"j1""#])
    let started = replay([startJ1], on: scheduled)
    let startedJob = started?.snapshot.payload.jobs?.first
    expect(started?.changedActionCount == 1, "Q2 timer_start clocks the matching job in")
    expect(startedJob?.timeSessions?.count == 1 && startedJob?.timeSessions?.first?.start == "2026-08-03T09:00:00.000Z"
           && startedJob?.timeSessions?.first?.end == nil, "Q2 timer_start opens {start: at, end: null}")
    expectEqual(startedJob?.status, "in_progress", "Q2 timer_start advances scheduled → in_progress")

    let ghost = replay([#""id":"a1","type":"timer_start","at":"2026-08-03T09:00:00.000Z","jobId":"ghost""#], on: scheduled)
    expect(ghost?.changedActionCount == 0 && encoded(ghost!.snapshot) == encoded(scheduled),
           "Q2 timer_start for a missing job is dropped and changes nothing")

    let running = snapshot(jobs: [#""id":"j1","timeSessions":[{"start":"2026-08-03T08:00:00.000Z","end":null}]"#])
    expectEqual(replay([startJ1], on: running)?.changedActionCount, 0, "Q2 timer_start on a clocked-in job is dropped")

    for status in ["complete", "invoiced", "paid", "declined"] {
        let done = snapshot(jobs: [#""id":"j1","status":"\#(status)""#])
        let result = replay([startJ1], on: done)
        expect(result?.changedActionCount == 0 && encoded(result!.snapshot) == encoded(done),
               "Q2 timer_start is dropped for a '\(status)' job")
    }

    let twoJobs = snapshot(jobs: [#""id":"j1","timeSessions":[{"start":"2026-08-03T08:00:00.000Z","end":null}]"#, #""id":"j2""#])
    let stopped = replay([#""id":"a1","type":"timer_stop","at":"2026-08-03T10:00:00.000Z","jobId":"j1""#], on: twoJobs)
    expect(stopped?.changedActionCount == 1
           && stopped?.snapshot.payload.jobs?.first?.timeSessions?.first?.end == "2026-08-03T10:00:00.000Z",
           "Q2 timer_stop with jobId closes that job's session")

    let secondRunning = snapshot(jobs: [#""id":"j1""#, #""id":"j2","timeSessions":[{"start":"2026-08-03T08:00:00.000Z","end":null}]"#])
    let fallback = replay([#""id":"a1","type":"timer_stop","at":"2026-08-03T10:00:00.000Z""#], on: secondRunning)
    expect(fallback?.changedActionCount == 1
           && fallback?.snapshot.payload.jobs?[1].timeSessions?.first?.end == "2026-08-03T10:00:00.000Z",
           "Q2 timer_stop without jobId falls back to the job with an active session")

    expectEqual(replay([#""id":"a1","type":"timer_stop","at":"2026-08-03T10:00:00.000Z""#], on: scheduled)?.changedActionCount,
                0, "Q2 timer_stop with nothing running is dropped")
    let idle = snapshot(jobs: [#""id":"j1","timeSessions":[]"#])
    let idleStop = replay([#""id":"a1","type":"timer_stop","at":"2026-08-03T10:00:00.000Z","jobId":"j1""#], on: idle)
    expect(idleStop?.changedActionCount == 0 && encoded(idleStop!.snapshot) == encoded(idle),
           "Q2 timer_stop for a job with no active session is dropped")

    let pair = replay([startJ1, #""id":"a2","type":"timer_stop","at":"2026-08-03T11:00:00.000Z","jobId":"j1""#], on: scheduled)
    let pairJob = pair?.snapshot.payload.jobs?.first
    expect(pair?.changedActionCount == 2 && pairJob?.timeSessions?.count == 1
           && pairJob?.timeSessions?.first?.start == "2026-08-03T09:00:00.000Z"
           && pairJob?.timeSessions?.first?.end == "2026-08-03T11:00:00.000Z"
           && pairJob?.status == "in_progress", "Q2 a start-then-stop pair applies in order")

    let tripOnly = replay([#""id":"a1","type":"trip_log","at":"2026-08-03T09:00:00.000Z","date":"2026-08-03","odometerStart":0,"odometerEnd":10"#], on: scheduled)
    expect(tripOnly?.snapshot.payload.jobs?.first?.timeSessions?.isEmpty == true,
           "Q2 a trip_log action never touches jobs")

    // tripFromAction
    let tripAction = #""id":"sa1","type":"trip_log","at":"2026-08-03T09:30:00.000Z","date":"2026-08-03""#
    let trip = replay([tripAction + #","odometerStart":100,"odometerEnd":115"#], on: snapshot())?.snapshot.payload.trips?.first
    expect(trip?.id == "t_siri_sa1" && trip?.date == "2026-08-03" && trip?.odometerStart == 100
           && trip?.odometerEnd == 115 && trip?.miles == 15 && trip?.fromJobId == nil
           && trip?.fromLabel == "Home / Shop" && trip?.toJobId == nil && trip?.toLabel == "Home / Shop"
           && trip?.purpose == "Business trip (Siri)" && trip?.createdAt == "2026-08-03",
           "Q2 trip_log builds RN's exact Trip (t_siri_<id>, Home / Shop, Business trip (Siri))")
    let backwards = replay([tripAction + #","odometerStart":200,"odometerEnd":150"#], on: snapshot())
    expectEqual(backwards?.snapshot.payload.trips?.first?.miles, 0, "Q2 trip miles clamp to 0 when end < start")
    let existingTrip = snapshot(trips: #"[{"id":"t_siri_sa1","date":"2026-08-03","odometerStart":1,"odometerEnd":2,"miles":1,"fromJobId":null,"fromLabel":"x","toJobId":null,"toLabel":"y","purpose":"p","createdAt":"2026-08-03"}]"#)
    let dedupedTrip = replay([tripAction + #","odometerStart":100,"odometerEnd":115"#], on: existingTrip)
    expect(dedupedTrip?.changedActionCount == 0 && dedupedTrip?.snapshot.payload.trips?.count == 1,
           "Q2 trip_log dedupes on t_siri_<id>")
    // RN drops just the bad action; native rejects the whole batch (§4.3).
    for (label, fields) in [
        ("odometerStart missing", #","odometerEnd":115"#),
        ("odometerEnd missing", #","odometerStart":100"#),
        ("odometerStart negative", #","odometerStart":-1,"odometerEnd":115"#),
        ("odometerEnd negative", #","odometerStart":100,"odometerEnd":-1"#),
        ("odometerStart not a number", #","odometerStart":"100","odometerEnd":115"#),
    ] {
        let error = planError(queue([tripAction + fields]))
        expect({ if case .invalidAction(index: 0, _)? = error { return true }; return false }(),
               "Q2 trip_log \(label): the batch is rejected (§4.3 native difference; RN drops the action)")
    }
    expect({ if case .invalidAction(index: 0, field: "date")? = planError(queue([#""id":"sa1","type":"trip_log","at":"2026-08-03T09:30:00.000Z","odometerStart":100,"odometerEnd":115"#])) { return true }; return false }(),
           "Q2 trip_log without a date is rejected")
    expectEqual(planError(queue([tripAction + #","odometerStart":Infinity,"odometerEnd":115"#])), .malformedQueue,
                "Q2 a non-finite odometer cannot be written as JSON: the queue is malformed")

    // expenseFromAction
    let expenseAction = #""id":"ea1","type":"expense_log","at":"2026-08-03T09:30:00.000Z","date":"2026-08-03""#
    let expense = replay([expenseAction + #","amount":42.5,"category":"materials","description":"Lumber""#], on: snapshot())?
        .snapshot.payload.expenses?.first
    expect(expense?.id == "e_siri_ea1" && expense?.createdAt == "2026-08-03T09:30:00.000Z"
           && expense?.description == "Lumber" && expense?.amount == Decimal(string: "42.5")
           && expense?.category == "materials" && expense?.date == "2026-08-03" && expense?.notes == ""
           && expense?.receiptUri == nil, "Q2 expense_log builds RN's exact Expense (e_siri_<id>)")
    let existingExpense = snapshot(expenses: #"[{"id":"e_siri_ea1","createdAt":"2026-08-03","description":"x","amount":1,"category":"other","date":"2026-08-03","notes":"","receiptUri":null}]"#)
    expectEqual(replay([expenseAction + #","amount":42.5"#], on: existingExpense)?.changedActionCount, 0,
                "Q2 expense_log dedupes on e_siri_<id>")
    for (label, amount) in [("zero", "0"), ("negative", "-5"), ("over the 1,000,000 cap", "1000001"), ("not a number", #""42.50""#)] {
        let error = planError(queue([expenseAction + #","amount":\#(amount)"#]))
        expect({ if case .invalidAction(index: 0, field: "amount")? = error { return true }; return false }(),
               "Q2 expense amount \(label): the batch is rejected (§4.3 native difference)")
    }
    for literal in ["NaN", "Infinity"] {
        expectEqual(planError(queue([expenseAction + #","amount":\#(literal)"#])), .malformedQueue,
                    "Q2 expense amount \(literal) cannot be written as JSON: the queue is malformed")
    }
    let capped = replay([expenseAction + #","amount":1000000"#], on: snapshot())
    expectEqual(capped?.snapshot.payload.expenses?.first?.amount, Decimal(1_000_000), "Q2 an amount exactly at the cap is kept")
    expectEqual(replay([expenseAction + #","amount":5,"category":"bogus""#], on: snapshot())?.snapshot.payload.expenses?.first?.category,
                "other", "Q2 an unknown category falls back to other")
    let moneyUtils = readOrFail(root, "utils/moneyUtils.ts")
    let categoryBlock = matches(#"(?s)EXPENSE_CATEGORIES[^=]*=\s*\[(.*?)\];"#, in: moneyUtils).first?[1] ?? ""
    let rnCategories = matches(#"id:\s*'([a-z_]+)'"#, in: categoryBlock).map { $0[1] }
    expectEqual(rnCategories.count, 8, "Q2 RN EXPENSE_CATEGORIES parsed from utils/moneyUtils.ts")
    for category in rnCategories {
        expectEqual(replay([expenseAction + #","amount":5,"category":"\#(category)""#], on: snapshot())?.snapshot.payload.expenses?.first?.category,
                    category, "Q2 RN category '\(category)' is kept")
    }
    for (label, fields) in [("empty", #","amount":5,"description":"""#), ("missing", #","amount":5"#)] {
        expectEqual(replay([expenseAction + fields], on: snapshot())?.snapshot.payload.expenses?.first?.description,
                    "Logged via Siri", "Q2 an \(label) description falls back to Logged via Siri")
    }
    expect({ if case .invalidAction(index: 0, field: "date")? = planError(queue([#""id":"ea1","type":"expense_log","at":"2026-08-03T09:30:00.000Z","amount":5"#])) { return true }; return false }(),
           "Q2 expense_log without a date is rejected")

    // parsePendingActions: RN drops a structurally bad entry; native rejects the batch.
    expectEqual(planError("{not json"), .malformedQueue, "Q2 malformed JSON: malformedQueue")
    expectEqual(planError(#"{"id":"a1","type":"timer_start","at":"x"}"#), .malformedQueue, "Q2 a non-array: malformedQueue")
    expectEqual(planError(queue([startJ1, #""type":"timer_start","at":"2026-08-03T09:00:00.000Z""#])),
                .malformedAction(index: 1), "Q2 an entry missing id rejects the batch (§4.3 native difference)")
    expectEqual(planError(queue([#""id":"a4","type":"timer_stop""#])), .malformedAction(index: 0),
                "Q2 an entry missing at rejects the batch")
    let untagged = try? NativeWidgetActionBatchPlanner.prepare(
        rawValue: #"[null,"not an object",{"id":"a1","type":"timer_start","at":"2026-08-03T09:00:00.000Z","jobId":"j1"}]"#,
        verifiedAccountBinding: planningBinding
    )
    expect(untagged?.actions.isEmpty == true && untagged?.ownerDroppedCount == 3,
           "Q2 null, non-object and untagged RN-era entries are owner-dropped, never applied (§4.5)")

    // Retry after a publish that was not acknowledged is idempotent.
    if let first = replay([startJ1, tripAction + #","odometerStart":100,"odometerEnd":115"#, expenseAction + #","amount":5"#], on: scheduled) {
        let again = replay([startJ1, tripAction + #","odometerStart":100,"odometerEnd":115"#, expenseAction + #","amount":5"#], on: first.snapshot)
        expect(again?.changedActionCount == 0 && again?.ignoredActionCount == 3, "Q2 replaying the same claim twice is a no-op")
    } else {
        expect(false, "Q2 mixed batch replays")
    }
}

// MARK: - Q3 Deep links (contract §6)

private func testDeepLinks() {
    typealias Parser = NativeDeepLinkParser
    expectEqual(Parser.parse("tradeready://job/j1722_4"), .job(id: "j1722_4"), "Q3 job link")
    expectEqual(Parser.parse(" TradeReady://job/abc "), .job(id: "abc"), "Q3 job: scheme case-insensitive, trimmed")
    expectEqual(Parser.parse("tradeready://job/a%2Bb"), .job(id: "a+b"), "Q3 job: percent-decoded id")
    expectEqual(Parser.parse("tradeready://onmyway/j1722_4"), .onMyWay(id: "j1722_4"), "Q3 onmyway link")
    expectEqual(Parser.parse(" TradeReady://onmyway/abc "), .onMyWay(id: "abc"), "Q3 onmyway: case-insensitive, trimmed")
    expectEqual(Parser.parse("tradeready://onmyway/a%2Bb"), .onMyWay(id: "a+b"), "Q3 onmyway: percent-decoded id")
    for url in [
        "", "tradeready://job/", "tradeready://job/a/b", "tradeready://job/a?x=1", "tradeready://invoice/i1",
        "otherapp://job/j1", "https://gettradereadyapp.com/job/j1", "tradeready://job/%zz",
        "tradeready://onmyway/", "tradeready://onmyway/a/b", "tradeready://onmyway/a?x=1",
        "otherapp://onmyway/j1", "tradeready://onmyway/%zz",
    ] {
        expect(Parser.parse(url) == nil, "Q3 rejects \(url.isEmpty ? "\"\"" : url)")
    }

    let now = ISO8601DateFormatter().date(from: "2026-08-03T18:00:00Z")!
    func stash(_ url: String, _ at: String) -> String { #"{"url":"\#(url)","at":"\#(at)"}"# }
    for at in ["2026-08-03T17:59:58Z", "2026-08-03T18:00:00Z", "2026-08-03T17:59:30.512Z", "2026-08-03T17:55:01Z"] {
        expectEqual(Parser.parsePendingOpenURL(stash("tradeready://onmyway/j1", at), now: now)?.url,
                    "tradeready://onmyway/j1", "Q3 pending stash at \(at) is accepted")
    }
    for at in ["2026-08-03T17:54:00Z", "2026-08-03T18:00:05Z"] {
        expect(Parser.parsePendingOpenURL(stash("tradeready://onmyway/j1", at), now: now) == nil,
               "Q3 pending stash at \(at) is dropped (stale or future)")
    }
    for (label, raw) in [
        ("empty string", ""),
        ("malformed JSON", "{not json"),
        ("a JSON array", #"[{"url":"tradeready://onmyway/j1","at":"2026-08-03T18:00:00Z"}]"#),
        ("a bare JSON string", #""tradeready://onmyway/j1""#),
        ("missing url", #"{"at":"2026-08-03T18:00:00Z"}"#),
        ("empty url", #"{"url":"","at":"2026-08-03T18:00:00Z"}"#),
        ("non-string url", #"{"url":42,"at":"2026-08-03T18:00:00Z"}"#),
        ("missing at", #"{"url":"tradeready://onmyway/j1"}"#),
        ("non-string at", #"{"url":"tradeready://onmyway/j1","at":1754251200000}"#),
        ("unparseable at", #"{"url":"tradeready://onmyway/j1","at":"whenever"}"#),
    ] {
        expect(Parser.parsePendingOpenURL(raw, now: now) == nil, "Q3 pending stash dropped: \(label)")
    }
    // RN: parsePendingOpenUrl returns "otherapp://evil" and parseWidgetDeepLink then
    // rejects it. Native vets both at one boundary (§6.3); the end result is the same.
    expect(Parser.parsePendingOpenURL(stash("otherapp://evil", "2026-08-03T18:00:00Z"), now: now) == nil
           && Parser.parse("otherapp://evil") == nil,
           "Q3 a foreign URL in the stash never routes (one boundary natively, two in RN)")
}

// MARK: - Q4 Analytics catalog vs call sites (contract §9.5, §9.7)

/// Events with no native emission, each with a named owner (contract §17).
private let analyticsExclusions: [String: String] = [
    "booking_request_opened": "no native remote-push surface; owner: native push notifications (Phase 12 / later push task)",
    "booking_update_opened": "no native remote-push surface; owner: native push notifications (Phase 12 / later push task)",
    "tax_settings_saved": "emitted only by AppStore.commitTaxSettings, which nothing calls; owner: the native tax-settings editor",
]

/// Distinct event names from RN `track(` call sites (literal or a two-literal ternary).
private func rnTrackedEvents(root: URL) -> (events: Set<String>, sites: Int, unparsed: [String]) {
    var events = Set<String>()
    var sites = 0
    var unparsed: [String] = []
    var files: [URL] = [root.appendingPathComponent("App.tsx")]
    for directory in ["screens", "components", "hooks", "utils", "context"] {
        let base = root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walker where ["ts", "tsx"].contains(url.pathExtension) {
            if url.path.contains("/__tests__/") || url.path.contains("/node_modules/") { continue }
            files.append(url)
        }
    }
    for url in files {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for (number, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.contains("function track(") { continue }
            for match in matches(#"(?<![\w.])track\(\s*([^,)]*)"#, in: line) {
                let argument = match[1].trimmingCharacters(in: .whitespaces)
                if let literal = matches(#"^["']([a-z_]+)["']$"#, in: argument).first {
                    events.insert(literal[1]); sites += 1
                } else if let ternary = matches(#"^[^?]+\?\s*["']([a-z_]+)["']\s*:\s*["']([a-z_]+)["']$"#, in: argument).first {
                    events.insert(ternary[1]); events.insert(ternary[2]); sites += 1
                } else {
                    unparsed.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
    }
    return (events, sites, unparsed)
}

/// Constructor name → event name, from `NativeAnalyticsEvents.swift`.
private func constructorEvents(_ text: String) -> [String: String] {
    guard let start = text.range(of: "extension NativeAnalyticsEvent {"),
          let end = text.range(of: "enum NativeAnalyticsGatePolicy") else { return [:] }
    let region = String(text[start.upperBound..<end.lowerBound])
    let declarations = matches(#"static (?:func|let) (\w+)"#, in: region).map { $0[1] }
    let pieces = region.components(separatedBy: "static ").dropFirst()
    var direct: [String: String] = [:]
    var composite: [String: String] = [:]
    for piece in pieces {
        guard let name = matches(#"^(?:func|let) (\w+)"#, in: piece).first?[1] else { continue }
        if let event = matches(#"(?:Self|\.init)\(\s*"([a-z_]+)""#, in: piece).first?[1] {
            direct[name] = event
        } else if let target = matches(#"\.(\w+)\("#, in: piece).map({ $0[1] }).first(where: { declarations.contains($0) && $0 != name }) {
            composite[name] = target
        }
    }
    for (name, target) in composite { if let event = direct[target] { direct[name] = event } }
    return direct
}

/// `[(start, end, name)]` of every `func name(...) { ... }` in `file`.
private func functionRanges(_ file: SourceFile) -> [(start: Int, end: Int, name: String)] {
    var ranges: [(Int, Int, String)] = []
    for hit in file.occurrences(of: "func") {
        let nameStart = file.skipSpace(hit + 4)
        guard let (name, afterName) = file.identifier(at: nameStart),
              let paren = (afterName..<file.code.count).first(where: { file.code[$0] == "(" }),
              let parenClose = file.matching(paren),
              let brace = ((parenClose + 1)..<file.code.count).first(where: { file.code[$0] == "{" || file.code[$0] == "}" }),
              file.code[brace] == "{",
              let close = file.matching(brace) else { continue }
        ranges.append((hit, close, name))
    }
    return ranges
}

/// Names of `AppStore` functions reachable from a root: a reference in any other
/// `N/` file (views, coordinators) or an `AppStore` reference outside every
/// `func` body (`init`, property initializers). A reference inside function G
/// makes F live only once G is live, so a helper called only from dead code
/// stays dead. Overloads share a name, which errs toward "live".
private func liveFunctions(
    store: SourceFile,
    functions: [(start: Int, end: Int, name: String)],
    sources: [SourceFile]
) -> Set<String> {
    let names = Set(functions.map(\.name))
    var roots = Set<String>()
    var callers: [String: Set<String>] = [:]
    for file in sources {
        let isStore = file.relativePath == store.relativePath
        var k = 0
        let code = file.code
        while k < code.count {
            guard code[k].isLetter || code[k] == "_" else { k += 1; continue }
            let before: Character? = k > 0 ? code[k - 1] : nil
            guard let (name, end) = file.identifier(at: k) else { k += 1; continue }
            defer { k = end }
            if let before, before.isLetter || before.isNumber || before == "_" { continue }
            guard names.contains(name) else { continue }
            if k >= 5, file.codeSlice((k - 5)..<k) == "func " { continue }
            guard isStore else { roots.insert(name); continue }
            if let caller = functions.filter({ $0.start < k && k < $0.end }).max(by: { $0.start < $1.start }) {
                if caller.name != name { callers[name, default: []].insert(caller.name) }
            } else {
                roots.insert(name)
            }
        }
    }
    var live = roots
    var changed = true
    while changed {
        changed = false
        for (name, from) in callers where !live.contains(name) && !from.isDisjoint(with: live) {
            live.insert(name)
            changed = true
        }
    }
    return live
}

private func testAnalyticsCatalog(root: URL, sources: [SourceFile]) {
    guard let catalog = NativeAnalyticsEventCatalog.standard else {
        expect(false, "Q4 the §9.5 catalog loads"); return
    }
    let catalogEvents = Set(catalog.events.keys)
    expectEqual(catalogEvents.count, 52, "Q4 the §9.5 catalog holds 52 events")

    // RN call sites == catalog.
    let rn = rnTrackedEvents(root: root)
    expectEqual(rn.unparsed, [], "Q4 every RN track( site has a literal (or two-literal ternary) event name")
    expectEqual(rn.events, catalogEvents, "Q4 RN track( events equal the native catalog")
    expect(rn.sites >= 70, "Q4 RN track( sites scanned (\(rn.sites))")

    // Native emissions.
    guard let eventsFile = sources.first(where: { $0.relativePath == "NativeAnalyticsEvents.swift" }),
          let store = sources.first(where: { $0.relativePath == "AppStore.swift" }) else {
        expect(false, "Q4 N/NativeAnalyticsEvents.swift and N/AppStore.swift load"); return
    }
    let constructors = constructorEvents(String(eventsFile.raw))
    expect(Set(constructors.values) == catalogEvents,
           "Q4 every catalog event has a typed constructor (missing: \(catalogEvents.subtracting(constructors.values).sorted()))")
    expectEqual(constructors["bulkInvoiceReminderRun"], "bulk_invoice_reminders", "Q4 the composite constructor resolves")

    let functions = functionRanges(store)
    let live = liveFunctions(store: store, functions: functions, sources: sources)
    var reachable = Set<String>()
    var unreachable: [String: Set<String>] = [:]
    for hit in store.occurrences(of: "emitAnalytics") {
        let open = store.skipSpace(hit + "emitAnalytics".count)
        guard open < store.code.count, store.code[open] == "(", let close = store.matching(open) else { continue }
        if hit >= 5, store.codeSlice((hit - 5)..<hit) == "func " { continue }
        let argument = store.codeSlice((open + 1)..<close)
        let names = matches(#"\.(\w+)"#, in: argument).map { $0[1] }.compactMap { constructors[$0] }
        expect(!names.isEmpty, "Q4 AppStore.swift:\(store.line(of: hit)) emits a typed constructor")
        let enclosing = functions.filter { $0.start < hit && hit < $0.end }.max { $0.start < $1.start }
        if let enclosing, !live.contains(enclosing.name) {
            unreachable[enclosing.name, default: []].formUnion(names)
        } else {
            reachable.formUnion(names)
        }
    }
    // Gate-driven events (onboarding steps, the onboarding paywall).
    let transition = functionBody(eventsFile, "transition")
    let gateEvents = matches(#"append\(\.(\w+)"#, in: transition).compactMap { constructors[$0[1]] }
    expect(store.codeText.contains("output.events.forEach(emitAnalytics)"),
           "Q4 AppStore forwards NativeAnalyticsGatePolicy events to emitAnalytics")
    expectEqual(Set(gateEvents), ["onboarding_step_viewed", "subscription_paywall_shown"],
                "Q4 the gate policy emits the onboarding-step and paywall events")
    reachable.formUnion(gateEvents)

    expect(reachable.isSubset(of: catalogEvents), "Q4 native emits only catalog events")
    let unwired = catalogEvents.subtracting(reachable)
    expectEqual(unwired, Set(analyticsExclusions.keys),
                "Q4 every catalog event without a reachable native emission is a named exclusion")
    expectEqual(reachable.count, 49, "Q4 49 of 52 catalog events are wired natively")
    expectEqual(unreachable, ["emitTaxSettingsSaved": ["tax_settings_saved"]],
                "Q4 the only unreachable emission is tax_settings_saved (emitTaxSettingsSaved)")
    expect(!live.contains("commitTaxSettings"), "Q4 commitTaxSettings, emitTaxSettingsSaved's only caller, has no caller")
    expect(analyticsExclusions.values.allSatisfy { $0.contains("owner:") }, "Q4 every exclusion names an owner")
}

// MARK: - Q5 Redaction denylist (contract §10.1)

private func testRedaction(root: URL) throws {
    let keys = readOrFail(root, "utils/storage/keys.ts")
    let secureBlock = matches(#"SECURE_FIELDS\s*=\s*\[([^\]]*)\]"#, in: keys).first?[1] ?? ""
    let secureFields = matches(#""(\w+)""#, in: secureBlock).map { $0[1] }
    expectEqual(secureFields, ["providerKey", "anthropicKey", "groqKey"], "Q5 RN SECURE_FIELDS parsed from utils/storage/keys.ts")

    let redactor = NativeErrorRedaction.standard
    for field in secureFields {
        expectEqual(NativeAnalyticsPrivacyPolicy.classifyUnknownKey(field), .secureKey,
                    "Q5 analytics classifies RN secure field \(field) as a secure key")
        expect(redactor.isDeniedKey(field), "Q5 the crash redactor denies RN secure field \(field)")
    }

    // One fixture per §10.1 deny row.
    let denyRow: [String: Any] = [
        "providerKey": "sk_live_provider", "providerKeys": ["venmo": "@me"], "anthropicKey": "sk-ant-x",
        "groqKey": "gsk_x", "geminiKey": "AIzaSyX", "rcAppleApiKey": "appl_x", "rcGoogleApiKey": "goog_x",
        "TradeReadyRevenueCatAPIKey": "appl_y", "stripeSecretKey": "sk_live_x", "stripePublishableKey": "pk_live_x",
        "paymentLinkUrl": "https://buy.stripe.com/abc", "accessToken": "eyJhbGciOi", "refreshToken": "r",
        "sessionToken": "s", "Authorization": "Bearer abc", "BACKEND_API_TOKEN": "t", "portalToken": "p",
        "bookingToken": "b", "customerName": "Alice Johnson", "email": "a@example.com", "phone": "555-123-4567",
        "address": "12 Oak St", "notes": "gate code", "messageBody": "hi", "reviewText": "great",
        "pdfBase64": "JVBERi0", "receiptImage": "data:image/png;base64,AAAA", "jobPhoto": "file:///x.jpg",
        "csvExport": "a,b", "requestBody": "{}", "amount": 42, "balanceRemaining": 10, "userEmail": "me@example.com",
    ]
    let crash = redactor.redactDictionary(denyRow)
    expectEqual(Array(crash.keys).sorted(), [], "Q5 the crash redactor drops every §10.1 deny-row key")
    let extras = redactor.redactExtras(denyRow.merging(["jobId": "j1", "count": 3]) { $1 })
    expectEqual(Set(extras.keys), ["jobId", "count"], "Q5 crash extras keep only allow-listed keys (money denied)")

    var analyticsProperties: [String: NativeAnalyticsValue] = [:]
    for key in denyRow.keys { analyticsProperties[key] = .string("x") }
    let evaluation = NativeAnalyticsPrivacyPolicy.standard.evaluate(event: "sign_up", properties: analyticsProperties)
    expectEqual(evaluation.decision, .send(event: "sign_up", properties: [:]),
                "Q5 analytics strips every §10.1 deny-row key from a catalog event")
    // The diagnostic keeps at most `maxIssues`, so the reason check runs on the RN secure fields alone.
    let secureOnly = NativeAnalyticsPrivacyPolicy.standard.evaluate(
        event: "sign_up", properties: Dictionary(uniqueKeysWithValues: secureFields.map { ($0, NativeAnalyticsValue.string("x")) })
    )
    let reasons = Dictionary(uniqueKeysWithValues: (secureOnly.diagnostic?.issues ?? []).map { ($0.key, $0.reason) })
    for field in secureFields {
        expectEqual(reasons[field], .secureKey, "Q5 analytics reports \(field) as secureKey")
    }

    // Secret values scrubbed in free text.
    for secret in ["sk_live_abcdef123456", "sk-ant-api03-abcdef", "gsk_abcdef123456", "appl_abcdef123456", "whsec_abcdef123456"] {
        let scrubbed = redactor.redactString("failed with \(secret) today")
        expect(!scrubbed.contains(secret), "Q5 the crash redactor scrubs a \(secret.prefix(5))… value in text")
        expect(NativeSensitiveData.containsSecret(secret), "Q5 \(secret.prefix(5))… is a recognised secret prefix")
    }

    // Widget snapshot keys (§10.1 column 3): no secure-looking key, no secure field.
    let snapshotJSON = try projectSnapshot([
        canonicalJob(#""id":"j9","scheduledDate":"2026-08-04","notes":"sk_live_planted""#),
        canonicalJob(#""id":"j2","timeSessions":[{"start":"2026-08-03T10:00:00.000Z"}]"#),
    ]).encodedJSON()
    var snapshotKeys = Set<String>()
    func collect(_ value: Any) {
        if let object = value as? [String: Any] {
            for (key, child) in object { snapshotKeys.insert(key); collect(child) }
        }
    }
    collect(try JSONSerialization.jsonObject(with: Data(snapshotJSON.utf8)))
    for key in snapshotKeys {
        let normalized = NativeSensitiveData.normalizedKey(key)
        expect(!NativeSensitiveData.secureKeyFragments.contains(where: normalized.contains),
               "Q5 widget snapshot key \(key) is not a secure key")
    }
    expect(secureFields.allSatisfy { !snapshotJSON.contains($0) } && !snapshotJSON.contains("sk_live_"),
           "Q5 no secure field or secret value reaches the widget snapshot")
}

// MARK: - Q6 Accessibility and layout (contract §12)

private func testAccessibilityRows(root: URL) {
    let contract = readOrFail(root, "docs/native-phase-11-platform-hardening-contract-decisions.md")
    var rows = 0
    for line in contract.components(separatedBy: "\n") where line.range(of: #"^\| A\d+ \|"#, options: .regularExpression) != nil {
        rows += 1
        let columns = line.components(separatedBy: " | ")
        guard columns.count >= 3 else { expect(false, "Q6 §12.1 row parses: \(line.prefix(12))"); continue }
        let id = columns[0].replacingOccurrences(of: "| ", with: "")
        let status = columns[2]
        expect(!status.hasPrefix("**Open"), "Q6 §12.1 \(id) is not open (\(status.prefix(40)))")
    }
    expectEqual(rows, 31, "Q6 §12.1 lists A1–A31")
    // A30's measurements run in run-accessibility-audit-tests.sh
    // (testDocumentPDFContrast); here only its row status is qualified.
}

@main
struct Phase11QualificationTests {
    static func main() throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sources = loadSources(root: root)

        try testWidgetSnapshot(root: root, sources: sources)
        testActionReplay(root: root)
        testDeepLinks()
        testAnalyticsCatalog(root: root, sources: sources)
        try testRedaction(root: root)
        testAccessibilityRows(root: root)

        if failures > 0 {
            print("phase11-qualification tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("phase11-qualification tests: \(checks)/\(checks) checks passed")
    }
}
