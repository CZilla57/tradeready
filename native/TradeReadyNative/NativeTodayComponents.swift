import SwiftUI

/// Today screen sub-components (task 10.11, requirements D1, D2, D3, D6).
///
/// Ported section-for-section from `screens/TodayScreen.tsx`'s local
/// components (`WeekStrip`, `StatsRow`, `BriefingSection`, `OverdueInvoiceRow`,
/// `LeadRow`, `SeeMoreRow`, `JobCard`, `ScheduleStop`, `EmptySchedule`) plus
/// the first-action hero and the booking-attention row. All selection,
/// caps, ordering, and label text come from `AppStore`'s `today*` wiring
/// (which itself is a thin pass-through to the pure `NativeTodayBriefing`,
/// task 10.04) or from RN's copy verbatim — nothing here re-derives policy.

// MARK: - Money formatting

func nativeTodayMoney(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).doubleValue.currency
}

// MARK: - Relative date formatting

/// `daysAgo` (`utils/dateHelpers.ts`) ported verbatim: whole-day floor of a
/// real timestamp difference (not a date-only local-frame walk — `createdAt`
/// is a full ISO instant), "today" / "1 day ago" / "N days ago".
func nativeTodayDaysAgo(_ dateString: String, now: Date = Date()) -> String {
    guard let then = nativeTodayParseISO8601(dateString) else { return "recently" }
    let diff = Int(floor(now.timeIntervalSince(then) / 86400))
    if diff == 0 { return "today" }
    if diff == 1 { return "1 day ago" }
    return "\(diff) days ago"
}

private func nativeTodayParseISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

// MARK: - Week strip

private let nativeTodayDayLetters = ["M", "T", "W", "T", "F", "S", "S"]

struct NativeTodayWeekStripView: View {
    let strip: NativeWeekStrip
    let onSelectDay: (String) -> Void
    let onPrevWeek: () -> Void
    let onNextWeek: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(strip.monthLabel.uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Button(action: onPrevWeek) {
                    Text("‹").font(.title2)
                }
                .accessibilityLabel("Previous week")

                ForEach(Array(strip.days.enumerated()), id: \.element.date) { index, day in
                    Button {
                        onSelectDay(day.date)
                    } label: {
                        VStack(spacing: 4) {
                            Text(nativeTodayDayLetters[index])
                                .font(.caption2.monospaced())
                                .foregroundStyle(day.isSelected ? Color.tradeReady : .secondary)
                            ZStack {
                                Circle()
                                    .fill(day.isSelected ? Color.tradeReady : Color.clear)
                                    .overlay {
                                        if day.isToday, !day.isSelected {
                                            Circle().stroke(Color.tradeReady, lineWidth: 1.5)
                                        }
                                    }
                                    .frame(width: 30, height: 30)
                                Text("\(day.dayNumber)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(day.isSelected ? Color.white : (day.isToday ? Color.tradeReady : .primary))
                            }
                            Circle()
                                .fill(day.hasJobs ? Color.tradeReady : Color.clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(nativeTodayDayLetters[index]), \(day.dayNumber)\(day.hasJobs ? ", has jobs" : "")")
                    .accessibilityAddTraits(day.isSelected ? [.isSelected] : [])
                }

                Button(action: onNextWeek) {
                    Text("›").font(.title2)
                }
                .accessibilityLabel("Next week")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary) }
    }
}

// MARK: - Stats row

struct NativeTodayStatsRowView: View {
    let earnings: Decimal
    let overdueTotal: Decimal
    let overdueCount: Int
    let leadCount: Int
    let onEarningsTap: () -> Void
    let onOverdueTap: () -> Void
    let onLeadsTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statCard(
                label: "TODAY",
                value: nativeTodayMoney(earnings),
                sub: "Expected",
                accent: false,
                tint: .primary,
                action: onEarningsTap,
                accessibilityLabel: "Today's expected earnings: \(nativeTodayMoney(earnings))"
            )
            statCard(
                label: overdueCount > 0 ? "⚠ OVERDUE" : "OVERDUE",
                value: overdueCount > 0 ? nativeTodayMoney(overdueTotal) : "—",
                sub: overdueCount > 0 ? "\(overdueCount) invoice\(overdueCount == 1 ? "" : "s")" : "All clear",
                accent: overdueCount > 0,
                tint: overdueCount > 0 ? .red : .secondary,
                action: onOverdueTap,
                accessibilityLabel: "Overdue invoices: \(overdueCount > 0 ? "\(overdueCount), \(nativeTodayMoney(overdueTotal))" : "none")"
            )
            statCard(
                label: "LEADS",
                value: leadCount > 0 ? "\(leadCount)" : "—",
                sub: leadCount > 0 ? "follow up" : "None pending",
                accent: leadCount > 0,
                tint: leadCount > 0 ? .orange : .secondary,
                action: onLeadsTap,
                accessibilityLabel: "Leads: \(leadCount > 0 ? "\(leadCount) to follow up" : "none pending")"
            )
        }
    }

