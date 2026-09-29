import Foundation

// App Store rating prompt tests (native-only; RN never asked for a rating).
//
// The policy decides WHEN to ask; StoreKit decides whether the system sheet
// actually appears (Apple caps it at three a year per device). So these tests
// pin our side only: count owner wins, ask on a get-paid moment once the owner
// has real use behind them, never twice in one app version, and never inside
// the cooldown.

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

private let september1 = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01T00:00:00Z
private func days(_ count: Double) -> TimeInterval { count * 86_400 }

private func state(wins: Int, version: String? = nil, at: Date? = nil) -> NativeAppRatingPromptState {
    NativeAppRatingPromptState(winCount: wins, lastPromptedVersion: version, lastPromptedAt: at)
}

// MARK: - Policy

private func testRecordingCountsEveryWin() {
    let once = NativeAppRatingPromptPolicy.recording(.estimateSent, in: .initial)
    let twice = NativeAppRatingPromptPolicy.recording(.invoicePaid, in: once)
    expectEqual(once.winCount, 1, "an estimate sent is a win")
    expectEqual(twice.winCount, 2, "an invoice paid is a win")
    expectEqual(twice.lastPromptedVersion, nil, "recording never stamps a prompt")
}

private func testPaidMomentNeedsThreeWins() {
    expect(!NativeAppRatingPromptPolicy.shouldPrompt(
        after: .invoicePaid, state: state(wins: 2), appVersion: "1.3", now: september1),
        "two wins is too early to ask")
    expect(NativeAppRatingPromptPolicy.shouldPrompt(
        after: .invoicePaid, state: state(wins: 3), appVersion: "1.3", now: september1),
        "the third win, landing on a paid invoice, asks")
}

private func testEstimateSentOnlyAsksAtTheFallbackThreshold() {
    expect(!NativeAppRatingPromptPolicy.shouldPrompt(
        after: .estimateSent, state: state(wins: 3), appVersion: "1.3", now: september1),
        "an estimate send is not the moment to ask while a paid moment can still come")
    expect(!NativeAppRatingPromptPolicy.shouldPrompt(
        after: .estimateSent, state: state(wins: 9), appVersion: "1.3", now: september1),
        "nine wins without a paid moment still waits")
    expect(NativeAppRatingPromptPolicy.shouldPrompt(
        after: .estimateSent, state: state(wins: 10), appVersion: "1.3", now: september1),
        "an owner who never records payments in-app is asked at ten wins")
}

private func testNeverTwiceInOneVersion() {
    let askedThisVersion = state(wins: 20, version: "1.3", at: september1 - days(365))
    expect(!NativeAppRatingPromptPolicy.shouldPrompt(
        after: .invoicePaid, state: askedThisVersion, appVersion: "1.3", now: september1),
        "an owner already asked in this version is not asked again")
}

private func testCooldownAcrossVersions() {
    let recent = state(wins: 20, version: "1.2", at: september1 - days(119))
    let stale = state(wins: 20, version: "1.2", at: september1 - days(120))
    expect(!NativeAppRatingPromptPolicy.shouldPrompt(
        after: .invoicePaid, state: recent, appVersion: "1.3", now: september1),
        "a new version inside the 120-day cooldown does not ask")
    expect(NativeAppRatingPromptPolicy.shouldPrompt(
        after: .invoicePaid, state: stale, appVersion: "1.3", now: september1),
        "a new version after the cooldown asks again")
}

private func testClockRollbackStaysInCooldown() {
    let future = state(wins: 20, version: "1.2", at: september1 + days(30))
    expect(!NativeAppRatingPromptPolicy.shouldPrompt(
        after: .invoicePaid, state: future, appVersion: "1.3", now: september1),
        "a last-asked date in the future (clock moved back) is treated as recent")
}

private func testMarkingPromptedStampsVersionAndDate() {
    let stamped = NativeAppRatingPromptPolicy.markingPrompted(
        state(wins: 3), appVersion: "1.3", now: september1)
    expectEqual(stamped.lastPromptedVersion, "1.3", "the prompt stamps the app version")
    expectEqual(stamped.lastPromptedAt, september1, "the prompt stamps the date")
    expectEqual(stamped.winCount, 3, "stamping keeps the win count")
}

// MARK: - Store

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "tradeready.tests.app-rating.\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func testStoreRoundTrip() {
    let defaults = freshDefaults("roundtrip")
    let store = NativeAppRatingPromptStore(defaults: defaults)
    expectEqual(store.load(), NativeAppRatingPromptState.initial, "an empty store loads the initial state")
    let saved = state(wins: 4, version: "1.3", at: september1)
    store.save(saved)
    expectEqual(NativeAppRatingPromptStore(defaults: defaults).load(), saved,
                "state survives a new store instance (app relaunch)")
}

