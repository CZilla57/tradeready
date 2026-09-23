import Foundation

// Setup checklist tests (task 10.03, requirements D4, D5).
//
// Ports `__tests__/setupChecklist.test.js` (derivation, idempotent writes,
// dismissal, sample-tour flag, the shared `isSetupComplete` gate) plus the
// exact-owner store contract (atomic write + backup recovery, mismatch
// rejection, seed adoption) and the reminder-prompt flag.

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

private let binding = String(repeating: "c", count: 64)
private let otherBinding = String(repeating: "d", count: 64)

/// `baseSettings` from the oracle.
private func input(
    phone: String = "",
    address: String = "",
    logoPhoto: String? = nil,
    provider: String = "stripe",
    providerKeys: [String: String] = [:]
) -> NativeSetupChecklistInput {
    NativeSetupChecklistInput(
        phone: phone, address: address, logoPhoto: logoPhoto,
        provider: provider, providerKeys: providerKeys
    )
}

private func task(_ tasks: [NativeSetupTask], _ id: NativeSetupTaskID) -> NativeSetupTask? {
    tasks.first { $0.id == id }
}

// MARK: - deriveSetupTasks

private func testDerivation() {
    let fresh = input().tasks(state: NativeSetupChecklistState(), notificationsGranted: false)
    expectEqual(fresh.count, 5, "the checklist has five tasks")
    expect(fresh.allSatisfy { !$0.done }, "fresh settings complete nothing")
    expectEqual(fresh.map(\.id), NativeSetupTaskID.allCases, "task order is fixed")
    expectEqual(fresh.first?.title, "Add your contact details", "task titles match RN")
    expectEqual(fresh.first?.subtitle, "Phone and address appear on invoices and estimates.",
                "task subtitles match RN")

    // contact derives from phone AND address.
    expectEqual(task(input(phone: "(555) 111-2222").tasks(state: NativeSetupChecklistState(), notificationsGranted: false), .contact)?.done,
                false, "a phone alone is not enough")
    expectEqual(task(input(phone: "(555) 111-2222", address: "1 Main St").tasks(state: NativeSetupChecklistState(), notificationsGranted: false), .contact)?.done,
                true, "phone + address completes the contact task")
    expectEqual(task(input(phone: "   ", address: "1 Main St").tasks(state: NativeSetupChecklistState(), notificationsGranted: false), .contact)?.done,
                false, "whitespace does not count as a phone")

    // logo derives from logoPhoto.
    expectEqual(task(input(logoPhoto: "file://logo.png").tasks(state: NativeSetupChecklistState(), notificationsGranted: false), .logo)?.done,
                true, "a stored logo completes the logo task")
    expectEqual(task(input(logoPhoto: "").tasks(state: NativeSetupChecklistState(), notificationsGranted: false), .logo)?.done,
                false, "an empty logo path does not")

    // rate completes only via recorded state.
    expectEqual(task(input().tasks(state: NativeSetupChecklistState(), notificationsGranted: false), .rate)?.done,
                false, "the pricing task has no derivation")
    expectEqual(task(input().tasks(state: NativeSetupChecklistState(done: ["rate": true]), notificationsGranted: false), .rate)?.done,
                true, "saving the pricing page completes it")

    // stripe completes via recorded status OR a configured alternative processor.
    expectEqual(task(input().tasks(state: NativeSetupChecklistState(done: ["stripe": true]), notificationsGranted: false), .stripe)?.done,
                true, "a recorded connect status completes the processor task")
    let venmo = input(provider: "venmo", providerKeys: ["venmo": "jo-the-plumber"])
    expectEqual(task(venmo.tasks(state: NativeSetupChecklistState(), notificationsGranted: false), .stripe)?.done,
                true, "a configured alternative processor completes it")
    let mismatched = input(provider: "venmo", providerKeys: ["paypal": "jo"])
    expectEqual(task(mismatched.tasks(state: NativeSetupChecklistState(), notificationsGranted: false), .stripe)?.done,
                false, "a key for a different provider does not count")
    let stripeKeyOnly = input(provider: "stripe", providerKeys: ["stripe": "sk_live"])
    expectEqual(task(stripeKeyOnly.tasks(state: NativeSetupChecklistState(), notificationsGranted: false), .stripe)?.done,
                false, "a stripe key is not the connect-status signal")

    // notifications derives from the granted flag.
    expectEqual(task(input().tasks(state: NativeSetupChecklistState(), notificationsGranted: true), .notifications)?.done,
                true, "a granted permission completes the reminders task")
}

