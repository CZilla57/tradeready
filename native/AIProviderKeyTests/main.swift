import Foundation
import Combine

// Task 11.15 host tests: Settings › AI Assistant advanced key entry
// (contract §11, C19; RN `screens/SettingsAIScreen.tsx`).
//
// - The pure policy (`NativeAIProviderKeyPolicy`): RN copy, trim/validation,
//   the save/clear outcome, masked display, and the transport's precedence.
// - The existing secure store (`NativeKeychainSecureSettingsStore`) over an
//   in-memory `NativeSecureKeyValueBacking`: save, clear, verification, and
//   the owner wipe (`clearAccountValues` / `clearAllValues`).
// - The real AppStore wiring: the provider summary and the coach request
//   follow a save or clear; sign-out and launch scrub recovery wipe the keys.
// - Redaction: an entered key never reaches an analytics payload, a crash
//   payload, UserDefaults, the App Group suite, the widget snapshot, the
//   business-data files, or AppStore diagnostics.
// The system Keychain is never touched. Run with TZ=America/Phoenix.

// MARK: - Harness

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// Sample keys in the real provider shapes (not real credentials).
let anthropicKey = "sk-ant-api03-Zq7XwT9bLm2Nc4Vd8Rf6Hs1Jk3Pp5Yt0Ue2Wa4Qg6Ic8Ox-Tn1Mv3Br5_AAQ"
let groqKey = "gsk_R4nD0mGr0qK3yF1xtur3N0tR3aL9bQ2wE5tY7uI1oP3aS6dF8"

/// True when any distinctive part of `key` appears in `text`: the whole key,
/// its last 12 characters, or the first 12 characters after its prefix.
func leaks(_ key: String, in text: String) -> Bool {
    let prefix = key.hasPrefix("sk-ant-") ? "sk-ant-" : "gsk_"
    let body = String(key.dropFirst(prefix.count))
    return text.contains(key) || text.contains(String(key.suffix(12))) || text.contains(String(body.prefix(12)))
}

func expectNoLeak(_ text: String, _ label: String) {
    expect(!leaks(anthropicKey, in: text), "\(label): no Anthropic key text")
    expect(!leaks(groqKey, in: text), "\(label): no Groq key text")
}

func canonicalJSON(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8)
    else { return "<invalid json>" }
    return text
}

func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<5 { await Task.yield() }
}

// MARK: - Fakes

final class MemorySecureBackend: NativeSecureKeyValueBacking {
    var values: [String: Data] = [:]
    var failUpsert = false
    var failRemove = false
    /// Removes of just these accounts fail (the AI keys, not the session).
    var failRemoveKeys: Set<String> = []
    /// A Keychain read error (for example before first unlock).
    var failRead = false
    /// Returns different bytes on read-back (a Keychain that did not persist).
    var corruptReads = false
    func upsert(_ value: Data, key: String) throws {
        if failUpsert { throw NativeSecureSettingsStoreError.writeFailed(key: key, status: -25300) }
        values[key] = value
    }
    func read(key: String) throws -> Data? {
        if failRead { throw NativeSecureSettingsStoreError.writeFailed(key: key, status: -25308) }
        guard let value = values[key] else { return nil }
        return corruptReads ? Data("x".utf8) : value
    }
    func remove(key: String) throws {
        if failRemove || failRemoveKeys.contains(key) { throw NativeSecureSettingsStoreError.writeFailed(key: key, status: -25300) }
        values.removeValue(forKey: key)
    }
    var allText: String {
        values.map { "\($0.key)=\(String(decoding: $0.value, as: UTF8.self))" }.sorted().joined(separator: "\n")
    }
}

final class FakeCoachLoader: NativeCoachHTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); requests.append(request); lock.unlock()
        let host = request.url?.host ?? ""
        let body: String
        if host.contains("anthropic") {
            body = #"{"content":[{"type":"text","text":"from anthropic"}]}"#
        } else if host.contains("groq") {
            body = #"{"choices":[{"message":{"content":"from groq"}}]}"#
        } else {
            body = #"{"text":"from backend"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

enum AnalyticsCall {
    case capture(String, [String: NativeAnalyticsValue])
    case identify(String)
    case reset
    case screen(String)
}

final class FakeAnalyticsAdapter: NativeAnalyticsSDKAdapter {
    var calls: [AnalyticsCall] = []
    func capture(_ event: String, properties: [String: NativeAnalyticsValue]) throws { calls.append(.capture(event, properties)) }
    func identify(_ distinctID: String) throws { calls.append(.identify(distinctID)) }
    func reset() throws { calls.append(.reset) }
    func screen(_ name: String) throws { calls.append(.screen(name)) }

    var observed: String {
        calls.map { call -> String in
            switch call {
            case .capture(let event, let properties):
                return "\(event) \(canonicalJSON(properties.mapValues(\.jsonObject)))"
            case .identify(let id): return "identify \(id)"
            case .reset: return "reset"
            case .screen(let name): return "screen \(name)"
            }
        }.joined(separator: "\n")
    }
}

final class FakeCrashAdapter: NativeCrashReportingSDKAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [NativeCrashReport] = []
    var reports: [NativeCrashReport] { lock.lock(); defer { lock.unlock() }; return recorded }
    func start(options: NativeCrashReportingOptions, redaction: NativeErrorRedaction) throws {}
    func capture(_ report: NativeCrashReport) throws { lock.lock(); recorded.append(report); lock.unlock() }
    func setUser(id: String?) throws {}
}

struct NoopReloader: NativeWidgetTimelineReloading {
    func reloadAllTimelines() {}
}

@MainActor
final class SubscriptionStub: NativeSubscriptionServing {
    /// Runs inside `useAnotherAccount`'s `logOut` await (mid-switch).
    var onLogOut: (@MainActor () -> Void)?
    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }
    func loadOffering() async throws -> NativeSubscriptionOffering { .init(packages: []) }
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        .init(entitlement: .init(isActive: false, isTrialing: false), userCancelled: false)
    }
    func restore() async throws -> NativeSubscriptionEntitlement { .init(isActive: false, isTrialing: false) }
    func logOut() async { onLogOut?() }
}

struct TempAppGroup {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    var lockFile: URL { directory.appendingPathComponent(WidgetAppGroup.lockFileName) }

    init(_ label: String) {
        suiteName = "com.tradeready.ai-provider-key.tests.\(label).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-1115-group-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var scrubber: NativeAppGroupAccountScrubber {
        NativeAppGroupAccountScrubber(suiteName: suiteName, defaults: defaults, lockFile: lockFile)
    }

    func mirror() -> NativeWidgetMirror {
        NativeWidgetMirror(defaults: defaults, lockFile: lockFile, reloader: NoopReloader())
    }

    var everything: String { "\(defaults.dictionaryRepresentation())" }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
func makeStore(
    _ tag: String,
    backend: MemorySecureBackend,
    group: TempAppGroup,
    directory existing: URL? = nil,
    loader: FakeCoachLoader = FakeCoachLoader(),
    analytics: NativeAnalytics = NativeNoOpAnalytics(),
    crashReporting: NativeCrashReporting = NativeNoOpCrashReporting(),
    subscription: SubscriptionStub? = nil
) -> (AppStore, URL) {
    let directory = existing ?? FileManager.default.temporaryDirectory
        .appending(path: "tradeready-1115-\(tag)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = AppStore(
        fileURL: directory.appending(path: "store.json"),
        seedIfMissing: true,
        appGroupAccountScrubber: group.scrubber,
        subscriptionService: subscription ?? SubscriptionStub(),
        coachTransport: NativeCoachTransport(backendBaseURL: URL(string: "https://backend.example.test/"), loader: loader),
        analytics: analytics,
        crashReporting: crashReporting,
        widgetTimelineReloader: NoopReloader(),
        secureSettingsStore: NativeKeychainSecureSettingsStore(backend: backend)
    )
    return (store, directory)
}

func filesText(in directory: URL) -> String {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return "" }
    var text = ""
    for case let url as URL in enumerator {
        if let data = try? Data(contentsOf: url) { text += String(decoding: data, as: UTF8.self) + "\n" }
    }
    return text
}

// MARK: - 1. Policy

func testCopy() {
    typealias P = NativeAIProviderKeyPolicy
    // RN `screens/SettingsAIScreen.tsx`, verbatim.
    expectEqual(P.introHint, "AI features work automatically via our cloud service. Toggle Advanced to use your own API keys instead.", "intro hint (RN)")
    expectEqual(P.advancedTitle, "Advanced", "toggle title (RN)")
    expectEqual(P.advancedAccessibilityLabel, "Advanced AI settings", "toggle a11y label (RN)")
    expectEqual(P.storageNote, "Stored only on your device. Never share this key.", "key note (RN)")
    expectEqual(NativeAIProviderKeyKind.allCases, [.groq, .anthropic], "RN order: the Groq card, then the Anthropic card")
    expectEqual(NativeAIProviderKeyKind.groq.hint,
                "Groq API key — powers the AI chat tab (estimates, advice, invoice messages). Get a free key at console.groq.com — no billing required.",
                "Groq hint (RN)")
    expectEqual(NativeAIProviderKeyKind.anthropic.hint,
                "Anthropic (Claude) API key — used for AI-generated invoice outreach messages. Get one at console.anthropic.com.",
                "Anthropic hint (RN)")
    expectEqual(NativeAIProviderKeyKind.groq.placeholder, "gsk_...", "Groq placeholder (RN)")
    expectEqual(NativeAIProviderKeyKind.anthropic.placeholder, "sk-ant-...", "Anthropic placeholder (RN)")
    expectEqual(NativeAIProviderKeyKind.groq.accessibilityLabel, "Groq API key", "Groq a11y label (RN)")
    expectEqual(NativeAIProviderKeyKind.anthropic.accessibilityLabel, "Anthropic API key", "Anthropic a11y label (RN)")
    // The Keychain accounts are RN's SECURE_FIELDS names, which the canonical
    // codec strips and `clearAccountValues` removes.
    expectEqual(NativeAIProviderKeyKind.anthropic.secureAccount, "anthropicKey", "Anthropic Keychain account")
    expectEqual(NativeAIProviderKeyKind.groq.secureAccount, "groqKey", "Groq Keychain account")
    for kind in NativeAIProviderKeyKind.allCases {
        expect(Canonical.SnapshotCodec.secureSettingsKeys.contains(kind.secureAccount),
               "\(kind.secureAccount) is a canonical secure-settings key (never serialized)")
    }
}

