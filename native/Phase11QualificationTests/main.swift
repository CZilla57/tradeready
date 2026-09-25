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
//       extracted from the working tree by the runner, decode F1–F6 (parsed
//       from contract §2.4) and the native writer's output. Cited:
//       WidgetSnapshotTests (schema, projection, writer, lock),
//       NextJobWidgetTests, JobTimerWidgetTests.
//   Q2  Action replay: the RN `__tests__/widgetActions.test.js` vectors through
//       the real planner, replayer and coordinator. A completeness guard pins
//       every RN vector to its checks. Cited: WidgetActionReplayTests (claim WAL,
//       coordinator), AppIntentQueueTests (native writer → replay → AppStore),
//       WidgetOwnerGatingTests (untagged/foreign drop).
//   Q3  Deep links: every RN `__tests__/deepLinks.test.js` vector with a Swift
//       form (the guard records the null/undefined rows) through
//       `NativeDeepLinkParser`. Cited: DeepLinkRoutingTests (auth/owner/record
//       gates), AppGroupPendingOpenURLTests (cold-launch consumer).
//   Q4  Analytics: the RN `track(` call sites equal the §9.5 catalog, and every
//       catalog event has a reachable native emission or a named exclusion.
//       Cited: AnalyticsEventTests (payload parity), AnalyticsTransportTests.
//   Q5  Redaction: RN `SECURE_FIELDS`, the §10.1 deny table (parsed) and the
//       Square token shapes through the analytics policy, the crash redactor
//       and the widget snapshot. Cited: ErrorRedactionTests,
//       AnalyticsTransportTests, AIProviderKeyTests.
//   Q6  Accessibility/layout: every §12.1 status is on the closed allow-list.
//       Cited:
//       AccessibilityAuditTests (including A30, fixed in 11.13),
//       LayoutMetricsTests.
//
// Native differences asserted here, not re-litigated: the planner rejects a
// whole batch on one invalid action (§4.3; RN drops only that action), a
// malformed or non-array queue is quarantined (C8; RN reads it as []), and
// `parsePendingOpenURL` vets the URL grammar at the same boundary (§6.3; RN
// returns the raw URL and leaves the grammar to `parseWidgetDeepLink`).