    private func statCard(
        label: String, value: String, sub: String, accent: Bool, tint: Color,
        action: @escaping () -> Void, accessibilityLabel: String
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption2.monospaced()).foregroundStyle(accent ? tint : .secondary)
                Text(value).font(.title3.weight(.semibold)).foregroundStyle(tint).monospacedDigit()
                Text(sub).font(.caption2).foregroundStyle(accent ? tint : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                accent ? tint.opacity(0.08) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - First-action hero

struct NativeTodayHeroCardView: View {
    let hero: NativeTodayHero
    let onTap: () -> Void

    private var symbol: String {
        switch hero.kind {
        case .sampleTour: "safari"
        case .addCustomer: "person.crop.circle.badge.plus"
        case .createJob: "hammer"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.white.opacity(0.18)).frame(width: 40, height: 40)
                    Image(systemName: symbol).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(hero.title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    Text(hero.subtitle).font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white)
            }
            .padding(14)
            .frame(minHeight: 64)
            .background(Color.tradeReady, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hero.title)
    }
}

// MARK: - Booking attention row
//
// The setup-checklist/insights slot hooks (`NativeTodaySetupChecklistSlot`/
// `NativeTodayInsightsSlot`, task 10.11) are filled by task 10.12's
// `NativeSetupChecklistCardView`/`NativeInsightsCardView`
// (`NativeSetupChecklistCard.swift`/`NativeInsightsCard.swift`), which
// `TodayView.body` now calls directly at the same RN positions.

struct NativeTodayBookingAttentionRow: View {
    let row: NativeBookingAttention.Row
    let onTap: () -> Void

    private var symbol: String {
        row.kind == .rescheduleRequested ? "arrow.left.arrow.right" : "xmark.circle"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.subheadline).foregroundStyle(.orange)
                Text(NativeTodayBriefing.bookingRowLabel(row))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("›").font(.title3).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NativeTodayBriefing.bookingRowLabel(row))
    }
}

// MARK: - Briefing section container

struct NativeTodayBriefingSection<Content: View>: View {
    let title: String
    var actionLabel: String?
    var onAction: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                if let actionLabel, let onAction {
                    Button(action: onAction) {
                        Text(actionLabel.uppercased()).font(.caption2.monospaced().weight(.semibold))
                    }
                    .accessibilityLabel(actionLabel)
                }
            }
            content
        }
    }
}

// MARK: - Overdue invoice row

struct NativeTodayOverdueInvoiceRow: View {
    let invoice: Canonical.Invoice
    let daysPastDue: Int
    let isLast: Bool
    let onTap: () -> Void

    private var isSerious: Bool { daysPastDue > 14 }

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(invoice.customer).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(invoice.number).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(nativeTodayMoney(invoice.amount))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSerious ? .red : .orange)
                        .monospacedDigit()
                    Text("\(daysPastDue)d overdue")
                        .font(.caption2.monospaced())
                        .foregroundStyle(isSerious ? .red : .orange)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((isSerious ? Color.red : .orange).opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast { Divider().padding(.horizontal, 14) }
        }
    }
}

// MARK: - Lead row

struct NativeTodayLeadRow: View {
    let job: Canonical.Job
    let daysAgo: String
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(job.customerName) · added \(daysAgo)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("›").font(.title3).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast { Divider().padding(.horizontal, 14) }
        }
    }
}

// MARK: - See more row

struct NativeTodaySeeMoreRow: View {
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label.uppercased())
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(Color.tradeReady)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - List card wrapper

struct NativeTodayListCard<Content: View>: View {
    var danger = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(danger ? Color.red.opacity(0.4) : Color(.quaternaryLabel), lineWidth: danger ? 1 : 0.5)
            }
    }
}

// MARK: - Job card / schedule stop

private let nativeTodayActiveJobStatuses: Set<String> = ["approved", "scheduled", "in_progress"]

struct NativeTodayJobCard: View {
    let job: Canonical.Job
    let onTap: () -> Void
    let onOnMyWay: () -> Void

    private var status: JobStatus { JobStatus(rawValue: job.status) ?? .lead }
    private var canSendOnMyWay: Bool {
        !(job.scheduledDate ?? "").isEmpty && nativeTodayActiveJobStatuses.contains(job.status)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.title).font(.subheadline.weight(.bold)).lineLimit(1)
                Text(job.address.isEmpty ? job.customerName : "\(job.customerName) · \(job.address)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(status.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(status.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                    Spacer()
                    if canSendOnMyWay {
                        Button(action: onOnMyWay) {
                            Text("On my way").font(.caption.weight(.bold)).foregroundStyle(Color.tradeReady)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("On my way to \(job.customerName)")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary) }
        }
        .buttonStyle(.plain)
    }
}

struct NativeTodayScheduleStop: View {
    let job: Canonical.Job
    let isLast: Bool
    let onTap: () -> Void
    let onOnMyWay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                Text(NativeTodayBriefing.formatTimeRange(job.scheduledStartTime, nil))
                    .font(.caption.monospaced())
                if let end = job.scheduledEndTime, !end.isEmpty {
                    Text(NativeTodayBriefing.formatTimeRange(end, nil))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Circle().fill(Color.tradeReady).frame(width: 7, height: 7)
                if !isLast {
                    Rectangle().fill(Color(.quaternaryLabel)).frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 52)
            NativeTodayJobCard(job: job, onTap: onTap, onOnMyWay: onOnMyWay)
        }
    }
}

struct NativeTodayEmptySchedule: View {
    let onScheduleJob: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("No jobs scheduled today").font(.title3.weight(.semibold))
            Text("Tap below to schedule your first job for today.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onScheduleJob) {
                Text("+ Schedule a Job").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(Color.tradeReady, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
