import SwiftUI

/// Phase 34 (referrals, spec 2026-10-03-referral-program-design.md §5.7):
/// Money › Referrals, the "who referred whom" screen. One section per referrer
/// (then Former customer and Referrer not recorded), each listing the
/// customers they referred with the joined date, what each paid in the period
/// and whether a thank-you is recorded. Rows open customer detail. Pushed on
/// the Money stack, so it hosts no NavigationStack of its own.
struct NativeReferralsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var filter: NativeMoneyDateFilter

    init(initialFilter: NativeMoneyDateFilter = .thisMonth) {
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        let groups = store.referralGroups(filter: filter, now: Date())
        List {
            Section {
                Picker("Period", selection: $filter) {
                    ForEach(NativeMoneyDateFilter.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Collected is what each referred customer paid in this period. Joined dates are all time.")
            }
            if groups.isEmpty {
                Section {
                    Text("No referrals recorded yet. Set \u{201C}How they found you\u{201D} to Referral and pick who referred them.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                Section {
                    if let referrerID = group.row.referrerID {
                        NavigationLink {
                            CustomerDetailView(customerID: referrerID, fallbackName: group.row.name)
                        } label: {
                            referrerHeader(group.row)
                        }
                        .accessibilityHint("Opens \(group.row.name)'s customer details")
                    } else {
                        referrerHeader(group.row)
                    }
                    ForEach(group.entries) { entry in
                        NavigationLink {
                            CustomerDetailView(customerID: entry.id, fallbackName: entry.name)
                        } label: {
                            entryRow(entry)
                        }
                    }
                } header: {
                    Text(group.row.name)
                }
            }
        }
        .nativeContentColumn(.list)
        .tradeReadyListStyle()
        .navigationTitle("Referrals")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func referrerHeader(_ row: NativeReferralReportRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NativeAccessibilityAdaptiveRow(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.isCatchAll ? row.name : "\(row.name)\(row.isArchived ? " (Archived)" : "")")
                    .font(.headline)
                    .foregroundStyle(row.isCatchAll ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(NativeMoneyFormat.money(row.collected))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.tradeSuccessText)
                    .layoutPriority(1)
            }
            Text("\(row.newReferred) new \u{00B7} \(row.referredAllTime) total")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if row.creditOwed > 0 {
                Text("Credit owed: \(NativeMoneyFormat.money(row.creditOwed))")
                    .font(.caption)
                    .foregroundStyle(Color.tradeWarningText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func entryRow(_ entry: NativeReferralEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            NativeAccessibilityAdaptiveRow(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(NativeMoneyFormat.money(entry.collected))
                    .font(.subheadline.monospacedDigit())
                    .layoutPriority(1)
            }
            if let joined = entry.joinedText {
                Text(joined)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label(entry.rewardStatus, systemImage: entry.hasReward ? "checkmark.circle" : "gift")
                .font(.caption)
                .foregroundStyle(entry.hasReward ? Color.tradeSuccessText : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
