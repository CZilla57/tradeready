import Foundation
#if canImport(Darwin)
import Darwin
#endif

private final class MemoryInbox: NativeAppGroupInbox, @unchecked Sendable {
    var values: [String: String]
    var readCount = 0

    init(_ values: [String: String] = [:]) { self.values = values }

    func value(forKey key: String) -> String? {
        readCount += 1
        return values[key]
    }

    func removeValue(forKey key: String) {
        values[key] = nil
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

        // Task 11.06 (contract §6.1 native bound): oversized links and ids
        // that are not valid record identifiers are dropped before routing.
        let maxID = String(repeating: "x", count: 128)
        expect(NativeDeepLinkParser.parse("tradeready://job/\(maxID)") == .job(id: maxID),
               "a 128-byte id is accepted")
        expect(NativeDeepLinkParser.parse("tradeready://job/\(maxID)x") == nil,
               "a 129-byte id is rejected")
        expect(NativeDeepLinkParser.parse("tradeready://job/a%0Ab") == nil,
               "an id that decodes to a control character is rejected")
        expect(NativeDeepLinkParser.parse("tradeready://job/j1" + String(repeating: " ", count: 1100)) == nil,
               "a link over the 1024-byte bound is rejected even when it trims to a valid one")
        expect(NativeDeepLinkParser.parse(String(repeating: " ", count: 1000) + "tradeready://job/j1") == .job(id: "j1"),
               "…while one inside the bound still trims and parses")

        // The stash now carries `ownerTag` (§6.2); it is decoded, not required
        // by the parser (the consumer discards an untagged one).
        let tag = String(repeating: "ab", count: 32)
        func tagged(_ url: String, _ at: String, tag: String = tag) -> String {
            "{\"url\":\"\(url)\",\"at\":\"\(at)\",\"ownerTag\":\"\(tag)\"}"
        }
        expect(NativeDeepLinkParser.parsePendingOpenURL(tagged("tradeready://job/j1", "2026-08-03T17:59:00Z"), now: now)?.ownerTag == tag,
               "the stash's owner tag is decoded")
        expect(NativeDeepLinkParser.parsePendingOpenURL(stash("tradeready://job/j1", "2026-08-03T17:59:00Z"), now: now)?.ownerTag == nil,
               "an untagged stash parses with a nil tag")
        expect(NativeDeepLinkParser.parsePendingOpenURL(
            "{\"url\":\"tradeready://job/j1\",\"at\":\"2026-08-03T17:59:00Z\",\"ownerTag\":7}", now: now) == nil,
               "a non-string tag is malformed")
        let padded = "{\"url\":\"tradeready://job/j1\",\"at\":\"2026-08-03T17:59:00Z\",\"pad\":\""
            + String(repeating: "p", count: 4100) + "\"}"
        expect(NativeDeepLinkParser.parsePendingOpenURL(padded, now: now) == nil,
               "a stash over the 4096-byte bound is rejected before decoding")

        // The consumer reads AND removes in one hold of the shared lock,
        // whether or not the value is valid (§6.2 step 3).
        let lockDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-pending-open-url-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: lockDir) }
        let lockFile = lockDir.appendingPathComponent(WidgetAppGroup.lockFileName)
        func consumer(_ inbox: MemoryInbox) -> NativePendingOpenURLConsumer {
            NativePendingOpenURLConsumer(inbox: inbox, lockFile: lockFile)
        }
        let key = NativePendingOpenURLConsumer.key
        expect(key == WidgetAppGroup.pendingOpenURLKey, "the consumer reads the contract key")

        let good = tagged("tradeready://onmyway/j1", "2026-08-03T17:59:00Z")
        let goodInbox = MemoryInbox([key: good])
        if case .pending(let pending) = consumer(goodInbox).take(now: now) {
            expect(pending.route == .onMyWay(id: "j1") && pending.ownerTag == tag, "a fresh tagged stash is returned")
        } else { expect(false, "a fresh tagged stash is returned") }
        expect(goodInbox.values[key] == nil, "…and removed from the App Group")
        expect(consumer(goodInbox).take(now: now) == .nothingPending, "a second take finds nothing (presented at most once)")

        for (label, raw) in [
            ("untagged", stash("tradeready://job/j1", "2026-08-03T17:59:00Z")),
            ("stale", tagged("tradeready://job/j1", "2026-08-03T17:54:59Z")),
            ("future", tagged("tradeready://job/j1", "2026-08-03T18:00:01Z")),
            ("malformed", "not-json"),
            ("foreign grammar", tagged("tradeready://invoice/i1", "2026-08-03T17:59:00Z")),
            ("oversized", padded),
        ] {
            let inbox = MemoryInbox([key: raw, "widgetActions": "[]"])
            expect(consumer(inbox).take(now: now) == .discarded, "\(label) stash is discarded")
            expect(inbox.values[key] == nil, "\(label) stash is removed anyway (read, remove, then parse)")
            expect(inbox.values["widgetActions"] == "[]", "\(label): no other App Group key is touched")
        }

        // A lock that cannot be taken reads and removes nothing.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-pending-open-url-file-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let unavailableInbox = MemoryInbox([key: good])
        let unavailable = NativePendingOpenURLConsumer(
            inbox: unavailableInbox, lockFile: blocker.appendingPathComponent("sub/lock")
        ).take(now: now)
        expect(unavailable == .unavailable && unavailableInbox.values[key] == good && unavailableInbox.readCount == 0,
               "no lock → nothing read, nothing removed")

        // The warm dedupe removes the stash only when it names the same route.
        let dedupeInbox = MemoryInbox([key: good])
        let other = consumer(dedupeInbox).takeMatching(.onMyWay(id: "j2"))
        expect(!other.removed && dedupeInbox.values[key] == good, "a stash for a different route is left in place")
        let same = consumer(dedupeInbox).takeMatching(.onMyWay(id: "j1"))
        expect(same.removed && same.ownerTag == tag && dedupeInbox.values[key] == nil,
               "the matching stash is removed and its tag returned")
        let jobVsOnMyWay = MemoryInbox([key: good])
        expect(!consumer(jobVsOnMyWay).takeMatching(.job(id: "j1")).removed, "job/j1 does not match onmyway/j1")

        // The take waits for another holder of the SAME lock file (§4.2).
        try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        precondition(descriptor >= 0 && flock(descriptor, LOCK_EX) == 0)
        let lockedInbox = MemoryInbox([key: good])
        let finished = DispatchSemaphore(value: 0)
        Thread {
            _ = NativePendingOpenURLConsumer(inbox: lockedInbox, lockFile: lockFile).take(now: now)
            finished.signal()
        }.start()
        expect(finished.wait(timeout: .now() + 0.3) == .timedOut, "the take blocks while the lock is held")
        expect(lockedInbox.values[key] == good, "…and has not removed anything yet")
        flock(descriptor, LOCK_UN)
        close(descriptor)
        expect(finished.wait(timeout: .now() + 5) == .success && lockedInbox.values[key] == nil,
               "…then reads and removes once it is released")

        let suite = "tradeready-pending-open-url-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let realInbox = NativeUserDefaultsAppGroupInbox(defaults: defaults)
        defaults.set("first", forKey: NativePendingOpenURLConsumer.key)
        expect(realInbox.value(forKey: NativePendingOpenURLConsumer.key) == "first",
               "UserDefaults implementation reads")
        realInbox.removeValue(forKey: NativePendingOpenURLConsumer.key)
        expect(defaults.object(forKey: NativePendingOpenURLConsumer.key) == nil,
               "UserDefaults implementation removes")
        expect(NativeUserDefaultsAppGroupInbox.suiteName == "group.com.gettradereadyapp.tradeready",
               "production inbox uses the established App Group suite")

        for key in NativeAppGroupAccountScrubber.accountKeys {
            defaults.set("previous-account-value", forKey: key)
        }
        let scrubLockFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-app-group-scrub-\(UUID().uuidString)/actions.lock")
        try! NativeAppGroupAccountScrubber(
            suiteName: suite, defaults: defaults, lockFile: scrubLockFile
        ).scrub()
        expect(NativeAppGroupAccountScrubber.accountKeys.allSatisfy {
            defaults.object(forKey: $0) == nil
        }, "account scrub blanks every established app and extension surface")

        if failures == 0 { print("App Group pending-open-URL tests passed") }
        else { fatalError("\(failures) App Group pending-open-URL test(s) failed") }
    }
}
