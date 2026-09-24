import SwiftUI

/// Job-detail timer card, ported from `TimeTrackingCard` in
/// `screens/JobDetailScreen.tsx`. The readout and the clock button come from
/// `NativeTimeTracking` on one side and the canonical job on the other: the
/// card never holds session state, so a clock-out from the widget/Siri replay
/// path or another device lands as an ordinary canonical change.
struct NativeTimeTrackingSection: View {
    @EnvironmentObject private var store: AppStore
    let jobID: String

    @State private var errorMessage: String?

    private var status: JobLifecycleStatus? {
        store.jobs.first { $0.id == jobID }?.status.lifecycleStatus
    }

    var body: some View {
        if let status, NativeTimeTracking.offers(for: status) {
            Section("Time tracking") {
                // The live timer needs a per-second redraw only while running;
                // an idle card renders once.
                if isClocked {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        card(now: context.date)
                    }
                } else {
                    card(now: .now)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isClocked: Bool {
        store.timeTrackingSummary(jobID: jobID)?.isClocked == true
    }

    @ViewBuilder
    private func card(now: Date) -> some View {
        if let summary = store.timeTrackingSummary(jobID: jobID, now: now) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.timer)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(summary.isClocked ? Color.tradeReady : .primary)
                        .accessibilityLabel(
                            summary.isClocked
                                ? "Timer running, \(summary.timer) elapsed"
                                : "Time tracked, \(summary.timer)"
                        )
                    if let estimate = estimateLine(summary) {
                        estimate
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if summary.sessionCount > 0 {
                    Text(sessionCountText(summary.sessionCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    toggleClock()
                } label: {
                    Label(
                        summary.isClocked ? "Clock out" : "Clock in",
                        systemImage: summary.isClocked ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(summary.isClocked ? .red : .tradeReadyFill)
                .accessibilityLabel(summary.isClocked ? "Clock out" : "Clock in")
            }
            if summary.isClocked, let active = summary.activeSession {
                Text("Session started \(NativeTimeTracking.elapsedLabel(milliseconds: NativeTimeTracking.durationMs(from: active.start, to: now))) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "est. 2h" plus the over/under delta once it is worth mentioning.
    /// React Native compares the delta as an IEEE-754 value (`Math.abs(...) >=
    /// 0.05`), so the gate is measured on the same side of that boundary even
    /// though the rollup itself stays exact here; only the delta is tinted.
    private func estimateLine(_ summary: NativeTimeTrackingSummary) -> Text? {
        guard summary.estimatedHours > 0 else { return nil }
        let base = Text("est. \(hoursLabel(summary.estimatedHours))h")
        guard let overUnder = summary.overUnder else { return base }
        let delta = NSDecimalNumber(decimal: overUnder).doubleValue
        guard abs(delta) >= 0.05 else { return base }
        let signed = "\(delta > 0 ? "+" : "")\(decimalLabel(overUnder))h"
        return base + Text("  \(signed)").foregroundColor(delta > 0 ? .red : .green)
    }

    private func sessionCountText(_ count: Int) -> String {
        "\(count) session\(count == 1 ? "" : "s")"
    }

    /// Whole or half-hour estimates read naturally ("2h", "2.5h") because the
    /// canonical value is the raw decimal the owner typed.
    private func hoursLabel(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func decimalLabel(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0.0"
    }

    /// One-tap clock in/out. Refusals (a timer already running, nothing
    /// running) and failed local commits are explained inline instead of
    /// silently doing nothing.
    private func toggleClock() {
        let clocked = store.timeTrackingSummary(jobID: jobID)?.isClocked == true
        let saved = clocked ? store.clockOut(jobID: jobID) : store.clockIn(jobID: jobID)
        errorMessage = saved ? nil : (store.migrationMessage ?? "The timer could not be updated.")
    }
}