// MARK: - isSetupComplete

private func testIsSetupComplete() {
    let done = input(phone: "555-0100", address: "1 Main St", logoPhoto: "file:///logo.png")
    expect(done.isSetupComplete(state: NativeSetupChecklistState(dismissed: true), notificationsGranted: false),
           "a dismissal completes the checklist regardless of task state")
    let recorded = NativeSetupChecklistState(done: ["rate": true, "stripe": true])
    expect(done.isSetupComplete(state: recorded, notificationsGranted: true),
           "all five tasks done completes it")
    expect(!done.isSetupComplete(state: recorded, notificationsGranted: false),
           "an open notifications task keeps it incomplete")
    let noLogo = input(phone: "555-0100", address: "1 Main St", logoPhoto: nil)
    expect(!noLogo.isSetupComplete(state: recorded, notificationsGranted: true),
           "an open logo task keeps it incomplete")
}

// MARK: - State transitions

private func testStateTransitions() {
    let recorded = NativeSetupChecklist.markingDone(.rate, in: NativeSetupChecklistState(done: ["stripe": true]))
    expectEqual(recorded.done, ["stripe": true, "rate": true], "marking a task preserves existing state")
    expectEqual(NativeSetupChecklist.dismissing(NativeSetupChecklistState(done: ["stripe": true])),
                NativeSetupChecklistState(dismissed: true, done: ["stripe": true]),
                "dismissing keeps recorded completions")
    expectEqual(NativeSetupChecklist.markingSampleTourDone(NativeSetupChecklistState()).sampleTourDone, true,
                "the sample tour flag can be set")

    // Seed merge: stored owner state wins field by field.
    let seed = NativeSetupChecklistState(dismissed: false, done: ["rate": true], sampleTourDone: true)
    let stored = NativeSetupChecklistState(dismissed: true, done: ["stripe": true], sampleTourDone: nil)
    let merged = NativeSetupChecklist.mergingSeed(seed, into: stored)
    expectEqual(merged.dismissed, true, "a stored dismissal wins over the seed")
    expectEqual(merged.sampleTourDone, true, "an unset stored flag adopts the seed")
    expectEqual(merged.done, ["rate": true, "stripe": true], "recorded tasks merge with stored winning per key")

    let empty = NativeSetupChecklist.mergingSeed(NativeSetupChecklistState(), into: NativeSetupChecklistState())
    expectEqual(empty.done, nil, "an all-empty merge keeps the absent record absent")
}

// MARK: - Routes

private func testRoutes() {
    expectEqual(NativeSetupChecklist.route(for: .contact), .business, "contact routes to Business settings")
    expectEqual(NativeSetupChecklist.route(for: .logo), .business, "logo routes to Business settings")
    expectEqual(NativeSetupChecklist.route(for: .rate), .pricing, "rate routes to Pricing settings")
    expectEqual(NativeSetupChecklist.route(for: .stripe), .payments, "stripe routes to Payments settings")
    expectEqual(NativeSetupChecklist.route(for: .notifications), .settings, "notifications falls back to Settings")
}

// MARK: - Stores

