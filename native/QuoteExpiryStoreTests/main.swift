import Foundation

// Phase 32 (quote expiration dates, spec 2026-10-03 §3, §6.4, §6.5, §8)
// store-level host tests: the AppStore wiring over the shared in-memory
// Supabase server (`native/HostTestSupport/InMemorySupabase.swift`) and a fake
// approval-link service — the review draft's proposed date, the three send
// stamps, the link's fail-closed date check, the declined-revision guard and
// `extendEstimateValidity`. The pure rules run in
// `native/QuoteExpiryTests/main.swift`. Run with TZ=America/Phoenix.

// MARK: - Harness

@MainActor var failures = 0
@MainActor var checks = 0

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

final class AlwaysReachable: NativeSyncReachability, @unchecked Sendable {
    func isReachable() async -> Bool { true }
}

/// The Worker's `create-link` as the device sees it: one token per job for
/// the life of the link (`planApprovalWrite` keeps it), a fresh `sentAt` per
/// call, and every snapshot it was sent recorded.
final class FakeEstimateLinkService: NativeEstimateApprovalLinking, @unchecked Sendable {
    private(set) var calls: [(jobID: String, snapshot: Canonical.EstimateApprovalSnapshot)] = []
    private var tokens: [String: String] = [:]
    var failure: NativeEstimateApprovalLinkError?

    func createLink(
        jobID: String,
        snapshot: Canonical.EstimateApprovalSnapshot,
        sessionBytes: Data
    ) async throws -> NativeEstimateApprovalLink {
        if let failure { throw failure }
        calls.append((jobID, snapshot))
        let token = tokens[jobID] ?? "tok_\(tokens.count + 1)_quoteexpiry_0123456789"
        tokens[jobID] = token
        return NativeEstimateApprovalLink(
            url: URL(string: "https://tradeready.example/estimate.html?j=\(jobID)&t=\(token)")!,
            token: token,
            sentAt: String(format: "2026-10-03T19:%02d:00.000Z", calls.count)
        )
    }

    func beginDeclinedRevision(jobID: String, approvalToken: String, sessionBytes: Data) async throws -> Canonical.Job {
        throw NativeEstimateApprovalLinkError.unavailable
    }
}

/// Forwards the device's push to the server, then (once, when armed) lets
/// another writer change the server's job before the coordinator's pull — the
/// window between "sync" and "authoritative pull" the store re-checks.
final class InterceptingPushLoader: NativeMutationPushHTTPLoading, @unchecked Sendable {
    let server: InMemorySupabase
    var afterJobsWrite: (@MainActor () async -> Void)?

    init(server: InMemorySupabase) { self.server = server }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try await server.data(for: request)
        if request.httpMethod != "GET", request.url?.pathComponents.last == "jobs", let hook = afterJobsWrite {
            afterJobsWrite = nil
            await hook()
        }
        return result
    }
}

/// One signed-in device of the test account with a completed workspace, a
/// real sync coordinator over `server`, and the fake link service.
@MainActor
struct Harness {
    static let subject = "32323232-3232-3232-3232-323232323232"
    static let binding = String(repeating: "c", count: 64)  // hex, as a real binding is
    static let session = Data(#"{"access_token":"private-access-token"}"#.utf8)
    static let supabaseURL = URL(string: "https://project.supabase.co")!

    let dir: URL
    let store: AppStore
    let server: InMemorySupabase
    let loader: InterceptingPushLoader
    let links: FakeEstimateLinkService
    let queue: Canonical.NativeMutationQueue
    let coordinator: NativeSyncCoordinator

    init(tag: String) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-quote-expiry-store-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.json")
        server = InMemorySupabase()
        loader = InterceptingPushLoader(server: server)
        links = FakeEstimateLinkService()
        store = AppStore(
            fileURL: storeURL,
            seedIfMissing: false,
            initialSyncService: NativeSupabaseInitialSyncService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", loader: server
            ),
            estimateApprovalLinkService: links,
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        // `createEstimateApprovalLink` and `extendEstimateValidity` require
        // the exact completed workspace on disk, as every real account has.
        try? NativeOnboardingStore(snapshotURL: storeURL).save(NativeOnboardingDocument(
            accountBinding: Self.binding, stage: .done,
            draft: .init(businessName: "Ada Electric", contactName: "Ada", trade: .electrical, step: 1)
        ))
        store.testSeedNativeSignedInOwner(subject: Self.subject, binding: Self.binding)
        let credentials = NativeSyncCredentials(subject: Self.subject, sessionBytes: Self.session)
        store.scheduleBookingTestCredentials = credentials
        queue = Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("mutation-queue.json"))
        let store = store
        // Mirrors `AppStore.syncCoordinatorIfConfigured` (as the poor-network
        // and rollback-readiness suites do), minus BuildEnvironment.
        coordinator = NativeSyncCoordinator(
            push: NativeSupabaseMutationPushService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key",
                allowsWrites: true, loader: loader
            ),
            queue: queue,
            reachability: AlwaysReachable(),
            credentialsProvider: { credentials },
            refreshSession: { false },
            settleRejected: { try store.testSettleRejectedChanges($0) },
            pull: { await store.testPullDeltaIfPossible() },
            statusChanged: { status in store.testApplySyncStatus(status) }
        )
        store.testUseSyncCoordinator(coordinator)
    }

    /// The canonical job as committed on disk (what a relaunch would read).
    func job(_ id: String) -> Canonical.Job? {
        let repository = Canonical.SnapshotRepository(primaryURL: dir.appendingPathComponent("store.json"))
        return (try? repository.load())??.snapshot.payload.jobs?.first { $0.id == id }
    }

    func serverJob(_ id: String) -> Canonical.Job? {
        guard let row = server.storedRow(table: "jobs", id: id, userID: Self.subject),
              let data = try? JSONEncoder().encode(row.data)
        else { return nil }
        return try? JSONDecoder().decode(Canonical.Job.self, from: data)
    }

    /// The queued upsert's raw JSON, so "the key is absent" is provable.
    func queuedJobJSON(_ id: String) -> [String: Canonical.JSONValue]? {
        guard let payload = queue.load().last(where: { $0.table == "jobs" && $0.recordId == id })?.payload,
              case let .object(fields) = payload
        else { return nil }
        return fields
    }

    func queueKeys() -> [String] { queue.load().map { "\($0.table)/\($0.recordId)" } }

    /// Another writer (the Worker, or a second device) replaces the server's job blob.
    func remoteWrite(_ job: Canonical.Job) async throws {
        let other = NativeSupabaseMutationPushService(
            supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", allowsWrites: true, loader: server
        )
        let payload = try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(job))
        let result = try await other.push(
            sessionBytes: Self.session, expectedUserSubject: Self.subject,
            items: [.init(table: "jobs", op: .upsert, recordId: job.id, payload: payload, ts: "2026-10-03T00:00:00.000Z")]
        )
        expect(result.remaining.isEmpty, "remote write: the job reached the server")
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