func testTrimAndValidation() {
    typealias P = NativeAIProviderKeyPolicy
    expectEqual(P.normalized("  \n\t\(anthropicKey) \n"), anthropicKey, "entry is trimmed of whitespace and newlines")
    expectEqual(P.outcome(for: anthropicKey, kind: .anthropic), .store(anthropicKey), "a well-formed Anthropic key is stored")
    expectEqual(P.outcome(for: "  \(anthropicKey)\n", kind: .anthropic), .store(anthropicKey), "a pasted Anthropic key is stored trimmed")
    expectEqual(P.outcome(for: groqKey, kind: .groq), .store(groqKey), "a well-formed Groq key is stored")
    expectEqual(P.outcome(for: "\t\(groqKey)  ", kind: .groq), .store(groqKey), "a pasted Groq key is stored trimmed")
    // Contract §11: an empty trimmed field counts as a clear.
    expectEqual(P.outcome(for: "", kind: .groq), .clear, "an empty entry is a clear")
    expectEqual(P.outcome(for: "  \n ", kind: .anthropic), .clear, "a whitespace-only entry is a clear")
    // Shape checks (recorded native difference): only keys the shared
    // redaction screens recognize can be stored.
    expectEqual(P.outcome(for: groqKey, kind: .anthropic), .rejected(.wrongPrefix), "a Groq key in the Anthropic field is rejected")
    expectEqual(P.outcome(for: anthropicKey, kind: .groq), .rejected(.wrongPrefix), "an Anthropic key in the Groq field is rejected")
    expectEqual(P.outcome(for: "sk-proj-abcdefghijklmnopqrstuvwxyz0123", kind: .anthropic), .rejected(.wrongPrefix), "an OpenAI key is not an Anthropic key")
    expectEqual(P.outcome(for: "abcdefghijklmnopqrstuvwxyz0123456789", kind: .groq), .rejected(.wrongPrefix), "an unprefixed value is rejected")
    expectEqual(P.outcome(for: "sk-ant-api03-abc def-ghijklmnopqrstu", kind: .anthropic), .rejected(.invalidCharacters), "an inner space is rejected")
    expectEqual(P.outcome(for: "gsk_abcdefghijklmnop.qrstuvwxyz", kind: .groq), .rejected(.invalidCharacters), "a '.' is rejected (redaction stops there)")
    expectEqual(P.outcome(for: "gsk_abcdefghijklmnopé1234567", kind: .groq), .rejected(.invalidCharacters), "non-ASCII is rejected")
    expectEqual(P.outcome(for: "sk-ant-api03-abc\ndefghijklmnopqrstu", kind: .anthropic), .rejected(.invalidCharacters), "an inner newline is rejected")
    expectEqual(P.outcome(for: "sk-ant-abc", kind: .anthropic), .rejected(.wrongLength), "a truncated key is rejected")
    expectEqual(P.outcome(for: "gsk_", kind: .groq), .rejected(.wrongLength), "a bare prefix is rejected")
    expectEqual(P.outcome(for: "gsk_" + String(repeating: "a", count: P.maximumLength), kind: .groq), .rejected(.wrongLength), "an oversize value is rejected")
    expectEqual(P.outcome(for: "gsk_" + String(repeating: "a", count: P.minimumLength - 4), kind: .groq),
                .store("gsk_" + String(repeating: "a", count: P.minimumLength - 4)), "exactly the minimum length is accepted")
    // An account boundary (signed out, sign-out or deletion in flight, scrub
    // pending) blocks every change, including a clear.
    expectEqual(P.outcome(for: anthropicKey, kind: .anthropic, canChange: false), .rejected(.unavailable), "blocked: a valid key is not stored")
    expectEqual(P.outcome(for: "", kind: .anthropic, canChange: false), .rejected(.unavailable), "blocked: a clear is not applied")
    expectEqual(P.clearOutcome(canChange: true), .clear, "explicit remove is a clear")
    expectEqual(P.clearOutcome(canChange: false), .rejected(.unavailable), "blocked: explicit remove is refused")

    expect(!P.canSubmit(""), "Save is disabled for an empty field")
    expect(!P.canSubmit("   \n"), "Save is disabled for a whitespace-only field")
    expect(P.canSubmit("g"), "Save is enabled once something is typed")
}

func testMessagesNeverEchoTheEntry() {
    typealias P = NativeAIProviderKeyPolicy
    let entries = [
        "sk-ant-api03-abc def-\(anthropicKey.suffix(20))",
        groqKey,
        "sk-ant-x",
        anthropicKey + ".tail",
    ]
    var all = ""
    for kind in NativeAIProviderKeyKind.allCases {
        for entry in entries {
            if case .rejected(let rejection) = P.outcome(for: entry, kind: kind) {
                let message = rejection.message(for: kind)
                expect(!message.isEmpty, "\(kind) \(rejection) has a message")
                all += message + "\n"
            }
        }
        for change in [NativeAIProviderKeyChange.saved(kind), .cleared(kind), .failed(kind, removing: false), .failed(kind, removing: true)] {
            all += change.message + "\n"
        }
    }
    expectNoLeak(all, "validation and result messages")
    expectEqual(NativeAIProviderKeyPolicy.Rejection.wrongPrefix.message(for: .groq),
                "That doesn't look like a Groq API key. Groq keys start with gsk_.", "wrong-prefix copy names the expected prefix")
    expectEqual(NativeAIProviderKeyChange.saved(.anthropic).message, "Anthropic API key saved.", "saved copy")
    expectEqual(NativeAIProviderKeyChange.cleared(.groq).message, "Groq API key removed.", "removed copy")
}

func testMaskedDisplay() {
    typealias P = NativeAIProviderKeyPolicy
    // RN has no masked format (its secure field redisplays the saved value
    // as dots), so native shows only the provider name plus "Saved".
    expectEqual(P.statusTitle(for: .anthropic), "Anthropic API key", "status row title is the provider name")
    expectEqual(P.savedStatus(isSaved: true), "Saved", "a saved key shows only \"Saved\"")
    expectEqual(P.savedStatus(isSaved: false), "Not set", "no key shows \"Not set\"")
    expectNoLeak(P.statusTitle(for: .anthropic) + P.statusTitle(for: .groq) + P.savedStatus(isSaved: true), "masked display")
    // Fix round 1 (M5): a Keychain read error is not "Not set".
    struct ReadError: Error {}
    expectEqual(P.savedState { Data(groqKey.utf8) }, .saved, "a readable key → saved")
    expectEqual(P.savedState { nil }, .notSet, "no item → not set")
    expectEqual(P.savedState { Data("  ".utf8) }, .notSet, "whitespace item → not set")
    expectEqual(P.savedState { throw ReadError() }, .unreadable, "a read error → unreadable")
    expectEqual(P.savedStatus(.saved), "Saved", "saved state copy")
    expectEqual(P.savedStatus(.notSet), "Not set", "not-set state copy")
    expectEqual(P.savedStatus(.unreadable), "Unavailable", "unreadable is not shown as Not set")
    expect(P.offersRemove(.saved) && P.offersRemove(.unreadable) && !P.offersRemove(.notSet), "Remove is offered whenever a key may exist")
}

func testStoredValueRule() {
    typealias P = NativeAIProviderKeyPolicy
    expectEqual(P.storedKey(from: nil), nil, "no Keychain item → no key")
    expectEqual(P.storedKey(from: Data()), nil, "empty item → no key")
    expectEqual(P.storedKey(from: Data("  \n".utf8)), nil, "whitespace item → no key")
    expectEqual(P.storedKey(from: Data(" \(groqKey)\n".utf8)), groqKey, "a migrated item is read trimmed")
    expectEqual(P.storedKey(from: Data([0xFF, 0xFE, 0xFD])), nil, "non-UTF-8 bytes → no key")
}

struct ApplyError: Error {}

func testApplyOutcome() {
    typealias P = NativeAIProviderKeyPolicy
    var saved: [String] = []
    var cleared = 0
    var result = P.apply(.store(anthropicKey), kind: .anthropic, save: { saved.append($0) }, clear: { cleared += 1 })
    expectEqual(result, .saved(.anthropic), "store → saved")
    expectEqual(saved, [anthropicKey], "store writes exactly the normalized key once")
    expectEqual(cleared, 0, "store never clears")

    saved = []
    result = P.apply(.clear, kind: .groq, save: { saved.append($0) }, clear: { cleared += 1 })
    expectEqual(result, .cleared(.groq), "clear → cleared")
    expectEqual(cleared, 1, "clear removes once")
    expect(saved.isEmpty, "clear never writes")

    cleared = 0
    result = P.apply(.rejected(.wrongPrefix), kind: .groq, save: { saved.append($0) }, clear: { cleared += 1 })
    expectEqual(result, .rejected(.groq, .wrongPrefix), "a rejection writes nothing")
    expect(saved.isEmpty && cleared == 0, "a rejection touches no store")

    result = P.apply(.store(groqKey), kind: .groq, save: { _ in throw ApplyError() }, clear: {})
    expectEqual(result, .failed(.groq, removing: false), "a failed write reports failure")
    result = P.apply(.clear, kind: .anthropic, save: { _ in }, clear: { throw ApplyError() })
    expectEqual(result, .failed(.anthropic, removing: true), "a failed remove reports failure")
    expect(NativeAIProviderKeyChange.saved(.groq).clearsEntry, "a save empties the field")
    expect(NativeAIProviderKeyChange.cleared(.groq).clearsEntry, "a remove empties the field")
    expect(!NativeAIProviderKeyChange.rejected(.groq, .wrongPrefix).clearsEntry, "a rejection keeps the field for correction")
    expect(!NativeAIProviderKeyChange.failed(.groq, removing: false).clearsEntry, "a failure keeps the field for retry")
}

func testPrecedence() {
    typealias P = NativeAIProviderKeyPolicy
    let cases: [(String?, String?, String)] = [
        (anthropicKey, groqKey, "anthropic"),
        (anthropicKey, nil, "anthropic"),
        (nil, groqKey, "groq"),
        (nil, nil, "backend"),
    ]
    for (anthropic, groq, expected) in cases {
        let provider = P.provider(savedAnthropicKey: anthropic, savedGroqKey: groq)
        expectEqual(provider, NativeCoachTransport.provider(anthropicKey: anthropic ?? "", groqKey: groq ?? ""),
                    "policy precedence is the transport's (\(expected))")
        expectEqual(NativeCoachProviderSummary(provider: provider).analyticsName, expected, "precedence → \(expected)")
    }
}

// MARK: - 2. Secure store (existing store, in-memory backing)

