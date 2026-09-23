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

        if failures > 0 {
            print("\(failures) background refresh test(s) failed")
            Foundation.exit(1)
        }
        print("Background refresh tests passed")
    }
}
