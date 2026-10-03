import Foundation

// Phase 25 (good/better/best quote options) store-level host tests: the
// AppStore wiring over the shared in-memory Supabase server
// (`native/HostTestSupport/InMemorySupabase.swift`) — option edits and their
// refusals, the owner-recorded choice, the post-pull decision reconciler
// (spec §6.3) and the rebase graft. The pure rules (tiers, add-ons, selection
// parity, acceptance, reconciler and graft per job) run in
// `native/QuoteOptionsTests/main.swift`. Run with TZ=America/Phoenix.

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

/// One device of the test account: a signed-in AppStore whose delta pull and
/// push run against `server`, plus the coordinator the app would build.
@MainActor
struct Harness {
    static let subject = "25252525-2525-2525-2525-252525252525"
    static let binding = String(repeating: "q", count: 64)
    static let session = Data(#"{"access_token":"private-access-token"}"#.utf8)
    static let supabaseURL = URL(string: "https://project.supabase.co")!

    let dir: URL
    let store: AppStore
    let server: InMemorySupabase
    let queue: Canonical.NativeMutationQueue
    let coordinator: NativeSyncCoordinator

    init(tag: String, server: InMemorySupabase = InMemorySupabase()) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-quote-options-store-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.server = server
        store = AppStore(
            fileURL: dir.appendingPathComponent("store.json"),
            seedIfMissing: false,
            initialSyncService: NativeSupabaseInitialSyncService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", loader: server
            ),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        store.scheduleBookingTestSeedSignedInOwner(subject: Self.subject, binding: Self.binding)
        let credentials = NativeSyncCredentials(subject: Self.subject, sessionBytes: Self.session)
        store.scheduleBookingTestCredentials = credentials
        queue = Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("mutation-queue.json"))
        let store = store
        // Mirrors `AppStore.syncCoordinatorIfConfigured` (as the poor-network
        // suite does), minus BuildEnvironment.
        coordinator = NativeSyncCoordinator(
            push: NativeSupabaseMutationPushService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key",
                allowsWrites: true, loader: server
            ),
            queue: queue,
            reachability: AlwaysReachable(),
            credentialsProvider: { credentials },
            refreshSession: { false },
            settleRejected: { try store.testSettleRejectedChanges($0) },
            pull: { await store.testPullDeltaIfPossible() },
            statusChanged: { status in store.testApplySyncStatus(status) }
        )
    }

    /// The canonical job as committed on disk (what a relaunch would read).
    func job(_ id: String) -> Canonical.Job? {
        let repository = Canonical.SnapshotRepository(primaryURL: dir.appendingPathComponent("store.json"))
        return (try? repository.load())??.snapshot.payload.jobs?.first { $0.id == id }
    }

    /// The job blob the server holds.
    func serverJob(_ id: String) -> Canonical.Job? {
        guard let row = server.storedRow(table: "jobs", id: id, userID: Self.subject),
              let data = try? JSONEncoder().encode(row.data)
        else { return nil }
        return try? JSONDecoder().decode(Canonical.Job.self, from: data)
    }

    func queuedJob(_ id: String) -> Canonical.Job? {
        guard let payload = queue.load().first(where: { $0.table == "jobs" && $0.recordId == id })?.payload,
              let data = try? JSONEncoder().encode(payload)
        else { return nil }
        return try? JSONDecoder().decode(Canonical.Job.self, from: data)
    }

    func queueKeys() -> [String] { queue.load().map { "\($0.table)/\($0.recordId)" } }

    /// Another writer (the Worker's `respond`, or a second device) replaces
    /// the server's job blob.
    func remoteWrite(_ job: Canonical.Job) async throws {
        let other = NativeSupabaseMutationPushService(
            supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", allowsWrites: true, loader: server
        )
        let payload = try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(job))
        let result = try await other.push(
            sessionBytes: Self.session, expectedUserSubject: Self.subject,
            items: [.init(table: "jobs", op: .upsert, recordId: job.id, payload: payload, ts: "2026-10-02T00:00:00.000Z")]
        )
        expect(result.remaining.isEmpty, "remote write: the job reached the server")
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

