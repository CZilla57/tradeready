import SwiftUI

// MARK: - Phase 33: the campaign builder (spec §5.5, §6, §7.1)
//
// One screen with three steps (Audience, Message, Review) over a local copy of
// the draft. Discrete changes (pickers, steppers, toggles, ticks) are saved as
// they happen; typed text is saved when its field loses focus, before drafting
// or sending, and when the screen closes. A new draft is stored only once it
// changes, so opening the builder and leaving writes nothing. The live count
// sits in a bottom bar; nothing sends from here: "Start sending" freezes the
// audience and opens the send session (`NativeCampaignSendView`).

/// Opens the send session (`fullScreenCover(item:)`).
struct NativeCampaignSessionRequest: Identifiable, Equatable {
    let id: String
}

struct NativeCampaignBuilderView: View {
    private enum Step: String, CaseIterable {
        case audience = "Audience"
        case message = "Message"
        case review = "Review"
    }

    private enum FocusField: Hashable {
        case name, keyword, details, text, subject, emailBody
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let campaignID: String?
    let preset: NativeCampaignSegments.Preset?

    @State private var draft: Canonical.Campaign?
    @State private var lastSaved: Canonical.Campaign?
    @State private var step: Step = .audience
    @State private var bookingLink: AppStore.CampaignBookingLinkState = .unknown
    @State private var isCheckingLink = false
    @State private var keywordInput = ""
    @State private var showingExclusions = false
    @State private var previewMember: NativeCampaignAudience.Member?
    @State private var briefKind: NativeCampaignMessage.Kind = .text
    @State private var tone: NativeCampaignDrafting.Tone = .friendly
    @State private var isDrafting = false
    @State private var draftNotice: String?
    @State private var draftWarnings: [String] = []
    @State private var lastDraftOutput: [NativeCampaignMessage.Kind: NativeCampaignDrafting.Draft] = [:]
    @State private var confirmingRedraft = false
    @State private var confirmingDelete = false
    @State private var isStarting = false
    @State private var session: NativeCampaignSessionRequest?
    @State private var errorMessage: String?
    @FocusState private var focus: FocusField?

    init(campaignID: String) {
        self.campaignID = campaignID
        self.preset = nil
    }

    init(preset: NativeCampaignSegments.Preset) {
        self.campaignID = nil
        self.preset = preset
    }