private var failures = 0
private var checks = 0
/// Every check label that ran, for the RN-vector completeness guard (Q2/Q3).
private var executedLabels: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    executedLabels.append(label)
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T?, _ label: String) {
    checks += 1
    executedLabels.append(label)
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

/// F1–F6, parsed from contract §2.4 ("Fixtures (verbatim; ruling P4)") rather
/// than hand-copied, so a contract edit reaches this suite (fix round 1, M5).
private func contractFixtures(_ contract: String) -> [String: String] {
    let section = contract.components(separatedBy: "### 2.4 Fixtures").dropFirst().first?
        .components(separatedBy: "\n## ").first ?? ""
    var fixtures: [String: String] = [:]
    for match in matches(#"(?s)\*\*(F[1-6]) — .*?```json\n(.*?)\n```"#, in: section) {
        fixtures[match[1]] = match[2]
    }
    return fixtures
}

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
    // F1–F6 (contract §2.4) through both RN decoders and the native one.
    let fixtures = contractFixtures(readOrFail(root, "docs/native-phase-11-platform-hardening-contract-decisions.md"))
    expectEqual(fixtures.keys.sorted(), ["F1", "F2", "F3", "F4", "F5", "F6"], "Q1 contract §2.4 yields F1–F6")
    let fixtureF6 = fixtures["F6"] ?? ""
    expect(fixtureF6.contains(#""address":null"#), "Q1 contract F6 is the address: null fixture")
    expect(fixtures["F4"]?.contains(#""ownerTag":""#) == true, "Q1 contract F4 is the native writer shape (ownerTag)")
    for name in ["F1", "F2", "F3", "F4", "F5"] {
        let fixture = fixtures[name] ?? ""
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

/// The App Group queue in memory (RN `getWidgetSharedItem`/`removeWidgetSharedItem`).
private final class MemoryActionQueue: NativeWidgetActionQueueBacking {
    var value: String?
    init(_ value: String?) { self.value = value }
    func read() -> String? { value }
    func write(_ value: String?) { self.value = value }
}

/// One `replayNext` through the real claim transport and coordinator (RN
/// `replayWidgetActions`): the result, the shared queue afterwards, what was
/// saved, and how many quarantine records the owner holds.
private func coordinatorReplay(_ raw: String?, on source: Canonical.Snapshot) throws -> (
    result: NativeWidgetActionReplayCommitResult, queue: String?, saved: Canonical.Snapshot?, quarantined: Int
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-1113-replay-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = MemoryActionQueue(raw)
    let transport = NativeWidgetActionClaimTransport(
        queue: queue,
        claimDirectory: root.appendingPathComponent("claims", isDirectory: true),
        lockFile: root.appendingPathComponent("group/\(WidgetAppGroup.lockFileName)")
    )
    let repository = Canonical.SnapshotRepository(primaryURL: root.appendingPathComponent("store.json"))
    let result = try NativeWidgetActionReplayCoordinator(transport: transport, repository: repository)
        .replayNext(snapshot: source, verifiedAccountBinding: planningBinding)
    return (result, queue.value, try repository.load()?.snapshot, try transport.quarantinedQueues(accountBinding: planningBinding).count)
}

private func committed(_ result: NativeWidgetActionReplayCommitResult) -> (changed: Int, ignored: Int, ownerDropped: Int)? {
    if case let .committed(_, changed, ignored, ownerDropped) = result { return (changed, ignored, ownerDropped) }
    return nil
}

private let startJ1 = #""id":"a1","type":"timer_start","at":"2026-08-03T09:00:00.000Z","jobId":"j1""#

private func testActionReplay(root: URL) throws {
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
                    "Logged via Siri", "Q2 description \(label): falls back to Logged via Siri")
    }
    expect({ if case .invalidAction(index: 0, field: "date")? = planError(queue([#""id":"ea1","type":"expense_log","at":"2026-08-03T09:30:00.000Z","amount":5"#])) { return true }; return false }(),
           "Q2 expense_log without a date is rejected")

    // parsePendingActions. null and "" are an empty batch in both clients (fix
    // round 1, I2: native used to quarantine ""). A structurally bad entry: RN
    // drops it; native rejects the batch (§4.3).
    if case .nothingPending? = try? coordinatorReplay(nil, on: scheduled).result {
        expect(true, "Q2 parsePendingActions null: an absent queue is nothing pending (RN [])")
    } else {
        expect(false, "Q2 parsePendingActions null: an absent queue is nothing pending (RN [])")
    }
    for (label, raw) in [("empty string", ""), ("whitespace only", " \n\t ")] {
        let batch = try? NativeWidgetActionBatchPlanner.prepare(rawValue: raw, verifiedAccountBinding: planningBinding)
        expect(batch != nil && batch?.actions.isEmpty == true && batch?.ownerDroppedCount == 0,
               "Q2 parsePendingActions \(label): prepares an empty batch (RN []), not malformedQueue")
    }
    expectEqual(planError("{not json"), .malformedQueue, "Q2 malformed JSON: malformedQueue")
    expectEqual(planError(#"{"id":"a1","type":"timer_start","at":"x"}"#), .malformedQueue, "Q2 a non-array: malformedQueue")
    expectEqual(planError(queue([startJ1, #""type":"timer_start","at":"2026-08-03T09:00:00.000Z""#])),
                .malformedAction(index: 1), "Q2 an entry missing id rejects the batch (§4.3 native difference)")
    expectEqual(planError(queue([#""id":"a3","at":"2026-08-03T09:00:00.000Z""#])), .malformedAction(index: 0),
                "Q2 an entry missing type rejects the batch")
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

    // replayWidgetActions, through the real transport and coordinator.
    for (label, raw) in [("empty string", ""), ("whitespace only", "  ")] {
        let run = try coordinatorReplay(raw, on: scheduled)
        let counts = committed(run.result)
        expect(counts?.changed == 0 && counts?.ignored == 0 && counts?.ownerDropped == 0
               && run.queue == nil && run.saved == nil && run.quarantined == 0,
               "Q2 replay empty queue (\(label)): a no-op commit; nothing saved or quarantined, and the empty key is cleared")
    }
    let timerRun = try coordinatorReplay(queue([startJ1]), on: scheduled)
    expect(committed(timerRun.result)?.changed == 1 && timerRun.queue == nil
           && timerRun.saved?.payload.jobs?.first?.timeSessions?.count == 1,
           "Q2 replay commits a timer action: claimed, removed, saved")
    let tripRun = try coordinatorReplay(queue([tripAction + #","odometerStart":100,"odometerEnd":115"#]), on: snapshot())
    expect(committed(tripRun.result)?.changed == 1 && tripRun.queue == nil
           && tripRun.saved?.payload.trips?.first?.id == "t_siri_sa1",
           "Q2 replay commits a trip_log action: claimed, removed, saved")
    let expenseRun = try coordinatorReplay(queue([expenseAction + #","amount":42.5"#]), on: snapshot())
    expect(committed(expenseRun.result)?.changed == 1 && expenseRun.queue == nil
           && expenseRun.saved?.payload.expenses?.first?.id == "e_siri_ea1",
           "Q2 replay commits an expense_log action: claimed, removed, saved")
    let mixedRun = try coordinatorReplay(
        queue([startJ1, tripAction + #","odometerStart":100,"odometerEnd":115"#, expenseAction + #","amount":5"#]), on: scheduled
    )
    expect(committed(mixedRun.result)?.changed == 3 && mixedRun.queue == nil
           && mixedRun.saved?.payload.trips?.count == 1 && mixedRun.saved?.payload.expenses?.count == 1,
           "Q2 replay commits a mixed batch (timer + trip + expense) in one claim")
    let badRun = try coordinatorReplay("not valid json", on: scheduled)
    if case .quarantined(reason: .malformedQueue) = badRun.result {
        expect(badRun.queue == nil && badRun.saved == nil && badRun.quarantined == 1,
               "Q2 replay quarantines a batch that fails every guard: key cleared, nothing saved (C8: bytes kept)")
    } else {
        expect(false, "Q2 replay quarantines a batch that fails every guard: key cleared, nothing saved (C8: bytes kept)")
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
    // RN's null and undefined rows have no Swift form: `parse` takes a String.
    for url in [
        "", "tradeready://job/", "tradeready://job/a/b", "tradeready://job/a?x=1", "tradeready://invoice/i1",
        "otherapp://job/j1", "https://gettradereadyapp.com/job/j1", "tradeready://job/%zz",
    ] {
        expect(Parser.parse(url) == nil, "Q3 job rejects \(url.isEmpty ? "\"\"" : url)")
    }
    for url in [
        "tradeready://onmyway/", "tradeready://onmyway/a/b", "tradeready://onmyway/a?x=1",
        "otherapp://onmyway/j1", "tradeready://onmyway/%zz",
    ] {
        expect(Parser.parse(url) == nil, "Q3 onmyway rejects \(url)")
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

// MARK: - Q2/Q3 RN vector completeness (fix round 1, I2)

/// One RN jest vector: a `test(` (rows 1) or a `test.each(` (rows = its table
/// length, or -1 when the table is computed, e.g. `EXPENSE_CATEGORIES.map`).
private struct RNVector: Equatable, CustomStringConvertible {
    let describe: String
    let title: String
    let rows: Int
    var description: String { "\(describe) › \(title) ×\(rows)" }
}

/// The index just past the string literal or comment starting at `i`, or nil.
private func skipJSLiteral(_ c: [Character], _ i: Int) -> Int? {
    let ch = c[i]
    if ch == "\"" || ch == "'" || ch == "`" {
        var j = i + 1
        while j < c.count, c[j] != ch { if c[j] == "\\" { j += 1 }; j += 1 }
        return min(j + 1, c.count)
    }
    guard ch == "/", i + 1 < c.count else { return nil }
    if c[i + 1] == "/" {
        var j = i
        while j < c.count, c[j] != "\n" { j += 1 }
        return j
    }
    if c[i + 1] == "*" {
        var j = i + 2
        while j + 1 < c.count, !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
        return min(j + 2, c.count)
    }
    return nil
}

/// The index of the bracket closing the one at `open` (strings and comments skipped).
private func jsClose(_ c: [Character], _ open: Int) -> Int? {
    var depth = 0
    var i = open
    while i < c.count {
        if let next = skipJSLiteral(c, i) { i = next; continue }
        if "([{".contains(c[i]) { depth += 1 }
        if ")]}".contains(c[i]) { depth -= 1; if depth == 0 { return i } }
        i += 1
    }
    return nil
}

/// Top-level elements between `from` and `to` (an array literal's inside).
private func jsElementCount(_ c: [Character], from: Int, to: Int) -> Int {
    var count = 0, depth = 0, content = false, i = from
    while i < to {
        if let next = skipJSLiteral(c, i) {
            if c[i] != "/" { content = true }
            i = next; continue
        }
        let ch = c[i]
        if "([{".contains(ch) { depth += 1; content = true }
        else if ")]}".contains(ch) { depth -= 1 }
        else if ch == ",", depth == 0 { if content { count += 1 }; content = false }
        else if !ch.isWhitespace { content = true }
        i += 1
    }
    return count + (content ? 1 : 0)
}

/// Every `describe(`/`test(`/`test.each(` vector of an RN jest file, in order.
private func rnVectors(_ text: String) -> [RNVector] {
    let c = Array(text)
    func word(_ w: String, at i: Int) -> Bool {
        let chars = Array(w)
        guard i + chars.count <= c.count, Array(c[i..<(i + chars.count)]) == chars else { return false }
        return i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber || c[i - 1] == "_" || c[i - 1] == ".")
    }
    func title(after i: Int) -> (String, Int)? {
        var j = i
        while j < c.count, c[j].isWhitespace { j += 1 }
        guard j < c.count, "\"'`".contains(c[j]), let end = skipJSLiteral(c, j) else { return nil }
        return (String(c[(j + 1)..<(end - 1)]), end)
    }
    var vectors: [RNVector] = []
    var describe = ""
    var i = 0
    while i < c.count {
        if word("describe(", at: i), let (name, end) = title(after: i + 9) {
            describe = name; i = end; continue
        }
        if word("test.each(", at: i), let close = jsClose(c, i + 9) {
            var j = i + 10
            while j < close, c[j].isWhitespace { j += 1 }
            let rows = c[j] == "[" ? jsClose(c, j).map { jsElementCount(c, from: j + 1, to: $0) } ?? -1 : -1
            if close + 1 < c.count, c[close + 1] == "(", let (name, end) = title(after: close + 2) {
                vectors.append(RNVector(describe: describe, title: name, rows: rows))
                i = end; continue
            }
        }
        if word("test(", at: i), let (name, end) = title(after: i + 5) {
            vectors.append(RNVector(describe: describe, title: name, rows: 1)); i = end; continue
        }
        if let next = skipJSLiteral(c, i) { i = next; continue }
        i += 1
    }
    return vectors
}

/// How this suite transcribes one RN vector: the check-label prefixes that
/// must have run, how many RN rows have no Swift form, and why.
private struct Transcription {
    let vector: RNVector
    let labels: [String]
    var untranscribable = 0
    var note = ""
}

private func t(_ describe: String, _ title: String, rows: Int = 1, _ labels: [String],
               untranscribable: Int = 0, note: String = "") -> Transcription {
    Transcription(vector: RNVector(describe: describe, title: title, rows: rows), labels: labels,
                  untranscribable: untranscribable, note: note)
}

private let widgetActionsTranscription: [Transcription] = [
    t("parsePendingActions", "null input → empty array", ["Q2 parsePendingActions null:"]),
    t("parsePendingActions", "empty string → empty array", ["Q2 parsePendingActions empty string:"]),
    t("parsePendingActions", "malformed JSON → empty array", ["Q2 malformed JSON: malformedQueue"],
      note: "native difference: quarantined (C8)"),
    t("parsePendingActions", "valid JSON that isn't an array → empty array", ["Q2 a non-array: malformedQueue"],
      note: "native difference: quarantined (C8)"),
    t("parsePendingActions", "drops entries missing id, type, or at; keeps valid ones",
      ["Q2 an entry missing id", "Q2 an entry missing type", "Q2 an entry missing at", "Q2 null, non-object and untagged"],
      note: "native difference: the batch is rejected (§4.3)"),
    t("applyTimerActions", "timer_start clocks the matching job in",
      ["Q2 timer_start clocks", "Q2 timer_start opens", "Q2 timer_start advances"]),
    t("applyTimerActions", "timer_start with no matching job is dropped", ["Q2 timer_start for a missing job"]),
    t("applyTimerActions", "timer_start on a job that's already clocked in is dropped (applyClockIn guard)",
      ["Q2 timer_start on a clocked-in job"]),
    t("applyTimerActions", "timer_start is dropped for a '%s' job — replay-layer policy (applyClockIn itself has no status guard; the in-app button still clocks into complete/invoiced jobs)",
      rows: 4, ["Q2 timer_start is dropped for a"]),
    t("applyTimerActions", "timer_stop with jobId closes that job's session", ["Q2 timer_stop with jobId"]),
    t("applyTimerActions", "timer_stop with no jobId falls back to the single job with an active session",
      ["Q2 timer_stop without jobId"]),
    t("applyTimerActions", "timer_stop with nothing running anywhere is dropped", ["Q2 timer_stop with nothing running"]),
    t("applyTimerActions", "timer_stop with an explicit jobId whose job has no active session is dropped",
      ["Q2 timer_stop for a job with no active session"]),
    t("applyTimerActions", "applies a start-then-stop pair for the same job in order", ["Q2 a start-then-stop pair"]),
    t("applyTimerActions", "ignores trip_log actions entirely", ["Q2 a trip_log action never touches jobs"]),
    t("tripFromAction", "builds a Trip with the t_siri_<id> prefix and Home/Shop endpoints", ["Q2 trip_log builds"]),
    t("tripFromAction", "clamps miles to 0 when the end reading is before the start (bad odometer entry)",
      ["Q2 trip miles clamp"]),
    t("tripFromAction", "dedupes: null when a trip with this id already exists", ["Q2 trip_log dedupes"]),
    t("tripFromAction", "drops the action when %s", rows: 6, ["Q2 trip_log odometer", "Q2 a non-finite odometer"],
      note: "native difference: the batch is rejected (§4.3)"),
    t("tripFromAction", "drops the action when date is missing", ["Q2 trip_log without a date"]),
    t("expenseFromAction", "builds an Expense with the e_siri_<id> prefix and the exact field mapping",
      ["Q2 expense_log builds"]),
    t("expenseFromAction", "dedupes: null when an expense with this id already exists", ["Q2 expense_log dedupes"]),
    t("expenseFromAction", "drops the action when amount is %s", rows: 6, ["Q2 expense amount"],
      note: "native difference: the batch is rejected (§4.3)"),
    t("expenseFromAction", "amount exactly at the 1,000,000 cap is kept", ["Q2 an amount exactly at the cap"]),
    t("expenseFromAction", "an unrecognized category falls back to 'other' rather than dropping",
      ["Q2 an unknown category"]),
    t("expenseFromAction", "keeps a valid category '%s' as-is", rows: -1,
      ["Q2 RN EXPENSE_CATEGORIES parsed", "Q2 RN category"]),
    t("expenseFromAction", "an empty/missing description falls back to 'Logged via Siri'", ["Q2 description "]),
    t("expenseFromAction", "drops the action when date is missing", ["Q2 expense_log without a date"]),
    t("replayWidgetActions", "empty queue (%s): no removeSharedItem call, but exactly one snapshot refresh", rows: 2,
      ["Q2 parsePendingActions null:", "Q2 replay empty queue"],
      note: "native clears an empty key; the widget refresh after replay is AppStore's (not qualified here)"),
    t("replayWidgetActions", "reads, removes, replays a timer action, saves jobs, and refreshes",
      ["Q2 replay commits a timer action"]),
    t("replayWidgetActions", "reads, removes, replays a trip_log action, saves trips, and refreshes",
      ["Q2 replay commits a trip_log action"]),
    t("replayWidgetActions", "reads, removes, replays an expense_log action, saves expenses, and refreshes",
      ["Q2 replay commits an expense_log action"]),
    t("replayWidgetActions", "a mixed batch (timer + trip + expense) applies all three kinds in one replay",
      ["Q2 replay commits a mixed batch"]),
    t("replayWidgetActions", "a batch that fails every guard still removes the key and refreshes, without saving",
      ["Q2 replay quarantines"], note: "native difference: the bytes move to a quarantine file (C8)"),
    t("replayWidgetActions", "never throws, even when reading the shared item rejects outright", [],
      untranscribable: 1, note: "cited: WidgetActionReplayTests (transport failures); AppStore catches replay errors"),
    t("replayWidgetActions", "never throws, even when the final refresh rejects", [],
      untranscribable: 1, note: "cited: WidgetSnapshotTests (mirror write failures are results, not throws)"),
]

private let deepLinksTranscription: [Transcription] = [
    t("parseWidgetDeepLink", "parses a widget job link", ["Q3 job link"]),
    t("parseWidgetDeepLink", "is case-insensitive on the scheme and trims whitespace", ["Q3 job: scheme case-insensitive"]),
    t("parseWidgetDeepLink", "decodes percent-encoded ids", ["Q3 job: percent-decoded"]),
    t("parseWidgetDeepLink", "rejects %s", rows: 10, ["Q3 job rejects"],
      untranscribable: 2, note: "null and undefined have no Swift form: parse takes a String"),
    t("parseWidgetDeepLink — onmyway", "parses an on-my-way link", ["Q3 onmyway link"]),
    t("parseWidgetDeepLink — onmyway", "is case-insensitive on the scheme and trims whitespace",
      ["Q3 onmyway: case-insensitive"]),
    t("parseWidgetDeepLink — onmyway", "decodes percent-encoded ids", ["Q3 onmyway: percent-decoded"]),
    t("parseWidgetDeepLink — onmyway", "rejects %s", rows: 5, ["Q3 onmyway rejects"]),
    t("parsePendingOpenUrl", "returns the url for a stash written moments ago", ["Q3 pending stash at 2026-08-03T17:59:58Z"]),
    t("parsePendingOpenUrl", "accepts a stash written exactly now", ["Q3 pending stash at 2026-08-03T18:00:00Z"]),
    t("parsePendingOpenUrl", "accepts fractional-second timestamps (the JS toISOString shape)",
      ["Q3 pending stash at 2026-08-03T17:59:30.512Z"]),
    t("parsePendingOpenUrl", "accepts a stash just inside the five-minute window", ["Q3 pending stash at 2026-08-03T17:55:01Z"]),
    t("parsePendingOpenUrl", "drops a stale stash past five minutes", ["Q3 pending stash at 2026-08-03T17:54:00Z"]),
    t("parsePendingOpenUrl", "drops a stash dated in the future", ["Q3 pending stash at 2026-08-03T18:00:05Z"]),
    t("parsePendingOpenUrl", "drops %s", rows: 11, ["Q3 pending stash dropped:"],
      untranscribable: 1, note: "null input has no Swift form: parsePendingOpenURL takes a String"),
    t("parsePendingOpenUrl", "does not vet the url itself — that stays parseWidgetDeepLink's job",
      ["Q3 a foreign URL in the stash"], note: "native difference: one boundary (§6.3)"),
]

/// Every RN vector in the two jest files is pinned above, and each pinned
/// vector's checks ran: a new or changed RN vector fails here until it is
/// transcribed (or its lack of a Swift form is recorded).
private func testRNVectorCompleteness(root: URL) {
    for (path, table) in [
        ("__tests__/widgetActions.test.js", widgetActionsTranscription),
        ("__tests__/deepLinks.test.js", deepLinksTranscription),
    ] {
        let parsed = rnVectors(readOrFail(root, path))
        let pinned = table.map(\.vector)
        expectEqual(parsed.count, pinned.count, "RN vectors: \(path) test count")
        for vector in parsed where !pinned.contains(vector) {
            expect(false, "RN vectors: \(path) has an untranscribed vector: \(vector)")
        }
        for vector in pinned where !parsed.contains(vector) {
            expect(false, "RN vectors: \(path) no longer has pinned vector: \(vector)")
        }
        for entry in table {
            let ran = entry.labels.map { prefix in executedLabels.filter { $0.hasPrefix(prefix) }.count }
            let needed = max(entry.vector.rows, 1) - entry.untranscribable
            expect(ran.allSatisfy { $0 > 0 } && ran.reduce(0, +) >= needed,
                   "RN vectors: \(entry.vector) is transcribed (\(ran) checks for \(needed) rows)")
            expect(entry.untranscribable == 0 || !entry.note.isEmpty,
                   "RN vectors: \(entry.vector) records why \(entry.untranscribable) row(s) have no check")
        }
    }
}

// MARK: - Q4 Analytics catalog vs call sites (contract §9.5, §9.7)

/// The controller's owner for every cross-client gap 11.13 records (fix round 1, M3).
private let cutoverOwner = "owner: Phase 12.00 — cutover-blocking parity gap (build or dated waiver)"

/// Events with no native emission, each with the named owner (contract §17.2).
private let analyticsExclusions: [String: String] = [
    "booking_request_opened": "G1: no native remote-push surface; \(cutoverOwner)",
    "booking_update_opened": "G1: no native remote-push surface; \(cutoverOwner)",
    "tax_settings_saved": "G2: emitted only by AppStore.commitTaxSettings, which nothing calls; \(cutoverOwner)",
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
    expect(analyticsExclusions.values.allSatisfy { $0.hasSuffix("; \(cutoverOwner)") },
           "Q4 every exclusion names the Phase 12.00 cutover owner")
    let gaps = readOrFail(root, "docs/native-phase-11-platform-hardening-contract-decisions.md")
        .components(separatedBy: "### 17.2").dropFirst().first ?? ""
    for gap in Set(analyticsExclusions.values.map { String($0.prefix(2)) }).sorted() {
        let line = gaps.components(separatedBy: "\n").first { $0.hasPrefix("| \(gap) |") } ?? ""
        expect(line.contains(cutoverOwner), "Q4 contract §17.2 \(gap) carries the same owner")
    }
    // Fix round 2 (controller ruling on G5): the Square token gaps are fixed
    // in 11.13, so neither row may still name the Phase 12.00 cutover owner.
    for gap in ["G4", "G5"] {
        let line = gaps.components(separatedBy: "\n").first { $0.hasPrefix("| \(gap) |") } ?? ""
        expect(line.contains("Fixed (fix round 2") && !line.contains(cutoverOwner),
               "Q4 contract §17.2 \(gap) is recorded as fixed, with no Phase 12.00 owner")
    }
}

// MARK: - Q5 Redaction denylist (contract §10.1)

/// A plausible value for each §10.1 deny-row key.
private let denyFixtureValues: [String: Any] = [
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

/// Fixture keys for the §10.1 deny rows whose Data column names a class in
/// prose rather than backticked keys, keyed by the row's opening words.
private let proseDenyRowKeys: [String: [String]] = [
    "Stripe secret or publishable keys": ["stripeSecretKey", "stripePublishableKey", "paymentLinkUrl"],
    "Supabase access, refresh or session tokens": ["accessToken", "refreshToken", "sessionToken", "portalToken", "bookingToken"],
    "Customer PII": ["customerName", "email", "phone", "address", "notes", "messageBody", "reviewText"],
    "Document bytes": ["pdfBase64", "receiptImage", "jobPhoto", "csvExport", "requestBody"],
    "Email address of the signed-in user": ["userEmail"],
]

/// The deny-row keys of contract §10.1: rows whose Sentry column denies.
private func contractDenyKeys(_ contract: String) -> (keys: Set<String>, unmappedRows: [String]) {
    let table = contract.components(separatedBy: "### 10.1 Allow/deny table").dropFirst().first?
        .components(separatedBy: "### 10.2").first ?? ""
    var keys = Set<String>()
    var unmapped: [String] = []
    for line in table.components(separatedBy: "\n") where line.hasPrefix("| ") && !line.hasPrefix("| Data") {
        let columns = line.components(separatedBy: " | ")
        guard columns.count >= 3, columns[2].contains("deny") else { continue }
        let data = String(columns[0].dropFirst(2))
        let named = matches(#"`(\w+)`"#, in: data).map { $0[1] }
        let prose = proseDenyRowKeys.first { data.hasPrefix($0.key) }?.value ?? []
        if named.isEmpty && prose.isEmpty { unmapped.append(String(data.prefix(40))) }
        keys.formUnion(named + prose)
    }
    return (keys, unmapped)
}

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

    // One fixture per §10.1 deny row. The keys are parsed from the table (fix
    // round 1, M5): the backticked names in the Data column of every row whose
    // Sentry column denies, plus a pinned key list for each prose-only row.
    let denyKeys = contractDenyKeys(readOrFail(root, "docs/native-phase-11-platform-hardening-contract-decisions.md"))
    expectEqual(denyKeys.unmappedRows, [], "Q5 every §10.1 deny row maps to fixture keys")
    expectEqual(denyKeys.keys.count, 33, "Q5 §10.1 yields 33 deny-row keys")
    expectEqual(denyKeys.keys.subtracting(denyFixtureValues.keys).sorted(), [],
                "Q5 every §10.1 deny-row key has a fixture value")
    let denyRow = denyFixtureValues.filter { denyKeys.keys.contains($0.key) }
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

    // Fix round 1 (I1): Square access tokens. RN `scrubLegacySquareToken`
    // (App.tsx sign-in chain; utils/storage/settings.ts) deletes any stored
    // Square value `isSquarePaymentLink` refuses; native ports it in fix round
    // 2 (G4/G5, below). The shared screens also recognise the token shapes.
    let squareTokens = [
        "EAAAEOuLQObrVwJvCvoio3qx9Bi7MEZ2Ymv2nUx8m2cVYzAh8Kx5yGQZ", "sq0atp-3_Wb0zJnNx7lzM1nb2eP0g",
        "sq0atb-Hx7lzM1nb2eP0g_3Wb0zJ", "sq0csp-Q2lnbmF0dXJlX2V4YW1wbGU", "sq0csb-Q2lnbmF0dXJlX2V4YW1wbGU",
    ]
    for token in squareTokens {
        let tag = String(token.prefix(7))
        expect(!NativeInvoicePaymentLinks.isSquarePaymentLink(token), "Q5 Square \(tag)… is not a payment link (RN scrubs it)")
        expect(NativeSensitiveData.containsSecret(token), "Q5 Square \(tag)… is a recognised secret (containsSecret)")
        expect(!redactor.redactString("square rejected \(token) today").contains(token),
               "Q5 the crash redactor scrubs a Square \(tag)… token in text")
        let sent = NativeAnalyticsPrivacyPolicy.standard.evaluate(
            event: "payment_link_sent", properties: ["provider": .string(token), "deposit": .bool(false)]
        ).decision
        let leaked: Bool = { if case let .send(_, properties) = sent { return properties["provider"] == .string(token) }; return false }()
        expect(!leaked, "Q5 analytics never sends a Square \(tag)… token as a catalog string value")
    }
    // No over-redaction of links: every value `isSquarePaymentLink` accepts
    // (RN parity) stays a non-secret, so the Square payment link still works.
    for link in [
        "https://square.link/u/EAAAbc12", "square.link/u/AbC123", "www.square.link/u/AbC123",
        "checkout.square.site/merchant/ML1/checkout/ABC", "http://example.com/pay",
    ] {
        expect(NativeInvoicePaymentLinks.isSquarePaymentLink(link) && !NativeSensitiveData.containsSecret(link),
               "Q5 Square link \(link) stays a payment link and is not a secret")
        expect(NativeInvoicePaymentLinks.isProviderConfigured(.square, key: link),
               "Q5 Square link \(link) still configures the Square provider")
    }

    // Fix round 2 (G4/G5): the native Settings Square field validates on
    // save, and the RN `scrubLegacySquareToken` heal is ported. Both share one
    // pure policy whose Square rule IS `isSquarePaymentLink`.
    let square = NativeSquareProviderKeyPolicy.providerID
    expectEqual(square, "square", "Q5 the policy guards the RN `square` providerKeys entry")
    for token in squareTokens {
        let tag = String(token.prefix(7))
        let decision = NativeSquareProviderKeyPolicy.validate(token, provider: square)
        expectEqual(decision, .reject(NativeSquareProviderKeyPolicy.rejectionMessage),
                    "Q5 saving a Square \(tag)… token is rejected")
        expectEqual(NativeSquareProviderKeyPolicy.validate("  \(token)\n", provider: square),
                    .reject(NativeSquareProviderKeyPolicy.rejectionMessage),
                    "Q5 a padded Square \(tag)… token is rejected too")
        expectEqual(NativeSquareProviderKeyPolicy.scrubbed([square: token, "venmo": "@me"]), ["venmo": "@me"],
                    "Q5 the heal deletes a stored Square \(tag)… token and keeps other providers")
    }
    expect(!NativeSquareProviderKeyPolicy.rejectionMessage.contains("EAAA")
               && NativeSquareProviderKeyPolicy.rejectionMessage.contains(
                   "Paste your Square payment link (create one in Square Dashboard → Payment Links, e.g. https://square.link/u/abc123)"),
           "Q5 the rejection copy carries RN's Square hint and never echoes a token")
    for link in ["https://square.link/u/EAAAbc12", "square.link/u/AbC123", " checkout.square.site/merchant/ML1/checkout/ABC "] {
        expectEqual(NativeSquareProviderKeyPolicy.validate(link, provider: square), .save(link),
                    "Q5 Square link \(link) saves as typed")
        expect(NativeSquareProviderKeyPolicy.scrubbed([square: link]) == nil,
               "Q5 the heal keeps Square link \(link) and reports no change (no write)")
    }
    for blank in ["", "   ", "\n"] {
        expectEqual(NativeSquareProviderKeyPolicy.validate(blank, provider: square), .save(""),
                    "Q5 an empty Square entry clears the field")
    }
    expect(NativeSquareProviderKeyPolicy.scrubbed([square: ""]) == nil
               && NativeSquareProviderKeyPolicy.scrubbed([:]) == nil
               && NativeSquareProviderKeyPolicy.scrubbed(["venmo": "EAAAvenmo"]) == nil,
           "Q5 the heal is a no-op without a non-empty Square value (RN `!square` short-circuit)")
    for provider in ["paypal", "venmo", "custom", "stripe"] {
        expectEqual(NativeSquareProviderKeyPolicy.validate("johndoe", provider: provider), .save("johndoe"),
                    "Q5 \(provider) keeps RN's unvalidated save")
    }
    // The heal runs where RN runs it (sign-in) and wherever native loads or
    // merges synced settings: the initial-sync commit, the returning-user
    // sign-in, and every delta-pull commit.
    let appStore = SourceFile(relativePath: "AppStore.swift",
                              text: readOrFail(root, "native/TradeReadyNative/AppStore.swift"))
    for function in ["beginInitialSyncGate", "applyAuthenticatedIdentityOutcome", "pullDeltaAndCommit"] {
        let body = SourceFile(relativePath: function, text: functionBody(appStore, function))
        expect(body.codeText.contains("scrubLegacySquareToken()"),
               "Q5 AppStore.\(function) runs the Square token heal")
    }
    let settingsView = SourceFile(relativePath: "SettingsView.swift",
                                  text: readOrFail(root, "native/TradeReadyNative/SettingsView.swift"))
    expect(!settingsView.codeText.contains(".setProviderKey(")
               && settingsView.codeText.contains("store.setPaymentProviderKey("),
           "Q5 Settings writes provider keys only through the validated AppStore save")

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

/// The §12.1 status openings that count as closed for Phase 11 (fix round 1,
/// M6). Anything else, including "**Open", fails.
private let closedStatuses = [
    "**Fixed", "**Retained", "**Done by", "**Accepted", "**Mitigated", "**Resolved",
    "**Deferred to device**",
]

private func testAccessibilityRows(root: URL) {
    let contract = readOrFail(root, "docs/native-phase-11-platform-hardening-contract-decisions.md")
    var rows = 0
    for line in contract.components(separatedBy: "\n") where line.range(of: #"^\| A\d+ \|"#, options: .regularExpression) != nil {
        rows += 1
        let columns = line.components(separatedBy: " | ")
        guard columns.count >= 3 else { expect(false, "Q6 §12.1 row parses: \(line.prefix(12))"); continue }
        let id = columns[0].replacingOccurrences(of: "| ", with: "")
        let status = columns[2]
        expect(closedStatuses.contains { status.hasPrefix($0) },
               "Q6 §12.1 \(id) has a closed status (\(status.prefix(40)))")
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
        try testActionReplay(root: root)
        testDeepLinks()
        testRNVectorCompleteness(root: root)
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
