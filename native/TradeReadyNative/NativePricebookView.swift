import SwiftUI

// MARK: - Pricebook list (task 9.12, requirements P1-P4)
//
// Port of `screens/PricebookScreen.tsx`: search, category-grouped sections with
// Uncategorized last, a row per service (name, description, quoted total),
// swipe/row delete with confirmation, the empty state with its
// "Add your first service" call to action, and "+ Add Service".
//
// This screen only reads: every write goes through `NativePricebookEntryView`
// and the typed 9.08 `commitPricebookEdit`.

struct NativePricebookView: View {
    @EnvironmentObject private var store: AppStore

    @State private var search = ""
    @State private var editorTarget: NativePricebookEditorTarget?
    @State private var pendingDeletion: NativePricebookRow?

    private var entries: [Canonical.PricebookEntry] {
        NativePricebook.sortedByName(store.canonicalPricebook)
    }

    private var sections: [NativePricebookSection] {
        NativePricebookList.sections(store.canonicalPricebook, query: search)
    }

    var body: some View {
        Group {
            if store.canonicalPricebook.isEmpty {
                ContentUnavailableView {
                    Label("No services yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Your Pricebook saves your standard services so you can load them into estimates with one tap instead of typing everything from scratch.")
                } actions: {
                    Button("Add your first service") { editorTarget = .create }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 24)
            } else {
                List {
                    Section {
                        searchField
                    }

                    if sections.isEmpty {
                        Section {
                            Text("No services match \"\(search)\".")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.rows, id: \.id) { row in
                                Button { editorTarget = .edit(row.id) } label: {
                                    NativePricebookRowView(row: row)
                                }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) { pendingDeletion = row } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .accessibilityAction(named: "Delete \(row.name)") {
                                    pendingDeletion = row
                                }
                            }
                        }
                    }

                    Section {
                        Button { editorTarget = .create } label: {
                            Label("Add Service", systemImage: "plus.circle.fill")
                        }
                    }
                }
                .tradeReadyListStyle()
                .refreshable { await store.performPullToRefresh() }
            }
        }
        .navigationTitle("Pricebook")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editorTarget) { target in
            NativePricebookEntryView(target: target, opened: openedEntry(for: target))
        }
        .confirmationDialog(
            "Delete Service",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDeletion { store.deletePricebookEntry(id: row.id) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Remove \"\(pendingDeletion?.name ?? "")\" from your Pricebook?")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search services...", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
    }

    private func openedEntry(for target: NativePricebookEditorTarget) -> Canonical.PricebookEntry? {
        guard case .edit(let id) = target else { return nil }
        return store.canonicalPricebook.first { $0.id == id }
    }
}

/// One service row: name, optional description, quoted estimate total.
struct NativePricebookRowView: View {
    let row: NativePricebookRow

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.subheadline.weight(.medium)).lineLimit(1)
                if let description = row.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(row.priceText)
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(row.priceText)")
    }
}