let consentAt = "2026-10-02T15:04:05.000Z"

/// A sent estimate with good/better options and one add-on, created through
/// the real store paths. Returns the job id and the two tier ids.
@MainActor
func optionsEstimate(_ h: Harness, _ label: String) -> (job: String, good: String, better: String, addOn: String)? {
    let customer = Customer(name: "Delta Roofing", email: "delta@example.test")
    var job = Job(customerId: customer.id, customerName: customer.name, title: "Water heater", laborRate: 100)
    job.status = .lead
    guard h.store.upsert(customer), h.store.upsert(job),
          var pricing = h.store.jobPricingDraft(jobID: job.id)
    else { expect(false, "\(label): the estimate saves"); return nil }
    pricing.laborHours = 2
    pricing.laborRate = 100
    expect(h.store.saveJobPricing(pricing), "\(label): the job is priced")
    expect(h.store.startQuoteOptions(jobID: job.id), "\(label): options start")
    guard let state = h.store.quoteOptionsState(jobID: job.id), state.tiers.count == 2 else {
        expect(false, "\(label): two tiers exist"); return nil
    }
    let good = state.tiers[0].id, better = state.tiers[1].id
    guard var betterPricing = h.store.quoteTierPricingDraft(jobID: job.id, tierID: better) else {
        expect(false, "\(label): the better tier opens in the calculator"); return nil
    }
    betterPricing.laborHours = 5
    expect(h.store.saveQuoteTierPricing(betterPricing, tierID: better), "\(label): the better tier is priced")
    expect(h.store.addQuoteAddOn(jobID: job.id, draft: .init(label: "Expansion tank", price: 149, cost: 60)),
           "\(label): an add-on saves")
    guard let addOn = h.store.quoteOptionsState(jobID: job.id)?.addOns.first?.id else {
        expect(false, "\(label): the add-on is listed"); return nil
    }
    return (job.id, good, better, addOn)
}

/// The approval the Worker stores for a sent options snapshot, optionally
/// with the customer's approve decision and resolved selection.
func approval(
    for job: Canonical.Job,
    token: String,
    approvingTier tierID: String? = nil,
    addOnIDs: [String] = []
) throws -> Canonical.EstimateApproval {
    let snapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: job, customerName: job.customerName, businessName: "Ada Electric"
    )
    var fields: [String: Canonical.JSONValue] = [
        "token": .string(token),
        "sentAt": .string("2026-10-01T09:00:00.000Z"),
        "snapshot": try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(snapshot))
    ]
    if let tierID, let options = snapshot.options,
       case let .success(selection) = NativeQuoteOptions.resolveSelection(
           snapshotOptions: options, tierId: tierID, addOnIds: addOnIDs
       ) {
        fields["decision"] = .string("approved")
        fields["consentAt"] = .string(consentAt)
        fields["signerName"] = .string("Pat Customer")
        fields["selection"] = try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(selection))
    }
    let data = try JSONEncoder().encode(Canonical.JSONValue.object(fields))
    return try JSONDecoder().decode(Canonical.EstimateApproval.self, from: data)
}

// MARK: - 1. Owner edits