/// The sealed item a save writes for `key` and `binding` (review I1).
func sealedItem(_ key: String, binding: String) -> Data? {
    try? NativeAIProviderKeyOwnerTag.seal(key, binding: binding)
}

func testSecureStore() {
    let backend = MemorySecureBackend()
    let store = NativeKeychainSecureSettingsStore(backend: backend)
    let owner = "bind-store"
    expectEqual(store.readAIProviderKey(.anthropic, ownerBinding: owner), nil, "empty store reads nil")

    do { try store.saveAIProviderKey(anthropicKey, kind: .anthropic, ownerBinding: owner) } catch { expect(false, "save anthropic: \(error)") }
    expectEqual(backend.values["anthropicKey"], sealedItem(anthropicKey, binding: owner), "save = one upsert of the sealed item under anthropicKey")
    expectEqual(store.readAIProviderKey(.anthropic, ownerBinding: owner), anthropicKey, "saved key reads back for its owner")
    expectEqual(store.readAIProviderKey(.groq, ownerBinding: owner), nil, "saving Anthropic leaves Groq unset")

    do { try store.saveAIProviderKey(groqKey, kind: .groq, ownerBinding: owner) } catch { expect(false, "save groq: \(error)") }
    expectEqual(backend.values["groqKey"], sealedItem(groqKey, binding: owner), "save = upsert under groqKey")
    expectEqual(store.readAIProviderKey(.anthropic, ownerBinding: owner), anthropicKey, "saving Groq leaves Anthropic intact")

    // Review I1: the item reads only for its owner.
    expectEqual(store.readAIProviderKey(.groq, ownerBinding: "bind-other"), nil, "I1: another owner reads nil")
    expectEqual(store.readAIProviderKey(.groq, ownerBinding: nil), nil, "I1: no owner reads nil")
    expectEqual(store.readAIProviderKey(.groq, ownerBinding: ""), nil, "I1: an empty owner reads nil")
    expectEqual(store.aiProviderKeyState(.groq, ownerBinding: owner), .saved, "I1: the owner's state is saved")
    expectEqual(store.aiProviderKeyState(.groq, ownerBinding: "bind-other"), .notSet, "I1: another owner's state is Not set")
    let tag = NativeAIProviderKeyOwnerTag.make(binding: owner)
    expectEqual(tag.count, 64, "I1: the owner tag is a 64-hex SHA-256")
    expect(tag != NativeWidgetOwnerTag.make(binding: owner), "I1: the key tag is domain-separated from the widget stamp")
    let text = String(decoding: backend.values["groqKey"] ?? Data(), as: UTF8.self)
    expect(text.contains(tag) && !text.contains(owner), "I1: the item carries the tag, never the binding")

    do { try store.clearAIProviderKey(.anthropic) } catch { expect(false, "clear anthropic: \(error)") }
    expect(backend.values["anthropicKey"] == nil, "clear = remove of anthropicKey")
    expectEqual(store.readAIProviderKey(.groq, ownerBinding: owner), groqKey, "clearing Anthropic leaves Groq intact")
    do { try store.clearAIProviderKey(.anthropic) } catch { expect(false, "clearing an absent key is a no-op: \(error)") }

    // Review I1: an untagged item (an RN-era migrated key) reads as absent;
    // a sealed item with stray whitespace in the key reads trimmed.
    backend.values["anthropicKey"] = Data("  \(anthropicKey)\n".utf8)
    expectEqual(store.readAIProviderKey(.anthropic, ownerBinding: owner), nil, "I1: an untagged migrated item reads as absent")
    expectEqual(store.aiProviderKeyState(.anthropic, ownerBinding: owner), .notSet, "I1: …and its state is Not set")
    backend.values["anthropicKey"] = sealedItem("  \(anthropicKey)\n", binding: owner)
    expectEqual(store.readAIProviderKey(.anthropic, ownerBinding: owner), anthropicKey, "a sealed key reads trimmed")
    backend.values["anthropicKey"] = Data(#"{"schemaVersion":2,"ownerTag":"\#(NativeAIProviderKeyOwnerTag.make(binding: owner))","key":"\#(anthropicKey)"}"#.utf8)
    expectEqual(store.readAIProviderKey(.anthropic, ownerBinding: owner), nil, "I1: an unknown item version reads as absent")

    // Read-back verification: a write that does not persist is an error.
    let flaky = MemorySecureBackend()
    flaky.corruptReads = true
    var threw = false
    do { try NativeKeychainSecureSettingsStore(backend: flaky).saveAIProviderKey(groqKey, kind: .groq, ownerBinding: owner) } catch { threw = true }
    expect(threw, "an unverified write throws")
    let failing = MemorySecureBackend()
    failing.failUpsert = true
    threw = false
    do { try NativeKeychainSecureSettingsStore(backend: failing).saveAIProviderKey(groqKey, kind: .groq, ownerBinding: owner) } catch {
        threw = true
        expectNoLeak("\(error) \(error.localizedDescription)", "Keychain write error text")
    }
    expect(threw, "a failed upsert throws")
}

func testOwnerWipe() {
    // Keys entered in Settings live in the same accounts migrated keys do, so
    // the existing account-boundary wipe removes them the same way.
    for scope in ["live", "all"] {
        let backend = MemorySecureBackend()
        let store = NativeKeychainSecureSettingsStore(backend: backend)
        do {
            try store.persist(LegacySecureSettings(providerKey: "rk_live_migratedproviderkey"))
            try store.saveAIProviderKey(anthropicKey, kind: .anthropic, ownerBinding: "bind-wipe")
            try store.saveAIProviderKey(groqKey, kind: .groq, ownerBinding: "bind-wipe")
            if scope == "live" { try store.clearAccountValues() } else { try store.clearAllValues() }
        } catch {
            expect(false, "owner wipe (\(scope)) threw \(error)")
        }
        expect(backend.values["anthropicKey"] == nil, "\(scope) wipe removes the entered Anthropic key")
        expect(backend.values["groqKey"] == nil, "\(scope) wipe removes the entered Groq key")
        expect(backend.values["providerKey"] == nil, "\(scope) wipe removes the migrated providerKey too")
        expectNoLeak(backend.allText, "backing store after \(scope) wipe")
    }
}

// MARK: - 3. AppStore wiring

@MainActor
func testAppStoreWiring() async {
    let group = TempAppGroup("wiring")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let loader = FakeCoachLoader()
    let (store, directory) = makeStore("wiring", backend: backend, group: group, loader: loader)
    defer { try? FileManager.default.removeItem(at: directory) }
    var changes = 0
    let token = store.objectWillChange.sink { _ in changes += 1 }
    defer { token.cancel() }

    // Signed out: nothing is written.
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .rejected(.anthropic, .unavailable), "signed out → refused")
    expect(backend.values.isEmpty, "signed out → nothing written")
    expectEqual(store.coachProviderSummary.analyticsName, "backend", "no key → backend")

    store.scheduleBookingTestSeedSignedInOwner(subject: "user-1115", binding: "bind-1115")

    changes = 0
    expectEqual(store.setAIProviderKey(.groq, entry: "  \(groqKey)\n"), .saved(.groq), "save Groq")
    expect(changes > 0, "a save republishes the store so the page and summary refresh")
    expectEqual(backend.values["groqKey"], sealedItem(groqKey, binding: "bind-1115"), "Groq key stored trimmed, sealed for its owner")
    expect(store.aiProviderKeyIsSaved(.groq), "Groq shows as saved")
    expect(!store.aiProviderKeyIsSaved(.anthropic), "Anthropic shows as not set")
    expectEqual(store.coachProviderSummary.analyticsName, "groq", "Groq key → summary groq")
    expectEqual(store.advisoryGroqKey, groqKey, "the coach's Groq read sees the saved key")

    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "save Anthropic")
    expectEqual(store.coachProviderSummary.analyticsName, "anthropic", "Anthropic wins over Groq (transport precedence)")
    expectEqual(store.coachProviderSummary.service, "Anthropic (Claude)", "summary service is the provider name")
    expectEqual(store.advisoryAnthropicKey, anthropicKey, "receipt/pricebook Anthropic read sees the saved key")

    // The coach transport routes by the same keys.
    let history = [NativeCoachMessage(role: .user, text: "How am I doing?")]
    _ = try? await store.sendCoachMessage(history: history)
    expectEqual(loader.last?.url, NativeCoachTransport.anthropicURL, "coach routes to Anthropic after the save")
    expectEqual(loader.last?.value(forHTTPHeaderField: "x-api-key"), anthropicKey, "coach sends the saved Anthropic key")

    // A rejected entry changes nothing.
    expectEqual(store.setAIProviderKey(.anthropic, entry: groqKey), .rejected(.anthropic, .wrongPrefix), "wrong shape refused")
    expectEqual(store.advisoryAnthropicKey, anthropicKey, "a refused entry keeps the saved key")

    changes = 0
    expectEqual(store.clearAIProviderKey(.anthropic), .cleared(.anthropic), "remove Anthropic")
    expect(changes > 0, "a remove republishes the store")
    expect(backend.values["anthropicKey"] == nil, "Anthropic key removed from the secure store")
    expectEqual(store.coachProviderSummary.analyticsName, "groq", "remove Anthropic → Groq")
    _ = try? await store.sendCoachMessage(history: history)
    expectEqual(loader.last?.url, NativeCoachTransport.groqURL, "coach routes to Groq after the remove")
    expectEqual(loader.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(groqKey)", "coach sends the saved Groq key")

    // Contract §11: an empty field saved counts as a clear.
    expectEqual(store.setAIProviderKey(.groq, entry: "   "), .cleared(.groq), "empty save clears Groq")
    expectEqual(store.coachProviderSummary.analyticsName, "backend", "no keys → backend")
    store.scheduleBookingSessionOverride = Data(#"{"access_token":"session-token-1115"}"#.utf8)
    _ = try? await store.sendCoachMessage(history: history)
    expectEqual(loader.last?.url?.host, "backend.example.test", "coach routes to the backend with no user key")

    // A failing Keychain reports failure and republishes the real state.
    backend.failUpsert = true
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .failed(.groq, removing: false), "Keychain failure surfaces")
    expectEqual(store.coachProviderSummary.analyticsName, "backend", "a failed save leaves the provider unchanged")
    backend.failUpsert = false

    // Fix round 1 (M5): an unreadable Keychain shows "Unavailable", and the
    // coach treats the key as absent (backend).
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "save Groq again")
    expectEqual(store.aiProviderKeyState(.groq), .saved, "state saved")
    expectEqual(store.aiProviderKeyState(.anthropic), .notSet, "state not set")
    backend.failRead = true
    expectEqual(store.aiProviderKeyState(.groq), .unreadable, "a read error is unreadable, not Not set")
    expectEqual(store.coachProviderSummary.analyticsName, "backend", "an unreadable key routes to the backend")
    backend.failRead = false
}

