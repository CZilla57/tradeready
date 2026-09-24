import Foundation
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
        var recordID: String?
        if method == "POST", let body = request.httpBody,
           case let .object(fields)? = try? JSONDecoder().decode(Canonical.JSONValue.self, from: body) {
            if case let .string(id)? = fields["id"] { recordID = id }
            else if case let .string(key)? = fields["customer_key"] { recordID = key }
            else { recordID = table }
        } else if method == "PATCH" {
            recordID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "id" }?.value?.replacingOccurrences(of: "eq.", with: "")
        }
        attempts.append(Attempt(method: method, table: table, recordID: recordID, reachedServer: reachedServer))
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

@MainActor
struct Harness {
    static let subject = "11111111-2222-3333-4444-555555555555"
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

    init(tag: String) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-poor-network-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        server = InMemorySupabase()
        link = PoorNetworkLink(server: server)
        clock = TestClock()
        // A throwaway App Group suite: a host test never touches the real one.
        let suite = "com.tradeready.poor-network.tests.\(UUID().uuidString)"
        store = AppStore(
            fileURL: dir.appendingPathComponent("store.json"),
            seedIfMissing: false,
            appGroupAccountScrubber: NativeAppGroupAccountScrubber(
                suiteName: suite,
                defaults: UserDefaults(suiteName: suite) ?? .standard,
                lockFile: dir.appendingPathComponent("app-group.lock")
            ),
            initialSyncService: NativeSupabaseInitialSyncService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key", loader: link
            )
        )
        store.scheduleBookingTestSeedSignedInOwner(subject: Self.subject, binding: String(repeating: "b", count: 64))
        let credentials = NativeSyncCredentials(subject: Self.subject, sessionBytes: Self.session)
        store.scheduleBookingTestCredentials = credentials
        // The same files AppStore.init opened: every local edit lands here.
        queue = Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("mutation-queue.json"))
        cursorStore = Canonical.NativeSyncCursorStore(fileURL: dir.appendingPathComponent("sync-cursor.json"))
        let clock = clock
        let store = store
        // `AppStore.syncCoordinatorIfConfigured`, minus BuildEnvironment.
        coordinator = NativeSyncCoordinator(
            push: NativeSupabaseMutationPushService(
                supabaseURL: Self.supabaseURL, publishableKey: "publishable-key",
                allowsWrites: true, loader: link
            ),
            queue: queue,
            reachability: link,
            credentialsProvider: { credentials },
            refreshSession: { false },
            pull: { await store.testPullDeltaIfPossible() },
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
        expect(h.link.reads.isEmpty, "B: no pull runs over pending local writes")
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
        expect(h.link.reads.isEmpty, "C4: no pull runs over the pending remainder")
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