@MainActor
func testOwnerEdits() throws {
    let h = Harness(tag: "edits")
    defer { h.cleanup() }
    guard let ids = optionsEstimate(h, "edits") else { return }
    guard let saved = h.job(ids.job), let options = saved.quoteOptions else {
        expect(false, "edits: the options are committed"); return
    }
    expectEqual(options.tiers.map(\.name), ["Good", "Better"], "edits: Good and Better tiers")
    expectEqual(options.recommendedTierId, ids.good, "edits: the job's own pricing is the recommended tier")
    let goodTotal = options.tier(id: ids.good)!.estimateTotal
    let betterTotal = options.tier(id: ids.better)!.estimateTotal
    expect(betterTotal > goodTotal, "edits: the better tier is priced on its own")
    expectEqual(saved.estimateTotal, goodTotal, "edits M1: the job total is the recommended tier's")
    expectEqual(saved.laborHours, 2, "edits M1: pricing a non-recommended tier leaves the job's pricing alone")
    expectEqual(h.queueKeys().filter { $0 == "jobs/\(ids.job)" }.count, 1, "edits: one queued upsert for the job")
    expect(h.queuedJob(ids.job)?.quoteOptions?.addOns.first?.cost == 60,
           "edits: the internal add-on cost syncs with the job (it never enters a snapshot)")

    expect(h.store.setRecommendedQuoteTier(jobID: ids.job, tierID: ids.better), "edits: recommend Better")
    expectEqual(h.job(ids.job)?.estimateTotal, betterTotal, "edits M1: recommending mirrors the tier's total")
    expectEqual(h.job(ids.job)?.laborHours, 5, "edits M1: recommending mirrors the tier's pricing")
    expectEqual(h.store.jobs.first { $0.id == ids.job }?.estimateTotal,
                NSDecimalNumber(decimal: betterTotal).doubleValue, "edits: the job list sees the recommended price")

    expect(!h.store.addQuoteAddOn(jobID: ids.job, draft: .init(label: "Free thing", price: 0)),
           "edits: a $0 add-on is refused")
    expectEqual(h.store.migrationMessage, NativeQuoteOptionsError.invalidAddOnPrice.errorDescription,
                "edits: the refusal explains itself, unprefixed")
    expect(!h.store.renameQuoteTier(jobID: ids.job, tierID: ids.good, name: "   "), "edits: a blank name is refused")
    expect(h.store.renameQuoteTier(jobID: ids.job, tierID: ids.good, name: "  Repair  "), "edits: rename")
    expect(h.store.describeQuoteTier(jobID: ids.job, tierID: ids.good, description: "Fix the leak only"),
           "edits: describe")
    expect(h.store.duplicateQuoteTier(jobID: ids.job, tierID: ids.better), "edits: a third tier")
    expect(!h.store.duplicateQuoteTier(jobID: ids.job, tierID: ids.better), "edits: a fourth tier is refused")
    expectEqual(h.store.migrationMessage, NativeQuoteOptionsError.tierLimitReached.errorDescription,
                "edits: the tier limit explains itself")
    let state = h.store.quoteOptionsState(jobID: ids.job)
    expectEqual(state?.tiers.map(\.name), ["Repair", "Better", "Best"], "edits: names after rename and duplicate")
    expectEqual(state?.tiers.first?.description, "Fix the leak only", "edits: the description is kept")
    expect(state?.canDuplicateTier == false && state?.canDeleteTier == true, "edits: limits drive the controls")

    // Remove options keeps the chosen tier's pricing as a single estimate.
    expect(h.store.removeQuoteOptions(jobID: ids.job, keepingTierID: ids.good), "edits: remove options")
    expect(h.job(ids.job)?.quoteOptions == nil, "edits: back to a single-total estimate")
    expectEqual(h.job(ids.job)?.estimateTotal, goodTotal, "edits: the kept tier's total is the job's")
    expect(h.store.quoteOptionsState(jobID: ids.job)?.isEditable == true, "edits: options can start again")

    // Past the estimate stage the options cannot start.
    guard var scheduled = h.store.jobs.first(where: { $0.id == ids.job }) else { return }
    scheduled.status = .scheduled
    expect(h.store.upsert(scheduled), "edits: the job moves on")
    expect(!h.store.startQuoteOptions(jobID: ids.job), "edits: a scheduled job cannot start options")
    expectEqual(h.store.migrationMessage, NativeQuoteOptionsError.notAnEstimate.errorDescription,
                "edits: the stage refusal explains itself")
}

// MARK: - 2. Owner-recorded choice

