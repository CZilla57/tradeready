import SwiftUI

// MARK: - Phase 33: customer tag chips, the tag editor and the tags sheet
//
// Spec `docs/superpowers/specs/2026-10-03-campaigns-tags-design.md` §3.2. Chips
// use the `NativeInvoiceOutreachView` capsule style in a horizontal scroller
// (the app has no wrapping chip layout). Every chip that does something is a
// text-titled button; read-only chip rows read as one VoiceOver element.

/// One capsule chip label.
struct NativeTagChipLabel: View {
    let text: String
    var systemImage: String? = nil
    var isSelected = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
            }
            Text(text).font(.subheadline)
        }
        .foregroundStyle(isSelected ? Color.tradeReady : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.tradeReady.opacity(0.12) : Color.clear, in: Capsule())
        .overlay(Capsule().stroke(isSelected ? AnyShapeStyle(Color.tradeReady) : AnyShapeStyle(.quaternary)))
    }
}

/// The horizontal chip scroller every Phase 33 chip row uses.
struct NativeTagChipRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
                .padding(.vertical, 2)
        }
    }
}

/// Read-only tags, one VoiceOver element ("Tags: AC, VIP").
struct NativeTagChipList: View {
    let tags: [String]

    var body: some View {
        NativeTagChipRow {
            ForEach(tags, id: \.self) { NativeTagChipLabel(text: $0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
    }
}

/// The rows of a tag editor, for a `Section`: removable chips, "3 of 10", the
/// add field (return or a comma adds) and the vocabulary suggestions. A typed
/// tag that matches the vocabulary snaps to its existing spelling. The owner
/// of `draft` adds what is still typed when it saves (`adding`).
struct NativeTagEditor: View {
    @Binding var tags: [String]
    @Binding var draft: String
    let vocabulary: [NativeCustomerTags.Entry]
    @FocusState private var fieldFocused: Bool

    private var isFull: Bool { tags.count >= NativeCustomerTags.maxPerCustomer }
    private var suggestions: [NativeCustomerTags.Entry] {
        NativeCustomerTags.suggestions(prefix: draft, vocabulary: vocabulary, excluding: tags)
    }

    var body: some View {
        Group {
            if tags.isEmpty {
                Text("No tags yet").foregroundStyle(.secondary)
            } else {
                NativeTagChipRow {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            NativeTagChipLabel(text: tag, systemImage: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                }
            }
            LabeledContent("Tags", value: "\(tags.count) of \(NativeCustomerTags.maxPerCustomer)")
            if isFull {
                Text("Up to \(NativeCustomerTags.maxPerCustomer) tags per customer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Add a tag", text: $draft)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($fieldFocused)
                    .onSubmit { addDraft(keepFocus: true) }
                    .onChange(of: draft) { _, value in
                        if value.contains(",") || value.contains(";") { addDraft(keepFocus: true) }
                    }
                    .accessibilityLabel("Add a tag")
                    .accessibilityHint("Type a tag and press return. Commas separate several.")
                if !suggestions.isEmpty {
                    NativeTagChipRow {
                        ForEach(suggestions, id: \.key) { entry in
                            Button {
                                add(entry.display)
                                draft = ""
                            } label: {
                                NativeTagChipLabel(text: "\(entry.display) (\(entry.count))", systemImage: "plus")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add tag \(entry.display), used on \(entry.count) customer\(entry.count == 1 ? "" : "s")")
                        }
                    }
                }
            }
        }
    }

    private func addDraft(keepFocus: Bool) {
        tags = Self.adding(draft, to: tags, vocabulary: vocabulary)
        draft = ""
        if keepFocus, !isFull { fieldFocused = true }
    }

    private func add(_ raw: String) {
        tags = Self.adding(raw, to: tags, vocabulary: vocabulary)
    }

    /// `tags` plus every piece of `raw` (split on `,`, `;` or `|`), snapped to
    /// the vocabulary's spelling, without duplicates, up to 10, sorted.
    static func adding(_ raw: String, to tags: [String], vocabulary: [NativeCustomerTags.Entry]) -> [String] {
        var next = tags
        for piece in NativeCustomerTags.split(raw) {
            guard next.count < NativeCustomerTags.maxPerCustomer,
                  let label = NativeCustomerTags.snapped(piece, vocabulary: vocabulary) else { continue }
            let key = NativeCustomerTags.key(label)
            if !next.contains(where: { NativeCustomerTags.key($0) == key }) { next.append(label) }
        }
        return NativeCustomerTags.normalizeList(next) ?? []
    }
}

/// Customer detail › Edit tags (spec §3.2). Save writes the canonical
/// customer and enqueues its upsert (`AppStore.setCustomerTags`).
struct NativeCustomerTagsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let customerID: String
    let customerName: String
    @State private var tags: [String]
    @State private var draft = ""
    @State private var saveFailed = false

    init(customerID: String, customerName: String, tags: [String]) {
        self.customerID = customerID
        self.customerName = customerName
        _tags = State(initialValue: tags)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NativeTagEditor(tags: $tags, draft: $draft, vocabulary: store.customerTagVocabulary)
                } header: {
                    Text("Tags for \(customerName)")
                } footer: {
                    Text("Tags help you find customers and choose who gets a campaign. Up to \(NativeCustomerTags.maxLength) characters each.")
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle("Edit tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                DismissableFormToolbar(title: "Edit tags") {
                    // A tag still being typed is saved too.
                    let finalTags = NativeTagEditor.adding(draft, to: tags, vocabulary: store.customerTagVocabulary)
                    if store.setCustomerTags(customerID: customerID, tags: finalTags) {
                        dismiss()
                    } else {
                        saveFailed = true
                    }
                }
            }
            .alert("Tags not saved", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your existing customer data was preserved. Try saving again.")
            }
        }
    }
}
