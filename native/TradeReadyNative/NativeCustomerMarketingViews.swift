import SwiftUI

// MARK: - Phase 33: tags and "Do not contact for marketing" on customer screens
//
// Spec `docs/superpowers/specs/2026-10-03-campaigns-tags-design.md` §3.2, §3.3
// and §4.1. Self-contained sections the Customers list, customer detail and the
// customer editor place with one line each, so the shared screens stay small.

extension NativeCustomerListEntry: NativeCustomerListFilterable {}

/// Customer detail › Tags (after Overview).
struct NativeCustomerTagsSection: View {
    @EnvironmentObject private var store: AppStore
    let customerID: String
    let customerName: String
    @State private var showingEditor = false

    private var tags: [String] { NativeCustomerTags.normalizeList(store.canonicalCustomer(id: customerID)?.tags) ?? [] }

    var body: some View {
        Section("Tags") {
            if !tags.isEmpty { NativeTagChipList(tags: tags) }
            Button(tags.isEmpty ? "Add tag" : "Edit tags", systemImage: "tag") { showingEditor = true }
                .accessibilityHint("Opens the tags for \(customerName)")
        }
        .sheet(isPresented: $showingEditor) {
            NativeCustomerTagsSheet(customerID: customerID, customerName: customerName, tags: tags)
        }
    }
}

/// Customer detail › Marketing (after Contact): the opt-out toggle with its
/// reason picker, and a confirmation to turn marketing back on.
struct NativeCustomerMarketingSection: View {
    @EnvironmentObject private var store: AppStore
    let customerID: String
    let customerName: String
    @State private var choosingReason = false
    @State private var confirmingClear = false
    @State private var saveFailed = false

    private var customer: Canonical.Customer? { store.canonicalCustomer(id: customerID) }
    private var firstName: String {
        let first = NativeCampaignMessage.firstName(customerName)
        return first == "there" ? customerName : first
    }