@MainActor
func testOwnerRecordedChoice() throws {
    let h = Harness(tag: "owner-choice")
    defer { h.cleanup() }
    guard let ids = optionsEstimate(h, "owner") else { return }
    expect(!h.store.recordOwnerQuoteAcceptance(jobID: ids.job, tierID: ids.good, addOnIDs: []),
           "owner: a lead (unsent) estimate cannot be recorded as approved")
    expect(h.store.markEstimateSent(id: ids.job, from: .lead), "owner: the estimate is marked sent")
    expect(h.store.quoteOptionsState(jobID: ids.job)?.needsOwnerChoice == true,
           "owner: Mark as approved asks which option")

    let date = Date(timeIntervalSince1970: 1_790_000_000)
    expect(h.store.recordOwnerQuoteAcceptance(jobID: ids.job, tierID: ids.better, addOnIDs: [ids.addOn], on: date),
           "owner: the choice is recorded")
    guard let saved = h.job(ids.job), let acceptance = saved.quoteOptions?.acceptance else {
        expect(false, "owner: the acceptance is committed"); return
    }
    let betterTotal = saved.quoteOptions!.tier(id: ids.better)!.estimateTotal
    let expected = NativeQuoteOptions.selectionTotal(tierTotal: betterTotal, addOnAmounts: [149])
    expectEqual(saved.status, "approved", "owner: the job is approved in the same commit")
    expectEqual(acceptance.source, Canonical.QuoteAcceptance.sourceOwner, "owner: source owner")
    expectEqual(acceptance.tierId, ids.better, "owner: the chosen tier")
    expectEqual(acceptance.addOnIds, [ids.addOn], "owner: the chosen add-on")
    expectEqual(acceptance.total, expected, "owner M2: tier total plus add-ons")
    expectEqual(saved.estimateTotal, expected, "owner M2: the job total includes the add-on")
    expectEqual(saved.laborHours, 5, "owner M2: the job carries the chosen tier's pricing")
    expect(acceptance.acceptedAt.hasPrefix("2026-09-21T"), "owner: accepted at the recorded instant (\(acceptance.acceptedAt))")
    expectEqual(h.queuedJob(ids.job)?.status, "approved", "owner: the approved job is queued")

    // M3: read-only afterwards, and the invoice bills the add-on as a line.
    expect(!h.store.addQuoteAddOn(jobID: ids.job, draft: .init(label: "Late extra", price: 10)),
           "owner M3: options are read-only once accepted")
    expectEqual(h.store.migrationMessage, NativeQuoteOptionsError.readOnly.errorDescription, "owner M3: refusal copy")
    let state = h.store.quoteOptionsState(jobID: ids.job)
    expectEqual(state?.acceptance?.tierName, "Better", "owner: the sheet shows the chosen option")
    expectEqual(state?.acceptance?.viaLink, false, "owner: recorded by the owner")
    expect(state?.needsOwnerChoice == false && state?.isEditable == false, "owner: no further choice")
    let lines = NativeQuoteOptions.invoiceAddOnLines(job: saved)
    expectEqual(lines.map(\.description), ["Expansion tank"], "owner: the invoice bills the accepted add-on")
}

// MARK: - 3. Decision reconciler after a pull