// Fixed instants, read in America/Phoenix (UTC−7, no DST).
let now = ISO8601DateFormatter().date(from: "2026-10-03T19:00:00Z")!      // Oct 3, 12:00 MST
let monthAgo = ISO8601DateFormatter().date(from: "2026-09-01T19:00:00Z")! // Sep 1, 12:00 MST
let today = "2026-10-03"
let todayPlus30 = "2026-11-02"

/// A priced lead estimate for a saved customer, through the real store paths.
@MainActor
func pricedLead(_ h: Harness, _ label: String, title: String = "Panel upgrade") -> String? {
    let customer = Customer(name: "Delta Roofing", email: "delta@example.test", phone: "555-0100")
    var job = Job(customerId: customer.id, customerName: customer.name, title: title, laborRate: 100)
    job.status = .lead
    guard h.store.upsert(customer), h.store.upsert(job),
          var pricing = h.store.jobPricingDraft(jobID: job.id)
    else { expect(false, "\(label): the estimate saves"); return nil }
    pricing.laborHours = 3
    pricing.laborRate = 100
    expect(h.store.saveJobPricing(pricing), "\(label): the job is priced")
    return job.id
}

/// Moves a sent estimate back to a lead through the UI model, which keeps
/// every canonical key the UI does not show (here, a stale valid-until date).
@MainActor
func revertToLead(_ h: Harness, _ id: String) -> Bool {
    guard var ui = h.store.jobs.first(where: { $0.id == id }) else { return false }
    ui.status = .lead
    return h.store.upsert(ui)
}

func sortedJSON<T: Encodable>(_ value: T?) -> String {
    guard let value else { return "nil" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "unencodable"
}

/// The approval the Worker stores for a snapshot, optionally decided.
func approval(
    token: String,
    snapshot: Canonical.EstimateApprovalSnapshot,
    decision: String? = nil
) throws -> Canonical.EstimateApproval {
    var fields: [String: Canonical.JSONValue] = [
        "token": .string(token),
        "sentAt": .string("2026-09-01T19:00:00.000Z"),
        "snapshot": try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(snapshot))
    ]
    if let decision {
        fields["decision"] = .string(decision)
        fields["consentAt"] = .string("2026-09-02T19:00:00.000Z")
        fields["signerName"] = .string("Pat Customer")
    }
    let data = try JSONEncoder().encode(Canonical.JSONValue.object(fields))
    return try JSONDecoder().decode(Canonical.EstimateApproval.self, from: data)
}

// MARK: - 1. Review draft proposal (spec §3)

@MainActor
func testReviewDraftProposal() throws {
    let h = Harness(tag: "proposal")
    defer { h.cleanup() }
    let zone = TimeZone.current.identifier
    expectEqual(zone, "America/Phoenix", "proposal: the runner pins TZ=America/Phoenix")

    // A fresh lead: today + 30 (absent setting), zone frozen with it.
    guard let lead = pricedLead(h, "proposal") else { return }
    guard let leadDraft = h.store.estimateReviewDraft(jobID: lead, now: now) else {
        expect(false, "proposal: a lead opens for review"); return
    }
    expectEqual(leadDraft.validUntil, todayPlus30, "proposal: a lead proposes today + 30")
    expectEqual(leadDraft.snapshot.validUntil, todayPlus30, "proposal: the date is frozen into the snapshot")
    expectEqual(leadDraft.snapshot.validUntilTimeZone, zone, "proposal: with the device zone")
    expectEqual(leadDraft.validUntilTimeZone, zone, "proposal: the draft reports the snapshot's zone")
    expect(h.job(lead)?.estimateValidUntil == nil, "proposal: opening a review never writes the job")
    expect(h.queuedJobJSON(lead)?["estimateValidUntil"] == nil, "proposal: nor queues a date")

    // FA-039: 23:30 local on Oct 2 is still Oct 2 here, though UTC says Oct 3.
    let lateNight = ISO8601DateFormatter().date(from: "2026-10-03T06:30:00Z")!
    expectEqual(h.store.estimateReviewDraft(jobID: lead, now: lateNight)?.validUntil, "2026-11-01",
                "proposal FA-039: today is the local date, so +30 is Nov 1")

    // A lead ignores a stale stored date: a revised estimate is a new offer.
    expect(h.store.markEstimateSent(id: lead, from: .lead, validUntil: "2026-10-20", on: now), "proposal: sent with Oct 20")
    expect(revertToLead(h, lead), "proposal: back to a lead (the stale date stays on the job)")
    expectEqual(h.job(lead)?.estimateValidUntil, "2026-10-20", "proposal: the lead still carries the old date")
    expectEqual(h.store.estimateReviewDraft(jobID: lead, now: now)?.validUntil, todayPlus30,
                "proposal: a lead ignores a stale estimateValidUntil")

    // estimate_sent keeps a still-valid date, including one that ends today.
    guard let sent = pricedLead(h, "proposal-sent", title: "Rewire garage") else { return }
    expect(h.store.markEstimateSent(id: sent, from: .lead, validUntil: "2026-10-20", on: now), "proposal: sent")
    expectEqual(h.store.estimateReviewDraft(jobID: sent, now: now)?.validUntil, "2026-10-20",
                "proposal: a re-send keeps a still-valid date")
    let lastDay = ISO8601DateFormatter().date(from: "2026-10-21T06:59:00Z")! // Oct 20, 23:59 MST
    expectEqual(h.store.estimateReviewDraft(jobID: sent, now: lastDay)?.validUntil, "2026-10-20",
                "proposal: a date ending today is still kept")

    // A past date is re-proposed; so is an absent one.
    guard let past = pricedLead(h, "proposal-past", title: "Replace breaker") else { return }
    expect(h.store.markEstimateSent(id: past, from: .lead, validUntil: "2026-09-20", on: monthAgo), "proposal: sent last month")
    expectEqual(h.store.estimateReviewDraft(jobID: past, now: now)?.validUntil, todayPlus30,
                "proposal: an expired date gets a fresh proposal")
    guard let undated = pricedLead(h, "proposal-undated", title: "Install fan") else { return }
    expect(h.store.markEstimateSent(id: undated, from: .lead, on: now), "proposal: sent without a date")
    expect(h.job(undated)?.estimateValidUntil == nil, "proposal: no date stored")
    expectEqual(h.store.estimateReviewDraft(jobID: undated, now: now)?.validUntil, todayPlus30,
                "proposal: an absent date gets a fresh proposal")

    // The owner's choice overrides the proposal; out-of-range choices refuse.
    let chosen = h.store.estimateReviewDraft(jobID: lead, validUntil: .date("2026-12-15"), now: now)
    expectEqual(chosen?.validUntil, "2026-12-15", "proposal: a chosen date is used")
    let none = h.store.estimateReviewDraft(jobID: lead, validUntil: .doesNotExpire, now: now)
    expect(none != nil && none?.validUntil == nil, "proposal: Doesn't expire has no date")
    expect(none?.snapshot.validUntil == nil && none?.snapshot.validUntilTimeZone == nil,
           "proposal: and neither snapshot key")
    expect(h.store.estimateReviewDraft(jobID: lead, validUntil: .date("2026-10-02"), now: now) == nil,
           "proposal: yesterday is refused")
    expectEqual(h.store.migrationMessage, NativeEstimateExtensionError.invalidDate.errorDescription,
                "proposal: the refusal explains itself")
    expect(h.store.estimateReviewDraft(jobID: lead, validUntil: .date("2027-10-04"), now: now) == nil,
           "proposal: more than 365 days out is refused")
    expectEqual(h.store.estimateReviewDraft(jobID: lead, validUntil: .date("2027-10-03"), now: now)?.validUntil,
                "2027-10-03", "proposal: exactly 365 days out is allowed")

    // The validity setting drives the proposal; 0 means no expiry.
    h.store.settings.estimateValidityDays = 10
    expectEqual(h.store.estimateReviewDraft(jobID: lead, now: now)?.validUntil, "2026-10-13",
                "proposal: validityDays 10 proposes today + 10")
    h.store.settings.estimateValidityDays = 0
    let noExpiry = h.store.estimateReviewDraft(jobID: lead, now: now)
    expect(noExpiry != nil && noExpiry?.validUntil == nil, "proposal: validityDays 0 proposes no date")
    expect(noExpiry?.snapshot.validUntilTimeZone == nil, "proposal: validityDays 0 freezes no zone")
    expectEqual(h.store.estimateReviewDraft(jobID: past, now: now)?.validUntil, nil,
                "proposal: validityDays 0 re-proposes no date for an expired re-send")
}