@MainActor
func testAppStoreOwnerWipe() async {
    // Sign-out (scope .live) through the real signOut path.
    do {
        let group = TempAppGroup("signout")
        defer { group.cleanUp() }
        let backend = MemorySecureBackend()
        let (store, directory) = makeStore("signout", backend: backend, group: group)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
        expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic")
        expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "owner A saves Groq")
        backend.values["auxiliary-account-binding-key.v1"] = Data("device-binding".utf8)
        do { try await store.signOut(revokeRemote: false) } catch { expect(false, "signOut threw \(error)") }
        expect(backend.values["auxiliary-account-binding-key.v1"] != nil, "sign-out is the .live scope (device binding kept)")
        expectEqual(store.advisoryAnthropicKey, nil, "sign-out wipes the entered Anthropic key")
        expectEqual(store.advisoryGroqKey, nil, "sign-out wipes the entered Groq key")
        expect(backend.values["anthropicKey"] == nil && backend.values["groqKey"] == nil, "no key account survives sign-out")
        expectEqual(store.coachProviderSummary.analyticsName, "backend", "after sign-out the summary is backend")
        // The next owner starts with no key.
        store.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: "bind-b")
        expect(!store.aiProviderKeyIsSaved(.anthropic) && !store.aiProviderKeyIsSaved(.groq), "owner B inherits no key")
    }

    // Deletion (scope .all) through the real launch scrub recovery: a pending
    // `.all` scrub marker is finished by the next launch, with the same store.
    do {
        let group = TempAppGroup("delete")
        defer { group.cleanUp() }
        let backend = MemorySecureBackend()
        let (store, directory) = makeStore("delete", backend: backend, group: group)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
        _ = store.setAIProviderKey(.anthropic, entry: anthropicKey)
        _ = store.setAIProviderKey(.groq, entry: groqKey)
        do {
            try Canonical.SnapshotRepository(primaryURL: directory.appending(path: "store.json")).beginAccountScrub(scope: .all)
        } catch {
            expect(false, "could not stage a pending deletion scrub: \(error)")
        }
        // Fix round 1 (M2): seed the device binding so the scope check can fail.
        backend.values["auxiliary-account-binding-key.v1"] = Data("device-binding".utf8)
        let (relaunched, _) = makeStore("delete", backend: backend, group: group, directory: directory)
        expect(!relaunched.isAccountScrubBlocked, "the deletion scrub finished at launch")
        expect(backend.values["anthropicKey"] == nil && backend.values["groqKey"] == nil, "deletion scrub wipes both keys")
        expect(backend.values["auxiliary-account-binding-key.v1"] == nil, "deletion scrub is the .all scope")
        expectEqual(relaunched.coachProviderSummary.analyticsName, "backend", "after deletion the summary is backend")
    }
}

// Fix round 1 (I1, controller ruling): keys are owner-bound across the
// account switch and both password-recovery exits.
@MainActor
func testAppStoreAccountSwitchWipesKeys() async {
    let group = TempAppGroup("switch")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let subscription = SubscriptionStub()
    let (store, directory) = makeStore("switch", backend: backend, group: group, subscription: subscription)
    defer { try? FileManager.default.removeItem(at: directory) }
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    store.scheduleBookingTestSeedIdentityActivator()
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic")
    // A migrated key (written by the importer, untrimmed) follows the same rule.
    backend.values["groqKey"] = Data(" \(groqKey)\n".utf8)
    expectEqual(store.coachProviderSummary.analyticsName, "anthropic", "sanity: owner A routes to Anthropic")

    var midSwitchSave: NativeAIProviderKeyChange?
    var midSwitchSaved = true
    var midSwitchSummary = ""
    subscription.onLogOut = { [unowned store] in
        // Already wiped before the first await.
        midSwitchSaved = store.aiProviderKeyIsSaved(.anthropic) || store.aiProviderKeyIsSaved(.groq)
        midSwitchSummary = store.coachProviderSummary.analyticsName
        // The gate is still `.signedIn` here; the switch must refuse a save.
        midSwitchSave = store.setAIProviderKey(.groq, entry: groqKey)
        // A key landing by any other path during the awaits is wiped after them.
        backend.values["anthropicKey"] = Data(anthropicKey.utf8)
    }
    await store.useAnotherAccount(clearGoogleCredential: {})
    expectEqual(store.authenticationGateState, .signedOut, "sanity: useAnotherAccount reached its success path")
    expect(!midSwitchSaved, "keys are wiped before the switch's first await")
    expectEqual(midSwitchSummary, "backend", "mid-switch the summary is already backend")
    expectEqual(midSwitchSave, .rejected(.groq, .unavailable), "a save attempted mid-switch is refused")
    expect(backend.values["anthropicKey"] == nil && backend.values["groqKey"] == nil, "no key survives the account switch (entered, migrated or mid-switch)")
    expectEqual(store.coachProviderSummary.analyticsName, "backend", "after the switch the summary is backend")
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: "bind-b")
    expect(!store.aiProviderKeyIsSaved(.anthropic) && !store.aiProviderKeyIsSaved(.groq), "owner B inherits no key after the switch")
    expectEqual(store.coachProviderSummary.analyticsName, "backend", "owner B's summary is backend")
    // The gate reopens for owner B.
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "owner B can save after the switch")
}

@MainActor
func testAppStoreRecoveryExitWipesKeys() async {
    let group = TempAppGroup("recovery")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("recovery", backend: backend, group: group)
    defer { try? FileManager.default.removeItem(at: directory) }
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic")
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "owner A saves Groq")
    await store.cancelPasswordRecovery()
    expectEqual(store.authenticationGateState, .signedOut, "sanity: cancelPasswordRecovery reached the recovery sign-out")
    expect(backend.values["anthropicKey"] == nil && backend.values["groqKey"] == nil, "cancelPasswordRecovery wipes both keys")
    expectEqual(store.coachProviderSummary.analyticsName, "backend", "after recovery cancel the summary is backend")
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: "bind-b")
    expect(!store.aiProviderKeyIsSaved(.anthropic) && !store.aiProviderKeyIsSaved(.groq), "owner B inherits no key after recovery")
}

// Final review 1b: a failed boundary wipe fails closed and is retried.
@MainActor
func testAppStoreBoundaryWipeFailureFailsClosed() async {
    let group = TempAppGroup("wipe-fail")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("wipe-fail", backend: backend, group: group)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appending(path: "store.json").appendingPathExtension("ai-key-wipe-pending")
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    store.scheduleBookingTestSeedIdentityActivator()
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic")

    backend.failRemoveKeys = ["anthropicKey", "groqKey"]
    await store.useAnotherAccount(clearGoogleCredential: {})
    expectEqual(store.authenticationGateState, .signedOut, "sanity: useAnotherAccount reached its success path")
    expect(backend.values["anthropicKey"] != nil, "sanity: the Keychain still holds A's key")
    expect(FileManager.default.fileExists(atPath: marker.path), "1b: the failed wipe leaves a durable pending marker")
    expect(store.aiProviderKeyWipeFailureCount >= 1, "1b: the failed wipe is counted")
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: "bind-b")
    expect(store.advisoryAnthropicKey == nil && store.advisoryGroqKey == nil,
           "1b: while the wipe is pending the coach reads no client key")
    expectEqual(store.coachProviderSummary.analyticsName, "backend", "1b: …so owner B's coach uses the backend")
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .rejected(.groq, .unavailable),
                "1b: no key can be saved while the wipe is pending")

    // A relaunch while the Keychain still refuses keeps it pending.
    let (relaunched, _) = makeStore("wipe-fail", backend: backend, group: group, directory: directory)
    expect(FileManager.default.fileExists(atPath: marker.path), "1b: the pending wipe survives a relaunch")
    expect(relaunched.advisoryAnthropicKey == nil, "1b: …and still fails closed after it")

    // Sign-in retry.
    backend.failRemoveKeys = []
    store.testFinishInteractiveSignIn(subject: "user-b", binding: "bind-b", email: "b@example.test", method: .password)
    expect(!FileManager.default.fileExists(atPath: marker.path), "1b: the sign-in retry clears the marker")
    expect(backend.values["anthropicKey"] == nil, "1b: …after removing A's key")
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "1b: B can save once the retry succeeded")

    // A recovery exit's failed wipe is pending too; the launch retry clears it.
    backend.failRemoveKeys = ["anthropicKey", "groqKey"]
    await store.cancelPasswordRecovery()
    expectEqual(store.authenticationGateState, .signedOut, "sanity: cancelPasswordRecovery reached the recovery sign-out")
    expect(FileManager.default.fileExists(atPath: marker.path), "1b: a recovery exit's failed wipe is pending")
    backend.failRemoveKeys = []
    let (launched, _) = makeStore("wipe-fail", backend: backend, group: group, directory: directory)
    expect(!FileManager.default.fileExists(atPath: marker.path), "1b: the launch retry clears the marker")
    expect(backend.values["groqKey"] == nil, "1b: …after removing the key")
    _ = launched
}

// MARK: - 3b. Phase 12.00b.2-A: boundary steps survive a double failure