@MainActor
func testReconcilerAppliesLinkDecision() async throws {
    let h = Harness(tag: "reconciler")
    defer { h.cleanup() }
    guard let ids = optionsEstimate(h, "reconcile") else { return }
    expect(h.store.markEstimateSent(id: ids.job, from: .lead), "reconcile: sent")
    _ = await h.coordinator.sync(trigger: .manual)
    expect(h.queueKeys().isEmpty, "reconcile: the baseline reached the server")

    // The Worker's respond writes the customer's approval and selection.
    guard var server = h.serverJob(ids.job) else { expect(false, "reconcile: the server holds the job"); return }
    server.approval = try approval(for: server, token: "tok-reconcile", approvingTier: ids.better, addOnIDs: [ids.addOn])
    try await h.remoteWrite(server)
    let consented = server.approval!.selection!.total

    _ = await h.coordinator.sync(trigger: .manual)
    guard let local = h.job(ids.job), let acceptance = local.quoteOptions?.acceptance else {
        expect(false, "reconcile: the pulled decision is applied"); return
    }
    expectEqual(local.status, "approved", "reconcile: a sent estimate moves to approved")
    expectEqual(acceptance.source, Canonical.QuoteAcceptance.sourceLink, "reconcile: link acceptance")
    expectEqual(acceptance.acceptedAt, consentAt, "reconcile: accepted at the customer's consent time")
    expectEqual(acceptance.total, consented, "reconcile: the consented selection total")
    expectEqual(local.estimateTotal, consented, "reconcile M2: the job total is what the customer agreed to")
    expectEqual(local.laborHours, 5, "reconcile M2: the chosen tier's pricing")
    expectEqual(h.store.jobs.first { $0.id == ids.job }?.status, .approved, "reconcile: the UI sees approved")
    expectEqual(h.queuedJob(ids.job)?.status, "approved", "reconcile: the change is queued for the server")
    expectEqual(h.queuedJob(ids.job)?.approval?.decision, "approved", "reconcile: the queued blob keeps the decision")

    _ = await h.coordinator.sync(trigger: .manual)
    let pushed = h.serverJob(ids.job)
    expectEqual(pushed?.status, "approved", "reconcile: the server row is approved")
    expectEqual(pushed?.approval?.selection?.tierId, ids.better, "reconcile: the server keeps the selection")
    expectEqual(pushed?.quoteOptions?.acceptance?.tierId, ids.better, "reconcile: the server sees the acceptance")
    expectEqual(h.store.reconcileEstimateDecisions(), 0, "reconcile: a second run changes nothing")
    _ = await h.coordinator.sync(trigger: .manual)
    expect(h.queueKeys().isEmpty, "reconcile: nothing re-queued after convergence")

    // A declined estimate moves to declined; a job already past approval stays put.
    guard let other = optionsEstimate(h, "decline") else { return }
    expect(h.store.markEstimateSent(id: other.job, from: .lead), "decline: sent")
    _ = await h.coordinator.sync(trigger: .manual)
    guard var declined = h.serverJob(other.job) else { return }
    var declinedApproval = try approval(for: declined, token: "tok-decline")
    declinedApproval.decision = "declined"
    declinedApproval.consentAt = consentAt
    declined.approval = declinedApproval
    try await h.remoteWrite(declined)
    _ = await h.coordinator.sync(trigger: .manual)
    expectEqual(h.job(other.job)?.status, "declined", "decline: the job moves to declined")
    expect(h.job(other.job)?.quoteOptions?.acceptance == nil, "decline: no acceptance recorded")
}

// MARK: - 4. Rebase graft

