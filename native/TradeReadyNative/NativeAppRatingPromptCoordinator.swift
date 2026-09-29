import Combine
import Foundation

/// Persists `NativeAppRatingPromptState` in `UserDefaults` (device-scoped; see
/// the state type for why it is not account-bound). An unreadable value starts
/// over: the worst case is one extra request, which StoreKit rate-limits anyway.
struct NativeAppRatingPromptStore {
    static let key = "tradeready.appRatingPrompt.v1"

    let defaults: UserDefaults

    func load() -> NativeAppRatingPromptState {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(NativeAppRatingPromptState.self, from: data)
        else { return .initial }
        return state
    }

    func save(_ state: NativeAppRatingPromptState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Turns owner wins into at most one pending rating request. `AppStore`
/// reports wins through `onAppRatingWin`; `NativeAppRatingPromptPresenter`
/// watches `isRequestPending` and calls `beginPresentation()` right before
/// asking StoreKit, which is when the version/date stamp is written. A request
/// that never reaches the screen (the app went to the background first) is
/// in memory only, so it burns nothing and the next paid win asks again.
@MainActor
final class NativeAppRatingPromptCoordinator: ObservableObject {
    @Published private(set) var isRequestPending = false

    private let store: NativeAppRatingPromptStore
    private let appVersion: String
    private let now: () -> Date

    init(store: NativeAppRatingPromptStore, appVersion: String, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.appVersion = appVersion
        self.now = now
    }

    static func live() -> NativeAppRatingPromptCoordinator {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return NativeAppRatingPromptCoordinator(
            store: NativeAppRatingPromptStore(defaults: .standard),
            appVersion: version
        )
    }

    func recordWin(_ win: NativeAppRatingWin) {
        let state = NativeAppRatingPromptPolicy.recording(win, in: store.load())
        store.save(state)
        if !isRequestPending,
           NativeAppRatingPromptPolicy.shouldPrompt(after: win, state: state, appVersion: appVersion, now: now()) {
            isRequestPending = true
        }
    }

    /// Stamps and clears the pending request. Returns true exactly once per
    /// request; the caller asks StoreKit only when it does.
    func beginPresentation() -> Bool {
        guard isRequestPending else { return false }
        isRequestPending = false
        store.save(NativeAppRatingPromptPolicy.markingPrompted(store.load(), appVersion: appVersion, now: now()))
        return true
    }
}
