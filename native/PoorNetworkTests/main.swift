import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Task 11.12 host tests (H3): poor-network behavior of the real sync stack.
//
// Everything here is production code except the network: the real
// `NativeSyncCoordinator`, the real durable `NativeMutationQueue` that
// `AppStore` writes on every local edit, the real push transport
// (`NativeSupabaseMutationPushService`), the real delta pull
// (`NativeSupabaseInitialSyncService.pullDelta`) and the real `AppStore`
// pull commit (`pullDeltaIfPossible`, wired into the coordinator exactly as
// `syncCoordinatorIfConfigured` wires it). The server is the shared
// `InMemorySupabase` (native/HostTestSupport, the two-device convergence
// model). `PoorNetworkLink` sits in front of it as the device's radio: it is
// the coordinator's reachability and both transports' HTTP loader, and it can
// go offline, throttle, time out before or after the server commits, or drop
// after N more requests.
//
// Scenarios (plan 11.12 step 3):
//   A. offline → online: queued mutations drain once, in queue order;
//   B. throttled / timed-out transport: a typed, bounded failure and no
//      duplicate commit;
//   C. connectivity drop mid-pass (pull side, a dead link behind optimistic
//      reachability, one throttled table, push side): the prior committed
//      state is kept, and the next pass recovers.
// The link also models PostgREST's primary-key conflict for a plain insert,
// so a replayed write is idempotent only through the real upsert header.
// Cases already covered elsewhere are not repeated: the coordinator's gates
// over a fake push (SyncCoordinatorTests), the push wire contract
// (MutationPushTests), queue durability (MutationQueueTests), delta merge
// rules (DeltaSyncTests) and relaunch convergence (TwoDeviceConvergenceTests).
// The 11.12 DeltaPull signposts are checked along the way (counts and outcome
// words only). Run with TZ=America/Phoenix.

// MARK: - The device's network

final class PoorNetworkLink: NativeInitialSyncHTTPDataLoading, NativeMutationPushHTTPLoading,
    NativeSyncReachability, @unchecked Sendable {
    enum Condition: Equatable {
        case online
        /// No path: reachability reports offline and any request fails.
        case offline
        /// The server answers every request with this status without committing.
        case throttled(status: Int)
        /// The request times out before it reaches the server.
        case timeoutBeforeServer
        /// The server commits, then the response is lost to a timeout.
        case timeoutAfterCommit
        /// This many more requests go through, then the link drops (offline).
        case dropAfter(requests: Int)
        /// Only requests for this table are throttled; the rest go through.
        case throttledTable(String, status: Int)
        /// Reads go through; every write fails as a lost connection.
        case writesFail
    }

    struct Attempt: Equatable {
        let method: String
        let table: String
        let recordID: String?
        let reachedServer: Bool

        var isWrite: Bool { method != "GET" }
        var key: String { "\(table)/\(recordID ?? "-")" }
    }

    let server: InMemorySupabase
    var condition: Condition = .online
    /// `NWPathMonitor` is optimistic until its first update, so reachability
    /// can say "reachable" while the link is down. Nil follows `condition`.
    var reachabilityOverride: Bool?
    private(set) var attempts: [Attempt] = []
    private(set) var reachabilityChecks = 0
    /// When set, the next request suspends until `release()`.
    var holdNextRequest = false
    /// When set, the next GET is served now (it reads the server as it is at
    /// this moment) and its response is held until `release()`.
    var holdNextResponse = false
    /// 12.00b.1 (I2): a write of one record (`<table>/<id>`) is answered with
    /// this status and never reaches the server: a 4xx the server will never
    /// accept (a poison change), or a 5xx that never clears.
    var writeStatus: [String: Int] = [:]
    private(set) var isHolding = false
    private var held: CheckedContinuation<Void, Never>?

    init(server: InMemorySupabase) { self.server = server }

    func isReachable() async -> Bool {
        reachabilityChecks += 1
        if let reachabilityOverride { return reachabilityOverride }
        return condition != .offline
    }

    func release() {
        let continuation = held
        held = nil
        isHolding = false
        continuation?.resume()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.httpMethod != "GET", condition != .offline,
           let status = writeStatus["\(request.url?.pathComponents.last ?? "")/\(Self.recordID(of: request) ?? "-")"] {
            log(request, reachedServer: false)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(#"{"code":"23514","message":"refused"}"#.utf8), response)
        }
        if holdNextResponse, condition == .online || condition == .writesFail, request.httpMethod == "GET" {
            holdNextResponse = false
            let response = try await forward(request)
            isHolding = true
            await withCheckedContinuation { held = $0 }
            return response
        }
        if holdNextRequest {
            holdNextRequest = false
            isHolding = true
            await withCheckedContinuation { held = $0 }
        }
        switch condition {
        case .online:
            return try await forward(request)
        case .offline:
            log(request, reachedServer: false)
            throw URLError(.notConnectedToInternet)
        case let .throttled(status):
            log(request, reachedServer: false)
            return Self.throttle(request, status: status)
        case .writesFail:
            guard request.httpMethod != "GET" else { return try await forward(request) }
            log(request, reachedServer: false)
            throw URLError(.networkConnectionLost)
        case let .throttledTable(table, status):
            guard request.url?.pathComponents.last == table else { return try await forward(request) }
            log(request, reachedServer: false)
            return Self.throttle(request, status: status)
        case .timeoutBeforeServer:
            log(request, reachedServer: false)
            throw URLError(.timedOut)
        case .timeoutAfterCommit:
            let (_, response) = try await serve(request)
            log(request, reachedServer: (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
            throw URLError(.timedOut)
        case let .dropAfter(remaining):
            guard remaining > 0 else {
                condition = .offline
                log(request, reachedServer: false)
                throw URLError(.networkConnectionLost)
            }
            condition = .dropAfter(requests: remaining - 1)
            return try await forward(request)
        }
    }

    private static func throttle(_ request: URLRequest, status: Int) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "Retry-After": "30"]
        )!
        return (Data(#"{"message":"rate limited"}"#.utf8), response)
    }

    private func forward(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try await serve(request)
        log(request, reachedServer: (result.1 as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
        return result
    }

    /// The server, plus the one PostgREST rule the shared fake does not model:
    /// a plain insert (no `Prefer: resolution=merge-duplicates`) of an id that
    /// already exists is a primary-key conflict (409), not an upsert. That is
    /// what makes a replayed write idempotent or not.
    private func serve(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if request.httpMethod == "POST",
           !(request.value(forHTTPHeaderField: "Prefer") ?? "").contains("resolution=merge-duplicates"),
           let body = request.httpBody,
           case let .object(fields)? = try? JSONDecoder().decode(Canonical.JSONValue.self, from: body),
           case let .string(id)? = fields["id"],
           case let .string(userID)? = fields["user_id"],
           let table = request.url?.pathComponents.last,
           server.storedRow(table: table, id: id, userID: userID) != nil {
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"code":"23505"}"#.utf8), response)
        }
        return try await server.data(for: request)
    }

    private func log(_ request: URLRequest, reachedServer: Bool) {
        let method = request.httpMethod ?? "GET"
        let table = request.url?.pathComponents.last ?? ""
        attempts.append(Attempt(method: method, table: table, recordID: Self.recordID(of: request), reachedServer: reachedServer))
    }

    /// The record a write targets (a GET targets none).
    private static func recordID(of request: URLRequest) -> String? {
        let method = request.httpMethod ?? "GET"
        let table = request.url?.pathComponents.last ?? ""
        if method == "POST", let body = request.httpBody,
           case let .object(fields)? = try? JSONDecoder().decode(Canonical.JSONValue.self, from: body) {
            if case let .string(id)? = fields["id"] { return id }
            if case let .string(key)? = fields["customer_key"] { return key }
            return table
        }
        if method == "PATCH" {
            return URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "id" }?.value?.replacingOccurrences(of: "eq.", with: "")
        }
        return nil
    }

    var writes: [Attempt] { attempts.filter(\.isWrite) }
    var committedWrites: [Attempt] { writes.filter(\.reachedServer) }
    var reads: [Attempt] { attempts.filter { !$0.isWrite } }

    func committedWriteCount(_ key: String) -> Int { committedWrites.filter { $0.key == key }.count }

    func resetLog() { attempts.removeAll() }
}

final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

// MARK: - Harness

/// The App Group widget/Siri action queue in memory (the extension's writer side).
final class MemoryWidgetActionQueue: NativeWidgetActionQueueBacking {
    var value: String?
    func read() -> String? { value }
    func write(_ value: String?) { self.value = value }
}

@MainActor
struct Harness {
    static let subject = "11111111-2222-3333-4444-555555555555"
    static let binding = String(repeating: "b", count: 64)
    static let session = Data(#"{"access_token":"private-access-token"}"#.utf8)
    static let supabaseURL = URL(string: "https://project.supabase.co")!
    static let baseBackoff: TimeInterval = 30

    let dir: URL
    let store: AppStore
    let server: InMemorySupabase
    let link: PoorNetworkLink
    let queue: Canonical.NativeMutationQueue
    let cursorStore: Canonical.NativeSyncCursorStore
    let clock: TestClock
    let coordinator: NativeSyncCoordinator
    /// Final review C1: the widget/Siri queue the real replay claims from.
    let widgetQueue = MemoryWidgetActionQueue()

    /// `server` lets a second harness act as "another device" of the same account.
    init(tag: String, server: InMemorySupabase = InMemorySupabase()) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-poor-network-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.server = server
        link = PoorNetworkLink(server: server)
        clock = TestClock()
        // A throwaway App Group suite: a host test never touches the real one.
        let suite = "com.tradeready.poor-network.tests.\(UUID().uuidString)"
        store = AppStore(
            fileURL: dir.appendingPathComponent("store.json"),
            seedIfMissing: false,
            widgetActionReplayTransport: NativeWidgetActionClaimTransport(
                queue: widgetQueue,
                claimDirectory: dir.appendingPathComponent("WidgetActionClaims", isDirectory: true),
                lockFile: dir.appendingPathComponent("app-group.lock")
            ),
            appGroupAccountScrubber: NativeAppGroupAccountScrubber(
                suiteName: suite,
                defaults: UserDefaults(suiteName: suite) ?? .standard,
                lockFile: dir.appendingPathComponent("app-group.lock")
            ),
            initialSyncService: NativeSupabaseInitialSyncService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", loader: link
            ),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        store.scheduleBookingTestSeedSignedInOwner(subject: Self.subject, binding: Self.binding)
        let credentials = NativeSyncCredentials(subject: Self.subject, sessionBytes: Self.session)
        store.scheduleBookingTestCredentials = credentials
        // The same files AppStore.init opened: every local edit lands here.
        queue = Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("mutation-queue.json"))
        cursorStore = Canonical.NativeSyncCursorStore(fileURL: dir.appendingPathComponent("sync-cursor.json"))
        let clock = clock
        let store = store
        // Mirrors `AppStore.syncCoordinatorIfConfigured` (keep the two in
        // step), minus BuildEnvironment: the link stands in for the push
        // loader and reachability, and a test clock and backoff drive retries.
        coordinator = NativeSyncCoordinator(
            push: NativeSupabaseMutationPushService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key",
                allowsWrites: true, loader: link
            ),
            queue: queue,
            reachability: link,
            credentialsProvider: { credentials },
            refreshSession: { false },
            // 12.00b.1: the rejected-change settle step, as the app wires it.
            settleRejected: { try store.testSettleRejectedChanges($0) },
            pull: { await store.testPullDeltaIfPossible() },
            statusChanged: { status in store.testApplySyncStatus(status) },
            now: { clock.now },
            baseBackoff: Self.baseBackoff,
            maxBackoff: 300
        )
    }

    /// The canonical snapshot as committed on disk (what a relaunch would read).
    func committed() -> Canonical.Snapshot? {
        (try? Canonical.SnapshotRepository(primaryURL: dir.appendingPathComponent("store.json")).load())??.snapshot
    }

    func queueKeys() -> [String] { queue.load().map { "\($0.table)/\($0.recordId)" } }

    /// 12.00b.1: every entry in the rejected-change store for this owner
    /// (including one hidden while its Retry is queued).
    func rejectedEntries() -> [NativeRejectedChange] {
        (try? NativeRejectedChangeStore(fileURL: dir.appendingPathComponent("rejected-changes.json"))
            .load(binding: Self.binding)) ?? []
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

func jsonValue<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
    try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(value))
}

/// Canonical records are not `Equatable`; compare their stable encoding.
func encoded<T: Encodable>(_ value: T?) -> Data? {
    guard let value else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try? encoder.encode(value)
}