    var body: some View {
        Group {
            if let current = draft {
                let audience = store.campaignAudience(
                    segment: current.segment,
                    channelPlan: NativeCampaignSegments.channelPlan(current),
                    manualExclusions: current.manualExclusions ?? []
                )
                Form {
                    Section {
                        Picker("Step", selection: $step) {
                            ForEach(Step.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    switch step {
                    case .audience: audienceStep(current, audience: audience)
                    case .message: messageStep(current, audience: audience)
                    case .review: reviewStep(current, audience: audience)
                    }
                }
                .nativeContentColumn(.list)
                .scrollContentBackground(.hidden)
                .background(Color.tradeCanvas)
                .safeAreaInset(edge: .bottom) { countBar(audience) }
                .sheet(isPresented: $showingExclusions) {
                    NativeCampaignExclusionsSheet(exclusions: audience.exclusions)
                }
                .sheet(item: $previewMember) { member in
                    NativeCampaignPreviewSheet(campaign: current, member: member, bookingLink: bookingLink)
                }
            } else {
                ProgressView("Loading…")
            }
        }
        .navigationTitle(draft?.name.isEmpty == false ? (draft?.name ?? "Campaign") : "New campaign")
        .navigationBarTitleDisplayMode(.inline)
        .nativeKeyboardDoneBar()
        .onAppear(perform: load)
        .onDisappear(perform: persist)
        .onChange(of: focus) { oldValue, _ in
            // Typed text is saved as soon as its field loses focus.
            if oldValue != nil { persist() }
        }
        .onChange(of: draft?.segment) { _, _ in persist() }
        .onChange(of: draft?.channelPlan) { _, _ in persist() }
        .onChange(of: draft?.manualExclusions) { _, _ in persist() }
        .onChange(of: draft?.message.goal) { _, _ in persist() }
        .onChange(of: step) { _, _ in
            persist()
            resolveLinkIfNeeded()
        }
        .confirmationDialog("Replace your message?", isPresented: $confirmingRedraft, titleVisibility: .visible) {
            Button("Replace with a new draft", role: .destructive) { Task { await performDraft() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You've edited this message. Drafting again replaces it.")
        }
        .confirmationDialog("Delete this draft?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete draft", role: .destructive) {
                guard let id = draft?.id else { return }
                if store.campaign(id: id) == nil || store.deleteCampaign(id: id) {
                    draft = nil
                    lastSaved = nil
                    dismiss()
                } else {
                    errorMessage = "The draft could not be deleted. Nothing was changed."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can undo for a few seconds.")
        }
        .alert("Campaign", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .fullScreenCover(item: $session, onDismiss: { dismiss() }) { request in
            NativeCampaignSendView(campaignID: request.id)
        }
    }

    // MARK: Audience (spec §5.5 step 1)

    @ViewBuilder
    private func audienceStep(_ current: Canonical.Campaign, audience: NativeCampaignAudience) -> some View {
        Section {
            TextField("Campaign name", text: Binding(
                get: { draft?.name ?? "" },
                set: { value in setDraft { $0.name = String(value.prefix(NativeCampaignMessage.nameMaxLength)) } }
            ))
                .focused($focus, equals: .name)
                .submitLabel(.done)
                .accessibilityLabel("Campaign name")
            if current.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Give the campaign a name.").font(.footnote).foregroundStyle(Color.tradeDangerText)
            }
            Menu {
                ForEach(NativeCampaignSegments.Preset.allCases, id: \.self) { preset in
                    Button(preset.displayName) { applyPreset(preset) }
                }
            } label: {
                LabeledContent("Start from", value: "Choose a preset")
            }
            .accessibilityLabel("Start from a preset")
        } header: {
            Text("Campaign")
        }

        let service = NativeCampaignSegments.service(current.segment)
        Section {
            Picker("Who", selection: Binding(
                get: { service },
                set: { value in setDraft { $0.segment.service = value.rawValue } }
            )) {
                ForEach(NativeCampaignSegments.Service.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if service == .served {
                Stepper(value: monthsBinding(\.minMonthsSinceService), in: 0...240) {
                    Text(current.segment.minMonthsSinceService.map { "At least \($0) month\($0 == 1 ? "" : "s") ago" } ?? "No minimum")
                }
                Stepper(value: monthsBinding(\.maxMonthsSinceService), in: 0...240) {
                    Text(current.segment.maxMonthsSinceService.map { "At most \($0) month\($0 == 1 ? "" : "s") ago" } ?? "No maximum")
                }
                if let minimum = current.segment.minMonthsSinceService, let maximum = current.segment.maxMonthsSinceService,
                   minimum > maximum {
                    Text("The minimum is more than the maximum, so nobody matches.")
                        .font(.footnote).foregroundStyle(Color.tradeWarningText)
                }
            }
        } header: {
            Text("Last service")
        } footer: {
            Text("Last service is the latest scheduled date of a completed, invoiced or paid job.")
        }

        Section {
            if !current.segment.jobKeywords.isEmpty {
                NativeTagChipRow {
                    ForEach(current.segment.jobKeywords, id: \.self) { word in
                        Button {
                            setDraft { $0.segment.jobKeywords.removeAll { $0 == word } }
                        } label: {
                            NativeTagChipLabel(text: word, systemImage: "xmark", isSelected: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove job word \(word)")
                    }
                }
            }
            let suggestions = store.campaignKeywordSuggestions.filter { !current.segment.jobKeywords.contains($0) }
            if !suggestions.isEmpty {
                NativeTagChipRow {
                    ForEach(suggestions, id: \.self) { word in
                        Button {
                            setDraft { $0.segment.jobKeywords.append(word) }
                        } label: {
                            NativeTagChipLabel(text: word, systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add job word \(word)")
                    }
                }
            }
            TextField("Add a word, like furnace", text: $keywordInput)
                .focused($focus, equals: .keyword)
                .submitLabel(.done)
                .onSubmit(addKeyword)
                .accessibilityLabel("Add a job word")
        } header: {
            Text("Job type")
        } footer: {
            Text("Matches any of these words in the titles of jobs you finished for them. Leave empty for any job.")
        }

        tagSection(current)

        Section {
            Menu {
                ForEach(leadSourceChoices, id: \.key) { choice in
                    Toggle(choice.name, isOn: Binding(
                        get: { current.segment.leadSources.contains(choice.key) },
                        set: { on in
                            setDraft { draft in
                                if on { draft.segment.leadSources.append(choice.key) }
                                else { draft.segment.leadSources.removeAll { $0 == choice.key } }
                            }
                        }
                    ))
                }
            } label: {
                LabeledContent("Found you via", value: leadSourceSummary(current))
            }
            .accessibilityLabel("Found you via, \(leadSourceSummary(current))")
            Picker("Referral", selection: Binding(
                get: { NativeCampaignSegments.referral(current.segment) },
                set: { value in setDraft { $0.segment.referral = value.rawValue } }
            )) {
                Text("Anyone").tag(NativeCampaignSegments.Referral.any)
                Text("Came from a referral").tag(NativeCampaignSegments.Referral.cameFromReferral)
                if store.campaignReferralFilterAvailable || current.segment.referral == NativeCampaignSegments.Referral.hasReferred.rawValue {
                    Text("Has referred someone").tag(NativeCampaignSegments.Referral.hasReferred)
                }
            }
        } header: {
            Text("Lead source")
        }

        Section {
            Toggle("Skip customers with open work", isOn: Binding(
                get: { current.segment.excludeOpenWork },
                set: { value in setDraft { $0.segment.excludeOpenWork = value } }
            ))
            Toggle("Skip customers on a maintenance plan", isOn: Binding(
                get: { current.segment.excludeMaintenancePlans },
                set: { value in setDraft { $0.segment.excludeMaintenancePlans = value } }
            ))
            Stepper(value: Binding(
                get: { current.segment.excludeContactedWithinDays },
                set: { value in setDraft { $0.segment.excludeContactedWithinDays = max(0, value) } }
            ), in: 0...365, step: 5) {
                Text(current.segment.excludeContactedWithinDays == 0
                     ? "Include people you contacted recently"
                     : "Skip anyone contacted in the last \(current.segment.excludeContactedWithinDays) days")
            }
            Picker("Send by", selection: Binding(
                get: { NativeCampaignSegments.channelPlan(current) },
                set: { value in setDraft { $0.channelPlan = value.rawValue } }
            )) {
                ForEach(NativeCampaignSegments.ChannelPlan.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if !store.campaignCanEmail, NativeCampaignSegments.channelPlan(current).usesEmail {
                Text(audience.counts.reachableOnceAddressSet > 0
                     ? "Email is off until you add a business mailing address (\(audience.counts.reachableOnceAddressSet) more could get it)."
                     : "Email is off until you add a business mailing address in Settings → Business profile.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Skip and send")
        } footer: {
            Text("Customers marked Do not contact, archived customers and anyone without a usable phone or email are always skipped.")
        }

        Section {
            if audience.recipients.isEmpty {
                Text("Nobody matches yet. Loosen a filter above.").foregroundStyle(.secondary)
            }
            ForEach(audience.recipients) { member in
                recipientRow(member, current: current)
            }
            let removed = current.manualExclusions ?? []
            if !removed.isEmpty {
                Button("Put back \(removed.count) you removed") { setDraft { $0.manualExclusions = nil } }
            }
        } header: {
            Text("Preview (\(audience.recipients.count))")
        } footer: {
            Text("Untick anyone you don't want to send to.")
        }

        if campaignID != nil || lastSavedIsStored {
            Section {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete draft", systemImage: "trash").nativeDestructiveText()
                }
            }
        }
    }

    @ViewBuilder
    private func tagSection(_ current: Canonical.Campaign) -> some View {
        let vocabulary = store.customerTagVocabulary
        Section {
            if vocabulary.isEmpty {
                Text("No tags yet. Add tags on a customer's page to target them here.").foregroundStyle(.secondary)
            } else {
                Text("Has any of").font(.subheadline.weight(.semibold))
                NativeTagChipRow {
                    ForEach(vocabulary, id: \.key) { entry in
                        tagToggle(entry, selected: current.segment.tagsAny.contains(entry.key), list: \.tagsAny, verb: "Include")
                    }
                }
                Text("Doesn't have").font(.subheadline.weight(.semibold))
                NativeTagChipRow {
                    ForEach(vocabulary, id: \.key) { entry in
                        tagToggle(entry, selected: current.segment.tagsNone.contains(entry.key), list: \.tagsNone, verb: "Leave out")
                    }
                }
            }
        } header: {
            Text("Tags")
        }
    }

    private func tagToggle(
        _ entry: NativeCustomerTags.Entry,
        selected: Bool,
        list: WritableKeyPath<Canonical.Campaign.Segment, [String]>,
        verb: String
    ) -> some View {
        Button {
            setDraft { draft in
                if selected { draft.segment[keyPath: list].removeAll { $0 == entry.key } }
                else { draft.segment[keyPath: list].append(entry.key) }
            }
        } label: {
            NativeTagChipLabel(text: entry.display, systemImage: selected ? "checkmark" : nil, isSelected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(verb) customers tagged \(entry.display)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func recipientRow(_ member: NativeCampaignAudience.Member, current: Canonical.Campaign) -> some View {
        let lastService = NativeCampaignMessage.monthYear(member.lastServiceDate).map { "Last service: \($0)" } ?? "No dated service"
        return HStack {
            Toggle(isOn: Binding(
                get: { !(current.manualExclusions ?? []).contains(member.customerID) },
                set: { included in
                    setDraft { draft in
                        var removed = draft.manualExclusions ?? []
                        if included { removed.removeAll { $0 == member.customerID } } else { removed.append(member.customerID) }
                        draft.manualExclusions = removed.isEmpty ? nil : removed
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name)
                    Label("\(member.channel.displayName) · \(lastService)",
                          systemImage: member.channel == .text ? "message" : "envelope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Send to \(member.name), by \(member.channel.displayName.lowercased()), \(lastService)")
            if hasMessage(current, for: member.channel) {
                Button("Preview") { previewMember = member }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Preview the message for \(member.name)")
            }
        }
    }

    // MARK: Message (spec §6)

    @ViewBuilder
    private func messageStep(_ current: Canonical.Campaign, audience: NativeCampaignAudience) -> some View {
        let plan = NativeCampaignSegments.channelPlan(current)
        let goal = NativeCampaignDrafting.Goal(rawValue: current.message.goal ?? "") ?? .custom
        Section {
            Picker("Goal", selection: Binding(
                get: { goal },
                set: { value in setDraft { $0.message.goal = value.rawValue } }
            )) {
                ForEach(NativeCampaignDrafting.Goal.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("Details, like $89 AC tune-up, book by April 30", text: Binding(
                get: { current.message.brief ?? "" },
                set: { value in setDraft { $0.message.brief = value.isEmpty ? nil : String(value.prefix(NativeCampaignMessage.briefMaxLength)) } }
            ), axis: .vertical)
            .lineLimit(2...5)
            .focused($focus, equals: .details)
            .accessibilityLabel("Details for the AI draft")
            Picker("Tone", selection: $tone) {
                ForEach(NativeCampaignDrafting.Tone.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            if plan.usesText && plan.usesEmail {
                Picker("Draft the", selection: $briefKind) {
                    Text("Text").tag(NativeCampaignMessage.Kind.text)
                    Text("Email").tag(NativeCampaignMessage.Kind.email)
                }
                .pickerStyle(.segmented)
            }
            Button {
                requestDraft(current)
            } label: {
                HStack {
                    Label(isDrafting ? "Drafting…" : "Draft with AI", systemImage: "sparkles")
                    if isDrafting { Spacer(); ProgressView() }
                }
            }
            .disabled(isDrafting)
            if let draftNotice {
                Text(draftNotice).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(draftWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Color.tradeWarningText)
            }
        } header: {
            Text("Draft with AI")
        } footer: {
            Text("\(NativeCampaignDrafting.detailsFooter) Up to \(NativeCampaignMessage.briefMaxLength) characters.")
        }

        if plan.usesText {
            Section {
                TextEditor(text: Binding(
                    get: { current.message.text ?? "" },
                    set: { value in setDraft { $0.message.text = value.isEmpty ? nil : value } }
                ))
                .frame(minHeight: 140)
                .focused($focus, equals: .text)
                .accessibilityLabel("Text message")
                insertFieldMenu("Insert field") { token in
                    setDraft { $0.message.text = ($0.message.text ?? "") + token }
                }
                Text("Added automatically: \(NativeCampaignMessage.textOptOutLine)")
                    .font(.footnote).foregroundStyle(.secondary)
                issueRows(current, kinds: [.text])
            } header: {
                Text(plan.usesEmail ? "Text message (\(audience.counts.byText))" : "Text message")
            }
        }

        if plan.usesEmail {
            Section {
                TextField("Subject", text: Binding(
                    get: { current.message.emailSubject ?? "" },
                    set: { value in setDraft { $0.message.emailSubject = value.isEmpty ? nil : value } }
                ))
                .focused($focus, equals: .subject)
                .accessibilityLabel("Email subject")
                TextEditor(text: Binding(
                    get: { current.message.emailBody ?? "" },
                    set: { value in setDraft { $0.message.emailBody = value.isEmpty ? nil : value } }
                ))
                .frame(minHeight: 180)
                .focused($focus, equals: .emailBody)
                .accessibilityLabel("Email body")
                insertFieldMenu("Insert field in email") { token in
                    setDraft { $0.message.emailBody = ($0.message.emailBody ?? "") + token }
                }
                Text("Added automatically:\n" + NativeCampaignMessage.complianceText(kind: .email, business: store.campaignBusiness))
                    .font(.footnote).foregroundStyle(.secondary)
                issueRows(current, kinds: [.email])
            } header: {
                Text(plan.usesText ? "Email (\(audience.counts.byEmail))" : "Email")
            }
        }

        Section {
            bookingLinkStatus(current)
            Text(NativeCampaignMessage.disclaimer).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func insertFieldMenu(_ title: String, insert: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(NativeCampaignMessage.Field.allCases, id: \.self) { field in
                Button("\(field.displayName) \(field.token)") { insert(field.token) }
            }
        } label: {
            Label(title, systemImage: "curlybraces")
        }
    }

    @ViewBuilder
    private func issueRows(_ current: Canonical.Campaign, kinds: Set<NativeCampaignMessage.Kind>) -> some View {
        ForEach(store.campaignMessageIssues(current, kinds: kinds, bookingLink: bookingLink), id: \.self) { issue in
            Label(issue.message, systemImage: issue.isBlocking ? "xmark.octagon" : "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(issue.isBlocking ? Color.tradeDangerText : Color.tradeWarningText)
        }
    }

    @ViewBuilder
    private func bookingLinkStatus(_ current: Canonical.Campaign) -> some View {
        if usesBookingLink(current) {
            switch bookingLink {
            case .ready:
                Label("Booking link ready. Each message gets this campaign's link.", systemImage: "link")
                    .font(.footnote).foregroundStyle(Color.tradeSuccessText)
            case .off:
                Label("Your booking link is off. Turn it on in Settings, or remove {bookingLink}.", systemImage: "link.badge.plus")
                    .font(.footnote).foregroundStyle(Color.tradeWarningText)
            case .unverified, .unknown:
                HStack {
                    Text(isCheckingLink ? "Checking your booking link…" : "Your booking link couldn't be checked.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if isCheckingLink { ProgressView() } else {
                        Button("Retry") { resolveLink() }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: Review (spec §7.1)

    @ViewBuilder
    private func reviewStep(_ current: Canonical.Campaign, audience: NativeCampaignAudience) -> some View {
        let kinds = Self.kinds(audience)
        let issues = store.campaignMessageIssues(current, kinds: kinds, bookingLink: bookingLink)
        let blocking = issues.filter(\.isBlocking)
        Section {
            LabeledContent("Recipients", value: "\(audience.recipients.count)")
            if audience.counts.byText > 0 { LabeledContent("By text", value: "\(audience.counts.byText)") }
            if audience.counts.byEmail > 0 { LabeledContent("By email", value: "\(audience.counts.byEmail)") }
            if audience.exceedsCap {
                Text("Up to \(NativeCampaignSegments.maxRecipients) people per campaign. Narrow the audience or untick some.")
                    .font(.footnote).foregroundStyle(Color.tradeDangerText)
            }
            if let hint = NativeCampaignQueue.largeTextSendHint(textCount: audience.counts.byText) {
                Text(hint).font(.footnote).foregroundStyle(Color.tradeWarningText)
            }
        } header: {
            Text("Who gets it")
        }

        if let sample = audience.recipients.first {
            Section {
                ForEach(NativeCampaignMessage.Kind.allCases.filter { kinds.contains($0) }, id: \.self) { kind in
                    let rendered = store.renderCampaignMessage(
                        current, kind: kind, customerID: sample.customerID, fallbackName: sample.name, bookingLink: bookingLink
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kind.displayName).font(.subheadline.weight(.semibold))
                        if let subject = rendered.subject { Text("Subject: \(subject)").font(.subheadline) }
                        Text(rendered.body).font(.body).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Preview for \(sample.name)")
            }
        }

        Section {
            if kinds.contains(.text), !NativeMessageComposer.canPresent(.sms) {
                Text("Messages isn't available on this device. Each text opens in your messages app instead, and you confirm whether you sent it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if kinds.contains(.email), !NativeMessageComposer.canPresent(.email) {
                Text("Apple Mail isn't set up here. Each email opens in your default mail app instead, and you confirm whether you sent it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(issues, id: \.self) { issue in
                Label(issue.message, systemImage: issue.isBlocking ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(issue.isBlocking ? Color.tradeDangerText : Color.tradeWarningText)
            }
            bookingLinkStatus(current)
            Button {
                startSending()
            } label: {
                HStack {
                    Label("Start sending", systemImage: "paperplane")
                    if isStarting { Spacer(); ProgressView() }
                }
                .frame(maxWidth: .infinity)
            }
            .tradeReadyProminentButtonStyle()
            .disabled(isStarting || audience.recipients.isEmpty || audience.exceedsCap || !blocking.isEmpty
                      || (usesBookingLink(current) && bookingLink.url == nil))
        } footer: {
            Text("Each person gets their own message in Apple's composer. Review it and tap Send; nothing is sent automatically. The message locks after the first send.")
        }
    }

    // MARK: Count bar (spec §5.5)

    private func countBar(_ audience: NativeCampaignAudience) -> some View {
        HStack {
            Text(countLine(audience))
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(countLine(audience))
            Spacer()
            if !audience.exclusions.isEmpty {
                Button("\(audience.exclusions.count) excluded") { showingExclusions = true }
                    .accessibilityHint("Shows who is left out and why")
            }
        }
        .nativeContentColumnFrame()
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func countLine(_ audience: NativeCampaignAudience) -> String {
        var parts = ["\(audience.recipients.count) will receive it"]
        if audience.counts.byText > 0 { parts.append("\(audience.counts.byText) by text") }
        if audience.counts.byEmail > 0 { parts.append("\(audience.counts.byEmail) by email") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var lastSavedIsStored: Bool {
        guard let id = draft?.id else { return false }
        return store.campaign(id: id) != nil
    }

    private func load() {
        guard draft == nil else { return }
        if let campaignID, let stored = store.campaign(id: campaignID) {
            draft = stored
            lastSaved = stored
            if NativeCampaignSegments.channelPlan(stored) == .emailOnly { briefKind = .email }
        } else if let preset {
            let fresh = store.makeCampaignDraft(preset: preset)
            draft = fresh
            lastSaved = fresh
        }
    }

    /// Saves the local draft when it changed (a new draft is inserted then).
    private func persist() {
        guard var current = draft, current != lastSaved else { return }
        if current.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.name = lastSaved?.name.isEmpty == false ? (lastSaved?.name ?? "") : "New campaign"
        }
        switch store.saveCampaignDraft(current) {
        case let .success(saved):
            lastSaved = saved
        case .failure(.invalidName):
            errorMessage = "Campaign names can be up to \(NativeCampaignMessage.nameMaxLength) characters."
        case .failure(.messageLocked):
            errorMessage = "This campaign has started, so its message is locked. Duplicate it to change the message."
        case .failure:
            errorMessage = "The campaign could not be saved. Your last saved version is kept."
        }
    }

    private func setDraft(_ change: (inout Canonical.Campaign) -> Void) {
        guard var current = draft else { return }
        change(&current)
        draft = current
    }

    /// The message kinds this audience receives.
    private static func kinds(_ audience: NativeCampaignAudience) -> Set<NativeCampaignMessage.Kind> {
        var kinds: Set<NativeCampaignMessage.Kind> = []
        if audience.counts.byText > 0 { kinds.insert(.text) }
        if audience.counts.byEmail > 0 { kinds.insert(.email) }
        return kinds
    }

    private func monthsBinding(_ keyPath: WritableKeyPath<Canonical.Campaign.Segment, Int?>) -> Binding<Int> {
        Binding(
            get: { draft?.segment[keyPath: keyPath] ?? 0 },
            set: { value in setDraft { $0.segment[keyPath: keyPath] = value <= 0 ? nil : value } }
        )
    }

    private func applyPreset(_ preset: NativeCampaignSegments.Preset) {
        setDraft { $0.segment = preset.segment }
    }

    private func addKeyword() {
        let word = keywordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        keywordInput = ""
        guard !word.isEmpty else { return }
        setDraft { draft in
            if !draft.segment.jobKeywords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                draft.segment.jobKeywords.append(word)
            }
        }
        persist()
    }

    private struct LeadSourceChoice {
        let key: String
        let name: String
    }

    private var leadSourceChoices: [LeadSourceChoice] {
        let presets = NativeLeadSource.presets.map { LeadSourceChoice(key: $0.key, name: $0.displayName) }
        let custom = NativeLeadSource.customLabels(in: store.canonicalCustomers.map(\.leadSource)).map {
            LeadSourceChoice(key: NativeLeadSource.bucketKey($0), name: $0)
        }
        return presets + custom + [LeadSourceChoice(key: NativeLeadSource.unknownBucketKey, name: NativeLeadSource.unknownDisplayName)]
    }

    private func leadSourceSummary(_ current: Canonical.Campaign) -> String {
        let names = leadSourceChoices.filter { current.segment.leadSources.contains($0.key) }.map(\.name)
        return names.isEmpty ? "Any source" : names.joined(separator: ", ")
    }

    private func hasMessage(_ current: Canonical.Campaign, for channel: NativeCampaignSegments.Channel) -> Bool {
        let body = channel == .text ? current.message.text : current.message.emailBody
        return !(body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func usesBookingLink(_ current: Canonical.Campaign) -> Bool {
        [current.message.text, current.message.emailBody, current.message.emailSubject]
            .contains { NativeCampaignMessage.uses(.bookingLink, in: $0) }
    }

    private func resolveLinkIfNeeded() {
        guard step != .audience, let current = draft, usesBookingLink(current), bookingLink == .unknown else { return }
        resolveLink()
    }

    private func resolveLink() {
        guard !isCheckingLink else { return }
        isCheckingLink = true
        Task { @MainActor in
            bookingLink = await store.resolveCampaignBookingLink()
            isCheckingLink = false
        }
    }

    private func requestDraft(_ current: Canonical.Campaign) {
        guard !isDrafting else { return }
        let plan = NativeCampaignSegments.channelPlan(current)
        let kind: NativeCampaignMessage.Kind = plan.usesText && plan.usesEmail ? briefKind : (plan.usesText ? .text : .email)
        let existing = kind == .text
            ? NativeCampaignDrafting.Draft(subject: nil, body: current.message.text ?? "")
            : NativeCampaignDrafting.Draft(subject: current.message.emailSubject, body: current.message.emailBody ?? "")
        let edited = !existing.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lastDraftOutput[kind] != existing
        if edited { confirmingRedraft = true } else { Task { await performDraft() } }
    }

    private func performDraft() async {
        guard !isDrafting, let current = draft else { return }
        isDrafting = true
        defer { isDrafting = false }
        persist()
        let plan = NativeCampaignSegments.channelPlan(current)
        let kind: NativeCampaignMessage.Kind = plan.usesText && plan.usesEmail ? briefKind : (plan.usesText ? .text : .email)
        let goal = NativeCampaignDrafting.Goal(rawValue: current.message.goal ?? "") ?? .custom
        let brief = NativeCampaignDrafting.Brief(goal: goal, tone: tone, kind: kind, details: current.message.brief ?? "")
        let result = await store.draftCampaignMessage(brief: brief, bookingLinkReady: bookingLink.url != nil)
        setDraft { draft in
            switch kind {
            case .text:
                draft.message.text = result.draft.body
            case .email:
                draft.message.emailSubject = result.draft.subject
                draft.message.emailBody = result.draft.body
            }
            draft.message.aiDrafted = result.source == .ai ? true : draft.message.aiDrafted
        }
        lastDraftOutput[kind] = result.draft
        draftNotice = result.notice
        draftWarnings = result.warnings
        persist()
    }

    private func startSending() {
        guard !isStarting, let current = draft else { return }
        isStarting = true
        defer { isStarting = false }
        persist()
        switch store.startCampaignSending(id: current.id, bookingLink: bookingLink) {
        case let .success(frozen):
            draft = frozen
            lastSaved = frozen
            session = .init(id: frozen.id)
        case .failure(.emptyAudience):
            errorMessage = "Nobody is in this audience yet."
        case let .failure(.tooManyRecipients(count)):
            errorMessage = "This audience has \(count) people. Up to \(NativeCampaignSegments.maxRecipients) per campaign."
        case let .failure(.invalidMessage(issues)):
            errorMessage = issues.first?.message ?? "Fix the message before sending."
        case .failure(.notFound):
            errorMessage = "Save the campaign first: give it a name and pick who it's for."
        case .failure:
            errorMessage = "The campaign could not be started. Nothing was sent."
        }
    }
}

/// "9 excluded": who is left out, grouped by reason.
struct NativeCampaignExclusionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exclusions: [NativeCampaignAudience.Exclusion]

    private var groups: [(label: String, members: [NativeCampaignAudience.Exclusion])] {
        var order: [String] = []
        var byKey: [String: [NativeCampaignAudience.Exclusion]] = [:]
        for exclusion in exclusions {
            let key = exclusion.reason.groupKey
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(exclusion)
        }
        return order.compactMap { key in
            guard let members = byKey[key], let first = members.first else { return nil }
            return ("\(first.reason.label) (\(members.count))", members)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if exclusions.isEmpty {
                    Text("Nobody is left out.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.members) { Text($0.name) }
                    }
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .navigationTitle("Excluded")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

/// One recipient's fully rendered message, compliance text included.
struct NativeCampaignPreviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let campaign: Canonical.Campaign
    let member: NativeCampaignAudience.Member
    let bookingLink: AppStore.CampaignBookingLinkState

    var body: some View {
        let kind: NativeCampaignMessage.Kind = member.channel == .text ? .text : .email
        let rendered = store.renderCampaignMessage(
            campaign, kind: kind, customerID: member.customerID, fallbackName: member.name, bookingLink: bookingLink
        )
        NavigationStack {
            List {
                Section {
                    LabeledContent(member.channel.displayName, value: member.contact)
                    if let subject = rendered.subject { LabeledContent("Subject", value: subject) }
                    Text(rendered.body).textSelection(.enabled)
                } header: {
                    Text(member.name)
                } footer: {
                    if !rendered.fallbacks.isEmpty {
                        Text("Filled in with a stand-in: \(rendered.fallbacks.map(\.displayName).joined(separator: ", ")).")
                    }
                }
                if rendered.isLongText {
                    Text("This text may arrive as several texts.").font(.footnote).foregroundStyle(Color.tradeWarningText)
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