/// Makes `directory` refuse new entries, so a boundary-step file marker
/// cannot be written there (a full or read-only volume). False when the
/// environment ignores the permission (for example, running as root).
func makeReadOnly(_ directory: URL) -> Bool {
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    let probe = directory.appending(path: "probe-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return true }
    try? FileManager.default.removeItem(at: probe)
    return false
}

func makeWritable(_ directory: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
}

/// The Keychain accounts that hold a boundary-step record (L286.5b).
func boundaryRecords(_ backend: MemorySecureBackend) -> [String] {
    backend.values.keys.filter { $0.hasPrefix("account-boundary-") }.sorted()
}

/// L286.5b (S1): for every (marker write fails) × (wipe fails) combination
/// followed by a relaunch — a fresh store on the same directory and Keychain —
/// the previous owner's keys are unreadable through every gated path (the
/// wipe still reads as pending, or the keys are gone), and a later successful
/// retry clears the pending state and reopens the gates.
@MainActor
func testAIKeyWipeSurvivesDoubleFailureAndRelaunch() async {
    for markerFails in [false, true] {
        for wipeFails in [false, true] {
            let label = "L286.5b ai-key-wipe (marker \(markerFails ? "fails" : "ok"), wipe \(wipeFails ? "fails" : "ok"))"
            let group = TempAppGroup("double-\(markerFails)-\(wipeFails)")
            defer { group.cleanUp() }
            let backend = MemorySecureBackend()
            let (store, directory) = makeStore("double", backend: backend, group: group)
            defer { makeWritable(directory); try? FileManager.default.removeItem(at: directory) }
            let marker = directory.appending(path: "store.json").appendingPathExtension("ai-key-wipe-pending")
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
            store.scheduleBookingTestSeedIdentityActivator()
            expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "\(label): owner A saves Anthropic")
            expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "\(label): owner A saves Groq")

            if wipeFails { backend.failRemoveKeys = ["anthropicKey", "groqKey"] }
            if markerFails { expect(makeReadOnly(directory), "\(label): sanity: the marker write can be made to fail") }
            await store.useAnotherAccount(clearGoogleCredential: {})
            expectEqual(store.authenticationGateState, .signedOut, "\(label): sanity: the switch reached its success path")
            expectEqual(store.isAccountBoundaryCleanupPending, wipeFails, "\(label): the cleanup retry is offered exactly while the wipe is pending")
            if markerFails {
                expect(!FileManager.default.fileExists(atPath: marker.path), "\(label): sanity: no file marker was written")
                expect(store.boundaryStepMarkerWriteFailureCount >= 1, "\(label): the marker write failure is counted")
            }

            // Relaunch (the volume still refuses the file marker when it did
            // before), then the next owner signs in.
            let (relaunched, _) = makeStore("double", backend: backend, group: group, directory: directory)
            relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: "bind-b")
            if wipeFails {
                expect(backend.values["anthropicKey"] != nil, "\(label): sanity: A's key is still in the Keychain")
                expect(relaunched.advisoryAnthropicKey == nil && relaunched.advisoryGroqKey == nil,
                       "\(label): after the relaunch the coach reads no client key")
                expectEqual(relaunched.coachProviderSummary.analyticsName, "backend", "\(label): …so B's coach uses the backend")
                expect(!relaunched.aiProviderKeyIsSaved(.anthropic) && !relaunched.aiProviderKeyIsSaved(.groq),
                       "\(label): Settings shows no saved key")
                expectEqual(relaunched.setAIProviderKey(.groq, entry: groqKey), .rejected(.groq, .unavailable),
                            "\(label): no key can be saved while the wipe is pending")
                expect(relaunched.isAccountBoundaryCleanupPending, "\(label): the relaunch offers the cleanup retry")
            } else {
                expect(backend.values["anthropicKey"] == nil && backend.values["groqKey"] == nil, "\(label): A's keys are gone")
                expect(!relaunched.isAccountBoundaryCleanupPending, "\(label): nothing is pending after the relaunch")
            }

            // A later successful retry clears the pending state and reopens
            // the gates.
            makeWritable(directory)
            backend.failRemoveKeys = []
            relaunched.retryAccountScrub()
            expect(backend.values["anthropicKey"] == nil && backend.values["groqKey"] == nil, "\(label): the retry removed A's keys")
            expect(!FileManager.default.fileExists(atPath: marker.path), "\(label): no file marker remains")
            expect(boundaryRecords(backend).isEmpty, "\(label): no Keychain boundary record remains")
            expect(!relaunched.isAccountBoundaryCleanupPending, "\(label): the cleanup retry is no longer offered")
            expectEqual(relaunched.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "\(label): B can save once the retry succeeded")
            expectEqual(relaunched.advisoryGroqKey, groqKey, "\(label): …and the coach reads B's own key")
        }
    }
}

/// L286.5b: the Keychain record's own failures fail closed. An unreadable
/// record gates both steps as pending without running them (no wipe of the
/// current owner's key on a guess) until a retry can read it; a record that
/// cannot be removed keeps its step pending across a relaunch.
@MainActor
func testBoundaryRecordFailuresFailClosed() async {
    let group = TempAppGroup("record")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("record", backend: backend, group: group)
    defer { makeWritable(directory); try? FileManager.default.removeItem(at: directory) }
    let recordAccount = NativeKeychainSecureSettingsStore.boundaryStepRecordAccount(.aiKeyWipe)
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic")

    // Unreadable at launch, absent once readable.
    backend.failRead = true
    let (unreadable, _) = makeStore("record", backend: backend, group: group, directory: directory)
    backend.failRead = false
    unreadable.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    expect(unreadable.isAccountBoundaryCleanupPending, "L286.5b: an unreadable record gates as pending")
    expect(unreadable.advisoryAnthropicKey == nil, "L286.5b: …so the coach reads no client key")
    expect(unreadable.boundaryStepRecordFailureCount >= 1, "L286.5b: …and the read failure is counted")
    expect(backend.values["anthropicKey"] != nil, "L286.5b: the step did not run on a guess")
    unreadable.retryAccountScrub()
    expect(!unreadable.isAccountBoundaryCleanupPending, "L286.5b: a readable, absent record reopens the gates")
    expectEqual(unreadable.advisoryAnthropicKey, anthropicKey, "L286.5b: …with the owner's own key intact")

    // Unreadable at launch, present once readable: the step runs then.
    backend.values[recordAccount] = Data(#"{"schemaVersion":1}"#.utf8)
    backend.failRead = true
    let (recorded, _) = makeStore("record", backend: backend, group: group, directory: directory)
    backend.failRead = false
    recorded.retryAccountScrub()
    expect(backend.values["anthropicKey"] == nil, "L286.5b: a recorded step runs once its record can be read")
    expect(boundaryRecords(backend).isEmpty && !recorded.isAccountBoundaryCleanupPending, "L286.5b: …and its record is removed")

    // The step succeeds but its record cannot be removed.
    recorded.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    recorded.scheduleBookingTestSeedIdentityActivator()
    expectEqual(recorded.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic again")
    backend.failRemoveKeys = [recordAccount]
    expect(makeReadOnly(directory), "sanity: the marker write can be made to fail")
    await recorded.useAnotherAccount(clearGoogleCredential: {})
    makeWritable(directory)
    expect(backend.values["anthropicKey"] == nil, "sanity: the wipe itself succeeded")
    expect(recorded.isAccountBoundaryCleanupPending, "L286.5b: a record that cannot be removed keeps the step pending")
    let (relaunched, _) = makeStore("record", backend: backend, group: group, directory: directory)
    expect(relaunched.isAccountBoundaryCleanupPending, "L286.5b: …across a relaunch")
    backend.failRemoveKeys = []
    relaunched.retryAccountScrub()
    expect(boundaryRecords(backend).isEmpty && !relaunched.isAccountBoundaryCleanupPending, "L286.5b: the retry removes it")
}

/// L286.4 (S2): a pending boundary step is reachable from the manual retry
/// on both of its branches, and sign-up's immediate session retries it before
/// binding the new owner.
@MainActor
func testPendingBoundaryStepsReachEveryRetry() async {
    let group = TempAppGroup("reach")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("reach", backend: backend, group: group)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appending(path: "store.json")
    let marker = storeURL.appendingPathExtension("ai-key-wipe-pending")

    func failSwitch(_ step: String) async {
        store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
        store.scheduleBookingTestSeedIdentityActivator()
        backend.values["anthropicKey"] = Data(anthropicKey.utf8)
        backend.failRemoveKeys = ["anthropicKey"]
        await store.useAnotherAccount(clearGoogleCredential: {})
        expect(FileManager.default.fileExists(atPath: marker.path), "L286.4 \(step): sanity: the wipe is pending")
        expect(store.isAccountBoundaryCleanupPending, "L286.4 \(step): the cleanup retry is offered")
        backend.failRemoveKeys = []
    }

    // The retry while no account scrub is pending.
    await failSwitch("retry, no scrub pending")
    store.retryAccountScrub()
    expect(!FileManager.default.fileExists(atPath: marker.path), "L286.4 retry (no scrub pending): the step ran")
    expect(!store.isAccountBoundaryCleanupPending, "L286.4 retry (no scrub pending): the retry is no longer offered")

    // The retry while a sign-out scrub is also pending: finishing the scrub
    // runs the pending step too.
    await failSwitch("retry, scrub pending")
    do { try Canonical.SnapshotRepository(primaryURL: storeURL).beginAccountScrub(scope: .live) } catch {
        expect(false, "L286.4: could not stage a pending sign-out scrub: \(error)")
    }
    store.retryAccountScrub()
    expect(!store.isAccountScrubBlocked, "L286.4 retry (scrub pending): sanity: the scrub finished")
    expect(!FileManager.default.fileExists(atPath: marker.path), "L286.4 retry (scrub pending): the pending step ran too")
    expect(!store.isAccountBoundaryCleanupPending, "L286.4 retry (scrub pending): the retry is no longer offered")

    // Sign-up's immediate session retries before binding the new owner.
    await failSwitch("sign-up")
    store.testBindSignedUpOwner(subject: "user-b", binding: "bind-b", email: "b@example.test")
    expect(!FileManager.default.fileExists(atPath: marker.path), "L286.4 sign-up: the pre-bind retry cleared the marker")
    expect(backend.values["anthropicKey"] == nil, "L286.4 sign-up: …after removing A's key")
    expect(!store.isAccountBoundaryCleanupPending, "L286.4 sign-up: the retry is no longer offered")
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "L286.4 sign-up: B can save")
}

/// L286.5a (S2): while the wipe is pending, Settings shows "Not set" for
/// both kinds — the same as a kind the previous owner never saved — and
/// offers no Remove, matching the closed change gate.
@MainActor
func testSavedStateHidesAPendingWipe() async {
    let group = TempAppGroup("saved-state")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("saved-state", backend: backend, group: group)
    defer { try? FileManager.default.removeItem(at: directory) }
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    store.scheduleBookingTestSeedIdentityActivator()
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic only")
    backend.failRemoveKeys = ["anthropicKey", "groqKey"]
    await store.useAnotherAccount(clearGoogleCredential: {})
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: "bind-b")
    expect(backend.values["anthropicKey"] != nil, "sanity: A's key is still in the Keychain")
    expect(!store.aiProviderKeyIsSaved(.anthropic), "L286.5a: A's key does not show as saved for B")
    expectEqual(store.aiProviderKeyState(.anthropic), .notSet, "L286.5a: the saved kind reads Not set while pending")
    expectEqual(store.aiProviderKeyState(.groq), .notSet, "L286.5a: …exactly like the kind A never saved")
    expect(!NativeAIProviderKeyPolicy.offersRemove(store.aiProviderKeyState(.anthropic)),
           "L286.5a: no Remove is offered while the change gate is closed")
    backend.failRemoveKeys = []
    store.retryAccountScrub()
    expectEqual(store.aiProviderKeyState(.anthropic), .notSet, "L286.5a: after the wipe the kind is really not set")
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "B saves their own key")
    expectEqual(store.aiProviderKeyState(.anthropic), .saved, "L286.5a: B's own key reads Saved")
}