// MARK: - 2. Send stamps (spec §3, §6.4)

@MainActor
func testSendStamps() async throws {
    let h = Harness(tag: "stamps")
    defer { h.cleanup() }

    // markEstimateSent writes the review's date with the stamp.
    guard let marked = pricedLead(h, "stamps-mark") else { return }
    guard let markDraft = h.store.estimateReviewDraft(jobID: marked, now: now) else { return }
    expect(h.store.markEstimateSent(id: marked, from: .lead, validUntil: markDraft.validUntil, on: now),
           "stamps: marked sent")
    expectEqual(h.job(marked)?.status, "estimate_sent", "stamps: estimate_sent")
    expectEqual(h.job(marked)?.estimateSentAt, today, "stamps: estimateSentAt is today")
    expectEqual(h.job(marked)?.estimateValidUntil, todayPlus30, "stamps: mark writes the date")
    expectEqual(h.queuedJobJSON(marked)?["estimateValidUntil"], .string(todayPlus30),
                "stamps: in the same upsert")
    // A sheet left open past its date refuses to mark the estimate sent.
    guard let stale = pricedLead(h, "stamps-stale", title: "Stale sheet") else { return }
    expect(!h.store.markEstimateSent(id: stale, from: .lead, validUntil: "2026-10-02", on: now),
           "stamps: a passed date is refused")
    expectEqual(h.job(stale)?.status, "lead", "stamps: the refused job is still a lead")

    // recordEstimateDelivery matches with a custom review date and writes it.
    guard let delivered = pricedLead(h, "stamps-deliver", title: "Deliver") else { return }
    guard let custom = h.store.estimateReviewDraft(jobID: delivered, validUntil: .date("2026-12-15"), now: now) else {
        expect(false, "stamps: a custom-dated review opens"); return
    }
    expectEqual(h.store.recordEstimateDelivery(for: custom, on: now), .recorded,
                "stamps: a custom review date still matches the current estimate")
    expectEqual(h.job(delivered)?.estimateValidUntil, "2026-12-15", "stamps: delivery writes the review's date")
    // Re-sent as "Doesn't expire": the stamp removes the key.
    guard let undatedResend = h.store.estimateReviewDraft(jobID: delivered, validUntil: .doesNotExpire, now: now) else {
        expect(false, "stamps: an undated re-send review opens"); return
    }
    expectEqual(h.store.recordEstimateDelivery(for: undatedResend, on: now), .recorded, "stamps: undated re-send recorded")
    expect(h.job(delivered)?.estimateValidUntil == nil, "stamps: Doesn't expire removes the stored date")
    expect(h.queuedJobJSON(delivered).map { $0["estimateValidUntil"] == nil } == true,
           "stamps: the upsert carries no estimateValidUntil key")
    // A pricing change after review is still preserved (no stamp).
    guard let dated = h.store.estimateReviewDraft(jobID: delivered, validUntil: .date("2026-11-20"), now: now),
          var pricing = h.store.jobPricingDraft(jobID: delivered)
    else { return }
    pricing.laborHours = 6
    expect(h.store.saveJobPricing(pricing), "stamps: pricing edited after review")
    expectEqual(h.store.recordEstimateDelivery(for: dated, on: now), .preservedNewerState,
                "stamps: a newer estimate is preserved")
    expect(h.job(delivered)?.estimateValidUntil == nil, "stamps: and its date is untouched")

    // createEstimateApprovalLink stamps the date, mints with it and mirrors it.
    guard let linked = pricedLead(h, "stamps-link", title: "Linked") else { return }
    guard let linkDraft = h.store.estimateReviewDraft(jobID: linked, now: now) else { return }
    let outcome = await h.store.createEstimateApprovalLink(for: linkDraft, on: now)
    guard case .success(let link) = outcome else {
        expect(false, "stamps: the approval link is created (\(outcome))"); return
    }
    expectEqual(h.job(linked)?.estimateValidUntil, todayPlus30, "stamps: the link path writes the date")
    expectEqual(h.links.calls.last?.snapshot.validUntil, todayPlus30, "stamps: the Worker receives the date")
    expectEqual(h.links.calls.last?.snapshot.validUntilTimeZone, "America/Phoenix", "stamps: and its zone")
    expectEqual(h.job(linked)?.approval?.token, link.token, "stamps: the link is mirrored")
    expectEqual(h.job(linked)?.approval?.snapshot.validUntil, todayPlus30, "stamps: the mirrored snapshot has the date")
    expectEqual(h.serverJob(linked)?.estimateValidUntil, todayPlus30, "stamps: the date reached the server")

    // An undated link path removes the key and mints without validity.
    guard let undatedLink = h.store.estimateReviewDraft(jobID: linked, validUntil: .doesNotExpire, now: now) else { return }
    guard case .success(let again) = await h.store.createEstimateApprovalLink(for: undatedLink, on: now) else {
        expect(false, "stamps: the undated link is updated"); return
    }
    expectEqual(again.token, link.token, "stamps: an update keeps the token")
    expect(h.job(linked)?.estimateValidUntil == nil, "stamps: an undated link removes the stored date")
    expect(h.links.calls.last?.snapshot.validUntil == nil && h.links.calls.last?.snapshot.validUntilTimeZone == nil,
           "stamps: the Worker receives no validity")

    // A review left open past its date never stamps or mints.
    guard let expiredReview = h.store.estimateReviewDraft(jobID: linked, validUntil: .date(today), now: now) else { return }
    let tomorrow = ISO8601DateFormatter().date(from: "2026-10-04T19:00:00Z")!
    let callsBefore = h.links.calls.count
    let sentBefore = h.job(linked)?.estimateSentAt
    let staleOutcome = await h.store.createEstimateApprovalLink(for: expiredReview, on: tomorrow)
    expectEqual(staleOutcome, .failure(.estimateChanged), "stamps: a passed review date fails closed")
    expectEqual(h.links.calls.count, callsBefore, "stamps: nothing minted")
    expectEqual(h.job(linked)?.estimateSentAt, sentBefore, "stamps: nothing stamped")
    expect(h.job(linked)?.estimateValidUntil == nil, "stamps: the stored date is untouched")
}

