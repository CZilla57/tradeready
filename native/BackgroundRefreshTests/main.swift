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
        // failure isolation, owner-identity re-verification, the generation
        // guard against a superseded (stale-resuming) publish, and the
        // register/cache surface. The higher-level guarantee ("exactly once
        // per committed canonical sync commit, never on .alreadyRunning,
        // offline, signed-out, or a pre-commit failure") is a property of
        // AppStore's several commit call sites (`pullDeltaIfPossible`,
        // `runBookingIntakeAfterVerifiedPull`'s local commit, and the
        // initial-sync commit in `beginInitialSyncGate`) each returning
        // before ever reaching their own publish call on every excluded
        // path — covered by `native/run-store-integration-tests.sh` and
        // `native/run-sync-coordinator-tests.sh`.

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

        // reset() (fix round 1, finding 2/4): clears ONLY the cached
        // snapshot at the account boundary. Observers are app-lifetime (the
        // 11.01 widget mirror registers once) and must survive sign-out to
        // receive the next owner's publishes after sign-in.
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
            expect(observed == 1, "sanity: the observer ran for the first publish")
            publisher.reset()
            expect(publisher.cachedSnapshot == nil, "reset() clears the cached snapshot at the account boundary")
            await publisher.publish(canonical: 10, expectedOwnerBinding: "owner-a")
            expect(observed == 2, "reset() does NOT remove observer registrations: the survivor is called again")
            expect(publisher.cachedSnapshot == "snapshot-10", "a publish after reset() still populates a fresh cache")
        }

        // Fail-closed cached-snapshot read (fix round 1, finding 2): the
        // cache is scoped to the owner it was built for. If the live owner
        // changes without an explicit reset() (e.g. a caller forgets to
        // clear it), the read must still come back nil rather than leak the
        // previous owner's data.
        do {
            var currentOwner = "owner-a"
            let publisher = NativeDerivedStatePublisher<Int, String>(
                notifySynchronize: { _ in },
                makeSnapshot: { input, _ in "snapshot-\(input)" },
                ownerBinding: { currentOwner }
            )
            await publisher.publish(canonical: 1, expectedOwnerBinding: "owner-a")
            expect(publisher.cachedSnapshot == "snapshot-1", "sanity: cache populated for owner-a")
            currentOwner = "owner-b"
            expect(publisher.cachedSnapshot == nil,
                   "fail-closed: a cache built for a previous owner never reads back for a different live owner")
            currentOwner = "owner-a"
            expect(publisher.cachedSnapshot == "snapshot-1",
                   "the cache reads back once the live owner matches again (no data was lost, just gated)")
        }

        // Generation guard (fix round 1, finding 3): an older publish that
        // resumes, after suspending in notifySynchronize, LATER than a newer
        // publish has already completed must not overwrite the newer
        // snapshot or re-notify observers with stale data.
        do {
            var observed: [String] = []
            var resumeOlder: CheckedContinuation<Void, Never>?
            var liveNow = Date(timeIntervalSince1970: 1)
            let publisher = NativeDerivedStatePublisher<Int, String>(
                notifySynchronize: { date in
                    // The "older" publish (canonical 1, now=1) suspends here
                    // until explicitly resumed; the "newer" publish (canonical
                    // 2, now=2) resolves immediately — modeling a direct
                    // booking pull whose notify call coalesces and returns
                    // right away while an earlier background pass is still
                    // suspended in its own notify call.
                    if date == Date(timeIntervalSince1970: 1) {
                        await withCheckedContinuation { resumeOlder = $0 }
                    }
                },
                makeSnapshot: { input, _ in "snapshot-\(input)" },
                ownerBinding: { "owner-a" },
                now: { liveNow }
            )
            publisher.register { observed.append($0) }
            liveNow = Date(timeIntervalSince1970: 1)
            let older = Task { await publisher.publish(canonical: 1, expectedOwnerBinding: "owner-a") }
            while resumeOlder == nil { await Task.yield() }
            liveNow = Date(timeIntervalSince1970: 2)
            await publisher.publish(canonical: 2, expectedOwnerBinding: "owner-a")
            expect(publisher.cachedSnapshot == "snapshot-2", "sanity: the newer publish completed and cached its snapshot")
            expect(observed == ["snapshot-2"], "sanity: the newer publish notified its observer")
            resumeOlder?.resume()
            _ = await older.value
            expect(publisher.cachedSnapshot == "snapshot-2",
                   "generation guard: the older publish resuming after the newer one does not overwrite the cache")
            expect(observed == ["snapshot-2"],
                   "generation guard: the older publish resuming after the newer one does not re-notify observers")
        }

        if failures > 0 {
            print("\(failures) background refresh test(s) failed")
            Foundation.exit(1)
        }
        print("Background refresh tests passed")
    }
}
