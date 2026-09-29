import AppIntents
import Foundation
import WidgetKit

// Task 11.04 (A1–A3): the two widget-button intents, Start/Stop Job Timer.
//
// Target membership: `N/Widgets/Shared/` compiles into BOTH targets (11.01 §7),
// so `Button(intent:)` in 11.03's Job Timer widget runs these in the extension
// process, and the app target has the same types. Each intent type is defined
// exactly once, here. Every Siri-only intent lives in `N/Intents/` (app only),
// and the `AppShortcutsProvider` in `N/NativeAppIntents.swift` (app only,
// Apple DTS).
//
// Single availability floor: iOS 17.0 on every intent type in the phase
// (contract §5.4; mixed availability is a documented App Intents crash).
//
// These are thin shells over `WidgetIntentEngine` (`WidgetActionQueue.swift`):
// the engine appends under the shared advisory lock, copies the snapshot's
// `ownerTag` from inside the same lock hold, and refuses (writes nothing) when
// there is no snapshot or tag. The extension never writes canonical data and
// never derives a tag. Timelines reload OUTSIDE the lock (§4.2 step 3).

@available(iOS 17.0, *)
struct StartTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Job Timer"
    /// Widget-button-only: a raw job id is meaningless in Shortcuts.
    static let isDiscoverable: Bool = false

    @Parameter(title: "Job ID")
    var jobId: String

    init() {
        jobId = ""
    }

    init(jobId: String) {
        self.jobId = jobId
    }

    func perform() async throws -> some IntentResult {
        let outcome = WidgetIntentEngine().startTimer(jobID: jobId)
        WidgetIntentTimelines.reloadIfNeeded(wroteQueue: outcome.wroteQueue)
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Job Timer"
    static let isDiscoverable: Bool = false

    @Parameter(title: "Job ID")
    var jobId: String

    init() {
        jobId = ""
    }

    init(jobId: String) {
        self.jobId = jobId
    }

    func perform() async throws -> some IntentResult {
        let outcome = WidgetIntentEngine().stopTimer(jobID: jobId)
        WidgetIntentTimelines.reloadIfNeeded(wroteQueue: outcome.wroteQueue)
        return .result()
    }
}

/// Reloads widget timelines after a queue write so the Job Timer widget shows
/// its pending state. Called after the engine returns, i.e. outside the lock.
enum WidgetIntentTimelines {
    static func reloadIfNeeded(wroteQueue: Bool) {
        guard wroteQueue else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
