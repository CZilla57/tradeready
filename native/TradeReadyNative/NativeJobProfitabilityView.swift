import SwiftUI

/// Job-detail "Estimate vs actual" card, ported from
/// `components/JobProfitabilitySection.tsx`. Est/actual/variance rows, the
/// collection summary, honest unknown-data warnings, and the "What changed?"
/// drill-down.
///
/// The section keeps no state of record — every figure comes from
/// `AppStore.jobProfitabilitySection(jobID:)`, which projects the canonical
/// job through `NativeJobProfitability` and the shared
/// `JobProfitabilityEngine`. Out of scope: the Money-tab aggregate and the
/// pre-linked "Add expense" path (expense deep-linking lives with the Money
/// tab slice).
struct NativeJobProfitabilitySection: View {
    @EnvironmentObject private var store: AppStore
    let jobID: String

    @State private var showingWhatChanged = false

    var body: some View {
        if let state = store.jobProfitabilitySection(jobID: jobID) {
            Section("Estimate vs actual") {
                HStack {
                    Spacer(minLength: 0)
                    Text("Estimate")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Actual")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                ForEach(state.rows, id: \.key) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label)
                                .font(.subheadline)
                            if let variance = row.variance {
                                Text(variance)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(toneColor(row.tone))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.estimate)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(row.actual)
                            .font(.subheadline.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if let summary = state.collectionSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !state.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.warnings.enumerated()), id: \.offset) { _, warning in
                            Text("· \(warning)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !state.whatChanged.isEmpty {
                    Button {
                        showingWhatChanged = true
                    } label: {
                        Label("What changed?", systemImage: "list.bullet")
                    }
                    .accessibilityLabel("What changed on this job")
                }
            }
            .sheet(isPresented: $showingWhatChanged) {
                NavigationStack {
                    List(state.whatChanged, id: \.key) { item in
                        HStack {
                            Text(item.label)
                                .font(.subheadline)
                            Spacer(minLength: 8)
                            Text(item.amount)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(toneColor(item.tone))
                        }
                    }
                    .navigationTitle("What changed on this job")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close") { showingWhatChanged = false }
                        }
                    }
                }
            }
        }
    }

    private func toneColor(_ tone: NativeProfitabilityTone?) -> Color {
        switch tone {
        case .good: .green
        case .bad: .red
        case .neutral, nil: .secondary
        }
    }
}
