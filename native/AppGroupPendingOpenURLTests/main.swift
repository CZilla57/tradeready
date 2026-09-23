import Foundation

private final class MemoryInbox: NativeAppGroupInbox {
    var values: [String: String]
    var readCount = 0

    init(_ values: [String: String] = [:]) { self.values = values }

    func value(forKey key: String) -> String? {
        readCount += 1
        return values[key]
    }

}

@main
struct AppGroupPendingOpenURLTests {
    static func main() {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        expect(NativeDeepLinkParser.parse("tradeready://job/j1") == .job(id: "j1"),
               "job link parses")
        expect(NativeDeepLinkParser.parse(" TradeReady://onmyway/a%2Fb ") == .onMyWay(id: "a/b"),
               "on-my-way link is case insensitive and decodes one encoded segment")
        expect(NativeDeepLinkParser.parse("tradeready://job/a%2Bb") == .job(id: "a+b"),
               "encoded plus remains part of the identifier")
        for malformed in [
            "tradeready://job/", "tradeready://job/a/b", "tradeready://job/a?x=1",
            "tradeready://job/a#x", "tradeready://invoice/i1", "other://job/j1",
            "https://gettradereadyapp.com/job/j1", "tradeready://job/%zz"
        ] {
            expect(NativeDeepLinkParser.parse(malformed) == nil, "malformed link is rejected")
        }

        let now = ISO8601DateFormatter().date(from: "2026-08-03T18:00:00Z")!
        func stash(_ url: String, _ at: String) -> String {
            "{\"url\":\"\(url)\",\"at\":\"\(at)\"}"
        }
        expect(NativeDeepLinkParser.parsePendingOpenURL(
            stash("tradeready://job/j1", "2026-08-03T17:55:00Z"), now: now
        )?.route == .job(id: "j1"), "exact five-minute boundary is accepted")
        expect(NativeDeepLinkParser.parsePendingOpenURL(
            stash("tradeready://job/j1", "2026-08-03T17:59:30.512Z"), now: now
        ) != nil, "fractional timestamp is accepted")
        expect(NativeDeepLinkParser.parsePendingOpenURL(
            stash("tradeready://job/j1", "2026-08-03T17:54:59Z"), now: now
        ) == nil, "stale handoff is rejected")
        expect(NativeDeepLinkParser.parsePendingOpenURL(
            stash("tradeready://job/j1", "2026-08-03T18:00:01Z"), now: now
        ) == nil, "future handoff is rejected")
        for malformed in [
            "not-json", "[]", "{}", "{\"url\":7,\"at\":false}",
            stash("other://job/j1", "2026-08-03T18:00:00Z")
        ] {
            expect(NativeDeepLinkParser.parsePendingOpenURL(malformed, now: now) == nil,
                   "malformed pending handoff is rejected as one boundary")
        }

        let pendingJob = stash("tradeready://job/j1", "2026-08-03T17:59:00Z")
        let unverified = MemoryInbox([NativePendingOpenURLConsumer.key: pendingJob])
        let unverifiedResult = NativePendingOpenURLConsumer(inbox: unverified).consume(
            localOwnerVerified: false, now: now, jobExists: { _ in true },
            routeToJob: { _ in }, presentOnMyWay: { _ in }
        )
        expect(unverifiedResult == .notAuthorized && unverified.readCount == 0
               && unverified.values[NativePendingOpenURLConsumer.key] == pendingJob,
               "unverified identity neither reads nor clears the handoff")

        let routable = MemoryInbox([NativePendingOpenURLConsumer.key: pendingJob])
        var routed: [String] = []
        let routedResult = NativePendingOpenURLConsumer(inbox: routable).consume(
            localOwnerVerified: true, now: now,
            jobExists: { $0 == "j1" }, routeToJob: { routed.append($0) },
            presentOnMyWay: { _ in }
        )
        expect(routedResult == .routedJob(id: "j1") && routed == ["j1"]
               && routable.values[NativePendingOpenURLConsumer.key] == pendingJob,
               "verified existing job routes without mutating cross-process state")

        let onMyWayRaw = stash("tradeready://onmyway/j1", "2026-08-03T17:59:00Z")
        let onMyWay = MemoryInbox([NativePendingOpenURLConsumer.key: onMyWayRaw])
        var presented: [String] = []
        let onMyWayResult = NativePendingOpenURLConsumer(inbox: onMyWay).consume(
            localOwnerVerified: true, now: now, jobExists: { $0 == "j1" },
            routeToJob: { routed.append($0) }, presentOnMyWay: { presented.append($0) }
        )
        expect(onMyWayResult == .presentedOnMyWay(id: "j1") && presented == ["j1"]
               && onMyWay.values[NativePendingOpenURLConsumer.key] == onMyWayRaw,
               "valid on-my-way handoff presents once without changing the source")

        let missing = MemoryInbox([NativePendingOpenURLConsumer.key: pendingJob])
        let missingResult = NativePendingOpenURLConsumer(inbox: missing).consume(
            localOwnerVerified: true, now: now, jobExists: { _ in false },
            routeToJob: { routed.append($0) }, presentOnMyWay: { presented.append($0) }
        )
        expect(missingResult == .retainedMissingJob
               && missing.values[NativePendingOpenURLConsumer.key] == pendingJob,
               "handoff for a missing job is retained without routing")

        let poison = MemoryInbox([NativePendingOpenURLConsumer.key: "not-json"])
        let poisonResult = NativePendingOpenURLConsumer(inbox: poison).consume(
            localOwnerVerified: true, now: now, jobExists: { _ in true },
            routeToJob: { routed.append($0) }, presentOnMyWay: { presented.append($0) }
        )
        expect(poisonResult == .retainedInvalid
               && poison.values[NativePendingOpenURLConsumer.key] == "not-json",
               "malformed cross-process state is ignored without mutation")

        let suite = "tradeready-pending-open-url-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let realInbox = NativeUserDefaultsAppGroupInbox(defaults: defaults)
        defaults.set("first", forKey: NativePendingOpenURLConsumer.key)
        expect(realInbox.value(forKey: NativePendingOpenURLConsumer.key) == "first",
               "UserDefaults implementation reads without consuming")
        expect(NativeUserDefaultsAppGroupInbox.suiteName == "group.com.gettradereadyapp.tradeready",
               "production inbox uses the established App Group suite")

        for key in NativeAppGroupAccountScrubber.accountKeys {
            defaults.set("previous-account-value", forKey: key)
        }
        let lockFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-app-group-scrub-\(UUID().uuidString)/actions.lock")
        try! NativeAppGroupAccountScrubber(
            suiteName: suite, defaults: defaults, lockFile: lockFile
        ).scrub()
        expect(NativeAppGroupAccountScrubber.accountKeys.allSatisfy {
            defaults.object(forKey: $0) == nil
        }, "account scrub blanks every established app and extension surface")

        if failures == 0 { print("App Group pending-open-URL tests passed") }
        else { fatalError("\(failures) App Group pending-open-URL test(s) failed") }
    }
}
