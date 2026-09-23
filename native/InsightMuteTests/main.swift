import Foundation

// Insight mute tests (task 10.03, requirement S4).
//
// Ports `__tests__/insightMutes.test.ts` (pinned clock: Tue Aug 4 2026, 10:00
// local) plus the exact-owner store contract from `NativeReviewRequestStore`
// (atomic write + backup recovery, mismatch rejection, seed adoption).

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

private let august4 = NativeCashBasis.localDate(year: 2026, month: 7, day: 4, hour: 10)
private let today = "2026-08-04"
private let binding = String(repeating: "a", count: 64)
private let otherBinding = String(repeating: "b", count: 64)

// MARK: - Policy (insightMutes.test.ts)

private func testMakeMute() {
    let dismiss = NativeInsightMutes.makeMute(id: "low_margin:j1:1200", now: august4)
    expectEqual(dismiss.id, "low_margin:j1:1200", "the mute keeps the insight id")
    expectEqual(dismiss.until, nil, "a dismiss has no until")
    expect(dismiss.mutedAt.hasPrefix("2026-08-04T17:00:00"), "mutedAt is the ISO instant of now")

    expectEqual(NativeInsightMutes.makeMute(id: "maintenance_due:c1", now: august4, days: 30).until,
                "2026-09-03", "a 30-day snooze runs to today + 30")
    expectEqual(NativeInsightMutes.makeMute(id: "maintenance_due:c1", now: august4, days: 1).until,
                "2026-08-05", "a 1-day snooze runs to tomorrow")
    expectEqual(NativeInsightMutes.makeMute(id: "x", now: august4, days: 0).until, nil,
                "a zero-day snooze is a dismiss")
}

private func testIsMuteActive() {
    expect(NativeInsightMutes.isMuteActive(.init(id: "x", mutedAt: "2026-08-04T17:00:00.000Z"), today: today),
           "a permanent dismiss is always active")
    let snooze = NativeInsightMute(id: "x", mutedAt: "2026-08-04T17:00:00.000Z", until: "2026-08-05")
    expect(NativeInsightMutes.isMuteActive(snooze, today: "2026-08-04"), "a snooze is active before its day")
    expect(!NativeInsightMutes.isMuteActive(snooze, today: "2026-08-05"), "a snooze expires on its day")
    expect(!NativeInsightMutes.isMuteActive(snooze, today: "2026-08-06"), "and stays expired")
}

private func testFilterMuted() {
    let insights = ["a", "b", "c", "d"]
    let muteB = NativeInsightMute(id: "b", mutedAt: "2026-08-04T17:00:00.000Z")
    expectEqual(
        NativeInsightMutes.filterMuted(insights, mutes: [muteB], now: august4, id: { $0 }),
        ["a", "c", "d"],
        "an actively-muted insight is dropped, order preserved (top-3 backfill)"
    )
    let expired = NativeInsightMute(id: "b", mutedAt: "2026-08-04T17:00:00.000Z", until: "2026-08-04")
    expectEqual(
        NativeInsightMutes.filterMuted(insights, mutes: [expired], now: august4, id: { $0 }),
        ["a", "b", "c", "d"],
        "an expired snooze no longer hides its insight"
    )
    expectEqual(NativeInsightMutes.filterMuted(insights, mutes: [], now: august4, id: { $0 }),
                insights, "no mutes is a pass-through")
}

private func testPrune() {
    let keep = NativeInsightMute(id: "keep", mutedAt: "2026-08-04T17:00:00.000Z")
    let expired = NativeInsightMute(id: "old", mutedAt: "2026-08-04T17:00:00.000Z", until: "2026-08-01")
    let stale = NativeInsightMute(id: "gone", mutedAt: "2026-08-04T17:00:00.000Z")
    expectEqual(NativeInsightMutes.prune([keep, expired], today: today), [keep],
                "expired snoozes are pruned")
    expectEqual(NativeInsightMutes.prune([keep, stale], today: today, liveIDs: ["keep"]), [keep],
                "mutes for insights the engine no longer emits are pruned")
    expectEqual(NativeInsightMutes.prune([keep, stale], today: today), [keep, stale],
                "without live ids every non-expired mute is kept")
}

private func testApplyingMute() {
    let existing = [
        NativeInsightMute(id: "keep", mutedAt: "2026-08-01T00:00:00.000Z"),
        NativeInsightMute(id: "expired", mutedAt: "2026-08-01T00:00:00.000Z", until: "2026-08-02"),
        NativeInsightMute(id: "no-longer-live", mutedAt: "2026-08-01T00:00:00.000Z"),
    ]
    let applied = NativeInsightMutes.applying(
        id: "maintenance_due:c9", now: august4, days: 30,
        liveIDs: ["keep", "maintenance_due:c9"], to: existing
    )
    expectEqual(applied.map(\.id), ["keep", "maintenance_due:c9"],
                "applying prunes expired + stale mutes and appends the new one")
    expectEqual(applied.last?.until, "2026-09-03", "the new mute is a 30-day snooze")

    let remuted = NativeInsightMutes.applying(
        id: "x", now: august4,
        to: [NativeInsightMute(id: "x", mutedAt: "2026-08-01T00:00:00.000Z", until: "2026-08-10")]
    )
    expectEqual(remuted.count, 1, "re-muting the same id replaces instead of stacking")
    expectEqual(remuted.first?.until, nil, "and the replacement is the new dismiss")

    expectEqual(NativeInsightMutes.sanitized([.init(id: "a", mutedAt: "x"), .init(id: "  ", mutedAt: "x")])
                    .map(\.id), ["a"], "blank ids are dropped on read")
}

