import SwiftUI
import WidgetKit

// Task 11.03 (W3): the Job Timer widget's rendering only. All state
// resolution (including the queued-action precedence) and the deep-link URL
// are pure Foundation code in `JobTimerWidgetPolicy.swift` (this folder) —
// this view renders exactly the state it is given and never re-derives it.
//
// Lives in Widgets/Shared per the 11.02/11.03 split; this folder compiles
// into both targets (11.01 §7), so `Button(intent:)` below runs 11.04's
// `StartTimerIntent`/`StopTimerIntent` (`WidgetIntents.swift`, same folder)
// in the extension process with no project-file edit. It defines no
// `AppIntent` type of its own.

/// TradeReady ink navy (#0c335e); matches `NextJobWidgetView`'s local copy
/// (that declaration is file-private, so this is its own copy).
private let jobTimerInkNavy = Color(red: 12 / 255, green: 51 / 255, blue: 94 / 255)

struct JobTimerWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let state: JobTimerWidgetState
    let now: Date
    let isPlaceholder: Bool

    var body: some View {
        content
            .redacted(reason: isPlaceholder ? .placeholder : [])
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) { jobTimerInkNavy }
            // The read-only fallback (interactive widgets are opt-in per
            // surface, e.g. StandBy/Lock Screen): tapping anywhere but the
            // button deep-links the job in play, or opens the app root when
            // there is none (`JobTimerWidgetPolicy.deepLinkURL`, §6.1).
            .widgetURL(JobTimerWidgetPolicy.deepLinkURL(for: state))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .running(let timer, let since):
            runningCard(timer: timer, since: since)
        case .pendingStop:
            statusCard(icon: "checkmark.circle", title: "Clocked out", detail: "Open app to sync")
        case .pendingStart:
            statusCard(icon: "hourglass", title: "Starting\u{2026}", detail: "Open app to sync")
        case .idle(let job):
            idleCard(job: job)
        case .noJob:
            statusCard(icon: "clock", title: "No job to clock into", detail: nil)
        case .syncNeeded:
            statusCard(icon: "arrow.clockwise", title: "Open app to sync", detail: nil)
        case .missing:
            statusCard(icon: "clock", title: "Open TradeReady and sign in", detail: nil)
        }
    }

    private func runningCard(timer: WidgetSnapshot.TimerState, since: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            captionLabel("ON THE CLOCK")
            // Ticks on its own with no new timeline entry (WidgetKit-native
            // countup), per the 11.03 brief.
            Text(since, style: .timer)
                .font(.system(size: family == .systemSmall ? 26 : 30, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(timer.jobTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Text(timer.customerName)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 4)
            // Stays enabled even when the snapshot is stale (§3.3): replay
            // clamps and ignores a stop against no open session.
            Button(intent: StopTimerIntent(jobId: timer.jobId)) {
                actionLabel(icon: "stop.fill", title: "Stop")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func idleCard(job: WidgetSnapshot.NextJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            captionLabel("OFF THE CLOCK")
            Text(job.title)
                .font(.system(size: family == .systemSmall ? 15 : 17, weight: .bold))
                .foregroundColor(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(2)
            Text(job.customerName)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(intent: StartTimerIntent(jobId: job.id)) {
                actionLabel(icon: "play.fill", title: "Start")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusCard(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.6))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func captionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .kerning(1.2)
            .foregroundColor(.white.opacity(0.55))
    }

    private func actionLabel(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(jobTimerInkNavy)
        .padding(.vertical, 7)
        .frame(maxWidth: family == .systemSmall ? CGFloat.infinity : 140)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