@MainActor
func testGraftKeepsDecisionUnderQueuedEdit() async throws {
    let h = Harness(tag: "graft")
    defer { h.cleanup() }
    guard let ids = optionsEstimate(h, "graft") else { return }
    expect(h.store.markEstimateSent(id: ids.job, from: .lead), "graft: sent")
    _ = await h.coordinator.sync(trigger: .manual)

    // The link is created: the server and this device share the token.
    guard var server = h.serverJob(ids.job) else { expect(false, "graft: the server holds the job"); return }
    server.approval = try approval(for: server, token: "tok-graft")
    try await h.remoteWrite(server)
    _ = await h.coordinator.sync(trigger: .manual)
    expectEqual(h.job(ids.job)?.approval?.token, "tok-graft", "graft: the device holds the sent approval")

    // An owner edit is queued (no push yet) ...
    guard var edited = h.store.jobs.first(where: { $0.id == ids.job }) else { return }
    edited.notes = "Gate code 4411"
    expect(h.store.upsert(edited), "graft: the owner edit saves")
    expectEqual(h.queueKeys(), ["jobs/\(ids.job)"], "graft: the edit is queued")
    expect(h.queuedJob(ids.job)?.approval?.decision == nil, "graft: the queued blob has no decision yet")

    // ... while the customer approves on the server.
    guard var decided = h.serverJob(ids.job) else { return }
    decided.approval = try approval(for: decided, token: "tok-graft", approvingTier: ids.good)
    try await h.remoteWrite(decided)

    let result = await h.store.testPullDeltaIfPossible()
    expectEqual(result.state, .completed, "graft: the pull completes with the edit still queued")
    guard let local = h.job(ids.job) else { return }
    expectEqual(local.notes, "Gate code 4411", "graft: the queued edit is kept")
    expectEqual(local.approval?.decision, "approved", "graft: the customer's decision is grafted on")
    expectEqual(local.approval?.selection?.tierId, ids.good, "graft: with its selection")
    expectEqual(local.status, "approved", "graft: the reconciler applies it")
    expectEqual(local.quoteOptions?.acceptance?.tierId, ids.good, "graft: the selection is accepted")
    let queued = h.queuedJob(ids.job)
    expectEqual(queued?.notes, "Gate code 4411", "graft: the queued push keeps the edit")
    expectEqual(queued?.approval?.decision, "approved", "graft: the queued push carries the decision")

    _ = await h.coordinator.sync(trigger: .manual)
    let pushed = h.serverJob(ids.job)
    expectEqual(pushed?.approval?.decision, "approved", "graft: the server keeps the customer's decision")
    expectEqual(pushed?.notes, "Gate code 4411", "graft: and receives the owner's edit")
    expectEqual(pushed?.status, "approved", "graft: and the approved status")

    // The owner records the approval on the phone (queued) while the customer
    // also approves through the link. The reconciler has nothing to change
    // (already approved, already accepted), so only the graft's re-queue keeps
    // the push from erasing the customer's consent record.
    guard let both = optionsEstimate(h, "graft-both") else { return }
    expect(h.store.markEstimateSent(id: both.job, from: .lead), "graft-both: sent")
    _ = await h.coordinator.sync(trigger: .manual)
    guard var sent = h.serverJob(both.job) else { return }
    sent.approval = try approval(for: sent, token: "tok-both")
    try await h.remoteWrite(sent)
    _ = await h.coordinator.sync(trigger: .manual)
    expect(h.store.recordOwnerQuoteAcceptance(jobID: both.job, tierID: both.good, addOnIDs: []),
           "graft-both: the owner records the choice")
    guard var customerApproved = h.serverJob(both.job) else { return }
    customerApproved.approval = try approval(for: customerApproved, token: "tok-both", approvingTier: both.good)
    try await h.remoteWrite(customerApproved)
    expectEqual(await h.store.testPullDeltaIfPossible().state, .completed, "graft-both: the pull completes")
    expectEqual(h.job(both.job)?.quoteOptions?.acceptance?.source, Canonical.QuoteAcceptance.sourceOwner,
                "graft-both M3: the first acceptance stays")
    expectEqual(h.queuedJob(both.job)?.approval?.decision, "approved",
                "graft-both: the queued push carries the customer's decision")
    expectEqual(h.queuedJob(both.job)?.approval?.signerName, "Pat Customer",
                "graft-both: and their consent record")
    _ = await h.coordinator.sync(trigger: .manual)
    expectEqual(h.serverJob(both.job)?.approval?.decision, "approved", "graft-both: the server keeps the decision")

    // Different token (a re-send replaced the approval): no graft.
    let pulled = try approval(for: local, token: "tok-other", approvingTier: ids.good)
    var serverCopy = local
    serverCopy.approval = pulled
    var unsent = local
    unsent.approval = try approval(for: local, token: "tok-mine")
    let graft = NativeQuoteOptions.graftingServerDecisions(live: [unsent], pulled: [serverCopy], pendingJobIDs: [local.id])
    expect(graft.grafted.isEmpty, "graft: a different token is never grafted")
    let notPending = NativeQuoteOptions.graftingServerDecisions(live: [unsent], pulled: [serverCopy], pendingJobIDs: [])
    expect(notPending.grafted.isEmpty, "graft: only queued jobs are grafted")
}

// MARK: - Main

@main
struct QuoteOptionsStoreTests {
    @MainActor
    static func main() async throws {
        try testOwnerEdits()
        try testOwnerRecordedChoice()
        try await testReconcilerAppliesLinkDecision()
        try await testGraftKeepsDecisionUnderQueuedEdit()
        if failures == 0 {
            print("PASS: quote-options store tests (\(checks) checks)")
        } else {
            print("quote-options store tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
    }
}