/// L205.e: the boundary wipe also removes the migrated legacy `providerKey`
/// and `geminiKey` fields, and a failure to remove one is counted and keeps
/// the step pending like the others.
@MainActor
func testBoundaryWipeClearsLegacyKeyFields() async {
    let legacy = ["providerKey": Data("legacy-provider-value".utf8), "geminiKey": Data("legacy-gemini-value".utf8)]
    let group = TempAppGroup("legacy")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("legacy", backend: backend, group: group)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appending(path: "store.json").appendingPathExtension("ai-key-wipe-pending")

    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    store.scheduleBookingTestSeedIdentityActivator()
    backend.values.merge(legacy) { _, new in new }
    await store.useAnotherAccount(clearGoogleCredential: {})
    expect(backend.values["providerKey"] == nil && backend.values["geminiKey"] == nil, "L205.e: the account switch removes the legacy fields")

    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    backend.values.merge(legacy) { _, new in new }
    await store.cancelPasswordRecovery()
    expectEqual(store.authenticationGateState, .signedOut, "sanity: cancelPasswordRecovery reached the recovery sign-out")
    expect(backend.values["providerKey"] == nil && backend.values["geminiKey"] == nil, "L205.e: a recovery exit removes the legacy fields")

    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    store.scheduleBookingTestSeedIdentityActivator()
    backend.values.merge(legacy) { _, new in new }
    let failuresBefore = store.aiProviderKeyWipeFailureCount
    backend.failRemoveKeys = ["geminiKey"]
    await store.useAnotherAccount(clearGoogleCredential: {})
    expect(store.aiProviderKeyWipeFailureCount > failuresBefore, "L205.e: a legacy field that cannot be removed is counted")
    expect(FileManager.default.fileExists(atPath: marker.path), "L205.e: …and keeps the wipe pending")
    backend.failRemoveKeys = []
    store.retryAccountScrub()
    expect(backend.values["geminiKey"] == nil && !FileManager.default.fileExists(atPath: marker.path),
           "L205.e: the retry removes it and clears the marker")
}

// MARK: - 3c. Phase 12.00b.2-A review fix round 1

/// Review I1 (controller ruling: owner-tagged keys) and M2. The triple
/// failure: the file marker, the Keychain record and the wipe all fail, and
/// the process dies before any retry. Nothing durable could record the step,
/// so the relaunch finds nothing pending (the documented residual), but A's
/// keys carry A's tag: the next owner reads none of them and can save their
/// own.
@MainActor
func testTripleFailureLeavesKeysInertForTheNextOwner() async {
    let label = "I1 triple failure"
    let group = TempAppGroup("triple")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("triple", backend: backend, group: group)
    defer { makeWritable(directory); try? FileManager.default.removeItem(at: directory) }
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    store.scheduleBookingTestSeedIdentityActivator()
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "\(label): owner A saves Anthropic")
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "\(label): owner A saves Groq")

    backend.failRemoveKeys = ["anthropicKey", "groqKey"]
    backend.failUpsert = true
    expect(makeReadOnly(directory), "\(label): sanity: the marker write can be made to fail")
    let recordFailuresBefore = store.boundaryStepRecordFailureCount
    await store.useAnotherAccount(clearGoogleCredential: {})
    expectEqual(store.authenticationGateState, .signedOut, "\(label): sanity: the switch reached its success path")
    // M2: the record write failed as well; the step is held in-process only.
    expect(store.boundaryStepRecordFailureCount > recordFailuresBefore, "M2: the record-write failure is counted")
    expect(boundaryRecords(backend).isEmpty, "M2: sanity: no Keychain record could be written")
    expect(store.isAccountBoundaryCleanupPending, "M2: in-process the step is still pending")
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: "bind-b")
    expect(store.advisoryAnthropicKey == nil && store.advisoryGroqKey == nil, "M2: in-process the coach reads no client key")
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .rejected(.groq, .unavailable), "M2: in-process no key can be saved")

    // The process dies before any retry; the relaunch finds nothing pending.
    let (relaunched, _) = makeStore("triple", backend: backend, group: group, directory: directory)
    relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: "bind-b")
    expect(!relaunched.isAccountBoundaryCleanupPending, "M2: the documented residual: after the relaunch nothing reads as pending")
    expect(backend.values["anthropicKey"] != nil && backend.values["groqKey"] != nil, "\(label): sanity: A's keys are still in the Keychain")
    expect(relaunched.advisoryAnthropicKey == nil && relaunched.advisoryGroqKey == nil, "\(label): B's coach reads none of A's keys")
    expectEqual(relaunched.coachProviderSummary.analyticsName, "backend", "\(label): …so B's coach uses the backend")
    expectEqual(relaunched.aiProviderKeyState(.anthropic), .notSet, "\(label): Settings shows Anthropic Not set")
    expectEqual(relaunched.aiProviderKeyState(.groq), .notSet, "\(label): Settings shows Groq Not set")
    expect(!relaunched.aiProviderKeyIsSaved(.anthropic) && !relaunched.aiProviderKeyIsSaved(.groq), "\(label): nothing shows as saved")
    backend.failUpsert = false
    expectEqual(relaunched.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "\(label): B can save their own key")
    expectEqual(relaunched.advisoryGroqKey, groqKey, "\(label): …and B's coach reads it")
    expect(relaunched.advisoryAnthropicKey == nil, "\(label): A's Anthropic key stays inert")
}

/// Review I1: a key reads only for the owner it was saved for. A keeps
/// reading A's keys across a relaunch with no boundary crossed; another
/// owner, no owner, and an untagged item (an RN-era migrated key) read as
/// absent until the owner saves again.
@MainActor
func testKeysReadOnlyForTheirOwner() async {
    let group = TempAppGroup("owner-tag")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("owner-tag", backend: backend, group: group)
    defer { try? FileManager.default.removeItem(at: directory) }
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic")
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "owner A saves Groq")
    expect(!backend.allText.contains("bind-a") && !backend.allText.contains("user-a"),
           "I1: no raw binding or user id is stored with the key")

    // A relaunch with no boundary crossed: A still reads A's keys.
    let (relaunched, _) = makeStore("owner-tag", backend: backend, group: group, directory: directory)
    expect(relaunched.advisoryAnthropicKey == nil && relaunched.advisoryGroqKey == nil,
           "I1: before an owner is verified no key reads")
    relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    expectEqual(relaunched.advisoryAnthropicKey, anthropicKey, "I1: after a relaunch A reads A's Anthropic key")
    expectEqual(relaunched.advisoryGroqKey, groqKey, "I1: …and A's Groq key")
    expectEqual(relaunched.aiProviderKeyState(.anthropic), .saved, "I1: …and Settings shows it saved")

    // Another owner, with no boundary wipe at all: the items are inert.
    relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-b", binding: "bind-b")
    expect(relaunched.advisoryAnthropicKey == nil && relaunched.advisoryGroqKey == nil, "I1: another owner reads none of A's keys")
    expectEqual(relaunched.coachProviderSummary.analyticsName, "backend", "I1: …so their coach uses the backend")
    expectEqual(relaunched.aiProviderKeyState(.groq), .notSet, "I1: …and Settings shows Not set")
    expect(!relaunched.aiProviderKeyIsSaved(.anthropic), "I1: …and nothing saved")

    // An untagged item (an RN-era key the launch migration copied, or any
    // raw write) reads as absent until the owner saves again.
    relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    backend.values["groqKey"] = Data(groqKey.utf8)
    backend.values["anthropicKey"] = Data("  \(anthropicKey)\n".utf8)
    expect(relaunched.advisoryGroqKey == nil && relaunched.advisoryAnthropicKey == nil, "I1: an untagged item reads as absent")
    expectEqual(relaunched.aiProviderKeyState(.groq), .notSet, "I1: …Not set in Settings")
    expectEqual(relaunched.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "I1: saving again tags it for the owner")
    expectEqual(relaunched.advisoryGroqKey, groqKey, "I1: …and it reads again")
}

/// Review M7: deletion's Keychain clear removes the boundary-step records
/// with any backend, not only through the system Keychain's whole-service
/// delete; sign-out's clear keeps them.
func testDeletionClearRemovesBoundaryRecords() {
    let backend = MemorySecureBackend()
    let store = NativeKeychainSecureSettingsStore(backend: backend)
    let steps = Canonical.SnapshotRepository.BoundaryStep.allCases
    do {
        for step in steps { try store.recordBoundaryStep(step) }
        try store.clearAccountValues()
    } catch {
        expect(false, "M7: sign-out clear threw \(error)")
    }
    expectEqual(boundaryRecords(backend).count, steps.count, "M7: sign-out's clearAccountValues keeps the step records")
    do { try store.clearAllValues() } catch { expect(false, "M7: deletion clear threw \(error)") }
    expect(boundaryRecords(backend).isEmpty, "M7: deletion's clearAllValues removes every step record")
}

/// Review M1: scene activation re-reads a record that was unreadable at
/// launch (for example before first unlock), so the owner's gates reopen
/// without a tap, a sign-in or a relaunch.
@MainActor
func testActivationRereadsAnUnverifiedStep() async {
    let group = TempAppGroup("activation")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("activation", backend: backend, group: group)
    defer { try? FileManager.default.removeItem(at: directory) }
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic")

    backend.failRead = true
    let (relaunched, _) = makeStore("activation", backend: backend, group: group, directory: directory)
    backend.failRead = false
    relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    expect(relaunched.isAccountBoundaryCleanupPending, "M1: sanity: an unreadable record gates as pending")
    relaunched.retryAccountBoundaryCleanupOnActivation()
    expect(!relaunched.isAccountBoundaryCleanupPending, "M1: scene activation re-reads the record and reopens the gates")
    expectEqual(relaunched.advisoryAnthropicKey, anthropicKey, "M1: …with the owner's own key intact")
}

