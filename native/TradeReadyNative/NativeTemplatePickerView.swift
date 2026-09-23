import SwiftUI

// MARK: - Trade template picker (task 9.12, requirement P2)
//
// Port of `components/TemplatePickerModal.tsx`: a list of structure-only starting
// points. Selecting one hands the template back to the caller — nothing is
// persisted here, and no template carries a rate, quantity, waste %, coverage
// figure, minimum, or legal claim (the 9.05 guardrail).

struct NativeTemplatePickerView: View {
    @Environment(\.dismiss) private var dismiss

    var templates: [NativeTradeTemplate] = NativeTradeTemplates.all
    let onSelect: (NativeTradeTemplate) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Templates are reminders, not prices. Each one seeds empty, editable lines and a scope checklist you fill in yourself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Templates") {
                    ForEach(NativePricebookTemplates.rows(templates), id: \.id) { row in
                        Button {
                            guard let template = templates.first(where: { $0.id == row.id }) else { return }
                            onSelect(template)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name).font(.subheadline.weight(.medium))
                                Text("\(row.tradesText) · \(row.checklistCount) scope reminder\(row.checklistCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start from \(row.name)")
                    }
                }
            }
            .tradeReadyListStyle()
            .navigationTitle("Start from a template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Job picker for the "Use in a job" prefill: exact canonical ids, newest first.
struct NativePricebookJobPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let jobs: [Canonical.Job]
    let onSelect: (Canonical.Job) -> Void

    @State private var search = ""

    private var matching: [Canonical.Job] {
        let live = jobs
            .filter { ($0.archivedAt ?? "").isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return live }
        return live.filter {
            $0.title.lowercased().contains(needle) || $0.customerName.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if matching.isEmpty {
                    ContentUnavailableView(
                        "No matching jobs",
                        systemImage: "briefcase",
                        description: Text("Only active jobs can take a pricebook prefill.")
                    )
                } else {
                    List(matching, id: \.id) { job in
                        Button {
                            onSelect(job)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.title).font(.subheadline.weight(.medium))
                                Text(job.customerName.isEmpty ? job.status : job.customerName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use for \(job.title)")
                    }
                    .tradeReadyListStyle()
                }
            }
            .navigationTitle("Use in a job")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search jobs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
