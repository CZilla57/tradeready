import Foundation

@main
struct BackgroundRefreshTests {
    @MainActor
    static func main() async throws {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if !condition {
                failures += 1
                print("FAIL: \(label)")
            }
        }

        let now = Date(timeIntervalSince1970: 1_000_000)
        expect(
            NativeBackgroundRefreshPolicy.earliestBeginDate(from: now)
                == now.addingTimeInterval(30 * 60),
            "the refresh request uses the React Native 30-minute minimum"
        )
        expect(
            NativeBackgroundRefreshPolicy.taskIdentifier
                == "com.gettradereadyapp.tradeready.sync-refresh",
            "the permitted identifier is stable"
        )
        expect(
            NativeBackgroundRefreshPolicy.canAttachVerifiedIdentity(
                verifiedAccountBinding: "owner-a",
                workspaceAccountBinding: "owner-a",
                workspaceIsComplete: true
            ),
            "an exact completed workspace can attach a verified identity"
        )
        expect(
            !NativeBackgroundRefreshPolicy.canAttachVerifiedIdentity(
                verifiedAccountBinding: "owner-a",
                workspaceAccountBinding: "owner-b",
                workspaceIsComplete: true
            ),
            "a different owner's workspace is rejected"
        )
        expect(
            !NativeBackgroundRefreshPolicy.canAttachVerifiedIdentity(
                verifiedAccountBinding: "owner-a",
                workspaceAccountBinding: "owner-a",
                workspaceIsComplete: false
            ),
            "an incomplete workspace is rejected"
        )
        expect(NativeBackgroundRefreshOutcome.completed.taskSucceeded,
               "completed work succeeds the system task")
        expect(NativeBackgroundRefreshOutcome.skipped.taskSucceeded,
               "a signed-out or unavailable workspace is a successful no-op")
        expect(!NativeBackgroundRefreshOutcome.failed.taskSucceeded,
               "failed work fails the system task")

        var completedValues: [Bool] = []
        let completed = NativeBackgroundRefreshOperation()
        completed.start(
            work: { .completed },
            completion: { completedValues.append($0) }
        )
        await Task.yield()
        expect(completedValues == [true], "completed work reports success exactly once")

        var failedValues: [Bool] = []
        let failed = NativeBackgroundRefreshOperation()
        failed.start(
            work: { .failed },
            completion: { failedValues.append($0) }
        )
        await Task.yield()
        expect(failedValues == [false], "failed work reports failure exactly once")

