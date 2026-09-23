import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingCalendar = false
    @State private var showingGlobalSearch = false
    @State private var showingSettings = false
    private var todayJobs: [Job] { store.jobs.filter { $0.scheduledAt.map(Calendar.current.isDateInToday) == true }.sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) } }
    private var overdue: [Invoice] { store.invoices.filter(\.isOverdue) }
    private var awaitingEstimateCount: Int { store.awaitingEstimateFollowUpCount() }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.title.bold())
                        Text("Here’s what needs your attention.").foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        MetricCard(title: "Jobs today", value: "\(todayJobs.count)", symbol: "hammer")
                        MetricCard(title: "Overdue", value: overdue.reduce(0) { $0 + $1.balance }.currency, symbol: "exclamationmark.circle", color: .orange)
                    }

                    section("Schedule") {
                        if todayJobs.isEmpty { EmptyContent(title: "A clear day", message: "Schedule a job and it will appear here.", symbol: "calendar.badge.checkmark") }
                        else {
                            ForEach(todayJobs) { job in
                                Button { store.selectedTab = .jobs; store.deepLinkedJobID = job.id } label: {
                                    HStack(spacing: 14) {
                                        Text(job.scheduledAt?.shortTime ?? "—").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                        VStack(alignment: .leading) { Text(job.title).fontWeight(.semibold); Text(job.customerName).font(.subheadline).foregroundStyle(.secondary) }
                                        Spacer(); StatusBadge(status: job.status)
                                    }
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    if !overdue.isEmpty {
                        section("Needs attention") {
                            ForEach(overdue) { invoice in
                                Button { store.selectedTab = .invoices } label: {
                                    HStack {
                                        Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                                        VStack(alignment: .leading) { Text("\(invoice.number) is overdue").fontWeight(.semibold); Text(invoice.customer).font(.subheadline).foregroundStyle(.secondary) }
                                        Spacer(); Text(invoice.balance.currency).fontWeight(.semibold)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    if awaitingEstimateCount > 0 {
                        Button { store.selectedTab = .jobs } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "hourglass")
                                    .foregroundStyle(.orange)
                                Text(NativeEstimateFollowUp.awaitingResponseLabel(count: awaitingEstimateCount))
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NativeEstimateFollowUp.awaitingResponseLabel(count: awaitingEstimateCount))
                        .accessibilityHint("Opens Jobs")
                    }

                    let bookingSummary = bookingAttentionSummary(store: store)
                    if bookingSummary.hasActionable {
                        let countText = "\(bookingSummary.count) booking request\(bookingSummary.count == 1 ? "" : "s") need attention"
                        Button { showingSettings = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar.badge.exclamationmark")
                                    .foregroundStyle(.orange)
                                Text(countText)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(countText)
                        .accessibilityHint("Opens Settings → Booking Requests")
                    }
                }
                .padding()
            }
            .background(Color.tradeCanvas)
            .navigationTitle(store.settings.businessName)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingGlobalSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search everything")
                    Button { showingCalendar = true } label: { Image(systemName: "calendar") }
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showingGlobalSearch) { NativeGlobalSearchView() }
            .sheet(isPresented: $showingCalendar) { NativeCalendarView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(spacing: 14) { content() }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

