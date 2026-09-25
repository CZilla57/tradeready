import AppIntents
import Foundation

// Task 11.04 (A1): "On My Way". App target only (`N/Intents/`).
//
// `openAppWhenRun` brings TradeReady to the front and runs `perform()` in the
// app process. The intent never sends anything:
// 1. `WidgetIntentEngine.stashOnMyWay()` takes the shared advisory lock, reads
//    the snapshot (`ownerTag`, freshness, `nextJob`) and writes the tagged
//    `pendingOpenUrl` stash `{url, at, ownerTag}` in that ONE lock hold
//    (contract §4.5, §6.2). No snapshot/tag → "Open TradeReady and sign in
//    first."; stale → "Open TradeReady to refresh your schedule."
//    `perform()` is `@MainActor`, so the lock wait is bounded to 100 ms
//    (Phase 12, 12.00b.2-B): a busy lock writes nothing, opens nothing and
//    speaks the stash-failure dialog "I couldn't open that. Open TradeReady
//    and try again." — the user's request is never silently dropped.
// 2. The URL `tradeready://onmyway/<id>` goes to `NativeIntentURLRouter`,
//    which feeds `AppStore.handle(url:)` → `routeToOnMyWay` →
//    `requestOnMyWayReview`: an editable review, never auto-sent (§5.1).
// The stash is the cold-launch backstop consumed by 11.06.

@available(iOS 17.0, *)
struct OnMyWayIntent: AppIntent {
    static let title: LocalizedStringResource = "On My Way"
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = WidgetIntentEngine().stashOnMyWay()
        if case .opening(let url, _, _) = outcome, let route = URL(string: url) {
            NativeIntentURLRouter.shared.open(route)
        }
        return .result(dialog: "\(SiriIntentDialogs.onMyWay(outcome))")
    }
}