func replacing(_ value: Canonical.JSONValue, _ key: String, with replacement: Canonical.JSONValue) -> Canonical.JSONValue {
    guard case var .object(fields) = value else { return value }
    fields[key] = replacement
    return .object(fields)
}

// MARK: - Tests

@main
struct PoorNetworkTests {
    @MainActor static var failures = 0
    @MainActor static var checks = 0

    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(label)") }
    }

    @MainActor
    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        checks += 1
        if actual != expected {
            failures += 1
            print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
        }
    }

    @MainActor
    static func main() async throws {
        let signposts = RecordingSignpostSink()
        NativePerformanceMetrics.shared.replaceSink(signposts)

        try await offlineToOnlineDrainsOnceInOrder()
        try await throttledAndTimedOutTransport()
        try await midPassDropKeepsCommittedState()
        checkSignposts(signposts)
        try await coordinatorPullKeepsEditMadeDuringAwait()
        try await directPullKeepsPendingEdits()
        try await pendingEditWinsOverServerChangeToSameRecord()
        try await directPullKeepsEditPushedDuringIt()
        rebaseRules()
        try await recurringGenerationWaitsForInitialSync()
        try await widgetReplayReachesTheServer()
        try await widgetReplayMarkersStayLocal()
        try await staleServerMarkersAreDroppedOnPull()
        try await poisonChangeLeavesTheQueueAndSyncKeepsPulling()
        try await keptRecordsDoNotPinTheCursor()
        try await retryRefusedChange()
        try await discardRefusedChange()

        NativePerformanceMetrics.shared.replaceSink(nil)
        if failures == 0 {
            print("poor-network tests: \(checks)/\(checks) checks passed")
        } else {
            print("poor-network tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
    }

    // MARK: A. Offline → online

    @MainActor
    static func offlineToOnlineDrainsOnceInOrder() async throws {
        let h = Harness(tag: "offline-online")
        defer { h.cleanup() }
        let store = h.store
        h.link.condition = .offline

        // Local edits made offline, through the real AppStore write paths.
        let customer = Customer(name: "Ada Electric", email: "ada@example.test")
        expect(store.upsert(customer), "A: the customer saves offline")
        var first = Job(customerId: customer.id, customerName: customer.name, title: "Panel upgrade", laborRate: 95)
        let second = Job(customerId: customer.id, customerName: customer.name, title: "Outlet repair", laborRate: 95)
        expect(store.upsert(first), "A: the first job saves offline")
        expect(store.upsert(second), "A: the second job saves offline")
        let invoice = Invoice(customerId: customer.id, customer: customer.name, number: "INV-0001", amount: 250)
        store.upsert(invoice)
        // A later edit of the first job replaces its pending change (last
        // writer wins), which moves it to the end of the queue.
        first.title = "Panel upgrade (200A)"
        expect(store.upsert(first), "A: the re-edit saves offline")

        let expectedOrder = [
            "customers/\(customer.id)", "jobs/\(second.id)", "invoices/\(invoice.id)", "jobs/\(first.id)",
        ]
        expectEqual(h.queueKeys(), expectedOrder, "A: the offline queue holds one change per record, oldest first")
        let queuedBytes = try? Data(contentsOf: h.queue.fileURL)

        // Every trigger while offline: nothing is sent and nothing is lost.
        var offlineOutcomes: [NativeSyncOutcome] = []
        offlineOutcomes.append(await h.coordinator.sync(trigger: .foreground))
        offlineOutcomes.append(await h.coordinator.sync(trigger: .localChange))
        h.clock.advance(Harness.baseBackoff + 1)
        offlineOutcomes.append(await h.coordinator.sync(trigger: .periodic))
        offlineOutcomes.append(await h.coordinator.sync(trigger: .manual))
        expectEqual(offlineOutcomes, [.offline, .backoffDeferred, .offline, .offline],
                    "A: offline triggers report offline (a non-manual one inside the retry window defers)")
        expect(h.link.attempts.isEmpty, "A: no request is attempted while offline")
        expect((try? Data(contentsOf: h.queue.fileURL)) == queuedBytes, "A: the queue file is untouched offline")
        let offlineStatus = h.coordinator.status()
        expect(offlineStatus.pendingCount == 4 && offlineStatus.consecutiveFailures == 0
               && offlineStatus.diagnosticCode == nil,
               "A: offline is not a failure: 4 pending, no failure count, no diagnostic")

        // Back online: one pass drains the queue once, in order, then pulls.
        h.link.condition = .online
        h.clock.advance(Harness.baseBackoff + 1)
        let online = await h.coordinator.sync(trigger: .foreground)
        expectEqual(online, .completed(pushed: 4, authRefreshed: false), "A: the online pass pushes all four changes")
        expectEqual(h.link.writes.map(\.key), expectedOrder, "A: the server receives the writes in queue order, each once")
        expect(h.link.writes.allSatisfy(\.reachedServer), "A: every write committed")
        expect(h.queue.load().isEmpty, "A: the durable queue is empty after the drain")
        let lastWrite = h.link.attempts.lastIndex(where: \.isWrite) ?? -1
        let firstRead = h.link.attempts.firstIndex(where: { !$0.isWrite }) ?? -1
        expect(firstRead > lastWrite, "A: the pull runs only after every local write reached the server")
        expectEqual(h.server.liveRowCount(table: "jobs", userID: Harness.subject), 2, "A: the server holds two jobs")
        expectEqual(h.server.storedRow(table: "jobs", id: first.id, userID: Harness.subject).flatMap { row -> String? in
            guard case let .object(fields) = row.data, case let .string(title)? = fields["title"] else { return nil }
            return title
        }, "Panel upgrade (200A)", "A: the server holds the latest edit of the re-edited job")
        let committedJobs = h.committed()?.payload.jobs ?? []
        expectEqual(committedJobs.filter { $0.id == first.id }.count, 1, "A: the pulled snapshot holds the job once")
        expect(h.cursorStore.load().tables["jobs"] != nil, "A: the pull committed an advanced jobs cursor")
        let drained = h.coordinator.status()
        expect(drained.lastSuccessfulSyncAt != nil && drained.consecutiveFailures == 0 && drained.pendingCount == 0,
               "A: the drain records a successful sync")

        // Triggers after the drain push nothing again.
        h.link.resetLog()
        _ = await h.coordinator.sync(trigger: .foreground)
        _ = await h.coordinator.sync(trigger: .manual)
        expect(h.link.writes.isEmpty, "A: later passes never re-send drained changes")

        // Overlapping triggers while the reconnect pass is in flight coalesce:
        // the new change still goes out once.
        h.link.condition = .offline
        let third = Job(customerId: customer.id, customerName: customer.name, title: "Breaker swap", laborRate: 95)
        expect(store.upsert(third), "A: a third job saves offline")
        h.link.condition = .online
        h.link.resetLog()
        h.link.holdNextRequest = true
        let reconnect = Task { await h.coordinator.sync(trigger: .manual) }
        for _ in 0..<500 where !h.link.isHolding { await Task.yield() }
        expect(h.link.isHolding, "A: the reconnect pass is suspended on its first request")
        let overlapping = [
            await h.coordinator.sync(trigger: .foreground),
            await h.coordinator.sync(trigger: .localChange),
            await h.coordinator.sync(trigger: .manual),
        ]
        expectEqual(overlapping, [.alreadyRunning, .alreadyRunning, .alreadyRunning],
                    "A: triggers during the in-flight pass coalesce")
        h.link.release()
        // `sync` returns the last run's outcome: the coalesced rerun found
        // nothing left to push.
        expectEqual(await reconnect.value, .completed(pushed: 0, authRefreshed: false),
                    "A: the coalesced rerun after the in-flight pass has nothing left to push")
        _ = await h.coordinator.waitUntilIdle()
        expectEqual(h.link.writes.map(\.key), ["jobs/\(third.id)"],
                    "A: the coalesced rerun does not push the change a second time")
        expectEqual(h.link.committedWriteCount("jobs/\(third.id)"), 1, "A: the new job committed once")
        expect(h.queue.load().isEmpty, "A: the queue is empty after the coalesced pass")
    }

    // MARK: B. Throttled and timed-out transport

    @MainActor
    static func throttledAndTimedOutTransport() async throws {
        let h = Harness(tag: "throttle")
        defer { h.cleanup() }
        let store = h.store
        let customer = Customer(name: "Birch Plumbing", email: "birch@example.test")
        let one = Job(customerId: customer.id, customerName: customer.name, title: "Water heater", laborRate: 110)
        let two = Job(customerId: customer.id, customerName: customer.name, title: "Leak check", laborRate: 110)
        expect(store.upsert(one) && store.upsert(two), "B: two jobs save locally")
        let queued = h.queueKeys()

        // Throttled (HTTP 429): a typed partial outcome, bounded diagnostic,
        // one attempt per change, nothing committed, pull held back.
        h.link.condition = .throttled(status: 429)
        let throttled = await h.coordinator.sync(trigger: .foreground)
        expectEqual(throttled, .partial(pushed: 0, remaining: 2, authRefreshed: false),
                    "B: a throttled push is a typed partial outcome that keeps both changes")
        var status = h.coordinator.status()
        expectEqual(status.diagnosticCode, "http-response/jobs/429", "B: the diagnostic is the bounded stage/table/status code")
        expect(status.consecutiveFailures == 1 && status.nextEarliestAttempt == h.clock.now.addingTimeInterval(30),
               "B: throttling opens the first backoff window (30 s)")
        expectEqual(h.link.writes.map(\.key), queued, "B: each change is attempted exactly once in the pass")
        expect(h.link.committedWrites.isEmpty, "B: a throttled server commits nothing")
        // 12.00b.1 (I2): the pull now runs after a partial push, as RN's
        // `syncIfOnline` does (utils/sync.ts 316-326). Throttled too, it
        // commits nothing, and the push's code stays the pass's code.
        expect(!h.link.reads.isEmpty && h.link.reads.allSatisfy { !$0.reachedServer },
               "B: the pull still runs after the partial push (RN parity) and is throttled too")
        expect(h.cursorStore.load().tables["jobs"] == nil, "B: the throttled pull commits no cursor")
        expectEqual(h.queueKeys(), queued, "B: the queue keeps both changes, in order")

        expectEqual(await h.coordinator.sync(trigger: .foreground), .backoffDeferred,
                    "B: a trigger inside the window defers")
        expectEqual(h.link.writes.count, 2, "B: a deferred trigger sends nothing")

        h.clock.advance(31)
        expectEqual(await h.coordinator.sync(trigger: .periodic), .partial(pushed: 0, remaining: 2, authRefreshed: false),
                    "B: still throttled after the window: still partial")
        status = h.coordinator.status()
        expect(status.consecutiveFailures == 2 && status.nextEarliestAttempt == h.clock.now.addingTimeInterval(60),
               "B: the backoff doubles (60 s)")

        // Throttle lifts: each change commits exactly once.
        h.link.condition = .online
        h.clock.advance(61)
        expectEqual(await h.coordinator.sync(trigger: .periodic), .completed(pushed: 2, authRefreshed: false),
                    "B: after the throttle lifts the pass completes")
        for key in queued {
            expectEqual(h.link.committedWriteCount(key), 1, "B: \(key) committed exactly once")
        }
        status = h.coordinator.status()
        expect(status.diagnosticCode == nil && status.consecutiveFailures == 0 && status.nextEarliestAttempt == nil,
               "B: a clean pass clears the diagnostic and the backoff")

        // Timed out before the server: typed transport failure, nothing committed.
        let three = Job(customerId: customer.id, customerName: customer.name, title: "Drain snake", laborRate: 110)
        expect(store.upsert(three), "B: a third job saves locally")
        h.link.resetLog()
        h.link.condition = .timeoutBeforeServer
        expectEqual(await h.coordinator.sync(trigger: .foreground), .partial(pushed: 0, remaining: 1, authRefreshed: false),
                    "B: a timeout before the server is a typed partial outcome")
        expectEqual(h.coordinator.status().diagnosticCode, "transport/jobs", "B: a timeout reports transport/<table> only")
        expect(h.link.committedWrites.isEmpty && h.queueKeys() == ["jobs/\(three.id)"],
               "B: nothing committed; the change stays queued")

        // Timed out after the server committed (the response was lost): the
        // client cannot know, so it keeps the change and replays it. The
        // replay is the idempotent primary-key upsert, so the server still
        // holds one row, and the local snapshot one record.
        h.link.resetLog()
        h.link.condition = .timeoutAfterCommit
        h.clock.advance(61)
        expectEqual(await h.coordinator.sync(trigger: .manual), .partial(pushed: 0, remaining: 1, authRefreshed: false),
                    "B: a lost response is a typed partial outcome")
        expectEqual(h.coordinator.status().diagnosticCode, "transport/jobs", "B: the lost response reports transport/jobs")
        expectEqual(h.link.committedWriteCount("jobs/\(three.id)"), 1, "B: the server committed the write before the timeout")
        expectEqual(h.queueKeys(), ["jobs/\(three.id)"], "B: the client keeps the change it could not confirm")
        h.link.condition = .online
        h.clock.advance(121)
        expectEqual(await h.coordinator.sync(trigger: .periodic), .completed(pushed: 1, authRefreshed: false),
                    "B: the replay completes")
        let replays = h.link.writes.filter { $0.key == "jobs/\(three.id)" }
        expectEqual(replays.count, 2, "B: the unconfirmed write was sent twice in total (lost response + replay)")
        expectEqual(h.server.liveRowCount(table: "jobs", userID: Harness.subject), 3,
                    "B: the replay did not create a second server row (3 distinct jobs)")
        let committedThree = (h.committed()?.payload.jobs ?? []).filter { $0.id == three.id }
        expectEqual(committedThree.count, 1, "B: the local snapshot holds the replayed job once")
        expect(h.queue.load().isEmpty, "B: the queue is empty after the replay")
    }

    // MARK: C. Connectivity drop mid-pass

    @MainActor
    static func midPassDropKeepsCommittedState() async throws {
        let h = Harness(tag: "mid-pass")
        defer { h.cleanup() }
        let store = h.store
        let customer = Customer(name: "Cedar HVAC", email: "cedar@example.test")
        let job = Job(customerId: customer.id, customerName: customer.name, title: "Furnace tune-up", laborRate: 120)
        expect(store.upsert(customer) && store.upsert(job), "C: a customer and a job save locally")
        expectEqual(await h.coordinator.sync(trigger: .foreground), .completed(pushed: 2, authRefreshed: false),
                    "C: the baseline pass commits both")
        let baselineCursor = h.cursorStore.load()
        expect(baselineCursor.tables["jobs"] != nil && baselineCursor.tables["customers"] != nil,
               "C: the baseline cursor has jobs and customers watermarks")

        // Another device edits both records on the server.
        let other = NativeSupabaseMutationPushService(
            supabaseURL: Harness.supabaseURL, publishableKey: "publishable-key", allowsWrites: true, loader: h.server
        )
        guard let canonicalJob = store.canonicalJobs.first(where: { $0.id == job.id }),
              let canonicalCustomer = h.committed()?.payload.customers?.first(where: { $0.id == customer.id })
        else {
            expect(false, "C: the baseline records are committed")
            return
        }
        let remoteJob = replacing(try jsonValue(canonicalJob), "title", with: .string("Furnace tune-up (remote)"))
        let remoteCustomer = replacing(try jsonValue(canonicalCustomer), "name", with: .string("Cedar HVAC (remote)"))
        let otherPush = try await other.push(
            sessionBytes: Harness.session, expectedUserSubject: Harness.subject,
            items: [
                .init(table: "jobs", op: .upsert, recordId: job.id, payload: remoteJob, ts: "2026-09-24T00:00:00.000Z"),
                .init(table: "customers", op: .upsert, recordId: customer.id, payload: remoteCustomer,
                      ts: "2026-09-24T00:00:00.000Z"),
            ]
        )
        expect(otherPush.remaining.isEmpty, "C: the other device's edits reached the server")

        // C1. Pull-side drop: the jobs page arrives, then the link drops.
        h.link.resetLog()
        h.link.condition = .dropAfter(requests: 1)
        let dropped = await h.coordinator.sync(trigger: .foreground)
        expectEqual(dropped, .completed(pushed: 0, authRefreshed: false), "C1: nothing was queued to push")
        var status = h.coordinator.status()
        expectEqual(status.lastPullResult?.state, .partial, "C1: the pull reports partial, not success")
        expectEqual(status.diagnosticCode, "transport/invoices", "C1: the first failed table's bounded code")
        expect(status.consecutiveFailures == 1 && status.lastSuccessfulSyncAt != nil,
               "C1: a partial pull counts one failure and keeps the last success time")
        let afterDrop = h.committed()
        let jobAfterDrop = afterDrop?.payload.jobs?.first { $0.id == job.id }
        let customerAfterDrop = afterDrop?.payload.customers?.first { $0.id == customer.id }
        expectEqual(jobAfterDrop?.title, "Furnace tune-up (remote)", "C1: the table that arrived before the drop committed")
        expectEqual(customerAfterDrop?.name, canonicalCustomer.name,
                    "C1: the dropped table keeps its prior committed record")
        expectEqual(afterDrop?.payload.customers?.count, 1, "C1: no customer was lost or duplicated")
        let droppedCursor = h.cursorStore.load()
        expectEqual(droppedCursor.tables["customers"], baselineCursor.tables["customers"],
                    "C1: the dropped table's cursor did not advance")
        expect(droppedCursor.tables["jobs"] != baselineCursor.tables["jobs"],
               "C1: the table that arrived advanced its cursor")
        expectEqual(store.canonicalJobs.first { $0.id == job.id }?.title, jobAfterDrop?.title,
                    "C1: memory matches the committed snapshot")

        // Reconnect: the unadvanced cursor re-fetches the dropped table.
        h.link.condition = .online
        h.clock.advance(31)
        _ = await h.coordinator.sync(trigger: .periodic)
        status = h.coordinator.status()
        expectEqual(status.lastPullResult?.state, .completed, "C1: the reconnect pull completes")
        expect(status.diagnosticCode == nil && status.consecutiveFailures == 0, "C1: recovery clears the failure")
        expectEqual(h.committed()?.payload.customers?.first { $0.id == customer.id }?.name, "Cedar HVAC (remote)",
                    "C1: the dropped table's remote change arrives on reconnect")

        // C2. Optimistic reachability with a dead link: the whole pull fails
        // and the committed snapshot and cursor are unchanged.
        let beforeDeadLink = h.committed()
        let cursorBeforeDeadLink = h.cursorStore.load()
        h.link.condition = .offline
        h.link.reachabilityOverride = true
        h.clock.advance(31)
        _ = await h.coordinator.sync(trigger: .foreground)
        status = h.coordinator.status()
        expectEqual(status.lastPullResult?.state, .partial, "C2: a dead link under optimistic reachability is a partial pull")
        expectEqual(status.diagnosticCode, "transport/jobs", "C2: bounded transport code for the first table")
        expectEqual(encoded(h.committed()?.payload.jobs), encoded(beforeDeadLink?.payload.jobs), "C2: committed jobs unchanged")
        expectEqual(encoded(h.committed()?.payload.customers), encoded(beforeDeadLink?.payload.customers),
                    "C2: committed customers unchanged")
        expectEqual(h.cursorStore.load(), cursorBeforeDeadLink, "C2: the cursor is unchanged")
        h.link.reachabilityOverride = nil

        // C3. One table throttled mid-pull (an edge 503 on customers only):
        // the other tables commit, the throttled one keeps its committed
        // record and cursor, and the pull says partial with that table's code.
        let secondRemote = replacing(remoteCustomer, "name", with: .string("Cedar HVAC (remote 2)"))
        let otherPush2 = try await other.push(
            sessionBytes: Harness.session, expectedUserSubject: Harness.subject,
            items: [.init(table: "customers", op: .upsert, recordId: customer.id, payload: secondRemote,
                          ts: "2026-09-24T00:00:01.000Z")]
        )
        expect(otherPush2.remaining.isEmpty, "C3: the other device's second customer edit reached the server")
        let cursorBeforeThrottle = h.cursorStore.load()
        h.link.resetLog()
        h.link.condition = .throttledTable("customers", status: 503)
        h.clock.advance(301)
        _ = await h.coordinator.sync(trigger: .periodic)
        status = h.coordinator.status()
        expectEqual(status.lastPullResult?.state, .partial, "C3: a single throttled table makes the pull partial")
        expectEqual(status.diagnosticCode, "http-response/customers/503", "C3: the throttled table's bounded code")
        expectEqual(h.committed()?.payload.customers?.first { $0.id == customer.id }?.name, "Cedar HVAC (remote)",
                    "C3: the throttled table keeps its prior committed record")
        expectEqual(h.cursorStore.load().tables["customers"], cursorBeforeThrottle.tables["customers"],
                    "C3: the throttled table's cursor did not advance")
        expect(h.link.reads.contains { $0.table == "jobs" && $0.reachedServer },
               "C3: the other tables were still pulled")
        h.link.condition = .online
        h.clock.advance(301)
        _ = await h.coordinator.sync(trigger: .periodic)
        expectEqual(h.coordinator.status().lastPullResult?.state, .completed, "C3: the next pull completes")
        expectEqual(h.committed()?.payload.customers?.first { $0.id == customer.id }?.name, "Cedar HVAC (remote 2)",
                    "C3: the throttled table's change arrives once the throttle lifts")

        // C4. Push-side drop: the first of three changes reaches the server,
        // then the link drops. The acknowledged change leaves the queue; the
        // rest stay, in order, and go out once on reconnect.
        let jobs = (1...3).map {
            Job(customerId: customer.id, customerName: customer.name, title: "Visit \($0)", laborRate: 120)
        }
        for item in jobs { expect(store.upsert(item), "C4: \(item.title) saves locally") }
        let keys = jobs.map { "jobs/\($0.id)" }
        expectEqual(h.queueKeys(), keys, "C4: three changes queued in order")
        h.link.resetLog()
        h.link.condition = .dropAfter(requests: 1)
        h.clock.advance(61)
        expectEqual(await h.coordinator.sync(trigger: .manual), .partial(pushed: 1, remaining: 2, authRefreshed: false),
                    "C4: a mid-push drop keeps the unacknowledged remainder")
        expectEqual(h.queueKeys(), Array(keys.dropFirst()), "C4: the queue holds the remainder, in order")
        expectEqual(h.link.committedWriteCount(keys[0]), 1, "C4: the first change committed once")
        // 12.00b.1 (I2): the pull runs after the partial push (RN parity);
        // the link is down, so it reaches nothing and commits nothing.
        expect(h.link.reads.allSatisfy { !$0.reachedServer }, "C4: the pull over the dead link reaches nothing")
        let local = Set(store.canonicalJobs.map(\.id))
        expect(jobs.allSatisfy { local.contains($0.id) }, "C4: local truth keeps all three jobs")
        expectEqual(h.coordinator.status().diagnosticCode, "transport/jobs", "C4: bounded transport code")

        h.link.resetLog()
        h.link.condition = .online
        h.clock.advance(301)
        expectEqual(await h.coordinator.sync(trigger: .periodic), .completed(pushed: 2, authRefreshed: false),
                    "C4: reconnect pushes the remainder")
        expectEqual(h.link.writes.map(\.key), Array(keys.dropFirst()),
                    "C4: only the remainder is sent, in order; the acknowledged change is never re-sent")
        expect(h.queue.load().isEmpty, "C4: the queue is empty")
        expectEqual(h.server.liveRowCount(table: "jobs", userID: Harness.subject), 4, "C4: four distinct jobs on the server")
    }

    // MARK: D–F. Local edits against an in-flight pull (11.12 Finding D, fixed)

    /// The coordinator's contract: "Never let a remote pull overwrite canonical
    /// records that still have a local mutation waiting to reach the server."
    /// The pass checks the queue before it pulls, but a slow pull leaves a
    /// window: an edit saved during the pull's network await is queued while
    /// the pull is still merging into the snapshot it read before the await.
    /// Finding D (fixed): the pull now rebases its delta onto the live snapshot
    /// at commit time and skips every record with a pending mutation.

    @MainActor
    static func title(_ h: Harness, job id: String) -> (memory: String?, disk: String?, server: String?) {
        let server = h.server.storedRow(table: "jobs", id: id, userID: Harness.subject).flatMap { row -> String? in
            guard case let .object(fields) = row.data, case let .string(title)? = fields["title"] else { return nil }
            return title
        }
        return (h.store.jobs.first { $0.id == id }?.title,
                h.committed()?.payload.jobs?.first { $0.id == id }?.title,
                server)
    }

    @MainActor
    static func customerName(_ h: Harness, _ id: String) -> (memory: String?, disk: String?) {
        (h.store.customers.first { $0.id == id }?.name,
         h.committed()?.payload.customers?.first { $0.id == id }?.name)
    }

    /// Another device edits a record on the server.
    @MainActor
    static func remoteEdit(_ h: Harness, table: String, id: String, field: String, to value: String) async throws {
        let other = NativeSupabaseMutationPushService(
            supabaseURL: Harness.supabaseURL, publishableKey: "publishable-key", allowsWrites: true, loader: h.server
        )
        let current: Canonical.JSONValue?
        switch table {
        case "jobs":
            current = try h.committed()?.payload.jobs?.first { $0.id == id }.map(jsonValue)
        default:
            current = try h.committed()?.payload.customers?.first { $0.id == id }.map(jsonValue)
        }
        guard let current else { expect(false, "remote edit: \(table) record exists"); return }
        let result = try await other.push(
            sessionBytes: Harness.session, expectedUserSubject: Harness.subject,
            items: [.init(table: table, op: .upsert, recordId: id,
                          payload: replacing(current, field, with: .string(value)), ts: "2026-09-24T00:00:00.000Z")]
        )
        expect(result.remaining.isEmpty, "remote edit: the other device's \(table) edit reached the server")
    }

    /// A synced customer and job, as the starting point for D–F.
    @MainActor
    static func syncedBaseline(_ h: Harness, _ label: String) async -> (Customer, Job) {
        let customer = Customer(name: "Delta Roofing", email: "delta@example.test")
        let job = Job(customerId: customer.id, customerName: customer.name, title: "Roof inspection", laborRate: 80)
        expect(h.store.upsert(customer) && h.store.upsert(job), "\(label): the baseline saves")
        expectEqual(await h.coordinator.sync(trigger: .manual), .completed(pushed: 2, authRefreshed: false),
                    "\(label): the baseline pass commits both")
        return (customer, job)
    }

    /// Saves an edit to the job's title through the real AppStore write path.
    @MainActor
    static func editTitle(_ h: Harness, _ id: String, _ title: String, _ label: String) {
        guard var edited = h.store.jobs.first(where: { $0.id == id }) else {
            expect(false, "\(label): the job is in the store")
            return
        }
        edited.title = title
        expect(h.store.upsert(edited), "\(label): the edit saves")
    }

    @MainActor
    static func waitUntilHolding(_ h: Harness, _ label: String) async {
        for _ in 0..<500 where !h.link.isHolding { await Task.yield() }
        expect(h.link.isHolding, "\(label): the pull is suspended on its first page")
    }

    /// D. Coordinator path (foreground, periodic and background refresh all
    /// pull through it): an edit lands during the pull's await.
    @MainActor
    static func coordinatorPullKeepsEditMadeDuringAwait() async throws {
        let h = Harness(tag: "edit-during-pull")
        defer { h.cleanup() }
        let (customer, job) = await syncedBaseline(h, "D")
        try await remoteEdit(h, table: "customers", id: customer.id, field: "name", to: "Delta Roofing (remote)")

        // The pull starts; its first page is slow. Meanwhile the user edits.
        h.link.holdNextRequest = true
        let pass = Task { await h.coordinator.sync(trigger: .foreground) }
        await waitUntilHolding(h, "D")
        let editedTitle = "Roof inspection + gutter repair"
        editTitle(h, job.id, editedTitle, "D")
        expectEqual(await h.coordinator.sync(trigger: .localChange), .alreadyRunning, "D: the edit's trigger coalesces")

        // Reads still work but writes now fail, so the coalesced rerun cannot
        // push the edit: the state after the pull commit is what the user sees.
        h.link.condition = .writesFail
        h.link.release()
        _ = await pass.value
        _ = await h.coordinator.waitUntilIdle()
        expectEqual(h.queueKeys(), ["jobs/\(job.id)"], "D: the edit is still queued")
        let after = title(h, job: job.id)
        expectEqual(after.memory, editedTitle, "D (a): the pending edit is still what the device shows after the pull commit")
        expectEqual(after.disk, editedTitle, "D (a): the pending edit is still what the device has on disk")
        let customerAfter = customerName(h, customer.id)
        expectEqual(customerAfter.memory, "Delta Roofing (remote)", "D (b): the server change to another record applied in memory")
        expectEqual(customerAfter.disk, "Delta Roofing (remote)", "D (b): the server change to another record applied on disk")

        // Still unable to write, the user changes another field of what they see.
        guard var second = h.store.jobs.first(where: { $0.id == job.id }) else { return }
        second.laborRate = 95
        expect(h.store.upsert(second), "D: a second edit saves")
        h.link.condition = .online
        h.clock.advance(301)
        _ = await h.coordinator.sync(trigger: .manual)
        expectEqual(title(h, job: job.id).server, editedTitle,
                    "D: after reconnecting, the first edit reached the server (not lost)")
        expect(h.queue.load().isEmpty, "D: the queue drains after reconnecting")
    }

    /// E. The direct callers (booking intake, reschedule and response
    /// recovery, portal recovery) call `pullDeltaIfPossible` themselves, even
    /// with changes still queued. A change queued before the pull and an edit
    /// saved during its await both survive; other server changes apply.
    @MainActor
    static func directPullKeepsPendingEdits() async throws {
        let h = Harness(tag: "direct-pull")
        defer { h.cleanup() }
        let (customer, job) = await syncedBaseline(h, "E")
        let other = Job(customerId: customer.id, customerName: customer.name, title: "Skylight quote", laborRate: 80)
        expect(h.store.upsert(other), "E: a second job saves")
        _ = await h.coordinator.sync(trigger: .manual)
        try await remoteEdit(h, table: "customers", id: customer.id, field: "name", to: "Delta Roofing (remote)")

        // Queued before the pull (the link cannot write, so it stays queued).
        h.link.condition = .writesFail
        editTitle(h, other.id, "Skylight quote (queued)", "E")
        // The direct pull; an edit lands during its first page.
        h.link.holdNextRequest = true
        let pull = Task { await h.store.testPullDeltaIfPossible() }
        await waitUntilHolding(h, "E")
        editTitle(h, job.id, "Roof inspection (edited during pull)", "E")
        h.link.release()
        let result = await pull.value
        expectEqual(result.state, .completed, "E: the direct pull completed")
        expectEqual(Set(h.queueKeys()), ["jobs/\(other.id)", "jobs/\(job.id)"], "E: both edits are still queued")
        let during = title(h, job: job.id)
        expectEqual(during.memory, "Roof inspection (edited during pull)", "E (a): the edit made during the await is kept in memory")
        expectEqual(during.disk, "Roof inspection (edited during pull)", "E (a): the edit made during the await is kept on disk")
        let queued = title(h, job: other.id)
        expectEqual(queued.memory, "Skylight quote (queued)", "E (a): the change queued before the pull is kept in memory")
        expectEqual(queued.disk, "Skylight quote (queued)", "E (a): the change queued before the pull is kept on disk")
        expectEqual(customerName(h, customer.id).memory, "Delta Roofing (remote)", "E (b): the server change to another record applied")
        expectEqual(customerName(h, customer.id).disk, "Delta Roofing (remote)", "E (b): the server change is committed on disk")
        expectEqual(h.committed()?.payload.jobs?.count, 2, "E: no job was lost or duplicated")
    }

    /// G. Review I1: a direct-caller pull is not single-flight with the
    /// coordinator. A change queued at the pull's start is pushed by the
    /// coordinator while the pull is in flight; the pull's first page, read
    /// before the push, carries the older server row (the cursor overlap
    /// refetches it). The pull commit must keep the pushed edit, and a
    /// follow-up edit and reconnect must not lose it on the server.
    @MainActor
    static func directPullKeepsEditPushedDuringIt() async throws {
        let h = Harness(tag: "pushed-during-direct-pull")
        defer { h.cleanup() }
        let (customer, job) = await syncedBaseline(h, "G")
        let other = Job(customerId: customer.id, customerName: customer.name, title: "Skylight quote", laborRate: 80)
        expect(h.store.upsert(other), "G: a second job saves")
        _ = await h.coordinator.sync(trigger: .manual)
        let local = "Roof inspection (pushed during pull)"
        editTitle(h, job.id, local, "G")
        expectEqual(h.queueKeys(), ["jobs/\(job.id)"], "G: the edit is queued when the direct pull starts")

        let jobsWatermarkBefore = h.cursorStore.load().tables["jobs"]
        expect(jobsWatermarkBefore != nil, "G: the baseline advanced the jobs watermark")
        // Another device changes the other job, so the pull's jobs page is newer than the watermark.
        try await remoteEdit(h, table: "jobs", id: other.id, field: "title", to: "Skylight quote (remote)")
        // The direct pull reads its first page (jobs) now; the response is slow.
        h.link.holdNextResponse = true
        let pull = Task { await h.store.testPullDeltaIfPossible() }
        await waitUntilHolding(h, "G")
        // Meanwhile the coordinator pushes the edit (and runs its own pull).
        expectEqual(await h.coordinator.sync(trigger: .manual), .completed(pushed: 1, authRefreshed: false),
                    "G: the coordinator pushes the edit while the direct pull is in flight")
        expect(h.queue.load().isEmpty, "G: the edit is acknowledged, so it is no longer pending")
        expectEqual(title(h, job: job.id).server, local, "G: the server has the edit")

        h.link.release()
        let result = await pull.value
        expectEqual(result.state, .completed, "G: the direct pull completed")
        let after = title(h, job: job.id)
        expectEqual(after.memory, local, "G: the pushed edit is still what the device shows after the direct pull commit")
        expectEqual(after.disk, local, "G: the pushed edit is still what the device has on disk")
        expectEqual(title(h, job: other.id).memory, "Skylight quote (remote)", "G: the server change to another job applied")
        expectEqual(h.cursorStore.load().tables["jobs"], jobsWatermarkBefore,
                    "G: the jobs watermark stays at its pre-pull value, so the next pull refetches the row it did not take")

        // A follow-up edit is built from what the device shows; then reconnect.
        guard var second = h.store.jobs.first(where: { $0.id == job.id }) else { return }
        second.laborRate = 95
        expect(h.store.upsert(second), "G: a follow-up edit saves")
        h.clock.advance(301)
        _ = await h.coordinator.sync(trigger: .manual)
        let final = title(h, job: job.id)
        expectEqual(final.server, local, "G: after the follow-up edit and reconnect, the server still has the edit")
        expectEqual(final.memory, local, "G: after reconnecting, the device shows the edit")
        expectEqual(final.disk, local, "G: after reconnecting, the edit is on disk")
        let serverRate = h.server.storedRow(table: "jobs", id: job.id, userID: Harness.subject).flatMap { row -> Decimal? in
            guard case let .object(fields) = row.data, case let .number(rate)? = fields["laborRate"] else { return nil }
            return rate
        }
        expectEqual(serverRate, Decimal(95), "G: the follow-up edit reached the server too")
        expect(h.queue.load().isEmpty, "G: the queue drains")
    }

    /// Final review C1: a widget/Siri replay is a local write like any other.
    /// It must queue the upserts of every record it wrote (RN routes replay
    /// through saveJobs/saveTrips/saveExpenses, `utils/widgetActions.ts`), so
    /// the records reach the server and a pull of a server-changed job keeps
    /// the replayed time session (the record is pending, so rebase keeps it).
    @MainActor
    static func widgetReplayReachesTheServer() async throws {
        let h = Harness(tag: "widget-replay")
        defer { h.cleanup() }
        let (_, job) = await syncedBaseline(h, "C1")
        expect(h.queue.load().isEmpty, "C1: the baseline drained the queue")
        let tag = NativeWidgetOwnerTag.make(binding: Harness.binding)
        func action(_ body: String) -> String { #"{"ownerTag":"\#(tag)",\#(body)}"# }

        // A batch that matches nothing (an unknown job, an idle stop) commits
        // nothing and so enqueues nothing.
        h.widgetQueue.value = "[" + [
            action(#""id":"c1-ghost","type":"timer_start","at":"2026-09-24T15:00:00.000Z","jobId":"no-such-job""#),
            action(#""id":"c1-idle-stop","type":"timer_stop","at":"2026-09-24T15:00:00.000Z""#),
        ].joined(separator: ",") + "]"
        h.store.testReplayWidgetActions()
        expect(h.widgetQueue.value == nil, "C1: the no-op batch is claimed and acknowledged")
        expectEqual(h.queueKeys(), [], "C1: a replay that commits nothing enqueues nothing")

        // One of each writing kind: timer_start, trip_log, expense_log.
        let startedAt = "2026-09-24T16:00:00.000Z"
        h.widgetQueue.value = "[" + [
            action(#""id":"c1-start","type":"timer_start","at":"\#(startedAt)","jobId":"\#(job.id)""#),
            action(#""id":"c1-trip","type":"trip_log","at":"2026-09-24T16:05:00.000Z","date":"2026-09-24","odometerStart":100,"odometerEnd":112"#),
            action(#""id":"c1-expense","type":"expense_log","at":"2026-09-24T16:10:00.000Z","date":"2026-09-24","amount":18.5,"category":"fuel""#),
        ].joined(separator: ",") + "]"
        h.store.testReplayWidgetActions()
        expect(h.widgetQueue.value == nil, "C1: the batch is claimed and acknowledged")
        expectEqual(Set(h.queueKeys()), ["jobs/\(job.id)", "trips/t_siri_c1-trip", "expenses/e_siri_c1-expense"],
                    "C1: the replay queued an upsert for every record it wrote")
        let queuedJob = h.queue.load().first { $0.table == "jobs" }?.payload
        if case let .object(fields)? = queuedJob, case let .array(sessions)? = fields["timeSessions"] {
            expectEqual(sessions.count, 1, "C1: the queued job payload carries the replayed time session")
        } else {
            expect(false, "C1: the queued job payload is the replayed job")
        }

        // Another device edits the same job from the server's copy (which has
        // no widget session); a pull runs before the push.
        guard let serverCopy = h.server.storedRow(table: "jobs", id: job.id, userID: Harness.subject)?.data else {
            expect(false, "C1: the baseline job is on the server"); return
        }
        let otherDevice = NativeSupabaseMutationPushService(
            supabaseURL: Harness.supabaseURL, publishableKey: "publishable-key", allowsWrites: true, loader: h.server
        )
        let remote = try await otherDevice.push(
            sessionBytes: Harness.session, expectedUserSubject: Harness.subject,
            items: [.init(table: "jobs", op: .upsert, recordId: job.id,
                          payload: replacing(serverCopy, "title", with: .string("Roof inspection (remote)")),
                          ts: "2026-09-24T16:30:00.000Z")]
        )
        expect(remote.remaining.isEmpty, "C1: the other device's job edit reached the server")
        h.link.condition = .writesFail
        expectEqual(await h.store.testPullDeltaIfPossible().state, .completed, "C1: the pull completes")
        let sessionsAfterPull = h.committed()?.payload.jobs?.first { $0.id == job.id }?.timeSessions
        expectEqual(sessionsAfterPull?.count, 1, "C1: the pull keeps the replayed time session on disk (pending record)")
        expectEqual(sessionsAfterPull?.first?.start, startedAt, "C1: the kept session is the widget's")
        expect(h.store.timeTrackingSummary(jobID: job.id)?.isClocked == true,
               "C1: the pull keeps the replayed clock-in in memory")

        // Reconnect: the replayed records reach the server.
        h.link.condition = .online
        h.clock.advance(301)
        _ = await h.coordinator.sync(trigger: .manual)
        expect(h.queue.load().isEmpty, "C1: the queue drains")
        let serverJob = h.server.storedRow(table: "jobs", id: job.id, userID: Harness.subject)?.data
        if case let .object(fields)? = serverJob, case let .array(sessions)? = fields["timeSessions"] {
            expectEqual(sessions.count, 1, "C1: the server job has the widget's time session")
        } else {
            expect(false, "C1: the server has the job row")
        }
        expect(h.server.storedRow(table: "trips", id: "t_siri_c1-trip", userID: Harness.subject) != nil,
               "C1: the replayed trip reached the server")
        expect(h.server.storedRow(table: "expenses", id: "e_siri_c1-expense", userID: Harness.subject) != nil,
               "C1: the replayed expense reached the server")

        // timer_stop (the fourth kind) re-queues the job with the closed session.
        h.widgetQueue.value = "[" + action(#""id":"c1-stop","type":"timer_stop","at":"2026-09-24T17:00:00.000Z""#) + "]"
        h.store.testReplayWidgetActions()
        expectEqual(h.queueKeys(), ["jobs/\(job.id)"], "C1: timer_stop queues the job upsert")
        _ = await h.coordinator.sync(trigger: .manual)
        let stopped = h.server.storedRow(table: "jobs", id: job.id, userID: Harness.subject)?.data
        if case let .object(fields)? = stopped, case let .array(sessions)? = fields["timeSessions"],
           case let .object(last)? = sessions.last {
            expectEqual(last["end"], .string("2026-09-24T17:00:00.000Z"), "C1: the server session is closed by the widget stop")
        } else {
            expect(false, "C1: the server job still has its session")
        }
    }

    /// Every `__native*` object key in `value`, at any depth.
    static func nativeKeys(_ value: Canonical.JSONValue?) -> [String] {
        switch value {
        case let .object(fields)?:
            return fields.flatMap { key, nested in (key.hasPrefix("__native") ? [key] : []) + nativeKeys(nested) }
        case let .array(values)?:
            return values.flatMap { nativeKeys($0) }
        default:
            return []
        }
    }

    static func sessionCount(_ data: Canonical.JSONValue?) -> Int? {
        guard case let .object(fields)? = data, case let .array(sessions)? = fields["timeSessions"] else { return nil }
        return sessions.count
    }

    /// Phase 12 12.00b.2-D (L286.1): replay's own bookkeeping never reaches
    /// the server, and a retry stays idempotent after a pull replaced the job.
    /// The widget clocks in and out; the acknowledgement fails after the save
    /// and enqueue (a directory sits where the set-aside record for the
    /// batch's one bad entry goes, as in the 12.00b.2-C tests); the sync
    /// pushes the job and pulls it back, replacing the local copy with the
    /// server's; then the claim is retried.
    @MainActor
    static func widgetReplayMarkersStayLocal() async throws {
        let h = Harness(tag: "widget-markers")
        defer { h.cleanup() }
        let (_, job) = await syncedBaseline(h, "L286.1")
        let tag = NativeWidgetOwnerTag.make(binding: Harness.binding)
        func action(_ body: String) -> String { #"{"ownerTag":"\#(tag)",\#(body)}"# }
        let startedAt = "2026-09-25T15:00:00.000Z", stoppedAt = "2026-09-25T16:30:00.000Z"
        let raw = "[" + [
            action(#""id":"l286-start","type":"timer_start","at":"\#(startedAt)","jobId":"\#(job.id)""#),
            action(#""id":"l286-stop","type":"timer_stop","at":"\#(stoppedAt)","jobId":"\#(job.id)""#),
            action(#""id":"l286-bad","type":"expense_log","at":"2026-09-25T15:05:00.000Z","date":"2026-09-25","amount":-1"#),
        ].joined(separator: ",") + "]"
        guard let entries = NativeWidgetActionBatchPlanner.rawEntries(of: Data(raw.utf8)), entries.count == 3 else {
            return expect(false, "L286.1: sanity: the queue splits into its entries")
        }
        let recordDigest = SHA256.hash(data: NativeWidgetActionBatchPlanner.joinedList([entries[2]]))
            .map { String(format: "%02x", $0) }.joined()
        let claims = h.dir.appendingPathComponent("WidgetActionClaims", isDirectory: true)
        let blocker = claims.appendingPathComponent("quarantine-\(Harness.binding)-\(recordDigest).json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        func claimFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: claims.path)) ?? []).filter { $0.hasPrefix("claim-") }
        }

        h.widgetQueue.value = raw
        h.store.testReplayWidgetActions()
        expectEqual(claimFiles().count, 1, "L286.1: sanity: the acknowledgement failed and the claim is kept")
        expectEqual(h.committed()?.payload.jobs?.first { $0.id == job.id }?.timeSessions?.count, 1,
                    "L286.1: sanity: the clock-in and clock-out are saved")
        expectEqual(h.queueKeys(), ["jobs/\(job.id)"], "L286.1: sanity: the replayed job is queued")
        let queued = h.queue.load().first { $0.table == "jobs" }?.payload
        expectEqual(nativeKeys(queued), [], "L286.1: the queued job payload has no __native key")

        // The sync pushes the job, then its pull replaces the local job with
        // the server copy (the job is no longer pending).
        _ = await h.coordinator.sync(trigger: .manual)
        expect(h.queue.load().isEmpty, "L286.1: the queue drains")
        let row = h.server.storedRow(table: "jobs", id: job.id, userID: Harness.subject)?.data
        expectEqual(nativeKeys(row), [], "L286.1: the Supabase row has no __native key")
        expectEqual(sessionCount(row), 1, "L286.1: the Supabase row has the widget's session")
        let pulled = h.committed()?.payload.jobs?.first { $0.id == job.id }
        expectEqual(pulled?.timeSessions?.count, 1, "L286.1: after the pull the local job has the one session")
        expectEqual(nativeKeys(try jsonValue(pulled?.timeSessions ?? [])), [],
                    "L286.1: after the pull the local job is the server copy (no __native key)")

        // The acknowledgement can be written now; the retry applies nothing again.
        try FileManager.default.removeItem(at: blocker)
        h.store.testReplayWidgetActions()
        expect(claimFiles().isEmpty, "L286.1: the retried claim is acknowledged")
        let retried = h.committed()?.payload.jobs?.first { $0.id == job.id }?.timeSessions
        expectEqual(retried?.count, 1, "L286.1: the retry after the pull does not clock in again (one session)")
        expectEqual(retried?.first?.start, startedAt, "L286.1: the session is the widget's")
        expectEqual(retried?.first?.end, stoppedAt, "L286.1: the session is closed by the widget's stop")
        let summary = h.store.timeTrackingSummary(jobID: job.id)
        expect(summary?.isClocked == false && summary?.completedMs == 5_400_000,
               "L286.1: memory shows the one 90-minute session too (got \(String(describing: summary?.completedMs)))")
        _ = await h.coordinator.sync(trigger: .manual)
        let after = h.server.storedRow(table: "jobs", id: job.id, userID: Harness.subject)?.data
        expectEqual(sessionCount(after), 1, "L286.1: the server keeps one session")
        expectEqual(nativeKeys(after), [], "L286.1: and still no __native key")
    }

    /// Phase 12 12.00b.2-D (L286.1): a row an older native build pushed with
    /// replay markers, which RN kept (`utils/timeTracking.ts` `applyClockOut`
    /// spreads the session), is pulled: it decodes, the local job holds no
    /// `__native` key, a new clock-in still applies, and the next push
    /// cleans the server row.
    @MainActor
    static func staleServerMarkersAreDroppedOnPull() async throws {
        let h = Harness(tag: "stale-markers")
        defer { h.cleanup() }
        let (_, job) = await syncedBaseline(h, "L286.1 stale")
        guard let serverCopy = h.server.storedRow(table: "jobs", id: job.id, userID: Harness.subject)?.data else {
            return expect(false, "L286.1 stale: the baseline job is on the server")
        }
        let staleSession: Canonical.JSONValue = .object([
            "start": .string("2026-09-24T09:00:00.000Z"), "end": .string("2026-09-24T10:00:00.000Z"),
            "__nativeWidgetStartActionID": .string("old-start"), "__nativeWidgetStopActionID": .string("old-stop"),
        ])
        // The RN client's own upsert of the whole job blob (no native code).
        var request = URLRequest(url: Harness.supabaseURL.appending(path: "rest/v1/jobs"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Canonical.JSONValue.object([
            "id": .string(job.id), "user_id": .string(Harness.subject), "deleted": .bool(false),
            "data": replacing(serverCopy, "timeSessions", with: .array([staleSession])),
        ]))
        _ = try await h.server.data(for: request)
        expectEqual(nativeKeys(h.server.storedRow(table: "jobs", id: job.id, userID: Harness.subject)?.data).count, 2,
                    "L286.1 stale: sanity: the server row carries the stale markers")

        expectEqual(await h.store.testPullDeltaIfPossible().state, .completed, "L286.1 stale: the pull completes")
        let local = h.committed()?.payload.jobs?.first { $0.id == job.id }
        expectEqual(local?.timeSessions?.count, 1, "L286.1 stale: the stale row decodes with its session")
        expectEqual(nativeKeys(try jsonValue(local?.timeSessions ?? [])), [],
                    "L286.1 stale: the local job holds no __native key")

        let tag = NativeWidgetOwnerTag.make(binding: Harness.binding)
        h.widgetQueue.value = #"[{"ownerTag":"\#(tag)","id":"new-start","type":"timer_start","at":"2026-09-25T09:00:00.000Z","jobId":"\#(job.id)"}]"#
        h.store.testReplayWidgetActions()
        expectEqual(h.committed()?.payload.jobs?.first { $0.id == job.id }?.timeSessions?.count, 2,
                    "L286.1 stale: a new clock-in applies")
        expectEqual(nativeKeys(h.queue.load().first { $0.table == "jobs" }?.payload), [],
                    "L286.1 stale: the queued job payload has no __native key")
        _ = await h.coordinator.sync(trigger: .manual)
        let cleaned = h.server.storedRow(table: "jobs", id: job.id, userID: Harness.subject)?.data
        expectEqual(sessionCount(cleaned), 2, "L286.1 stale: the server row has both sessions")
        expectEqual(nativeKeys(cleaned), [], "L286.1 stale: the next push cleans the server row")
    }

    /// Review M1: the pure three-way merge the pull commit uses
    /// (`AppStore.rebasePulledDelta`), table-driven. Each case derives
    /// `pulled` (the pull's candidate) and `live` (the snapshot at commit)
    /// from one base, with the protected keys (pending at the pull's start
    /// or at commit) the commit would pass.
    @MainActor
    static func rebaseRules() {
        let h = Harness(tag: "rebase-rules")
        defer { h.cleanup() }
        let customer = Customer(name: "Delta Roofing", email: "delta@example.test")
        let names = ["A", "B", "C"]
        let jobs = names.map { Job(customerId: customer.id, customerName: customer.name, title: "Job \($0)", laborRate: 80) }
        expect(h.store.upsert(customer), "rebase: the customer saves")
        for job in jobs { expect(h.store.upsert(job), "rebase: job saves") }
        guard var base = h.committed() else { expect(false, "rebase: a committed base exists"); return }
        let nameByID = Dictionary(uniqueKeysWithValues: zip(jobs.map(\.id), names))
        let idOf = Dictionary(uniqueKeysWithValues: zip(names, jobs.map(\.id)))
        // Normalize the base: jobs A, B, C in that order; settings; two notes.
        base.payload.jobs = names.compactMap { name in base.payload.jobs?.first { $0.id == idOf[name] } }
        expect(base.payload.settings != nil, "rebase: the base has settings")
        base.payload.settings?.businessName = "Base Co"
        base.payload.customerNotes = ["k1": "note 1", "k2": "note 2"]

        func key(_ name: String) -> String { "jobs/\(idOf[name] ?? name)" }
        func titled(_ snapshot: Canonical.Snapshot, _ name: String, _ title: String) -> Canonical.Snapshot {
            var copy = snapshot
            copy.payload.jobs = copy.payload.jobs?.map { job in
                guard job.id == idOf[name] else { return job }
                var edited = job
                edited.title = title
                return edited
            }
            return copy
        }
        func removing(_ snapshot: Canonical.Snapshot, _ name: String) -> Canonical.Snapshot {
            var copy = snapshot
            copy.payload.jobs = copy.payload.jobs?.filter { $0.id != idOf[name] }
            return copy
        }
        func adding(_ snapshot: Canonical.Snapshot, _ name: String, first: Bool) -> Canonical.Snapshot {
            var copy = snapshot
            guard var job = base.payload.jobs?.first else { return copy }
            job.id = "new-\(name)"
            job.title = "Job \(name)"
            copy.payload.jobs = first ? [job] + (copy.payload.jobs ?? []) : (copy.payload.jobs ?? []) + [job]
            return copy
        }
        func rows(_ snapshot: Canonical.Snapshot) -> [String] {
            (snapshot.payload.jobs ?? []).map { "\(nameByID[$0.id] ?? $0.id)=\($0.title)" }
        }

        struct Case {
            let name: String
            let pulled: Canonical.Snapshot
            let live: Canonical.Snapshot
            let protected: Set<String>
            let jobs: [String]
            let held: Set<String>
        }
        let cases: [Case] = [
            Case(name: "nothing touched locally: the pulled snapshot as is",
                 pulled: titled(removing(base, "C"), "B", "B server"), live: base, protected: [],
                 jobs: ["A=Job A", "B=B server"], held: []),
            Case(name: "pending delete against a server update: the delete wins, the cursor holds",
                 pulled: titled(base, "A", "A server"), live: removing(base, "A"), protected: [key("A")],
                 jobs: ["B=Job B", "C=Job C"], held: ["jobs"]),
            Case(name: "create during the pull: kept first (live order), server changes elsewhere apply, a new remote row follows",
                 pulled: adding(titled(base, "B", "B server"), "R", first: false),
                 live: adding(base, "X", first: true), protected: ["jobs/new-X"],
                 jobs: ["new-X=Job X", "A=Job A", "B=B server", "C=Job C", "new-R=Job R"], held: []),
            Case(name: "server tombstone against a pending upsert: the upsert wins, the cursor holds",
                 pulled: removing(base, "A"), live: titled(base, "A", "A local"), protected: [key("A")],
                 jobs: ["A=A local", "B=Job B", "C=Job C"], held: ["jobs"]),
            Case(name: "server tombstone for an untouched record: removed",
                 pulled: removing(base, "C"), live: titled(base, "A", "A local"), protected: [key("A")],
                 jobs: ["A=A local", "B=Job B"], held: []),
            Case(name: "pending at start and pushed during the pull (review I1): the local edit is kept, the cursor holds",
                 pulled: titled(base, "A", "A older server"), live: base, protected: [key("A")],
                 jobs: ["A=Job A", "B=Job B", "C=Job C"], held: ["jobs"]),
            Case(name: "edited during the pull and already pushed (not pending): kept, the cursor holds",
                 pulled: titled(base, "A", "A older server"), live: titled(base, "A", "A local"), protected: [],
                 jobs: ["A=A local", "B=Job B", "C=Job C"], held: ["jobs"]),
            Case(name: "kept record the server already agrees with: no cursor hold",
                 pulled: titled(base, "A", "A local"), live: titled(base, "A", "A local"), protected: [key("A")],
                 jobs: ["A=A local", "B=Job B", "C=Job C"], held: []),
        ]
        for c in cases {
            do {
                let merged = try AppStore.rebasePulledDelta(base: base, pulled: c.pulled, live: c.live, protectedKeys: c.protected)
                expectEqual(rows(merged.snapshot), c.jobs, "rebase: \(c.name) (jobs)")
                expectEqual(merged.heldCursorTables, c.held, "rebase: \(c.name) (held cursors)")
            } catch {
                expect(false, "rebase: \(c.name) threw")
            }
        }

        // Settings: pending wins; untouched takes the server; changed locally (pushed) is kept.
        var serverSettings = base
        serverSettings.payload.settings?.businessName = "Server Co"
        var localSettings = base
        localSettings.payload.settings?.businessName = "Local Co"
        let settingsCases: [(String, Canonical.Snapshot, Set<String>, String)] = [
            ("pending settings win over the server", localSettings, ["settings/settings"], "Local Co"),
            ("untouched settings take the server", base, [], "Server Co"),
            ("settings changed during the pull (pushed) are kept", localSettings, [], "Local Co"),
        ]
        for (name, live, protected, expected) in settingsCases {
            let merged = try? AppStore.rebasePulledDelta(base: base, pulled: serverSettings, live: live, protectedKeys: protected)
            expectEqual(merged?.snapshot.payload.settings?.businessName, expected, "rebase: \(name)")
        }

        // Customer notes: per key.
        var serverNotes = base
        serverNotes.payload.customerNotes = ["k1": "note 1 server", "k2": "note 2 server", "k3": "note 3 server"]
        var localNotes = base
        localNotes.payload.customerNotes = ["k1": "note 1 local"]
        let notes = try? AppStore.rebasePulledDelta(
            base: base, pulled: serverNotes, live: localNotes,
            protectedKeys: ["customer_notes/k1", "customer_notes/k2"]
        )
        expectEqual(notes?.snapshot.payload.customerNotes,
                    ["k1": "note 1 local", "k3": "note 3 server"],
                    "rebase: notes: a pending edit and a pending delete win, a new server note applies")
        let untouched = try? AppStore.rebasePulledDelta(base: base, pulled: serverNotes, live: base, protectedKeys: [])
        expectEqual(untouched?.snapshot.payload.customerNotes, serverNotes.payload.customerNotes,
                    "rebase: notes: untouched notes take the server's")
    }

    /// H. Fix round 3 (controller ruling): recurring job and invoice
    /// generation never runs before the initial sync commits. This device's
    /// local snapshot (data from before this sign-in, not queued) still has
    /// four due rules; on the server, another device of the account has
    /// already generated this period's occurrence for one job rule and one
    /// plan. A scene-activation foreground refresh during the initial-sync
    /// await generates and queues nothing. After the commit and the gate
    /// advance, the post-commit generation (the same method the initial-sync
    /// task calls) makes exactly one occurrence per due rule, and the server
    /// ends with no duplicate.
    ///
    /// The initial-sync task itself is not drivable in this host binary (its
    /// gate sits behind the Info.plist-backed `BuildEnvironment` guard; see
    /// StoreIntegrationTests "10.09 fix round 2"). Its state is set with the
    /// existing `testSetAuthenticationGateState` hook, and its merge is stood
    /// in for by the real delta pull from an empty cursor (a full pull with
    /// the same merge rules). The initial-sync task's call order is pinned by
    /// a source check below.
    @MainActor
    static func recurringGenerationWaitsForInitialSync() async throws {
        let other = Harness(tag: "recurring-other-device")
        let h = Harness(tag: "recurring-initial-sync", server: other.server)
        defer { other.cleanup(); h.cleanup() }
        let today = NativeRecurringJobs.todayString()
        let customer = Customer(name: "Delta Roofing", email: "delta@example.test")
        let seedJob = Job(customerId: customer.id, customerName: customer.name, title: "Gutter clean", laborRate: 80)
        expect(other.store.upsert(customer) && other.store.upsert(seedJob), "H: the other device's seed records save")
        guard var firstRule = other.store.recurringJobDraft(from: seedJob.id), var secondRule = other.store.recurringJobDraft(from: seedJob.id) else {
            expect(false, "H: job rules draft")
            return
        }
        // The draft counts the seed job as occurrence 1; make the next one due today.
        firstRule.nextDueDate = today
        secondRule.id = firstRule.id + "-second"
        secondRule.nextDueDate = today
        expectEqual(firstRule.nextDueDate, today, "H: the job rules are due today")
        func plan(_ id: String) -> Canonical.RecurringInvoice {
            Canonical.RecurringInvoice(
                id: id, customerId: customer.id, customerName: customer.name,
                description: "Maintenance", amount: 150, dueDays: 30,
                cadence: "monthly", endCondition: "never", endCount: nil, endDate: nil,
                occurrenceCount: 0, lastGeneratedDate: nil, nextDueDate: today,
                isActive: true, createdAt: today, autoSendEnabled: false)
        }
        let firstPlan = plan("rinv-h-first"), secondPlan = plan("rinv-h-second")

        // This device: the same four rules, not yet advanced, and nothing queued.
        expect(h.store.upsert(customer), "H: the customer is on this device")
        expect(h.store.createRecurringJob(firstRule) && h.store.createRecurringJob(secondRule)
               && h.store.createRecurringInvoice(firstPlan) && h.store.createRecurringInvoice(secondPlan),
               "H: this device holds the four due rules")
        try h.queue.removeAll()
        let jobsBefore = h.store.jobs.count, invoicesBefore = h.store.invoices.count

        // The other device generates this period for the first rule and plan,
        // then adds the second ones, and everything reaches the server.
        expect(other.store.createRecurringJob(firstRule) && other.store.createRecurringInvoice(firstPlan), "H: other device rules")
        expect(other.store.runRecurringJobGeneration(today: today), "H: the other device generates the first job occurrence")
        expect(other.store.runRecurringInvoiceGeneration(today: today), "H: the other device generates the first plan's invoice")
        expect(other.store.createRecurringJob(secondRule) && other.store.createRecurringInvoice(secondPlan), "H: other device second rules")
        let push = NativeSupabaseMutationPushService(
            supabaseURL: Harness.supabaseURL, publishableKey: "publishable-key", allowsWrites: true, loader: other.server
        )
        let pushed = try await push.push(sessionBytes: Harness.session, expectedUserSubject: Harness.subject, items: other.queue.load())
        expect(pushed.remaining.isEmpty, "H: the other device's records reached the server")

        func linked(_ rows: [Canonical.JSONValue], _ field: String, _ id: String) -> Int {
            rows.filter { row in
                guard case let .object(fields) = row, case let .string(value)? = fields[field] else { return false }
                return value == id
            }.count
        }
        func diskJobs(_ rule: String) -> Int { linked((h.committed()?.payload.jobs ?? []).compactMap { try? jsonValue($0) }, "recurringJobId", rule) }
        func diskInvoices(_ rule: String) -> Int { linked((h.committed()?.payload.invoices ?? []).compactMap { try? jsonValue($0) }, "recurringInvoiceId", rule) }
        func serverCount(_ table: String, _ field: String, _ id: String) -> Int {
            linked(h.server.liveRows(table: table, userID: Harness.subject).map(\.data), field, id)
        }

        // The initial sync is in flight; the user brings the app to the foreground.
        h.store.testSetAuthenticationGateState(.initialSyncLoading)
        await h.store.performForegroundRefresh()
        expectEqual(h.store.jobs.count, jobsBefore, "H: a foreground refresh during the initial sync generates no job")
        expectEqual(h.store.invoices.count, invoicesBefore, "H: a foreground refresh during the initial sync generates no invoice")
        expectEqual(h.queueKeys(), [], "H: a foreground refresh during the initial sync queues nothing")
        expect(h.store.recurringJobRules.allSatisfy { $0.nextDueDate == today }
               && h.store.recurringInvoiceRules.allSatisfy { $0.nextDueDate == today },
               "H: no rule advances during the initial sync")

        // The server's data arrives (stand-in for the initial-sync merge).
        expectEqual(await h.store.testPullDeltaIfPossible().state, .completed, "H: the full pull commits")
        expectEqual(h.queueKeys(), [], "H: the pull commit during the initial sync generates nothing either")
        expectEqual(diskJobs(firstRule.id), 1, "H: the other device's job occurrence arrived")
        expectEqual(diskInvoices(firstPlan.id), 1, "H: the other device's plan invoice arrived")

        // The initial sync commits and its gate advances; the post-commit generation runs.
        h.store.testSetAuthenticationGateState(.signedIn(email: nil))
        h.store.testRunRecurringGenerationAfterInitialSync()
        for (label, count) in [
            ("first job rule", diskJobs(firstRule.id)), ("second job rule", diskJobs(secondRule.id)),
            ("first plan", diskInvoices(firstPlan.id)), ("second plan", diskInvoices(secondPlan.id)),
        ] {
            expectEqual(count, 1, "H: after the initial sync, exactly one occurrence for the \(label)")
        }
        // A later activation generates nothing more.
        await h.store.performForegroundRefresh()
        expectEqual(diskJobs(secondRule.id) + diskInvoices(secondPlan.id), 2, "H: a later foreground refresh adds nothing")

        _ = await h.coordinator.sync(trigger: .manual)
        expect(h.queue.load().isEmpty, "H: this device's generated records reach the server")
        expectEqual(serverCount("jobs", "recurringJobId", firstRule.id), 1, "H: no duplicate of the other device's job occurrence on the server")
        expectEqual(serverCount("jobs", "recurringJobId", secondRule.id), 1, "H: one occurrence of the second job rule on the server")
        expectEqual(serverCount("invoices", "recurringInvoiceId", firstPlan.id), 1, "H: no duplicate of the other device's plan invoice on the server")
        expectEqual(serverCount("invoices", "recurringInvoiceId", secondPlan.id), 1, "H: one invoice for the second plan on the server")

        // The initial-sync task calls the post-commit generation only after its gate advances.
        let source = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TradeReadyNative/AppStore.swift"), encoding: .utf8)) ?? ""
        if let gate = source.range(of: "private func beginInitialSyncGate("),
           let end = source.range(of: "private func advancePastInitialSync(", range: gate.upperBound..<source.endIndex) {
            let body = String(source[gate.upperBound..<end.lowerBound])
            expect(!body.contains("refreshRecurringJobs()") && !body.contains("runRecurringInvoiceGeneration("),
                   "H: the initial-sync task has no generation call before its gate advances")
            if let advance = body.range(of: "self.advancePastInitialSync("),
               let generate = body.range(of: "self.runRecurringGenerationAfterInitialSync()") {
                expect(advance.lowerBound < generate.lowerBound,
                       "H: the initial-sync task generates after advancePastInitialSync")
            } else {
                expect(false, "H: the initial-sync task calls runRecurringGenerationAfterInitialSync()")
            }
        } else {
            expect(false, "H: AppStore.swift source is readable for the call-order pin")
        }
    }

    /// F. The server changed the same record the user has pending. Documented
    /// precedence: the local pending edit wins until it is pushed; the push
    /// then makes it the server's value (last writer).
    @MainActor
    static func pendingEditWinsOverServerChangeToSameRecord() async throws {
        let h = Harness(tag: "same-record")
        defer { h.cleanup() }
        let (_, job) = await syncedBaseline(h, "F")
        try await remoteEdit(h, table: "jobs", id: job.id, field: "title", to: "Roof inspection (remote)")

        h.link.holdNextRequest = true
        let pass = Task { await h.coordinator.sync(trigger: .foreground) }
        await waitUntilHolding(h, "F")
        editTitle(h, job.id, "Roof inspection (local)", "F")
        _ = await h.coordinator.sync(trigger: .localChange)
        h.link.condition = .writesFail
        h.link.release()
        _ = await pass.value
        _ = await h.coordinator.waitUntilIdle()
        let pending = title(h, job: job.id)
        expectEqual(pending.server, "Roof inspection (remote)", "F: the server holds the other device's edit")
        expectEqual(pending.memory, "Roof inspection (local)", "F: the pending local edit wins in memory until pushed")
        expectEqual(pending.disk, "Roof inspection (local)", "F: the pending local edit wins on disk until pushed")

        h.link.condition = .online
        h.clock.advance(301)
        _ = await h.coordinator.sync(trigger: .manual)
        let pushed = title(h, job: job.id)
        expectEqual(pushed.server, "Roof inspection (local)", "F: once pushed, the local edit is the server's value")
        expectEqual(pushed.memory, "Roof inspection (local)", "F: after the push and pull, the device still shows it")
        expect(h.queue.load().isEmpty, "F: the queue drains")
    }


    // MARK: P. A poison change (12.00b.1, known issue I2)

    /// The title a server row holds, or nil.
    @MainActor
    static func serverTitle(_ h: Harness, _ id: String) -> String? {
        guard let row = h.server.storedRow(table: "jobs", id: id, userID: Harness.subject), !row.deleted,
              case let .object(fields) = row.data, case let .string(title)? = fields["title"] else { return nil }
        return title
    }

    /// The title of a job in the committed snapshot (what a relaunch reads), or nil.
    @MainActor
    static func committedTitle(_ h: Harness, _ id: String) -> String? {
        h.committed()?.payload.jobs?.first { $0.id == id }?.title
    }

    /// Plan 12.00b.1 step 6: one change the server will never accept (HTTP
    /// 422) must not wedge sync. The good changes push, inbound changes keep
    /// arriving, and the poison change reaches the rejected store exactly once.
    ///
    /// RN parity: `utils/sync.ts` `syncIfOnline` (lines 316-326) awaits
    /// `pushQueue(userId)` (line 320) and then `pullRemote(userId)` (line 321)
    /// on every pass, so a failing change never holds back inbound changes.
    /// RN keeps the failed change queued and retries it every pass
    /// (`pushQueue`, lines 204-213); native files a refused change once in the
    /// rejected-change store, where Settings › Cloud Sync offers Retry and
    /// Discard (owner decision D3).
    @MainActor
    static func poisonChangeLeavesTheQueueAndSyncKeepsPulling() async throws {
        let h = Harness(tag: "poison")
        let other = Harness(tag: "poison-other", server: h.server)
        defer { h.cleanup(); other.cleanup() }
        let customer = Customer(name: "Poison Pipes", email: "poison@example.test")
        let good1 = Job(customerId: customer.id, customerName: customer.name, title: "Good one", laborRate: 90)
        let poison = Job(customerId: customer.id, customerName: customer.name, title: "Poison", laborRate: 90)
        let good2 = Job(customerId: customer.id, customerName: customer.name, title: "Good two", laborRate: 90)
        expect(h.store.upsert(customer), "P: the customer saves")
        for job in [good1, poison, good2] { expect(h.store.upsert(job), "P: \(job.title) saves") }
        let poisonKey = "jobs/\(poison.id)"
        h.link.writeStatus[poisonKey] = 422

        // Another device of the same account has a change waiting on the server.
        let remote = Job(customerId: customer.id, customerName: customer.name, title: "From the other device", laborRate: 90)
        expect(other.store.upsert(remote), "P: the other device saves a job")
        _ = await other.coordinator.sync(trigger: .manual)
        expect(serverTitle(h, remote.id) != nil, "P: sanity: the other device's job is on the server")

        let first = await h.coordinator.sync(trigger: .manual)
        expectEqual(first, .completed(pushed: 3, authRefreshed: false),
                    "P: the pass completes: the customer and both good jobs pushed, the refusal is not a failure")
        for key in ["customers/\(customer.id)", "jobs/\(good1.id)", "jobs/\(good2.id)"] {
            expectEqual(h.link.committedWriteCount(key), 1, "P: \(key) committed once")
        }
        expectEqual(h.link.writes.filter { $0.key == poisonKey }.count, 1, "P: the poison change was sent once")
        expect(h.queue.load().isEmpty, "P: the poison change left the live queue")
        let filed = h.rejectedEntries()
        expectEqual(filed.map(\.key), [poisonKey], "P: the poison change reached the rejected store")
        expectEqual(filed.first?.statusCode, 422, "P: …with its status")
        expectEqual(filed.first?.item.op, .upsert, "P: …as the original queued change")
        expectEqual(h.store.rejectedChanges.map(\.id), [poisonKey], "P: Cloud Sync lists it")
        expect(h.link.reads.contains { $0.table == "jobs" && $0.reachedServer }, "P: the pull ran after the push")
        expectEqual(committedTitle(h, remote.id), "From the other device", "P: the inbound change arrived")
        expectEqual(committedTitle(h, poison.id), "Poison", "P: the refused record keeps its local version")
        let status = h.coordinator.status()
        expect(status.consecutiveFailures == 0 && status.nextEarliestAttempt == nil && status.diagnosticCode == nil,
               "P: a refusal opens no backoff and leaves no failure code")
        expectEqual(status.pendingCount, 0, "P: nothing is pending")

        // The next passes: the poison change is never sent again or filed twice,
        // and inbound changes keep arriving.
        let filedAt = filed.first?.rejectedAt
        var later = remote
        later.title = "Edited on the other device"
        expect(other.store.upsert(later), "P: the other device edits its job")
        _ = await other.coordinator.sync(trigger: .manual)
        h.link.resetLog()
        _ = await h.coordinator.sync(trigger: .foreground)
        _ = await h.coordinator.sync(trigger: .manual)
        expect(h.link.writes.isEmpty, "P: later passes send nothing (the poison change is not retried)")
        expectEqual(h.rejectedEntries().map(\.key), [poisonKey], "P: still exactly one entry")
        expectEqual(h.rejectedEntries().first?.rejectedAt, filedAt, "P: the entry was filed exactly once")
        expectEqual(committedTitle(h, remote.id), "Edited on the other device", "P: later inbound changes keep arriving")
    }

    // MARK: Q. A kept record cannot pin its table's cursor (12.00b.1)

    /// Plan 12.00b.1 step 5: with the pull running while changes are still
    /// queued, the 11.12 commit keeps every record this device has a pending
    /// or refused change for. Such a record must not hold its table's
    /// watermark forever: a change that keeps failing (HTTP 503 every pass)
    /// and a refused one (HTTP 422) sit on "jobs" while another device edits
    /// the same two jobs and adds a third. The jobs watermark still advances
    /// to the newest server row on every pass.
    @MainActor
    static func keptRecordsDoNotPinTheCursor() async throws {
        let h = Harness(tag: "cursor")
        let other = Harness(tag: "cursor-other", server: h.server)
        defer { h.cleanup(); other.cleanup() }
        let customer = Customer(name: "Quartz Tile", email: "quartz@example.test")
        var stuck = Job(customerId: customer.id, customerName: customer.name, title: "Stuck", laborRate: 70)
        var refused = Job(customerId: customer.id, customerName: customer.name, title: "Refused", laborRate: 70)
        expect(h.store.upsert(customer) && h.store.upsert(stuck) && h.store.upsert(refused), "Q: the records save")
        expectEqual(await h.coordinator.sync(trigger: .manual), .completed(pushed: 3, authRefreshed: false), "Q: they reach the server")
        _ = await other.coordinator.sync(trigger: .manual)
        expect(other.store.jobs.count == 2, "Q: sanity: the other device pulled both jobs")

        // This device edits both; one keeps failing, one is refused.
        h.link.writeStatus["jobs/\(stuck.id)"] = 503
        h.link.writeStatus["jobs/\(refused.id)"] = 422
        stuck.title = "Stuck (local edit)"
        refused.title = "Refused (local edit)"
        expect(h.store.upsert(stuck) && h.store.upsert(refused), "Q: both local edits save")
        // The other device edits the same two jobs and adds a third.
        guard var otherStuck = other.store.jobs.first(where: { $0.id == stuck.id }),
              var otherRefused = other.store.jobs.first(where: { $0.id == refused.id }) else {
            expect(false, "Q: the other device has both jobs"); return
        }
        otherStuck.title = "Stuck (other device)"
        otherRefused.title = "Refused (other device)"
        let fresh = Job(customerId: customer.id, customerName: customer.name, title: "Fresh", laborRate: 70)
        expect(other.store.upsert(otherStuck) && other.store.upsert(otherRefused) && other.store.upsert(fresh),
               "Q: the other device's edits save")
        _ = await other.coordinator.sync(trigger: .manual)
        func newestJobStamp() -> String? {
            h.server.liveRows(table: "jobs", userID: Harness.subject).map(\.updatedAt).max()
        }

        let pass = await h.coordinator.sync(trigger: .manual)
        expectEqual(pass, .partial(pushed: 0, remaining: 1, authRefreshed: false),
                    "Q: the 503 change stays queued; the refused one left the queue")
        expectEqual(h.queueKeys(), ["jobs/\(stuck.id)"], "Q: only the failing change is queued")
        expectEqual(h.rejectedEntries().map(\.key), ["jobs/\(refused.id)"], "Q: the refused change is filed")
        expectEqual(committedTitle(h, stuck.id), "Stuck (local edit)", "Q: the pending record keeps its local version")
        expectEqual(committedTitle(h, refused.id), "Refused (local edit)", "Q: the refused record keeps its local version")
        expectEqual(committedTitle(h, fresh.id), "Fresh", "Q: the other device's new job arrived")
        expectEqual(h.cursorStore.load().tables["jobs"], newestJobStamp(),
                    "Q: the jobs watermark advanced to the newest server row despite the two kept records")

        // The other device keeps editing; every pass advances the watermark again.
        var freshEdit = fresh
        for round in 1...2 {
            freshEdit.title = "Fresh \(round)"
            expect(other.store.upsert(freshEdit), "Q: round \(round): the other device edits")
            _ = await other.coordinator.sync(trigger: .manual)
            h.clock.advance(301)
            _ = await h.coordinator.sync(trigger: .manual)
            expectEqual(committedTitle(h, fresh.id), "Fresh \(round)", "Q: round \(round): the edit arrived")
            expectEqual(h.cursorStore.load().tables["jobs"], newestJobStamp(),
                        "Q: round \(round): the watermark is not pinned")
            expectEqual(committedTitle(h, stuck.id), "Stuck (local edit)", "Q: round \(round): the pending record is still kept")
            expectEqual(committedTitle(h, refused.id), "Refused (local edit)", "Q: round \(round): the refused record is still kept")
        }

        // Once the failing change clears it reaches the server, and the
        // refused record's Discard shows the other device's version.
        h.link.writeStatus["jobs/\(stuck.id)"] = nil
        h.clock.advance(301)
        _ = await h.coordinator.sync(trigger: .manual)
        expectEqual(serverTitle(h, stuck.id), "Stuck (local edit)", "Q: the stuck change reached the server once it cleared")
        let discarded = await h.store.discardRejectedChange(id: "jobs/\(refused.id)")
        expect(discarded == nil, "Q: Discard succeeds")
        expectEqual(committedTitle(h, refused.id), "Refused (other device)",
                    "Q: Discard shows the server's version even though the watermark moved past it")
    }

    // MARK: R. Retry (12.00b.1, owner decision D3)

    @MainActor
    static func retryRefusedChange() async throws {
        let h = Harness(tag: "retry")
        defer { h.cleanup() }
        let customer = Customer(name: "Rowan Roofing", email: "rowan@example.test")
        var job = Job(customerId: customer.id, customerName: customer.name, title: "Original", laborRate: 80)
        expect(h.store.upsert(customer) && h.store.upsert(job), "R: the records save")
        _ = await h.coordinator.sync(trigger: .manual)
        let key = "jobs/\(job.id)"
        h.link.writeStatus[key] = 409
        job.title = "Refused edit"
        expect(h.store.upsert(job), "R: the edit saves")
        _ = await h.coordinator.sync(trigger: .manual)
        expectEqual(h.store.rejectedChanges.map(\.id), [key], "R: sanity: the edit was refused and listed")
        let original = h.rejectedEntries().first

        // Retry while the server still refuses: sent once, back in the list, no loop.
        h.link.resetLog()
        expect(h.store.retryRejectedChange(id: key), "R: Retry re-queues the change")
        expectEqual(h.queueKeys(), [key], "R: the change is back in the live queue")
        expectEqual(h.queue.load().first?.payload, original?.item.payload, "R: …with the refused change's payload")
        expect(h.store.rejectedChanges.isEmpty, "R: the entry is hidden while its Retry is queued")
        expectEqual(await h.coordinator.sync(trigger: .manual), .completed(pushed: 0, authRefreshed: false),
                    "R: the pass completes")
        expectEqual(h.link.writes.filter { $0.key == key }.count, 1, "R: the retried change was sent exactly once in the pass")
        expect(h.queue.load().isEmpty, "R: the refused retry left the queue again")
        expectEqual(h.store.rejectedChanges.map(\.id), [key], "R: the refused retry is back in the list")
        expectEqual(h.rejectedEntries().count, 1, "R: still one entry for the record")
        expect(!h.store.retryRejectedChange(id: "jobs/none"), "R: Retry of an unknown entry does nothing")

        // Retry is an ordinary queued change: a newer edit replaces it (last
        // writer wins), and the accepted push clears the entry.
        h.link.writeStatus[key] = nil
        expect(h.store.retryRejectedChange(id: key), "R: Retry again")
        job.title = "Edited after Retry"
        expect(h.store.upsert(job), "R: a newer edit saves")
        expectEqual(h.queueKeys(), [key], "R: the queue coalesces Retry and the edit into one change")
        h.link.resetLog()
        expectEqual(await h.coordinator.sync(trigger: .manual), .completed(pushed: 1, authRefreshed: false),
                    "R: the pass pushes the one change")
        expectEqual(serverTitle(h, job.id), "Edited after Retry", "R: the server has the newest edit")
        expect(h.store.rejectedChanges.isEmpty && h.rejectedEntries().isEmpty, "R: the accepted change cleared the entry")
        expect(!FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("rejected-changes.json").path),
               "R: an empty store leaves no file")
    }

    // MARK: S. Discard (12.00b.1, owner decision D3)

    @MainActor
    static func discardRefusedChange() async throws {
        let h = Harness(tag: "discard")
        let other = Harness(tag: "discard-other", server: h.server)
        defer { h.cleanup(); other.cleanup() }
        let customer = Customer(name: "Sage Siding", email: "sage@example.test")
        var job = Job(customerId: customer.id, customerName: customer.name, title: "Server version", laborRate: 80)
        let doomed = Job(customerId: customer.id, customerName: customer.name, title: "Keep on server", laborRate: 80)
        expect(h.store.upsert(customer) && h.store.upsert(job) && h.store.upsert(doomed), "S: the records save")
        _ = await h.coordinator.sync(trigger: .manual)
        _ = await other.coordinator.sync(trigger: .manual)

        // (a) The server has the record: Discard shows the server's current version.
        let key = "jobs/\(job.id)"
        h.link.writeStatus[key] = 422
        job.title = "Refused local edit"
        expect(h.store.upsert(job), "S(a): the edit saves")
        _ = await h.coordinator.sync(trigger: .manual)
        expectEqual(h.store.rejectedChanges.map(\.id), [key], "S(a): sanity: refused and listed")
        guard var otherJob = other.store.jobs.first(where: { $0.id == job.id }) else {
            expect(false, "S(a): the other device has the job"); return
        }
        otherJob.title = "Server version (newer)"
        expect(other.store.upsert(otherJob), "S(a): the other device edits the job")
        _ = await other.coordinator.sync(trigger: .manual)

        // Offline: nothing changes and the entry stays.
        h.link.condition = .offline
        let offline = await h.store.discardRejectedChange(id: key)
        expect(offline != nil, "S: an offline Discard explains why it did not finish")
        expectEqual(committedTitle(h, job.id), "Refused local edit", "S: an offline Discard changes nothing")
        expectEqual(h.store.rejectedChanges.map(\.id), [key], "S: …and keeps the entry")
        h.link.condition = .online

        h.link.resetLog()
        let discarded = await h.store.discardRejectedChange(id: key)
        expect(discarded == nil, "S(a): Discard succeeds")
        expect(h.link.writes.isEmpty, "S(a): Discard sends no write")
        expectEqual(h.link.reads.map(\.table), ["jobs"], "S(a): Discard fetches just that record")
        expectEqual(h.store.jobs.first { $0.id == job.id }?.title, "Server version (newer)", "S(a): the screen shows the server's version")
        expectEqual(committedTitle(h, job.id), "Server version (newer)", "S(a): …and it is committed")
        expect(h.store.rejectedChanges.isEmpty && h.rejectedEntries().isEmpty, "S(a): the entry is gone")
        expect(h.queue.load().isEmpty, "S(a): nothing is queued by Discard")
        let again = await h.store.discardRejectedChange(id: key)
        expect(again != nil, "S(a): a second Discard of the same entry does nothing")
        h.link.resetLog()
        _ = await h.coordinator.sync(trigger: .manual)
        expect(h.link.writes.isEmpty, "S(a): the next pass sends nothing for it")
        expectEqual(committedTitle(h, job.id), "Server version (newer)", "S(a): the server's version stays")

        // (b) A refused insert: the server never had it, so Discard removes
        // the local-only record.
        let orphan = Job(customerId: customer.id, customerName: customer.name, title: "Never saved", laborRate: 80)
        let orphanKey = "jobs/\(orphan.id)"
        h.link.writeStatus[orphanKey] = 400
        expect(h.store.upsert(orphan), "S(b): the new job saves locally")
        _ = await h.coordinator.sync(trigger: .manual)
        expectEqual(h.store.rejectedChanges.map(\.id), [orphanKey], "S(b): sanity: the insert was refused")
        expect(serverTitle(h, orphan.id) == nil, "S(b): sanity: the server has no such row")
        let discardedInsert = await h.store.discardRejectedChange(id: orphanKey)
        expect(discardedInsert == nil, "S(b): Discard succeeds")
        expect(h.store.jobs.first { $0.id == orphan.id } == nil, "S(b): the local-only job is removed")
        expect(committedTitle(h, orphan.id) == nil, "S(b): …and the removal is committed")
        expect(h.store.rejectedChanges.isEmpty, "S(b): the entry is gone")
        expect(h.queue.load().isEmpty, "S(b): Discard queues no delete for it")

        // A refused delete: Discard restores the server's record.
        let doomedKey = "jobs/\(doomed.id)"
        h.link.writeStatus[doomedKey] = 409
        expect(h.store.deleteJob(id: doomed.id), "S(delete): the job is deleted locally")
        _ = await h.coordinator.sync(trigger: .manual)
        expectEqual(h.rejectedEntries().first?.item.op, .delete, "S(delete): sanity: the delete was refused")
        let discardedDelete = await h.store.discardRejectedChange(id: doomedKey)
        expect(discardedDelete == nil, "S(delete): Discard succeeds")
        expectEqual(committedTitle(h, doomed.id), "Keep on server", "S(delete): the server's record is back on this device")
        expect(h.store.rejectedChanges.isEmpty, "S(delete): the entry is gone")
    }

    // MARK: Signposts (11.12 instrumentation on the pull commit path)

    @MainActor
    static func checkSignposts(_ sink: RecordingSignpostSink) {
        let pulls = sink.records(for: .deltaPull)
        let begins = pulls.filter { $0.phase == .begin }
        let ends = pulls.filter { $0.phase == .end }
        expect(!begins.isEmpty, "signposts: every pull commit emits a DeltaPull interval")
        expectEqual(begins.count, ends.count, "signposts: every DeltaPull begin has an end")
        expect(ends.contains { $0.metadata.hasSuffix("outcome=partial") },
               "signposts: a dropped pull ends with outcome=partial")
        expect(ends.contains { $0.metadata.hasSuffix("outcome=completed") },
               "signposts: a clean pull ends with outcome=completed")
        expectEqual(sink.mismatchedEnds, 0, "signposts: each end returns its own begin state")
        expectEqual(sink.openCount, 0, "signposts: no interval is left open")
        let pattern = "^(count=(0|[1-9][0-9]{0,8}))?( ?outcome=(completed|partial|failed|skipped))?$"
        for record in sink.records {
            expect(record.metadata.range(of: pattern, options: .regularExpression) != nil,
                   "signposts: \(record.interval.name) metadata '\(record.metadata)' is a count and an outcome only")
        }
        let forbidden = [Harness.subject, "private-access-token", "Cedar", "Furnace", "Ada", "example.test", "INV-"]
        for record in sink.records {
            for text in forbidden where record.metadata.contains(text) {
                expect(false, "signposts: \(record.interval.name) metadata leaks '\(text)'")
            }
        }
    }
}