private func testChecklistStore() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-setup-checklist-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NativeSetupChecklistStore(fileURL: directory.appendingPathComponent("setup-checklist.json"))

    expectEqual(try store.load(for: binding), NativeSetupChecklistState(), "a missing store reads as empty state")
    let withRate = try store.markTaskDone(.rate, for: binding)
    expectEqual(withRate.done, ["rate": true], "recording a task persists it")
    let unchanged = try store.markTaskDone(.rate, for: binding)
    expectEqual(unchanged, withRate, "re-recording a task does not change the state")

    var mismatched = false
    do { _ = try store.load(for: otherBinding) }
    catch NativeSetupChecklistStoreError.accountBindingMismatch { mismatched = true }
    catch { }
    expect(mismatched, "a mismatched account binding is refused")

    let dismissed = try store.dismiss(for: binding)
    expectEqual(dismissed, NativeSetupChecklistState(dismissed: true, done: ["rate": true]),
                "dismissal keeps recorded completions")
    let tour = try store.markSampleTourDone(for: binding)
    expectEqual(tour.sampleTourDone, true, "the sample tour flag persists once")
    expectEqual(try store.markSampleTourDone(for: binding).sampleTourDone, true, "and is idempotent")

    // The last-known-good backup covers a missing/torn primary.
    try store.save(NativeSetupChecklistState(done: ["stripe": true]), for: binding)
    try store.save(NativeSetupChecklistState(done: ["stripe": true]), for: binding)
    try FileManager.default.removeItem(at: store.fileURL)
    expectEqual(try store.load(for: binding).done, ["stripe": true], "a missing primary recovers from the backup")

    // A corrupt primary fails closed rather than silently reading as empty state.
    try store.save(NativeSetupChecklistState(done: ["stripe": true]), for: binding)
    try Data("{not-json".utf8).write(to: store.fileURL, options: .atomic)
    var unreadable = false
    do { _ = try store.load(for: binding) }
    catch NativeSetupChecklistStoreError.unreadableStore { unreadable = true }
    catch { }
    expect(unreadable, "a corrupt primary fails closed on read")
    var writeRefused = false
    do { try store.save(NativeSetupChecklistState(), for: binding) } catch { writeRefused = true }
    expect(writeRefused, "a corrupt primary refuses further writes until it is cleared")

    try store.removeAll()
    expectEqual(try store.load(for: binding), NativeSetupChecklistState(), "removeAll wipes the store")
}

private func testChecklistSeedAdoption() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-setup-adopt-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NativeSetupChecklistStore(fileURL: directory.appendingPathComponent("setup-checklist.json"))

    _ = try store.markTaskDone(.stripe, for: binding)
    let seed = NativeSetupChecklistState(dismissed: true, done: ["rate": true], sampleTourDone: true)
    let merged = try store.mergeSeeded(seed, for: binding)
    expectEqual(merged.dismissed, true, "the seed's dismissal is adopted when the owner has none")
    expectEqual(merged.sampleTourDone, true, "the seed's sample-tour flag is adopted")
    expectEqual(merged.done, ["rate": true, "stripe": true], "recorded tasks merge")
    expectEqual(try store.load(for: binding), merged, "the adoption is persisted")
}

private func testReminderPromptStore() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-reminder-prompt-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NativeReminderPromptStore(fileURL: directory.appendingPathComponent("reminder-prompt.json"))

    expectEqual(try store.wasShown(for: binding), false, "a fresh binding has not been asked")
    expectEqual(try store.markShown(for: binding), true, "marking stamps the flag before the prompt shows")
    expectEqual(try store.wasShown(for: binding), true, "the flag is durable")
    expectEqual(try store.mergeSeeded(false, for: binding), true, "a false seed never clears a live flag")
    expectEqual(try store.wasShown(for: binding), true, "and the live value stays true")

    let freshDirectory = directory.appendingPathComponent("fresh.json")
    let freshStore = NativeReminderPromptStore(fileURL: freshDirectory)
    expectEqual(try freshStore.mergeSeeded(true, for: binding), true, "a true seed stamps the flag once")
    expectEqual(try freshStore.wasShown(for: binding), true, "the seeded flag persists")

    var mismatched = false
    do { _ = try freshStore.wasShown(for: otherBinding) }
    catch NativeSetupChecklistStoreError.accountBindingMismatch { mismatched = true }
    catch { }
    expect(mismatched, "the prompt flag is owner-bound too")
}

// MARK: - Runner

testDerivation()
testIsSetupComplete()
testStateTransitions()
testRoutes()
try testChecklistStore()
try testChecklistSeedAdoption()
try testReminderPromptStore()

if failures == 0 {
    print("SetupChecklistTests: all checks passed")
} else {
    print("SetupChecklistTests: \(failures) failure(s)")
    exit(1)
}