private func testStoreRecoversFromCorruptData() {
    let defaults = freshDefaults("corrupt")
    defaults.set(Data("not json".utf8), forKey: NativeAppRatingPromptStore.key)
    expectEqual(NativeAppRatingPromptStore(defaults: defaults).load(), NativeAppRatingPromptState.initial,
                "unreadable state starts over rather than blocking the prompt forever")
}

// MARK: - Coordinator

@MainActor
private func makeCoordinator(
    _ defaults: UserDefaults,
    version: String = "1.3",
    now: Date = september1
) -> NativeAppRatingPromptCoordinator {
    NativeAppRatingPromptCoordinator(
        store: NativeAppRatingPromptStore(defaults: defaults),
        appVersion: version,
        now: { now }
    )
}

@MainActor
private func testCoordinatorRequestsOnTheThirdPaidWin() {
    let coordinator = makeCoordinator(freshDefaults("third"))
    coordinator.recordWin(.estimateSent)
    coordinator.recordWin(.invoicePaid)
    expect(!coordinator.isRequestPending, "two wins do not request a prompt")
    coordinator.recordWin(.invoicePaid)
    expect(coordinator.isRequestPending, "the third win on a paid invoice requests a prompt")
}

@MainActor
private func testCoordinatorPresentsOnceAndStamps() {
    let defaults = freshDefaults("present")
    let coordinator = makeCoordinator(defaults)
    for _ in 0..<3 { coordinator.recordWin(.invoicePaid) }
    expect(coordinator.beginPresentation(), "a pending request presents")
    expect(!coordinator.isRequestPending, "presenting clears the pending request")
    expect(!coordinator.beginPresentation(), "a second presentation without a new request is refused")
    expectEqual(NativeAppRatingPromptStore(defaults: defaults).load().lastPromptedVersion, "1.3",
                "presenting persists the version stamp before the system sheet is asked for")

    coordinator.recordWin(.invoicePaid)
    expect(!coordinator.isRequestPending, "a later win in the same version never re-requests")
}

@MainActor
private func testCoordinatorDoesNotStampUntilPresented() {
    let defaults = freshDefaults("unpresented")
    let coordinator = makeCoordinator(defaults)
    for _ in 0..<3 { coordinator.recordWin(.invoicePaid) }
    expectEqual(NativeAppRatingPromptStore(defaults: defaults).load().lastPromptedVersion, nil,
                "a request that never reached the screen (app backgrounded) burns nothing")

    let relaunched = makeCoordinator(defaults)
    expect(!relaunched.isRequestPending, "a pending request does not survive a relaunch")
    relaunched.recordWin(.invoicePaid)
    expect(relaunched.isRequestPending, "the next paid win after relaunch asks again")
}

@MainActor
private func testCoordinatorPersistsWinsAcrossLaunches() {
    let defaults = freshDefaults("persist")
    makeCoordinator(defaults).recordWin(.estimateSent)
    makeCoordinator(defaults).recordWin(.estimateSent)
    let third = makeCoordinator(defaults)
    third.recordWin(.invoicePaid)
    expect(third.isRequestPending, "wins accumulate across launches")
}

@MainActor
private func testCoordinatorRespectsCooldownFromAnEarlierVersion() {
    let defaults = freshDefaults("cooldown")
    let v12 = makeCoordinator(defaults, version: "1.2", now: september1)
    for _ in 0..<3 { v12.recordWin(.invoicePaid) }
    _ = v12.beginPresentation()

    let v13Soon = makeCoordinator(defaults, version: "1.3", now: september1 + days(30))
    v13Soon.recordWin(.invoicePaid)
    expect(!v13Soon.isRequestPending, "an update 30 days later does not re-ask")

    let v13Later = makeCoordinator(defaults, version: "1.3", now: september1 + days(121))
    v13Later.recordWin(.invoicePaid)
    expect(v13Later.isRequestPending, "an update past the cooldown asks again")
}

testRecordingCountsEveryWin()
testPaidMomentNeedsThreeWins()
testEstimateSentOnlyAsksAtTheFallbackThreshold()
testNeverTwiceInOneVersion()
testCooldownAcrossVersions()
testClockRollbackStaysInCooldown()
testMarkingPromptedStampsVersionAndDate()
testStoreRoundTrip()
testStoreRecoversFromCorruptData()
MainActor.assumeIsolated {
    testCoordinatorRequestsOnTheThirdPaidWin()
    testCoordinatorPresentsOnceAndStamps()
    testCoordinatorDoesNotStampUntilPresented()
    testCoordinatorPersistsWinsAcrossLaunches()
    testCoordinatorRespectsCooldownFromAnEarlierVersion()
}

if failures > 0 {
    print("App rating prompt tests failed: \(failures)")
    exit(1)
}
print("App rating prompt tests passed")