/// Review M1: a step still pending when a sign-out scrub succeeds is retried
/// right after it, so the sign-in screen shows no cleanup banner for data
/// the scrub already removed.
@MainActor
func testSignOutScrubFinishesAPendingStep() async {
    let group = TempAppGroup("scrub-step")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("scrub-step", backend: backend, group: group)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appending(path: "store.json").appendingPathExtension("ai-key-wipe-pending")
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    store.scheduleBookingTestSeedIdentityActivator()
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "owner A saves Anthropic")
    backend.failRemoveKeys = ["anthropicKey"]
    await store.useAnotherAccount(clearGoogleCredential: {})
    expect(FileManager.default.fileExists(atPath: marker.path) && store.isAccountBoundaryCleanupPending, "M1: sanity: the wipe is pending")
    backend.failRemoveKeys = []

    store.scheduleBookingTestSeedSignedInOwner(subject: "user-a", binding: "bind-a")
    do { try await store.signOut(revokeRemote: false) } catch { expect(false, "M1: signOut threw \(error)") }
    expect(!FileManager.default.fileExists(atPath: marker.path), "M1: a successful sign-out scrub also finishes the pending step")
    expect(!store.isAccountBoundaryCleanupPending, "M1: …so the sign-in screen shows no cleanup banner")
}

// MARK: - 4. Redaction and storage

@MainActor
func testAnalyticsNeverCarriesAKey() async {
    let group = TempAppGroup("analytics")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let adapter = FakeAnalyticsAdapter()
    var diagnostics: [NativeAnalyticsDiagnostic] = []
    let transport = NativeAnalyticsTransport(adapter: adapter, diagnostics: { diagnostics.append($0) }, catalogViolation: { _ in })
    let (store, directory) = makeStore("analytics", backend: backend, group: group, analytics: transport)
    defer { try? FileManager.default.removeItem(at: directory) }
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-analytics", binding: "bind-analytics")
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "save Anthropic (analytics)")
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "save Groq (analytics)")

    // The real call site: ai_chat_sent carries the provider name only.
    adapter.calls = []
    store.trackCoachMessageSent(sourceIsInsightPrefill: false)
    if case .capture(let event, let properties)? = adapter.calls.last {
        expectEqual(event, "ai_chat_sent", "the coach send event is captured")
        expectEqual(properties["provider"], .string("anthropic"), "provider is the provider name only")
        expectEqual(Set(properties.keys), ["source", "provider"], "no other property rides along")
    } else {
        expect(false, "ai_chat_sent reached the adapter")
    }

    // Adversarial: the key in every slot a mistaken call site could use.
    for key in [anthropicKey, groqKey, "  \(anthropicKey)\n"] {
        transport.track("ai_chat_sent", ["source": .string("organic"), "provider": .string(key)])
        transport.track("ai_chat_sent", ["source": .string("organic"), "provider": .string("anthropic"), "apiKey": .string(key)])
        transport.track("ai_chat_sent", ["source": .string("organic"), "provider": .string("anthropic"), "anthropicKey": .string(key), "groqKey": .string(key)])
        transport.track("ai_chat_sent", ["source": .string("organic"), "provider": .string("anthropic"), "tags": .strings([key])])
        transport.track("app_opened", ["context": .string("key \(key)")])
        transport.track(key, [:])
        transport.identify(key)
        transport.screen(key)
    }
    let observed = adapter.observed + "\n" + diagnostics.map(\.message).joined(separator: "\n")
    expectNoLeak(observed, "analytics adapter calls and diagnostics")
    for key in [anthropicKey, groqKey] {
        let label = key.hasPrefix("gsk_") ? "Groq" : "Anthropic"
        expect(NativeAnalyticsPrivacyPolicy.screenNameRejection(key) != nil, "a \(label) key is not a valid screen name")
        expect(NativeAnalyticsPrivacyPolicy.identityRejection(key) != nil, "a \(label) key is not a valid distinct id")
        expectEqual(NativeAnalyticsDiagnostic.sanitizedName(key), "<redacted>", "a \(label) key is never echoed as a name")
    }
    expect(adapter.calls.contains { if case .capture("ai_chat_sent", _) = $0 { return true }; return false },
           "sanity: sanitized events still reached the adapter")
}

@MainActor
func testCrashPayloadsNeverCarryAKey() async {
    let group = TempAppGroup("crash")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let adapter = FakeCrashAdapter()
    let reporter = NativeCrashReporter(adapter: adapter)
    let (store, directory) = makeStore("crash", backend: backend, group: group, crashReporting: reporter)
    defer { try? FileManager.default.removeItem(at: directory) }
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-crash", binding: "bind-crash")
    _ = store.setAIProviderKey(.anthropic, entry: anthropicKey)
    _ = store.setAIProviderKey(.groq, entry: groqKey)

    // The key in a non-Error value, in the context, and in an Error's text.
    for key in [anthropicKey, groqKey] {
        store.reportError(["code": "401", "message": "invalid x-api-key: \(key)"], context: [
            "context": "coach send failed for \(key)",
            "operation": key,
            "anthropicKey": key,
            "groqKey": key,
            "apiKey": key,
        ])
        store.reportError(key, context: ["context": "settings-ai"])
        store.reportError(NSError(domain: "Coach", code: 401, userInfo: [
            NSLocalizedDescriptionKey: "Provider rejected Bearer \(key)",
            NSDebugDescriptionErrorKey: "request failed key=\(key)",
        ]), context: ["context": "coach", "rawError": ["message": key, "hint": "check \(key)"]])
    }
    reporter.waitUntilIdle()
    expectEqual(adapter.reports.count, 6, "every report reached the adapter")

    let redaction = NativeErrorRedaction.standard
    var everything = ""
    for report in adapter.reports {
        everything += "\(report.title ?? "") \(canonicalJSON(report.extras)) \(report.fingerprint)\n"
        // What the SDK's `beforeSend` sees: the adapter's event mapping of the
        // captured error, plus SDK breadcrumbs and a request with headers.
        let ns = report.error as NSError
        var event = NativeCrashEventPayload()
        event.message = report.title
        event.exceptions = [.init(type: ns.domain, value: "\(ns.localizedDescription) \(ns.userInfo[NSDebugDescriptionErrorKey] ?? "")",
                                  mechanismDescription: nil, mechanismData: ["apiKey": anthropicKey])]
        event.extras = report.extras
        event.tags = ["provider": "anthropic", "groqKey": groqKey]
        event.contexts = ["app": ["anthropicKey": anthropicKey, "note": "sent \(groqKey)"]]
        event.breadcrumbs = [NativeCrashBreadcrumbPayload(category: "http", type: "http",
                                                          message: "POST https://api.anthropic.com/v1/messages x-api-key: \(anthropicKey)",
                                                          data: ["headers": ["x-api-key": anthropicKey], "value": groqKey])]
        event.request = .init(url: "https://api.groq.com/openai/v1/chat/completions?key=\(groqKey)", method: "POST",
                              headers: ["Authorization": "Bearer \(groqKey)", "x-api-key": anthropicKey],
                              cookies: nil, queryString: "key=\(groqKey)", fragment: nil, bodySize: 10)
        let redacted = redaction.redactEvent(event)
        everything += canonicalJSON(redacted.jsonObject) + "\n"
    }
    expectNoLeak(everything, "crash reports and redacted crash events")
    expect(everything.contains("[Filtered]"), "sanity: redaction replaced the keys")
}

@MainActor
func testKeysNeverReachDefaultsAppGroupWidgetOrFiles() async {
    let group = TempAppGroup("storage")
    defer { group.cleanUp() }
    let backend = MemorySecureBackend()
    let (store, directory) = makeStore("storage", backend: backend, group: group)
    defer { try? FileManager.default.removeItem(at: directory) }
    store.installWidgetMirror(group.mirror())
    store.scheduleBookingTestSeedSignedInOwner(subject: "user-storage", binding: "bind-storage")
    await settle()
    expectEqual(store.setAIProviderKey(.anthropic, entry: anthropicKey), .saved(.anthropic), "save Anthropic (storage)")
    expectEqual(store.setAIProviderKey(.groq, entry: groqKey), .saved(.groq), "save Groq (storage)")
    store.save()
    _ = store.refreshWidgetMirror(force: true)
    await settle()
    expect(group.defaults.string(forKey: WidgetAppGroup.snapshotKey) != nil, "sanity: the widget snapshot was written")
    expectNoLeak(group.defaults.string(forKey: WidgetAppGroup.snapshotKey) ?? "", "widget snapshot")
    expectNoLeak(group.everything, "App Group suite")
    expectNoLeak("\(UserDefaults.standard.dictionaryRepresentation())", "UserDefaults.standard")
    if let live = UserDefaults(suiteName: WidgetAppGroup.suiteName) {
        expectNoLeak("\(live.dictionaryRepresentation())", "the real App Group suite (read only)")
    }
    expect(FileManager.default.fileExists(atPath: directory.appending(path: "store.json").path), "sanity: the business file exists")
    expectNoLeak(filesText(in: directory), "business-data files")
    expectNoLeak(store.recordedDiagnostics.joined(separator: "\n"), "AppStore diagnostics")
    expectNoLeak("\(store.settings)", "BusinessSettings projection")
    expect(NativeAIProviderKeyOwnerTag.open(backend.values["anthropicKey"], binding: "bind-storage") == anthropicKey,
           "the key lives only in the secure store")
}

// MARK: - 5. Source checks

/// The body of the first function declared by `marker`, brace-matched to its
/// end (fix round 1, M6: replaces a fixed 4,000-character window).
func functionBody(_ text: String, _ marker: String) -> String? {
    guard let start = text.range(of: marker) else { return nil }
    // Skip the parameter list (a default argument may hold a closure).
    var bodySearch = start.upperBound
    if marker.hasSuffix("(") {
        var parens = 1
        while bodySearch < text.endIndex, parens > 0 {
            if text[bodySearch] == "(" { parens += 1 }
            if text[bodySearch] == ")" { parens -= 1 }
            bodySearch = text.index(after: bodySearch)
        }
    }
    guard let open = text[bodySearch...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = open
    while index < text.endIndex {
        switch text[index] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 { return String(text[start.lowerBound...index]) }
        default: break
        }
        index = text.index(after: index)
    }
    return nil
}