// MARK: - 3. createEstimateApprovalLink fails closed on a different pulled date

@MainActor
func testLinkFailsClosedOnPulledDate() async throws {
    let h = Harness(tag: "pulled-date")
    defer { h.cleanup() }
    guard let id = pricedLead(h, "pulled") else { return }
    _ = await h.coordinator.sync(trigger: .manual)
    expect(h.queueKeys().isEmpty, "pulled: the baseline reached the server")
    guard let review = h.store.estimateReviewDraft(jobID: id, now: now) else { return }

    // Another device extends the estimate between our push and our pull.
    h.loader.afterJobsWrite = {
        guard var other = h.serverJob(id) else { expect(false, "pulled: the server holds the job"); return }
        other.estimateValidUntil = "2026-12-31"
        try? await h.remoteWrite(other)
    }
    let outcome = await h.store.createEstimateApprovalLink(for: review, on: now)
    expectEqual(outcome, .failure(.estimateChanged), "pulled: a different pulled date fails closed")
    expect(h.links.calls.isEmpty, "pulled: nothing was minted")
    expectEqual(h.job(id)?.estimateValidUntil, "2026-12-31", "pulled: the device shows the newer date")
    expect(h.job(id)?.approval == nil, "pulled: no approval mirror")
}

// MARK: - 4. Declined-revision guard (spec §6.1)

@MainActor
func testDeclinedGuardIgnoresFreshDate() async throws {
    let h = Harness(tag: "declined")
    defer { h.cleanup() }
    guard let id = pricedLead(h, "declined") else { return }
    _ = await h.coordinator.sync(trigger: .manual)

    // The Worker's revise-declined result: a lead with the declined estimate
    // (dated last month) in history, no approval, no send stamp.
    guard var server = h.serverJob(id) else { expect(false, "declined: the server holds the job"); return }
    let declinedSnapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: server, customerName: "Delta Roofing", businessName: h.store.settings.businessName,
        validUntil: "2026-09-30", validUntilTimeZone: "America/Phoenix"
    )
    server.approvalHistory = [try approval(token: "tok-declined-0123456789", snapshot: declinedSnapshot, decision: "declined")]
    server.approval = nil
    server.estimateSentAt = nil
    try await h.remoteWrite(server)
    _ = await h.coordinator.sync(trigger: .manual)
    expectEqual(h.job(id)?.approvalHistory?.count, 1, "declined: the history was pulled")

    let fresh = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: h.job(id)!, customerName: "Delta Roofing", businessName: h.store.settings.businessName,
        validUntil: todayPlus30, validUntilTimeZone: "America/Phoenix"
    )
    expect(!CanonicalUIAdapters.estimateApprovalSnapshotsMatch(fresh, declinedSnapshot),
           "declined: the fresh date alone makes the snapshots differ")
    h.store.migrationMessage = nil
    expect(h.store.estimateReviewDraft(jobID: id, now: now) == nil,
           "declined: an unrevised re-send with a fresh date is still blocked")
    expect(h.store.migrationMessage?.hasPrefix("Revise the declined estimate") == true, "declined: the guard explains itself")
    expect(h.store.estimateReviewDraft(jobID: id, validUntil: .doesNotExpire, now: now) == nil,
           "declined: and with Doesn't expire")

    guard var pricing = h.store.jobPricingDraft(jobID: id) else { return }
    pricing.laborHours = 4
    expect(h.store.saveJobPricing(pricing), "declined: the owner revises the price")
    expect(h.store.estimateReviewDraft(jobID: id, now: now) != nil, "declined: a revised estimate opens for review")
}

// MARK: - 5. Extend (spec §6.5)

