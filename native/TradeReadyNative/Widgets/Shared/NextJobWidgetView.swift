import SwiftUI
import WidgetKit

// Task 11.02 (W2): the Next Job widget's rendering only. All state
// resolution, deep-link URL construction and timeline refresh policy are
// pure Foundation code in `NextJobWidgetPolicy.swift` (this folder) — this
// view renders exactly the state it is given and never re-derives it.
//
// Lives in Widgets/Shared per the 11.02 brief; only the extension actually
// hosts a widget using it, but this folder compiles into both targets
// (11.01 §7), so no project-file edit is needed here.

/// TradeReady ink navy (#0c335e), the blueprint brand ground — matches
/// `targets/widget/Widgets.swift`'s `inkNavy`.
private let nextJobInkNavy = Color(red: 12 / 255, green: 51 / 255, blue: 94 / 255)

struct NextJobWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let state: NextJobWidgetState
    let now: Date
    let isPlaceholder: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) { nextJobInkNavy }
            // Whole-card deep link (§6.1). Every state but `.job` is nil, so
            // tapping falls back to WidgetKit's default: opening the app root.
            .widgetURL(deepLinkURL)
    }

    private var deepLinkURL: URL? {
        guard case let .job(job) = state else { return nil }
        return NextJobWidgetPolicy.deepLinkURL(jobID: job.id)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .job(let job):
            jobCard(job)
        case .noUpcomingJob:
            emptyState(systemImage: "calendar.badge.checkmark", message: "No upcoming jobs")
        case .stale:
            emptyState(systemImage: "arrow.clockwise", message: "Open TradeReady to refresh")
        case .missing:
            emptyState(systemImage: "calendar.badge.checkmark", message: "Open TradeReady and sign in")
        }
    }

    @ViewBuilder
    private func jobCard(_ job: WidgetSnapshot.NextJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("NEXT JOB")
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.2)
                .foregroundColor(.white.opacity(0.55))
            Text(NextJobWidgetPolicy.whenLabel(for: job, now: now))
                .font(.system(size: family == .systemSmall ? 15 : 17, weight: .bold))
                .foregroundColor(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(job.customerName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Text(job.title)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(family == .systemSmall ? 2 : 1)
            if family != .systemSmall && !job.address.isEmpty {
                Spacer(minLength: 2)
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11))
                    Text(job.address)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .redacted(reason: isPlaceholder ? .placeholder : [])
    }

    @ViewBuilder
    private func emptyState(systemImage: String, message: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.6))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
