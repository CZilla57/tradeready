import Foundation

// Task 11.04 (A1, contract §5.1 "OnMyWay under native"): the in-process hand-off
// from `OnMyWayIntent.perform()` (which runs in the app process because of
// `openAppWhenRun`) to `AppStore.handle(url:)`.
//
// There is no RN `RCTOpenURLNotification` natively. `TradeReadyNativeApp.init`
// installs the handler as soon as the store exists; a URL that arrives before
// then is held (one slot, newest wins) and delivered on install. The App Group
// `pendingOpenUrl` stash the intent also writes stays the cold-launch backstop
// that 11.06 consumes (read-and-remove under the lock, tag + freshness check).
//
// Delivery is navigation only: `handle(url:)` ends in `routeToOnMyWay` →
// `requestOnMyWayReview`, which presents the editable review
// (`NativeOnMyWayReviewView`); nothing is ever sent without the user tapping
// Send in the system composer. Owner/auth/archived gating of `handle(url:)`
// belongs to 11.06 (contract §6.2).
@MainActor
final class NativeIntentURLRouter {
    static let shared = NativeIntentURLRouter()

    private var handler: ((URL) -> Void)?
    private(set) var heldURL: URL?

    init() {}

    func install(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        if let held = heldURL {
            heldURL = nil
            handler(held)
        }
    }

    func open(_ url: URL) {
        if let handler {
            handler(url)
        } else {
            heldURL = url
        }
    }
}