        var expirationValues: [Bool] = []
        let expiring = NativeBackgroundRefreshOperation()
        expiring.start(
            work: {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .completed
                } catch {
                    return .failed
                }
            },
            completion: { expirationValues.append($0) }
        )
        expiring.cancel()
        await Task.yield()
        await Task.yield()
        expect(expirationValues == [false], "expiration cancels work and completes only once")
        expiring.start(
            work: { .completed },
            completion: { expirationValues.append($0) }
        )
        await Task.yield()
        expect(expirationValues == [false], "a completed operation cannot be restarted")

        // MARK: - Task 10.09 (B1): NativeDerivedStatePublisher seam matrix
        //
        // These are unit-level tests of the publisher's own contract —
        // failure isolation, owner-identity re-verification, and the
        // register/cache surface. The higher-level guarantee ("invoked
        // exactly once per real committed pass, never on .alreadyRunning,
        // offline, signed-out, or a failed pass") is a property of its one
        // call site, `AppStore.pullDeltaIfPossible`, and is covered by
        // `native/run-store-integration-tests.sh` and
        // `native/run-sync-coordinator-tests.sh` (every earlier guard in
        // that function returns before ever reaching the publish call).

        struct SeamFailure: Error {}

        // Success: all three outputs fire from one publish, with the exact
        // input/now passed through.
        do {
            var notifyCalls: [Date] = []
            var observed: [String] = []
            let now = Date(timeIntervalSince1970: 42)
            let publisher = NativeDerivedStatePublisher<Int, String>(
                notifySynchronize: { date in notifyCalls.append(date) },
                makeSnapshot: { input, _ in "snapshot-\(input)" },
                ownerBinding: { "owner-a" },
                now: { now }
            )
            publisher.register { observed.append($0) }
            await publisher.publish(canonical: 7, expectedOwnerBinding: "owner-a")
            expect(notifyCalls == [now], "success: notification reconciliation runs exactly once")
            expect(publisher.cachedSnapshot == "snapshot-7", "success: the cache reflects the committed input")
            expect(observed == ["snapshot-7"], "success: a registered observer receives the committed snapshot")
        }

        // Owner mismatch before publish: no output runs at all.
        do {
            var notifyCalls = 0
            var observed = 0
            let publisher = NativeDerivedStatePublisher<Int, String>(
                notifySynchronize: { _ in notifyCalls += 1 },
                makeSnapshot: { input, _ in "snapshot-\(input)" },
                ownerBinding: { "owner-b" }
            )
            publisher.register { _ in observed += 1 }
            await publisher.publish(canonical: 1, expectedOwnerBinding: "owner-a")
            expect(notifyCalls == 0, "signed-out/switched owner: notification reconciliation never runs")
            expect(publisher.cachedSnapshot == nil, "signed-out/switched owner: no snapshot is cached")
            expect(observed == 0, "signed-out/switched owner: no observer is called")
        }

        // Owner mismatch appearing after the (a) await: (b)/(c) are skipped,
        // the prior good cache is left intact — never overwritten with
        // another owner's data.
        do {
            var currentOwner = "owner-a"
            var observed = 0
            let publisher = NativeDerivedStatePublisher<Int, String>(
                notifySynchronize: { _ in currentOwner = "owner-b" },
                makeSnapshot: { input, _ in "snapshot-\(input)" },
                ownerBinding: { currentOwner }
            )
            publisher.register { _ in observed += 1 }
            await publisher.publish(canonical: 1, expectedOwnerBinding: "owner-a")
            expect(publisher.cachedSnapshot == nil, "owner switches mid-pass: no snapshot from the old owner is cached")
            expect(observed == 0, "owner switches mid-pass: no observer sees the old owner's snapshot")
        }

        // One output failing (notify throws): (b)/(c) are unaffected —
        // failure in (a) never blocks or corrupts the others.
        do {
            var observed: [String] = []
            let publisher = NativeDerivedStatePublisher<Int, String>(
                notifySynchronize: { _ in throw SeamFailure() },
                makeSnapshot: { input, _ in "snapshot-\(input)" },
                ownerBinding: { "owner-a" }
            )
            publisher.register { observed.append($0) }
            await publisher.publish(canonical: 3, expectedOwnerBinding: "owner-a")
            expect(publisher.cachedSnapshot == "snapshot-3", "notify failure is isolated: the cache still refreshes")
            expect(observed == ["snapshot-3"], "notify failure is isolated: observers still run")
        }

        // One output failing (snapshot build throws): (a) still ran; the
        // prior good cache is left completely intact, not overwritten with a
        // partial/corrupt value; no observer sees a bad snapshot.
        do {
            var notifyCalls = 0
            var observed: [String] = []
            var shouldFail = false
            let publisher = NativeDerivedStatePublisher<Int, String>(
                notifySynchronize: { _ in notifyCalls += 1 },
                makeSnapshot: { input, _ in
                    if shouldFail { throw SeamFailure() }
                    return "snapshot-\(input)"
                },
                ownerBinding: { "owner-a" }
            )
            publisher.register { observed.append($0) }
            await publisher.publish(canonical: 1, expectedOwnerBinding: "owner-a")
            expect(publisher.cachedSnapshot == "snapshot-1", "a first good publish populates the cache")
            shouldFail = true
            await publisher.publish(canonical: 2, expectedOwnerBinding: "owner-a")
            expect(notifyCalls == 2, "snapshot-build failure is isolated: notification reconciliation still ran both times")
            expect(publisher.cachedSnapshot == "snapshot-1", "snapshot-build failure never corrupts the prior good cache")
            expect(observed == ["snapshot-1"], "snapshot-build failure: no observer is called for the failed pass")
        }

        // Multiple observers, one throwing: the throwing observer never
        // blocks delivery to the others, and never corrupts the cache.
        do {
            var first: [String] = []
            var second: [String] = []
            let publisher = NativeDerivedStatePublisher<Int, String>(
                notifySynchronize: { _ in },
                makeSnapshot: { input, _ in "snapshot-\(input)" },
                ownerBinding: { "owner-a" }
            )
            publisher.register { _ in throw SeamFailure() }
            publisher.register { first.append($0) }
            let secondToken = publisher.register { second.append($0) }
            await publisher.publish(canonical: 5, expectedOwnerBinding: "owner-a")
            expect(first == ["snapshot-5"], "a throwing observer never blocks another observer")
            expect(second == ["snapshot-5"], "a throwing observer never blocks another observer")
            publisher.unregister(secondToken)
            await publisher.publish(canonical: 6, expectedOwnerBinding: "owner-a")
            expect(second == ["snapshot-5"], "an unregistered observer receives no further snapshots")
        }

        // reset() clears both the cache and every observer registration —
        // the account-boundary guarantee (sign-out must never leak a prior
        // owner's cached snapshot or replay to a stale observer).
        do {
            var observed = 0
            let publisher = NativeDerivedStatePublisher<Int, String>(
                notifySynchronize: { _ in },
                makeSnapshot: { input, _ in "snapshot-\(input)" },
                ownerBinding: { "owner-a" }
            )
            publisher.register { _ in observed += 1 }
            await publisher.publish(canonical: 9, expectedOwnerBinding: "owner-a")
            expect(publisher.cachedSnapshot == "snapshot-9", "sanity: the cache is populated before reset")
            publisher.reset()
            expect(publisher.cachedSnapshot == nil, "reset() clears the cached snapshot at the account boundary")
            await publisher.publish(canonical: 10, expectedOwnerBinding: "owner-a")
            expect(observed == 1, "reset() removes every observer registration")
            expect(publisher.cachedSnapshot == "snapshot-10", "a publish after reset() still populates a fresh cache")
        }

        if failures > 0 {
            print("\(failures) background refresh test(s) failed")
            Foundation.exit(1)
        }
        print("Background refresh tests passed")
    }
}