@MainActor
func testExtendWithoutLink() async throws {
    let h = Harness(tag: "extend-local")
    defer { h.cleanup() }
    guard let id = pricedLead(h, "local") else { return }
    expect(h.store.markEstimateSent(id: id, from: .lead, validUntil: "2026-09-20", on: monthAgo), "local: sent last month")
    _ = await h.coordinator.sync(trigger: .manual)
    expect(h.queueKeys().isEmpty, "local: synced")
    expect(h.store.estimateValidity(jobID: id, now: now) == .expired(validUntil: "2026-09-20", daysAgo: 13),
           "local: expired 13 days ago")
    expect(h.store.canChangeEstimateValidity(jobID: id), "local: the owner may extend")
    let sentAt = h.job(id)?.estimateSentAt

    expectEqual(await h.store.extendEstimateValidity(jobID: id, validUntil: "2026-10-02", now: now),
                .failure(.invalidDate), "local: a past date is refused")
    expectEqual(await h.store.extendEstimateValidity(jobID: id, validUntil: "2027-10-04", now: now),
                .failure(.invalidDate), "local: more than a year out is refused")
    expectEqual(h.job(id)?.estimateValidUntil, "2026-09-20", "local: refusals change nothing")

    let outcome = await h.store.extendEstimateValidity(jobID: id, validUntil: "2026-12-01", now: now)
    expectEqual(outcome, .extended(link: nil), "local: extended without a link")
    expectEqual(h.job(id)?.estimateValidUntil, "2026-12-01", "local: the new date is saved")
    expectEqual(h.job(id)?.estimateSentAt, sentAt, "local: the follow-up clock is unchanged")
    expectEqual(h.job(id)?.status, "estimate_sent", "local: still sent")
    expect(h.links.calls.isEmpty, "local: the link service is never called")
    expectEqual(h.queueKeys(), ["jobs/\(id)"], "local: one queued upsert")
    expectEqual(h.queuedJobJSON(id)?["estimateValidUntil"], .string("2026-12-01"), "local: the upsert carries the date")
    expect(h.store.estimateValidity(jobID: id, now: now) == .open(validUntil: "2026-12-01", daysLeft: 59),
           "local: open again")

    expectEqual(await h.store.extendEstimateValidity(jobID: id, validUntil: nil, now: now), .extended(link: nil),
                "local: Doesn't expire")
    expect(h.job(id)?.estimateValidUntil == nil, "local: the date is removed")
    expect(h.queuedJobJSON(id).map { $0["estimateValidUntil"] == nil } == true, "local: the upsert has no date key")
    expect(h.store.estimateValidity(jobID: id, now: now) == nil, "local: no validity row")
}

@MainActor
func testExtendWithLink() async throws {
    let h = Harness(tag: "extend-link")
    defer { h.cleanup() }
    guard let id = pricedLead(h, "link") else { return }
    guard let review = h.store.estimateReviewDraft(jobID: id, validUntil: .date("2026-10-10"), now: monthAgo) else { return }
    guard case .success(let link) = await h.store.createEstimateApprovalLink(for: review, on: monthAgo) else {
        expect(false, "link: the approval link is created"); return
    }
    expect(h.queueKeys().isEmpty, "link: the mirror reached the server")
    let sentAt = h.job(id)?.estimateSentAt
    expectEqual(sentAt, "2026-09-01", "link: sent last month")
    expect(h.store.hasUndecidedEstimateApprovalLink(jobID: id), "link: an undecided link exists")

    let outcome = await h.store.extendEstimateValidity(jobID: id, validUntil: "2026-12-01", now: now)
    expectEqual(outcome, .extended(link: link.url), "link: extended, with the same URL")
    expectEqual(h.links.calls.count, 2, "link: create-link was called again")
    let refreshed = h.links.calls.last?.snapshot
    expectEqual(refreshed?.validUntil, "2026-12-01", "link: the Worker receives the new date")
    expectEqual(refreshed?.validUntilTimeZone, "America/Phoenix", "link: and the device zone")
    expectEqual(refreshed?.total, review.snapshot.total, "link: the same prices")
    guard let saved = h.job(id) else { return }
    expectEqual(saved.estimateValidUntil, "2026-12-01", "link: the job's date is updated")
    expectEqual(saved.approval?.token, link.token, "link: the same token")
    expectEqual(saved.approval?.snapshot.validUntil, "2026-12-01", "link: the mirror shows the new date")
    expectEqual(saved.approval?.sentAt, "2026-10-03T19:02:00.000Z", "link: the mirror keeps the server's sentAt")
    expectEqual(saved.estimateSentAt, sentAt, "link: estimateSentAt is not re-stamped")
    expect(h.queueKeys().isEmpty, "link: the extension synced")
    expectEqual(h.serverJob(id)?.estimateValidUntil, "2026-12-01", "link: the server job has the date")
    expectEqual(h.serverJob(id)?.approval?.snapshot.validUntil, "2026-12-01", "link: and the server snapshot")
    // "Let the customer know": the notice names the new date and the same link.
    let notice = h.store.estimateExtensionNoticeDraft(jobID: id, link: link.url)
    expect(notice?.body.hasPrefix("Hi Delta, good news — I've extended your estimate for Panel upgrade ($") == true
           && notice?.body.hasSuffix(") until December 1, 2026. You can review and approve it here: \(link.url.absoluteString)") == true,
           "link: the extension notice names the new date and the same link (\(notice?.body ?? "nil"))")
    expectEqual(notice?.customerEmail, "delta@example.test", "link: the notice goes to the saved customer")

    // The service fails: nothing on the device changes.
    h.links.failure = .unavailable
    let before = sortedJSON(h.job(id))
    expectEqual(await h.store.extendEstimateValidity(jobID: id, validUntil: "2026-12-20", now: now),
                .failure(.link(.unavailable)), "link: a service failure is reported")
    expectEqual(sortedJSON(h.job(id)), before, "link: a failed refresh leaves the device unchanged")
    h.links.failure = nil
}

@MainActor
func testExtendRefusedAfterPricingEdit() async throws {
    let h = Harness(tag: "extend-pricing")
    defer { h.cleanup() }
    guard let id = pricedLead(h, "pricing") else { return }
    guard let review = h.store.estimateReviewDraft(jobID: id, now: now),
          case .success = await h.store.createEstimateApprovalLink(for: review, on: now)
    else { expect(false, "pricing: the approval link is created"); return }
    guard var pricing = h.store.jobPricingDraft(jobID: id) else { return }
    pricing.laborHours = 7
    expect(h.store.saveJobPricing(pricing), "pricing: the price changes after sending")
    let before = sortedJSON(h.job(id))
    let calls = h.links.calls.count

    let outcome = await h.store.extendEstimateValidity(jobID: id, validUntil: "2026-12-01", now: now)
    expectEqual(outcome, .failure(.pricingChanged), "pricing: extend is refused")
    expectEqual(NativeEstimateExtensionError.pricingChanged.errorDescription,
                "This estimate changed after it was sent. Review and resend it so the customer sees the new version and date.",
                "pricing: the refusal copy")
    expectEqual(h.links.calls.count, calls, "pricing: the link is not refreshed")
    expectEqual(sortedJSON(h.job(id)), before, "pricing: the device is unchanged")
    expectEqual(h.job(id)?.estimateValidUntil, todayPlus30, "pricing: the old date stays")
    expectEqual(h.job(id)?.approval?.snapshot.validUntil, todayPlus30, "pricing: the link snapshot is untouched")
}