func testSources(root: URL) {
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appending(path: path), encoding: .utf8)) ?? ""
    }
    let policy = source("native/TradeReadyNative/NativeAIProviderKeyPolicy.swift")
    let storeExtension = source("native/TradeReadyNative/NativeAIProviderKeyStore.swift")
    let settings = source("native/TradeReadyNative/SettingsView.swift")
    let appStore = source("native/TradeReadyNative/AppStore.swift")
    expect(!policy.isEmpty && !storeExtension.isEmpty && !settings.isEmpty && !appStore.isEmpty, "sources readable")

    // No logging, defaults, or telemetry in the key files.
    let ownerTag = source("native/TradeReadyNative/NativeAIProviderKeyOwnerTag.swift")
    expect(!ownerTag.isEmpty, "owner-tag source readable")
    for (name, text) in [("policy", policy), ("store", storeExtension), ("owner tag", ownerTag)] {
        for banned in ["print(", "NSLog", "Logger(", "os_log", "UserDefaults", "AppStorage", "reportError", "track(", "SecItem"] {
            expect(!text.contains(banned), "\(name) file does not use \(banned)")
        }
    }
    expect(!policy.contains("import SwiftUI") && !policy.contains("import Security"), "policy is Foundation-only")

    // The page: SecureField only, no key in @AppStorage/defaults, no log.
    if let start = settings.range(of: "struct AISettings: View"),
       let end = settings.range(of: "struct NotificationSettings: View", range: start.upperBound..<settings.endIndex) {
        let page = String(settings[start.lowerBound..<end.lowerBound])
        expect(page.contains("SecureField("), "key entry uses SecureField")
        expect(!page.contains("TextField("), "no plain TextField on the AI page")
        for banned in ["AppStorage", "UserDefaults", "print(", "Logger(", "reportError", "store.settings", "SceneStorage", ".textContentType(.password"] {
            expect(!page.contains(banned), "AI page does not use \(banned)")
        }
        expect(page.contains("NativeAIProviderKeyPolicy.introHint") && page.contains("NativeAIProviderKeyPolicy.storageNote"),
               "the page renders the policy's RN copy")
        expect(page.contains("store.setAIProviderKey(") && page.contains("store.clearAIProviderKey("), "the page saves and removes through AppStore")
    } else {
        expect(false, "AISettings page found")
    }

    // Every account-scrub site uses the injected secure store (the same one
    // the keys are written to), never a fresh default.
    for marker in ["func signOut(", "func deleteAccount(", "func retryAccountScrub(", "func useAnotherAccount(",
                   "func updateRecoveredPassword(", "func cancelPasswordRecovery(", "func dismissInvalidPasswordRecovery("] {
        guard let body = functionBody(appStore, marker) else { expect(false, "\(marker) found"); continue }
        expect(body.count > 200 && body.hasSuffix("}"), "\(marker) body scanned to its end")
        expect(!body.contains("NativeKeychainSecureSettingsStore()"), "\(marker) uses the injected secure store")
    }
    // Fix round 1 (M1): no AppStore path builds its own secure store.
    expect(!appStore.contains("NativeKeychainSecureSettingsStore()"), "AppStore never constructs its own secure store")
    // Fix round 1 (I1): the switch wipes before its first await and after its last.
    if let body = functionBody(appStore, "func useAnotherAccount(") {
        let wipe = "wipeAIProviderKeysForAccountBoundary()"
        let first = body.range(of: wipe)
        let last = body.range(of: wipe, options: .backwards)
        let clear = body.range(of: "await activator.clearSession()")
        let logOut = body.range(of: "await subscriptionService.logOut()")
        if let first, let last, let clear, let logOut {
            expect(first.lowerBound < clear.lowerBound, "switch wipes keys before the first await")
            expect(last.lowerBound > logOut.upperBound, "switch wipes keys after the last await")
        } else {
            expect(false, "switch wipe and awaits found")
        }
        expect(body.contains("accountSwitchInFlight = true"), "switch closes the key gate")
    }
    if let gate = functionBody(appStore, "private var canChangeAIProviderKeys") {
        expect(gate.contains("!accountSwitchInFlight"), "the key gate is closed during an account switch")
    }
    if let recovery = functionBody(appStore, "private func applyRecoverySignedOutState(") {
        expect(recovery.contains("wipeAIProviderKeysForAccountBoundary()"), "recovery sign-out wipes keys")
    }
    for marker in ["func updateRecoveredPassword(", "func cancelPasswordRecovery("] {
        expect(functionBody(appStore, marker)?.contains("applyRecoverySignedOutState()") == true, "\(marker) ends in the recovery sign-out")
    }
    expect(appStore.contains("case .live: try secureSettingsStore.clearAccountValues()"), "launch recovery / retry wipe via the injected store")
    expect(appStore.contains("performLocalAccountScrub(sessionStore: secureSettingsStore, scope: .live)"), "sign-out scrub uses the injected store")
    expect(appStore.contains("performLocalAccountScrub(sessionStore: secureSettingsStore, scope: .all)"), "deletion scrub uses the injected store")
    expect(appStore.contains("secureSettingsStore.readAIProviderKey(.anthropic, ownerBinding: verifiedAccountBinding)")
           && appStore.contains("secureSettingsStore.readAIProviderKey(.groq, ownerBinding: verifiedAccountBinding)"),
           "the coach reads the keys through the same store, for the verified owner (review I1)")

    // Phase 12.00b.2-A.
    // L286.4: the non-blocking retry banner is driven by the boundary-step
    // flag and runs `retryAccountScrub`.
    let rootView = source("native/TradeReadyNative/RootView.swift")
    let banner = source("native/TradeReadyNative/NativeAccountCleanupBanner.swift")
    expect(rootView.contains("NativeAccountCleanupBanner()"), "L286.4: RootView shows the account-cleanup banner")
    expect(banner.contains("store.isAccountBoundaryCleanupPending"), "L286.4: the banner is gated on the pending boundary steps")
    expect(banner.contains("store.retryAccountScrub()") && banner.contains("Try cleanup again"), "L286.4: the banner's button runs the retry")
    // L286.4: sign-up's immediate session binds through the same pre-bind retry.
    if let signUp = functionBody(appStore, "func signUp(") {
        expect(signUp.contains("bindInteractiveOwner("), "L286.4: signUp binds through bindInteractiveOwner")
        expect(!signUp.contains("applyAuthenticatedIdentityOutcome("), "L286.4: signUp never binds directly")
    } else {
        expect(false, "signUp found")
    }
    expect(functionBody(appStore, "private func finishInteractiveSignIn(")?.contains("bindInteractiveOwner(") == true,
           "L286.4: interactive sign-in binds through bindInteractiveOwner")
    if let bind = functionBody(appStore, "private func bindInteractiveOwner("),
       let retry = bind.range(of: "retryPendingBoundarySteps()"),
       let apply = bind.range(of: "applyAuthenticatedIdentityOutcome(") {
        expect(retry.lowerBound < apply.lowerBound, "L286.4: the pending steps are retried before the owner is bound")
    } else {
        expect(false, "L286.4: bindInteractiveOwner retries, then binds")
    }
    // L286.5a: the saved state is gated like the advisory reads.
    expect(functionBody(appStore, "func aiProviderKeyState(")?.contains("isBoundaryStepPending(.aiKeyWipe)") == true,
           "L286.5a: aiProviderKeyState is gated on the pending wipe")
    // L205.g: the key rows never read the Keychain in `body`.
    if let start = settings.range(of: "private struct AIProviderKeySection: View"),
       let body = settings.range(of: "var body: some View", range: start.upperBound..<settings.endIndex),
       let end = settings.range(of: "private func save()", range: body.upperBound..<settings.endIndex) {
        let rowBody = String(settings[body.lowerBound..<end.lowerBound])
        expect(!rowBody.contains("store.aiProviderKeyState("), "L205.g: the key row's body does no Keychain read")
        expect(settings[start.lowerBound..<end.lowerBound].contains(".onChange(of: store.isAccountBoundaryCleanupPending)"),
               "L205.g: the cached state refreshes when a boundary step changes")
    } else {
        expect(false, "AIProviderKeySection found")
    }
    // L286.3: the stale claim about the switch is gone.
    expect(!appStore.contains("`useAnotherAccount` does not hold"), "L286.3: no stale comment about the switch's operation flag")

    // Review fix round 1.
    // M1: every scene activation retries the pending boundary steps, which
    // re-reads a record that was unreadable at launch.
    let app = source("native/TradeReadyNative/TradeReadyNativeApp.swift")
    if let active = app.range(of: "case .active:"),
       let background = app.range(of: "case .background:", range: active.upperBound..<app.endIndex) {
        expect(app[active.upperBound..<background.lowerBound].contains("store.retryAccountBoundaryCleanupOnActivation()"),
               "M1: scene activation retries the pending boundary steps")
    } else {
        expect(false, "M1: the scene activation branch found")
    }
    // M3 (L286.7): each session-rejected catch tears down through
    // `applyRejectedSessionState()` and nothing else.
    if let activation = functionBody(appStore, "func activateMigratedAuthenticatedIdentity(") {
        for error in ["rejectedSession", "malformedStoredSession", "missingAccessToken", "missingRefreshToken"] {
            guard let caught = activation.range(of: "catch NativeAuthenticatedIdentityError.\(error) {"),
                  let close = activation.range(of: "}", range: caught.upperBound..<activation.endIndex)
            else { expect(false, "M3: the \(error) catch found"); continue }
            let handler = activation[caught.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            expectEqual(handler, "applyRejectedSessionState()", "M3: the \(error) catch runs applyRejectedSessionState() only")
        }
    } else {
        expect(false, "M3: activateMigratedAuthenticatedIdentity found")
    }
}

// MARK: - Main

@main
struct AIProviderKeyTests {
    @MainActor
    static func main() async {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        testCopy()
        testTrimAndValidation()
        testMessagesNeverEchoTheEntry()
        testMaskedDisplay()
        testStoredValueRule()
        testApplyOutcome()
        testPrecedence()
        testSecureStore()
        testOwnerWipe()
        await testAppStoreWiring()
        await testAppStoreOwnerWipe()
        await testAppStoreAccountSwitchWipesKeys()
        await testAppStoreRecoveryExitWipesKeys()
        await testAppStoreBoundaryWipeFailureFailsClosed()
        await testAIKeyWipeSurvivesDoubleFailureAndRelaunch()
        await testBoundaryRecordFailuresFailClosed()
        await testPendingBoundaryStepsReachEveryRetry()
        await testSavedStateHidesAPendingWipe()
        await testBoundaryWipeClearsLegacyKeyFields()
        await testTripleFailureLeavesKeysInertForTheNextOwner()
        await testKeysReadOnlyForTheirOwner()
        testDeletionClearRemovesBoundaryRecords()
        await testActivationRereadsAnUnverifiedStep()
        await testSignOutScrubFinishesAPendingStep()
        await testAnalyticsNeverCarriesAKey()
        await testCrashPayloadsNeverCarryAKey()
        await testKeysNeverReachDefaultsAppGroupWidgetOrFiles()
        testSources(root: root)
        if failures > 0 {
            print("ai-provider-key tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("ai-provider-key tests: \(checks)/\(checks) checks passed")
    }
}