private func testShiftDateLocalFrame() {
    expectEqual(NativeInsightMutes.shift(dateString: "2026-08-31", days: 1), "2026-09-01",
                "shift rolls a month boundary")
    expectEqual(NativeInsightMutes.shift(dateString: "2026-01-01", days: -1), "2025-12-31",
                "shift rolls a year boundary backwards")
    expectEqual(NativeInsightMutes.shift(dateString: "not-a-date", days: 3), "not-a-date",
                "an unparseable date is returned unchanged")
}

// MARK: - Store

private func testStoreRoundTripAndRecovery() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-insight-mutes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NativeInsightMuteStore(fileURL: directory.appendingPathComponent("insight-mutes.json"))

    expectEqual(try store.load(for: binding), [], "a missing store reads as no mutes")
    let mute = NativeInsightMute(id: "maintenance_due:c1", mutedAt: "2026-08-04T17:00:00.000Z", until: "2026-09-03")
    try store.save([mute], for: binding)
    expectEqual(try store.load(for: binding), [mute], "the store round-trips")

    // Mismatched / invalid bindings fail closed.
    var mismatched = false
    do { _ = try store.load(for: otherBinding) }
    catch NativeInsightMuteStoreError.accountBindingMismatch { mismatched = true }
    catch { }
    expect(mismatched, "a mismatched account binding is refused")

    var invalidBinding = false
    do { _ = try store.load(for: "short") }
    catch NativeInsightMuteStoreError.invalidAccountBinding { invalidBinding = true }
    catch { }
    expect(invalidBinding, "an invalid account binding is refused")

    // The last-known-good backup covers a missing/torn primary: each save keeps
    // the previous bytes beside the new file.
    try store.save([mute], for: binding)
    try store.save([mute], for: binding)
    try FileManager.default.removeItem(at: store.fileURL)
    expectEqual(try store.load(for: binding), [mute], "a missing primary recovers from the backup")

    // A corrupt primary fails closed: reads refuse (never silently "no mutes",
    // which would resurrect dismissed rows) and writes refuse until cleared.
    try store.save([mute], for: binding)
    try Data("{not-json".utf8).write(to: store.fileURL, options: .atomic)
    var unreadable = false
    do { _ = try store.load(for: binding) }
    catch NativeInsightMuteStoreError.unreadableStore { unreadable = true }
    catch { }
    expect(unreadable, "a corrupt primary fails closed on read")
    var writeRefused = false
    do { try store.save([mute], for: binding) } catch { writeRefused = true }
    expect(writeRefused, "a corrupt primary refuses further writes until it is cleared")

    try store.removeAll()
    expectEqual(try store.load(for: binding), [], "removeAll wipes the store and its backup")
}

private func testStoreAppliesAndAdoptsSeeds() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-insight-mute-adopt-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NativeInsightMuteStore(fileURL: directory.appendingPathComponent("insight-mutes.json"))

    let applied = try store.applyMute(
        id: "low_margin:j1:1200", now: august4, for: binding
    )
    expectEqual(applied.map(\.id), ["low_margin:j1:1200"], "applyMute persists the new mute")
    let snoozed = try store.applyMute(
        id: "maintenance_due:c1", now: august4, days: 30,
        liveIDs: ["low_margin:j1:1200", "maintenance_due:c1"], for: binding
    )
    expectEqual(snoozed.map(\.id), ["low_margin:j1:1200", "maintenance_due:c1"],
                "a second mute appends behind the first")

    // Seed adoption: existing owner mutes win; seeded mutes fill only new ids.
    let seeded = [
        NativeInsightMute(id: "maintenance_due:c1", mutedAt: "2026-01-01T00:00:00.000Z"),
        NativeInsightMute(id: "expense_anomaly:2026-01", mutedAt: "2026-01-02T00:00:00.000Z"),
    ]
    let merged = try store.mergeSeeded(seeded, for: binding)
    expectEqual(merged.count, 3, "the seed adds only ids this device never muted")
    expectEqual(merged.first { $0.id == "maintenance_due:c1" }?.mutedAt,
                "2026-08-04T17:00:00.000Z", "the stored owner record wins for a seeded id")
    expectEqual(try store.mergeSeeded(seeded, for: binding).count, 3, "a repeat adoption is stable")

    // Duplicate ids in a document keep the newest write instead of failing.
    let duplicateDocument = """
    {"schemaVersion":1,"accountBinding":"\(binding)","mutes":[
      {"id":"x","mutedAt":"2026-01-01T00:00:00.000Z","until":"2026-01-05"},
      {"id":"x","mutedAt":"2026-02-01T00:00:00.000Z"}]}
    """
    try Data(duplicateDocument.utf8).write(to: store.fileURL, options: .atomic)
    expectEqual(try store.load(for: binding), [.init(id: "x", mutedAt: "2026-02-01T00:00:00.000Z")],
                "a duplicate id keeps the newest write")
}

// MARK: - Runner

testMakeMute()
testIsMuteActive()
testFilterMuted()
testPrune()
testApplyingMute()
testShiftDateLocalFrame()
try testStoreRoundTripAndRecovery()
try testStoreAppliesAndAdoptsSeeds()

if failures == 0 {
    print("InsightMuteTests: all checks passed")
} else {
    print("InsightMuteTests: \(failures) failure(s)")
    exit(1)
}