@MainActor
func testExtendRefusedOnceDecided() async throws {
    let h = Harness(tag: "extend-decided")
    defer { h.cleanup() }
    guard let id = pricedLead(h, "decided") else { return }
    guard let review = h.store.estimateReviewDraft(jobID: id, now: now),
          case .success(let link) = await h.store.createEstimateApprovalLink(for: review, on: now)
    else { expect(false, "decided: the approval link is created"); return }

    // The customer declines on the page; the device has not pulled yet.
    guard var server = h.serverJob(id) else { expect(false, "decided: the server holds the job"); return }
    server.approval = try approval(token: link.token, snapshot: review.snapshot, decision: "declined")
    try await h.remoteWrite(server)
    expect(h.store.canChangeEstimateValidity(jobID: id), "decided: the device still shows it open")
    let calls = h.links.calls.count
    let outcome = await h.store.extendEstimateValidity(jobID: id, validUntil: "2026-12-01", now: now)
    expectEqual(outcome, .failure(.notEligible), "decided: the pulled decision refuses the extension")
    expectEqual(NativeEstimateExtensionError.notEligible.errorDescription,
                "The customer already responded to this estimate.", "decided: the refusal copy")
    expectEqual(h.links.calls.count, calls, "decided: the link is not refreshed")
    expectEqual(h.job(id)?.estimateValidUntil, todayPlus30, "decided: the date is unchanged")
    expect(!h.store.canChangeEstimateValidity(jobID: id), "decided: the owner can no longer extend")
    expectEqual(await h.store.extendEstimateValidity(jobID: id, validUntil: "2026-12-01", now: now),
                .failure(.notEligible), "decided: a later attempt is refused up front")
    expectEqual(h.links.calls.count, calls, "decided: still no refresh")
}

// MARK: - 6. The job-detail alert after an extension (spec §6.5)

@MainActor
func testExtensionAlertCopy() {
    let link = URL(string: "https://tradeready.example/estimate.html?j=j1&t=tok")!
    func result(_ previous: String?, _ next: String?, link: URL? = nil, wasExpired: Bool = false) -> NativeEstimateExtensionResult {
        .init(jobID: "j1", previousValidUntil: previous, validUntil: next, link: link, wasExpired: wasExpired)
    }

    let revived = result("2026-09-20", "2026-12-01", link: link, wasExpired: true)
    expectEqual(revived.title, "Estimate extended", "alert: an expired estimate given a new date is extended")
    expectEqual(revived.message, "Valid until Dec 1, 2026. The customer’s approval link works again.",
                "alert: the spec copy with a link")
    expect(revived.isExtension, "alert: it offers Let the customer know")
    expectEqual(result("2026-09-20", "2026-12-01", wasExpired: true).message, "Valid until Dec 1, 2026.",
                "alert: the spec copy without a link")

    let later = result("2026-11-02", "2026-12-01", link: link)
    expectEqual(later.title, "Estimate extended", "alert: a later date on an open estimate is an extension")
    expectEqual(later.message, "Valid until Dec 1, 2026. The customer’s approval link shows the new date.",
                "alert: an open link is not said to work again")
    let unlimited = result("2026-11-02", nil, link: link)
    expect(unlimited.isExtension && unlimited.title == "Estimate extended", "alert: Doesn't expire is an extension")
    expectEqual(unlimited.message, "This estimate no longer expires. The customer’s approval link shows the new date.",
                "alert: Doesn't expire copy")

    let earlier = result("2026-12-01", "2026-11-02", link: link)
    expect(!earlier.isExtension, "alert: an earlier date is not an extension (no good-news notice)")
    expectEqual(earlier.title, "Valid-until date changed", "alert: an earlier date is a plain change")
    let newlyDated = result(nil, "2026-11-02")
    expect(!newlyDated.isExtension && newlyDated.title == "Valid-until date changed",
           "alert: dating an undated estimate is a plain change")
    expectEqual(newlyDated.message, "Valid until Nov 2, 2026.", "alert: plain change without a link")
}

// MARK: - 7. Review fixes (2026-10-03)

/// Finding 1: every Phase 32 "today" runs in a Gregorian calendar in the
/// device zone. The runner runs this test again with `-AppleLocale
/// en_US@calendar=buddhist|japanese`, where `Calendar.current` itself carries
/// another year (2569, or Reiwa 8), as on an iPhone with that Calendar setting.
@MainActor
func testDeviceCalendar() async throws {
    let h = Harness(tag: "device-calendar")
    defer { h.cleanup() }
    if let expected = ProcessInfo.processInfo.environment["QUOTE_EXPIRY_DEVICE_CALENDAR"] {
        expectEqual("\(Calendar.current.identifier)", expected, "calendar: the runner set Calendar.current")
    }
    let label = "calendar (\(Calendar.current.identifier))"
    expectEqual(h.store.estimateValidityToday(now: now), today, "\(label): today is the Gregorian date")

    // Mark as sent with the proposed date: the job stores a date the Worker
    // and the customer page read as the same day.
    guard let marked = pricedLead(h, label) else { return }
    guard let draft = h.store.estimateReviewDraft(jobID: marked, now: now) else {
        expect(false, "\(label): a lead opens for review"); return
    }
    expectEqual(draft.validUntil, todayPlus30, "\(label): the review proposes Gregorian today + 30")
    expect(h.store.markEstimateSent(id: marked, from: .lead, validUntil: draft.validUntil, on: now),
           "\(label): Mark as sent accepts the proposed date")
    expectEqual(h.job(marked)?.estimateValidUntil, todayPlus30, "\(label): the job stores the Gregorian date")
    expectEqual(h.store.estimateValidity(jobID: marked, now: now), .open(validUntil: todayPlus30, daysLeft: 30),
                "\(label): job detail counts 30 days left")
    let expiry = h.store.estimateFollowUpNotifications(now: now).first { $0.identifier == "est_exp_\(marked)" }
    expectEqual(expiry?.fireDate, ISO8601DateFormatter().date(from: "2026-10-31T16:00:00Z"),
                "\(label): the expiry reminder fires at 9:00 MST two days before the date")

    // The approval link is minted with the Gregorian date, and the
    // extension accepts one.
    guard let linked = pricedLead(h, "\(label) link", title: "Linked") else { return }
    guard let linkDraft = h.store.estimateReviewDraft(jobID: linked, now: now) else {
        expect(false, "\(label): the link review opens"); return
    }
    let outcome = await h.store.createEstimateApprovalLink(for: linkDraft, on: now)
    guard case .success(let link) = outcome else {
        expect(false, "\(label): the approval link is created (\(outcome))"); return
    }
    expectEqual(h.links.calls.last?.snapshot.validUntil, todayPlus30, "\(label): the Worker receives the Gregorian date")
    expectEqual(await h.store.extendEstimateValidity(jobID: linked, validUntil: "2026-12-01", now: now),
                .extended(link: link.url), "\(label): an extension to a Gregorian date is accepted")
    expectEqual(h.links.calls.last?.snapshot.validUntil, "2026-12-01", "\(label): and minted")

    // The review sheet's picker bridge, with its default calendar.
    let picked = NativeValidUntilPicker.date(from: "2026-12-15").map { NativeValidUntilPicker.ymd(from: $0) }
    expectEqual(picked, "2026-12-15", "\(label): the date picker round-trips the Gregorian day")
    guard let review = h.store.estimateReviewDraft(jobID: linked, now: now) else { return }
    expectEqual(h.store.estimateReviewDraft(review, changingValidUntilTo: .date(picked ?? ""), now: now)?.validUntil,
                "2026-12-15", "\(label): the review sheet accepts the picked date")
}

