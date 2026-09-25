import Foundation

/// An owner action that shows the app earning its keep. Only committed,
/// owner-initiated successes count; a sync pull that marks something paid
/// never does (the owner isn't looking at the app when it lands).
enum NativeAppRatingWin: Equatable {
    case invoicePaid
    case estimateSent
}

/// Device-scoped: it holds no account data (a count, a version string, a
/// date), and Apple's own prompt limits are per device, so it deliberately
/// survives account switches instead of being scrubbed at the boundary.
struct NativeAppRatingPromptState: Codable, Equatable {
    var winCount: Int
    var lastPromptedVersion: String?
    var lastPromptedAt: Date?

    static let initial = NativeAppRatingPromptState(winCount: 0, lastPromptedVersion: nil, lastPromptedAt: nil)
}

/// When to ask for an App Store rating (native-only; RN never asked).
///
/// Ask right after the owner gets paid, once they have real use behind them
/// (three wins). An owner who never records payments in-app is asked at ten
/// wins instead. Never twice in one app version, and never within 120 days of
/// the last ask. StoreKit still has the final say (at most three system
/// sheets a year), so this only decides when requesting one is worthwhile.
enum NativeAppRatingPromptPolicy {
    static let minimumWins = 3
    static let fallbackWins = 10
    static let cooldownDays = 120

    static func recording(_ win: NativeAppRatingWin, in state: NativeAppRatingPromptState) -> NativeAppRatingPromptState {
        var next = state
        next.winCount = state.winCount &+ 1
        return next
    }

    /// `state` already includes `win` (call after `recording`).
    static func shouldPrompt(
        after win: NativeAppRatingWin,
        state: NativeAppRatingPromptState,
        appVersion: String,
        now: Date
    ) -> Bool {
        let threshold = win == .invoicePaid ? minimumWins : fallbackWins
        guard state.winCount >= threshold else { return false }
        guard state.lastPromptedVersion != appVersion else { return false }
        if let last = state.lastPromptedAt {
            // A future date (the clock moved back) reads as recent.
            let elapsed = now.timeIntervalSince(last)
            guard elapsed >= Double(cooldownDays) * 86_400 else { return false }
        }
        return true
    }

    static func markingPrompted(
        _ state: NativeAppRatingPromptState,
        appVersion: String,
        now: Date
    ) -> NativeAppRatingPromptState {
        var next = state
        next.lastPromptedVersion = appVersion
        next.lastPromptedAt = now
        return next
    }
}
