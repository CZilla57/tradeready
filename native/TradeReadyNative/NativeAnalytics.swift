import Foundation

/// Minimal analytics seam (task 10.12, brief step 6 / ruling R5).
///
/// A pure protocol — event name + string properties, nothing else. No
/// transport lives here: `NativeNoOpAnalytics` is the production default
/// until Phase 11.08 wires a real transport with RN payload parity. Tests
/// inject a recording fake conforming to this same protocol.
///
/// Event names and property keys below mirror `utils/analytics.ts`'s
/// `insight_*`/`sample_job_opened` call sites in `components/InsightsCard.tsx`
/// and `screens/TodayScreen.tsx` verbatim — this seam does not invent new
/// names or drop properties RN sends.
protocol NativeAnalytics {
    func track(_ event: String, _ properties: [String: String])
}

extension NativeAnalytics {
    /// Convenience for the common zero-property call (`sample_job_opened`).
    func track(_ event: String) { track(event, [:]) }
}

/// Production default: does nothing. Never throws, never blocks, never
/// touches the network — safe to call unconditionally from any policy path.
struct NativeNoOpAnalytics: NativeAnalytics {
    func track(_ event: String, _ properties: [String: String]) {}
}