/// Finding 2: changing the date in an open review keeps the snapshot the
/// owner reviewed. A newer price synced in meanwhile is not swapped in, and
/// the send-time guard still preserves it.
@MainActor
func testDateChangeKeepsReviewedSnapshot() async throws {
    let h = Harness(tag: "date-change")
    defer { h.cleanup() }
    guard let id = pricedLead(h, "date change") else { return }
    guard let reviewed = h.store.estimateReviewDraft(jobID: id, now: now) else {
        expect(false, "date change: the review opens"); return
    }

    // An unchanged estimate: only the date and its zone move.
    guard let later = h.store.estimateReviewDraft(reviewed, changingValidUntilTo: .date("2026-12-15"), now: now) else {
        expect(false, "date change: a new date is accepted"); return
    }
    expectEqual(later.validUntil, "2026-12-15", "date change: the draft has the new date")
    expectEqual(later.snapshot.validUntilTimeZone, "America/Phoenix", "date change: with the device zone")
    expect(CanonicalUIAdapters.estimateApprovalSnapshotsMatch(later.snapshot, reviewed.snapshot, ignoringValidity: true),
           "date change: everything else in the snapshot is the reviewed one")
    guard let undated = h.store.estimateReviewDraft(later, changingValidUntilTo: .doesNotExpire, now: now) else {
        expect(false, "date change: Doesn't expire is accepted"); return
    }
    expect(undated.validUntil == nil && undated.snapshot.validUntilTimeZone == nil,
           "date change: Doesn't expire drops the date and the zone")
    h.store.migrationMessage = nil
    expect(h.store.estimateReviewDraft(reviewed, changingValidUntilTo: .date("2026-10-02"), now: now) == nil,
           "date change: yesterday is refused")
    expectEqual(h.store.migrationMessage, NativeEstimateExtensionError.invalidDate.errorDescription,
                "date change: the refusal explains itself")

    // Another device's price change syncs in while the sheet is open.
    guard var pricing = h.store.jobPricingDraft(jobID: id) else { return }
    pricing.laborHours = 6
    expect(h.store.saveJobPricing(pricing), "date change: the price changes under the open sheet")
    let newerTotal = h.store.estimateReviewDraft(jobID: id, now: now)?.snapshot.total
    expect(newerTotal != nil && newerTotal != reviewed.snapshot.total, "date change: the canonical total moved")

    guard let changed = h.store.estimateReviewDraft(reviewed, changingValidUntilTo: .date("2026-12-15"), now: now) else {
        expect(false, "date change: the date still changes after a price change"); return
    }
    expectEqual(changed.snapshot.total, reviewed.snapshot.total, "date change: the reviewed total stays")
    expect(CanonicalUIAdapters.estimateApprovalSnapshotsMatch(changed.snapshot, reviewed.snapshot, ignoringValidity: true),
           "date change: the newer pricing is not swapped in")
    expectEqual(changed.expectedStatus, reviewed.expectedStatus, "date change: the expected status stays")
    expectEqual(changed.customerEmail, reviewed.customerEmail, "date change: the reviewed recipient stays")
    expectEqual(h.store.recordEstimateDelivery(for: changed, on: now), .preservedNewerState,
                "date change: sending the stale review still preserves the newer estimate")
    expectEqual(h.job(id)?.status, "lead", "date change: nothing was stamped")
    expect(h.job(id)?.estimateValidUntil == nil, "date change: and no date was written")
}

/// Finding 3a: a failed "Update approval link" leaves the job on the date
/// the customer's link still enforces; a retry that succeeds moves both.
@MainActor
func testFailedLinkUpdateKeepsLinkDate() async throws {
    let h = Harness(tag: "failed-update")
    defer { h.cleanup() }
    guard let id = pricedLead(h, "failed update") else { return }
    guard let first = h.store.estimateReviewDraft(jobID: id, now: now),
          case .success(let link) = await h.store.createEstimateApprovalLink(for: first, on: now)
    else { expect(false, "failed update: the first link is created"); return }
    expectEqual(h.job(id)?.estimateValidUntil, todayPlus30, "failed update: the link and the job say Nov 2")

    guard let moved = h.store.estimateReviewDraft(jobID: id, validUntil: .date("2026-12-01"), now: now) else {
        expect(false, "failed update: the re-send review opens with Dec 1"); return
    }
    for failure in [NativeEstimateApprovalLinkError.rateLimited, .estimateRejected, .unavailable] {
        h.links.failure = failure
        let outcome = await h.store.createEstimateApprovalLink(for: moved, on: now)
        expectEqual(outcome, .failure(failure), "failed update (\(failure)): the failure is reported")
        expectEqual(h.job(id)?.estimateValidUntil, todayPlus30,
                    "failed update (\(failure)): the job keeps the date the link enforces")
        expectEqual(h.job(id)?.approval?.snapshot.validUntil, todayPlus30, "failed update (\(failure)): the link mirror is unchanged")
        expectEqual(h.serverJob(id)?.estimateValidUntil, todayPlus30, "failed update (\(failure)): the server job keeps it too")
        expectEqual(h.store.estimateValidity(jobID: id, now: now), .open(validUntil: todayPlus30, daysLeft: 30),
                    "failed update (\(failure)): job detail shows the link's date")
    }
    h.links.failure = nil

    let retried = await h.store.createEstimateApprovalLink(for: moved, on: now)
    guard case .success(let again) = retried else {
        expect(false, "failed update: the retry succeeds (\(retried))"); return
    }
    expectEqual(again.token, link.token, "failed update: the retry keeps the token")
    expectEqual(h.job(id)?.estimateValidUntil, "2026-12-01", "failed update: the retry moves the job's date")
    expectEqual(h.job(id)?.approval?.snapshot.validUntil, "2026-12-01", "failed update: and the link's")
    expectEqual(h.serverJob(id)?.estimateValidUntil, "2026-12-01", "failed update: and the server's")
}