    var body: some View {
        Section {
            Toggle("Do not contact for marketing", isOn: Binding(
                get: { customer?.isMarketingOptedOut ?? false },
                set: { optOut in
                    if optOut { choosingReason = true } else { confirmingClear = true }
                }
            ))
            if let customer, let detail = NativeMarketingOptOut.detail(customer) {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Marketing")
        } footer: {
            Text("Campaigns skip this customer. Invoices, estimates and appointment messages are not affected.")
        }
        .confirmationDialog("How did \(firstName) ask?", isPresented: $choosingReason, titleVisibility: .visible) {
            ForEach(NativeMarketingOptOut.Via.pickable, id: \.self) { via in
                Button(via.displayName) {
                    if !store.setMarketingOptOut(customerID: customerID, via: via) { saveFailed = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Campaigns will skip \(customerName) from now on.")
        }
        .alert("Turn marketing back on?", isPresented: $confirmingClear) {
            Button("Turn back on") {
                if !store.clearMarketingOptOut(customerID: customerID) { saveFailed = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only do this if \(firstName) asked to hear from you again.")
        }
        .alert("Not saved", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your existing customer data was preserved. Try again.")
        }
    }
}

/// The customer editor's Tags section (between "How they found you" and
/// Notes): the tag editor and the opt-out toggle (reason "Asked me").
struct NativeCustomerEditorMarketingSection: View {
    @EnvironmentObject private var store: AppStore
    @Binding var customer: Customer
    @State private var draft = ""
    @State private var confirmingClear = false

    var body: some View {
        Section {
            NativeTagEditor(
                tags: Binding(get: { customer.tags ?? [] }, set: { customer.tags = $0.isEmpty ? nil : $0 }),
                draft: $draft,
                vocabulary: store.customerTagVocabulary
            )
            Toggle("Do not contact for marketing", isOn: Binding(
                get: { !(customer.marketingOptOutOn ?? "").isEmpty },
                set: { optOut in
                    if optOut {
                        customer.marketingOptOutOn = NativeCashBasis.ymd(.now)
                        customer.marketingOptOutVia = NativeMarketingOptOut.Via.asked.rawValue
                    } else {
                        confirmingClear = true
                    }
                }
            ))
        } header: {
            Text("Tags")
        } footer: {
            Text("Press return after each tag. Campaigns skip customers marked Do not contact. Invoices, estimates and appointment messages are not affected.")
        }
        .alert("Turn marketing back on?", isPresented: $confirmingClear) {
            Button("Turn back on") {
                customer.marketingOptOutOn = nil
                customer.marketingOptOutVia = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only do this if they asked to hear from you again.")
        }
    }
}

/// The Customers list's row caption: up to three tags and a "No marketing"
/// badge (text, never color alone).
struct NativeCustomerRowMarketingCaption: View {
    @EnvironmentObject private var store: AppStore
    let customerID: String

    var body: some View {
        if let customer = store.canonicalCustomer(id: customerID) {
            let caption = NativeCustomerTags.caption(customer.tags)
            if caption != nil || customer.isMarketingOptedOut {
                HStack(spacing: 6) {
                    if let caption {
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if customer.isMarketingOptedOut {
                        Text("No marketing")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.tradeWarningText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tradeWarningText.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }
}

/// The Customers list "Filter" menu (spec §3.3): tags (any of), Do not
/// contact for marketing, No phone or email. With more than 12 tags the tag
/// choice opens a searchable list instead (`showingTagPicker`).
struct NativeCustomerListFilterMenu: View {
    @Binding var filter: NativeCustomerListFilter
    @Binding var showingTagPicker: Bool
    let vocabulary: [NativeCustomerTags.Entry]

    var body: some View {
        Menu {
            if !vocabulary.isEmpty {
                Section("Tags") {
                    if vocabulary.count > 12 {
                        Button("Choose tags…", systemImage: "tag") { showingTagPicker = true }
                    } else {
                        ForEach(vocabulary, id: \.key) { entry in
                            Toggle("\(entry.display) (\(entry.count))", isOn: tagBinding(entry.key))
                        }
                    }
                }
            }
            Toggle("Do not contact for marketing", isOn: $filter.optedOut)
            Toggle("No phone or email", isOn: $filter.noContact)
            if filter.isActive {
                Button("Clear filters", systemImage: "xmark.circle") { filter = .init() }
            }
        } label: {
            Label(
                "Filter",
                systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel(filter.isActive ? "Filter, on" : "Filter")
    }

    private func tagBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { filter.tagKeys.contains(key) },
            set: { on in
                if on { filter.tagKeys.insert(key) } else { filter.tagKeys.remove(key) }
            }
        )
    }
}

/// Active filters as dismissible chips with "Clear" (top of the list).
struct NativeCustomerListFilterChips: View {
    @Binding var filter: NativeCustomerListFilter
    let vocabulary: [NativeCustomerTags.Entry]

    var body: some View {
        HStack {
            NativeTagChipRow {
                ForEach(vocabulary.filter { filter.tagKeys.contains($0.key) }, id: \.key) { entry in
                    chip(entry.display, label: "Remove tag filter \(entry.display)") { filter.tagKeys.remove(entry.key) }
                }
                if filter.optedOut {
                    chip("Do not contact", label: "Remove Do not contact filter") { filter.optedOut = false }
                }
                if filter.noContact {
                    chip("No phone or email", label: "Remove No phone or email filter") { filter.noContact = false }
                }
            }
            Button("Clear") { filter = .init() }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear filters")
        }
    }

    private func chip(_ text: String, label: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            NativeTagChipLabel(text: text, systemImage: "xmark", isSelected: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The searchable tag picker for a vocabulary of more than 12 tags.
struct NativeCustomerTagFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: NativeCustomerListFilter
    let vocabulary: [NativeCustomerTags.Entry]
    @State private var search = ""

    private var shown: [NativeCustomerTags.Entry] {
        let key = NativeCustomerTags.key(search)
        return key.isEmpty ? vocabulary : vocabulary.filter { $0.key.contains(key) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(shown, id: \.key) { entry in
                        Toggle("\(entry.display) (\(entry.count))", isOn: Binding(
                            get: { filter.tagKeys.contains(entry.key) },
                            set: { on in
                                if on { filter.tagKeys.insert(entry.key) } else { filter.tagKeys.remove(entry.key) }
                            }
                        ))
                    }
                } footer: {
                    Text("Shows customers with any of the tags you pick.")
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .searchable(text: $search, prompt: "Search tags")
            .navigationTitle("Filter by tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