/// Finding 3b: when the job's date and the customer's undecided link
/// disagree (a re-send recorded without updating the link, or an older
/// failed update), saving the job's date in the job-detail editor is not a
/// no-op: it refreshes the link.
@MainActor
func testEditorRepairsLinkDateMismatch() async throws {
    let h = Harness(tag: "editor-repair")
    defer { h.cleanup() }
    guard let id = pricedLead(h, "editor repair") else { return }
    guard let first = h.store.estimateReviewDraft(jobID: id, now: now),
          case .success(let link) = await h.store.createEstimateApprovalLink(for: first, on: now)
    else { expect(false, "editor repair: the link is created"); return }
    expect(h.store.isEstimateValidityUnchanged(jobID: id, validUntil: todayPlus30),
           "editor repair: in step, saving the same date is a no-op")
    expect(!h.store.isEstimateValidityUnchanged(jobID: id, validUntil: "2026-12-01"),
           "editor repair: a different date is a change")
    expect(h.store.estimateLinkValidityNote(jobID: id) == nil, "editor repair: no note while in step")

    // Re-sent by email with Dec 1 without tapping "Update approval link".
    guard let resend = h.store.estimateReviewDraft(jobID: id, validUntil: .date("2026-12-01"), now: now) else { return }
    expectEqual(h.store.recordEstimateDelivery(for: resend, on: now), .recorded, "editor repair: the re-send is recorded")
    expectEqual(h.job(id)?.estimateValidUntil, "2026-12-01", "editor repair: the job says Dec 1")
    expectEqual(h.job(id)?.approval?.snapshot.validUntil, todayPlus30, "editor repair: the link still says Nov 2")

    expect(!h.store.isEstimateValidityUnchanged(jobID: id, validUntil: "2026-12-01"),
           "editor repair: saving the job's own date is not a no-op while the link differs")
    expectEqual(h.store.estimateLinkValidityNote(jobID: id),
                "The customer’s approval link still shows Nov 2, 2026. Save to update the link to match.",
                "editor repair: the editor says why")
    let calls = h.links.calls.count
    expectEqual(await h.store.extendEstimateValidity(jobID: id, validUntil: "2026-12-01", now: now),
                .extended(link: link.url), "editor repair: Save refreshes the link")
    expectEqual(h.links.calls.count, calls + 1, "editor repair: create-link was called")
    expectEqual(h.job(id)?.approval?.snapshot.validUntil, "2026-12-01", "editor repair: the link now says Dec 1")
    expect(h.store.isEstimateValidityUnchanged(jobID: id, validUntil: "2026-12-01"), "editor repair: back in step")
    expect(h.store.estimateLinkValidityNote(jobID: id) == nil, "editor repair: the note is gone")

    // An undated link against a dated job reads "no valid-until date".
    guard let undated = h.store.estimateReviewDraft(jobID: id, validUntil: .doesNotExpire, now: now),
          case .success = await h.store.createEstimateApprovalLink(for: undated, on: now),
          let redated = h.store.estimateReviewDraft(jobID: id, validUntil: .date("2026-12-20"), now: now)
    else { expect(false, "editor repair: the undated link is created"); return }
    expectEqual(h.store.recordEstimateDelivery(for: redated, on: now), .recorded, "editor repair: re-sent dated")
    expectEqual(h.store.estimateLinkValidityNote(jobID: id),
                "The customer’s approval link still shows no valid-until date. Save to update the link to match.",
                "editor repair: the undated link note")

    // Without a link only the job's date counts.
    guard let local = pricedLead(h, "editor repair local", title: "No link") else { return }
    expect(h.store.markEstimateSent(id: local, from: .lead, validUntil: todayPlus30, on: now), "editor repair: sent without a link")
    expect(h.store.isEstimateValidityUnchanged(jobID: local, validUntil: todayPlus30), "editor repair: no link, same date")
    expect(!h.store.isEstimateValidityUnchanged(jobID: local, validUntil: nil), "editor repair: no link, Doesn't expire is a change")
    expect(h.store.estimateLinkValidityNote(jobID: local) == nil, "editor repair: no link, no note")
}

// MARK: - Main

@main
struct QuoteExpiryStoreTests {
    @MainActor
    static func main() async throws {
        // Review fix 2026-10-03: the runner's extra passes under a Buddhist
        // and a Japanese `Calendar.current` run only the device-calendar test
        // (the rest pin `estimateSentAt`, which the app-wide
        // `Date.dateOnlyString` still writes in `Calendar.current`).
        if ProcessInfo.processInfo.environment["QUOTE_EXPIRY_STORE_ONLY"] == "device-calendar" {
            try await testDeviceCalendar()
            if failures == 0 {
                print("PASS: quote-expiry store tests, \(Calendar.current.identifier) device calendar (\(checks) checks)")
            } else {
                print("quote-expiry store tests (\(Calendar.current.identifier)): \(failures) of \(checks) checks FAILED")
                exit(1)
            }
            return
        }
        try testReviewDraftProposal()
        try await testSendStamps()
        try await testLinkFailsClosedOnPulledDate()
        try await testDeclinedGuardIgnoresFreshDate()
        try await testExtendWithoutLink()
        try await testExtendWithLink()
        try await testExtendRefusedAfterPricingEdit()
        try await testExtendRefusedOnceDecided()
        testExtensionAlertCopy()
        try await testDeviceCalendar()
        try await testDateChangeKeepsReviewedSnapshot()
        try await testFailedLinkUpdateKeepsLinkDate()
        try await testEditorRepairsLinkDateMismatch()
        if failures == 0 {
            print("PASS: quote-expiry store tests (\(checks) checks)")
        } else {
            print("quote-expiry store tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
    }
}
