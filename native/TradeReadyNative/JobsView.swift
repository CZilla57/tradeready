import SwiftUI

struct JobsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var filter: NativeJobListFilter = .active
    @State private var editingJob: Job?
    @State private var showingNewJob = false
    @State private var showingRecurringJobs = false
    @State private var path: [String] = []
    @State private var confirmationRequest: NativeConfirmationRequest?
    @State private var isRootVisible = true

    /// Task 11.11 fix round 1: anything this screen presents over itself.
    private var isPresentingAnything: Bool {
        showingNewJob || showingRecurringJobs || editingJob != nil || confirmationRequest != nil
    }

    /// ⌘N (new job) only while the list is on top: never under a sheet or
    /// dialog this screen presents, nor under a pushed job detail (a hidden
    /// toolbar's shortcut otherwise wins over the visible screen's).
    private var newShortcut: KeyboardShortcut? {
        isPresentingAnything || !path.isEmpty || !isRootVisible ? nil : KeyboardShortcut("n", modifiers: .command)
    }

    private var listState: NativeJobListState {
        // Task 11.12: a JobListProjection signpost with the visible row count.
        NativePerformanceMetrics.shared.measure(.jobListProjection, count: { $0.items.count }) {
            NativeJobList.state(items: store.jobListItems, selectedFilter: filter, query: search)
        }
    }

    private var contentState: NativeContentState {
        NativeContentState.collection(
            visibleCount: listState.items.count,
            totalCount: store.jobs.count,
            query: search,
            isFiltering: listState.effectiveFilter != .all
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NativeAccessibilityAdaptiveRow(alignment: .center, spacing: 8) {
                        JobListStat(title: "Active jobs", value: String(listState.stats.activeCount))
                        JobListStat(title: "Open estimates", value: String(listState.stats.openEstimateCount))
                        JobListStat(title: "Pending value", value: listState.stats.pendingValue.currency, accent: true)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(listState.filters) { summary in
                                filterButton(summary)
                            }
                        }.padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                ForEach(listState.items) { item in
                    if let job = store.jobs.first(where: { $0.id == item.id }) {
                        NavigationLink(value: job.id) {
                            JobRow(job: job, listItem: item) { showingRecurringJobs = true }
                        }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    confirmationRequest = .deleteJob(id: job.id, title: job.title)
                                } label: { Label("Delete", systemImage: "trash") }
                                .tint(Color.tradeDangerFill)
                                Button { editingJob = job } label: { Label("Edit", systemImage: "pencil") }.tint(Color.tradeReadyFill)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    store.setJobArchived(id: job.id, archived: !item.isArchived)
                                } label: {
                                    Label(
                                        item.isArchived ? "Restore" : "Archive",
                                        systemImage: item.isArchived ? "arrow.uturn.backward" : "archivebox"
                                    )
                                }
                                .tint(item.isArchived ? Color.tradeReadyFill : Color.tradeWarningFill)
                            }
                    }
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .overlay {
                NativeContentStateView(
                    state: contentState,
                    emptyTitle: "No jobs",
                    emptyMessage: "Add a job to track it from lead to paid.",
                    symbol: "hammer",
                    resetAction: { search = ""; filter = .active }
                )
            }
            .refreshable { await store.performPullToRefresh(screen: .jobs) }
            .navigationTitle("Jobs")
            .searchable(text: $search, prompt: "Jobs or customers")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Recurring", systemImage: "repeat") { showingRecurringJobs = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard !isPresentingAnything else { return }
                        showingNewJob = true
                    } label: { Label(NativeAccessibilityAudit.Label.addJob, systemImage: "plus") }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(NativeAccessibilityAudit.Label.addJob)
                        .keyboardShortcut(newShortcut)
                }
            }
            .navigationDestination(for: String.self) { id in
                if let job = store.jobs.first(where: { $0.id == id }) { JobDetailView(jobID: job.id) }
                else { ContentUnavailableView("Job not found", systemImage: "questionmark.folder") }
            }
            .sheet(isPresented: $showingNewJob) {
                JobEditor(job: Job(laborRate: store.settings.laborRate), isNewRecord: true)
            }
            .sheet(isPresented: $showingRecurringJobs) { NativeRecurringJobsView() }
            .sheet(item: $editingJob) { JobEditor(job: $0) }
            .onChange(of: store.deepLinkedJobID) { _, id in
                if let id, store.jobs.contains(where: { $0.id == id }) {
                    path = [id]
                    store.deepLinkedJobID = nil
                }
            }
            .onDisappear { isRootVisible = false }
            .onAppear {
                isRootVisible = true
                if let id = store.deepLinkedJobID, store.jobs.contains(where: { $0.id == id }) {
                    path = [id]
                    store.deepLinkedJobID = nil
                }
            }
            .nativeConfirmation($confirmationRequest) { intent in
                guard case .deleteJob(let recordID) = intent else { return }
                store.deleteJob(id: recordID)
            }
            // On the stack's root content, not the stack, so a pop back re-sends it.
            .nativeAnalyticsScreen(.jobList)
        }
    }

    private func filterButton(_ summary: NativeJobListFilterSummary) -> some View {
        let selected = listState.effectiveFilter == summary.filter
        return Button { filter = summary.filter } label: {
            Text("\(summary.filter.title)\(summary.count > 0 ? " (\(summary.count))" : "")")
                .font(.subheadline.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.tradeReadyFill : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct JobListStat: View {
    let title: String
    let value: String
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline)
                .foregroundStyle(accent ? Color.tradeReady : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct JobRow: View {
    let job: Job
    var listItem: NativeJobListItem?
    var recurringAction: (() -> Void)?

    init(job: Job, listItem: NativeJobListItem? = nil, recurringAction: (() -> Void)? = nil) {
        self.job = job
        self.listItem = listItem
        self.recurringAction = recurringAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.title).font(.headline)
                if listItem?.isRecurring == true {
                    Button { recurringAction?() } label: {
                        Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open recurring jobs")
                }
                Spacer()
                let total = listItem?.billableTotal ?? job.estimateTotal
                if total > 0 { Text(total.currency).fontWeight(.semibold) }
            }
            HStack { Text(job.customerName).foregroundStyle(.secondary); Spacer(); StatusBadge(status: job.status) }
            if let scheduled = job.scheduledAt { Label("\(scheduled.shortDate) at \(scheduled.shortTime)", systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
            if !job.description.isEmpty {
                Text(job.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 4)
    }
}

struct JobDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    @State private var editing = false
    @State private var duplicateDraft: NativeJobDuplicateDraft?
    @State private var pricingDraft: NativeJobPricingDraft?
    @State private var estimateReviewDraft: NativeEstimateReviewDraft?
    @State private var invoiceFromJobDraft: NativeInvoiceFromJobDraft?
    @State private var showingRevisionConfirmation = false
    @State private var isBeginningRevision = false
    @State private var revisionErrorMessage: String?
    @State private var showingRecurringJobs = false

    private var job: Job? { store.jobs.first { $0.id == jobID } }
    private var reviewSent: Bool { store.reviewRequestRecords.first(where: { $0.jobId == jobID })?.sentAt != nil }
    private var listItem: NativeJobListItem? { store.jobListItems.first { $0.id == jobID } }
    private var customer: Customer? {
        guard let job else { return nil }
        return store.customers.first { $0.id == job.customerId }
            ?? store.customers.first { $0.name.caseInsensitiveCompare(job.customerName) == .orderedSame }
    }

    var body: some View {
        Group {
            if let job {
                List {
                    detailSections(job)
                }
                .nativeContentColumn(.list)
                .tradeReadyListStyle()
                .navigationTitle(job.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Edit", systemImage: "pencil") { editing = true }
                    let isArchived = listItem?.isArchived == true
                    Button(
                        isArchived ? "Restore" : "Archive",
                        systemImage: isArchived ? "arrow.uturn.backward" : "archivebox"
                    ) {
                        if store.setJobArchived(id: job.id, archived: !isArchived), !isArchived {
                            dismiss()
                        }
                    }
                }
                .sheet(isPresented: $editing) { JobEditor(job: job) }
                .sheet(isPresented: $showingRecurringJobs) { NativeRecurringJobsView() }
                .sheet(item: $duplicateDraft) { JobEditor(duplicateDraft: $0) }
                .sheet(item: $pricingDraft) { NativePricingCalculatorView(draft: $0) }
                .sheet(item: $estimateReviewDraft) { NativeEstimateReviewView(draft: $0) }
                 .sheet(item: $invoiceFromJobDraft) { NativeCreateInvoiceFromJobView(draft: $0) }
                 .sheet(isPresented: reviewRequestIsPresented(jobID: job.id)) {
                     NativeReviewRequestView(jobID: job.id)
                 }
                .confirmationDialog(
                    "Revise declined estimate?",
                    isPresented: $showingRevisionConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Archive decision and revise", role: .destructive) {
                        beginDeclinedRevision()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The declined estimate and customer response will be preserved in history. Its old approval link will stop working, then you can edit pricing and create a new link.")
                }
                .alert("Couldn’t begin revision", isPresented: revisionErrorIsPresented) {
                    Button("OK", role: .cancel) { revisionErrorMessage = nil }
                } message: {
                    Text(revisionErrorText)
                }
                 .sheet(isPresented: onMyWayIsPresented(jobID: job.id)) {
                     NativeOnMyWayReviewView(job: job, customer: customer, settings: store.settings)
                 }
                 .sheet(isPresented: appointmentConfirmationIsPresented(jobID: job.id)) {
                     NativeAppointmentConfirmationReviewView(job: job, customer: customer, settings: store.settings)
                 }
                .sheet(item: estimateFollowUpDraft(jobID: job.id)) { draft in
                    NativeEstimateFollowUpView(draft: draft)
                }
            }
        }
        .nativeAnalyticsScreen(.jobDetail)
    }

    /// Shared by the approved/scheduled/in-progress status rows: routes to
    /// the existing deposit invoice, or opens the request-deposit sheet when
    /// none is linked yet — mirrors `JobDetailScreen.tsx`'s `DepositAction`.
    @ViewBuilder
    private func depositAction(_ job: Job) -> some View {
        if let invoiceID = job.invoiceId {
            Button("View deposit", systemImage: "doc.text") {
                store.routeToGlobalSearchResult(.invoice(invoiceID))
            }
        } else {
            Button("Request deposit", systemImage: "banknote") {
                invoiceFromJobDraft = store.invoiceFromJobDraft(jobID: job.id)
            }
        }
    }

    @ViewBuilder
    private func detailSections(_ job: Job) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(job.customerName).font(.title2.bold())
                    Spacer()
                    StatusBadge(status: job.status)
                }
                if !job.description.isEmpty { Text(job.description).foregroundStyle(.secondary) }
                if let customer { ContactButtons(phone: customer.phone, email: customer.email) }
            }
            .padding(.vertical, 5)
        }
        if let rule = store.recurringRule(forJobID: job.id) {
            Section("Recurring job") {
                Label(rule.isActive ? "Repeats \(rule.cadence)" : "Repeat series paused", systemImage: "repeat")
                Button("Manage series", systemImage: "arrow.up.right") { showingRecurringJobs = true }
            }
        } else {
            Section("Recurring job") {
                Button("Set up repeat", systemImage: "repeat") {
                    if let draft = store.recurringJobDraft(from: job.id) { store.createRecurringJob(draft) }
                }
            }
        }
        Section("Schedule") {
            if let start = job.scheduledAt {
                LabeledContent("Starts", value: "\(start.shortDate), \(start.shortTime)")
                if let end = job.scheduledEnd { LabeledContent("Ends", value: end.shortTime) }
            } else {
                Text("Needs scheduling").foregroundStyle(.secondary)
            }
            if !job.address.isEmpty { Label(job.address, systemImage: "mappin.and.ellipse") }
            if job.scheduledAt != nil && [.approved, .scheduled, .inProgress].contains(job.status) {
                Button { store.requestAppointmentConfirmationReview(jobID: job.id, fromNotification: false) } label: {
                    Label("Send confirmation", systemImage: "checkmark.message")
                }
                Button { store.requestOnMyWayReview(jobID: job.id) } label: {
                    Label("On my way", systemImage: "location.fill")
                }
            }
        }
        Section("Estimate") {
            LabeledContent("Total", value: (listItem?.billableTotal ?? job.estimateTotal).currency)
            LabeledContent("Labor", value: "\(job.laborHours.formatted()) hr × \(job.laborRate.currency)")
            Button(
                job.estimateTotal > 0 ? "Edit pricing" : "Build estimate",
                systemImage: "function"
            ) {
                pricingDraft = store.jobPricingDraft(jobID: job.id)
            }
        }
        // `JobDetailScreen` renders the change-order and timer blocks
        // immediately after the estimate card, before the status area.
        NativeChangeOrdersSection(jobID: job.id)
        NativeTimeTrackingSection(jobID: job.id)
        NativeJobProfitabilitySection(jobID: job.id)
        NativeJobPhotosView(jobID: job.id)
        statusSection(job)
        EstimateApprovalHistorySection(approvals: store.estimateApprovalHistory(jobID: job.id))
        if !job.notes.isEmpty {
            Section("Notes") { Text(job.notes) }
        }
        Section("Actions") {
            Button("Duplicate job", systemImage: "plus.square.on.square") {
                duplicateDraft = store.duplicateJobDraft(sourceID: job.id)
            }
        }
    }

    @ViewBuilder
    private func statusSection(_ job: Job) -> some View {
        Section("Status") {
            HStack {
                Text("Current")
                Spacer()
                StatusBadge(status: job.status)
            }
            switch job.status {
            case .lead:
                if job.estimateTotal > 0 {
                    Button("Review & send estimate", systemImage: "paperplane") {
                        estimateReviewDraft = store.estimateReviewDraft(jobID: job.id)
                    }
                } else {
                    Button("Build estimate", systemImage: "function") {
                        pricingDraft = store.jobPricingDraft(jobID: job.id)
                    }
                }
            case .estimateSent:
                Button("Review or resend estimate", systemImage: "paperplane") {
                    estimateReviewDraft = store.estimateReviewDraft(jobID: job.id)
                }
                Button("Send follow-up", systemImage: "hourglass") {
                    store.requestEstimateFollowUpReview(jobID: job.id, source: .jobDetail)
                }
                Button("Mark as approved by customer", systemImage: "checkmark.seal") {
                    store.advanceJobLifecycle(id: job.id, from: .estimateSent)
                }
            case .approved:
                Button("Schedule this job", systemImage: "calendar.badge.plus") {
                    editing = true
                }
                depositAction(job)
            case .scheduled:
                Button("Start job", systemImage: "play.fill") {
                    store.advanceJobLifecycle(id: job.id, from: .scheduled)
                }
                depositAction(job)
            case .inProgress:
                Button("Mark job complete", systemImage: "checkmark.circle") {
                    if case .autoInvoiced(let invoiceID) = store.completeJob(id: job.id) {
                        store.routeToGlobalSearchResult(.invoice(invoiceID))
                    }
                }
                depositAction(job)
            case .complete:
                Button(
                    job.invoiceId == nil ? "Create invoice" : "Finalize invoice",
                    systemImage: "doc.text.fill"
                ) {
                    invoiceFromJobDraft = store.invoiceFromJobDraft(jobID: job.id)
                }
                if !reviewSent {
                    Button("Request a review", systemImage: "star.bubble") {
                        store.requestReviewRequestReview(jobID: job.id, source: .jobDetail)
                    }
                }
            case .invoiced:
                if let invoiceID = job.invoiceId {
                    Button("View invoice", systemImage: "doc.text") {
                        store.routeToGlobalSearchResult(.invoice(invoiceID))
                    }
                } else {
                    Text("The linked invoice is unavailable on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !reviewSent {
                    Button("Request a review", systemImage: "star.bubble") {
                        store.requestReviewRequestReview(jobID: job.id, source: .jobDetail)
                    }
                }
            case .paid:
                if reviewSent {
                    Text("Review request sent")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("Request a review", systemImage: "star.bubble") {
                        store.requestReviewRequestReview(jobID: job.id, source: .jobDetail)
                    }
                }
            case .declined:
                if let reason = store.activeEstimateApproval(jobID: job.id)?.declineReason,
                   !reason.isEmpty {
                    LabeledContent("Customer reason", value: reason)
                }
                Button {
                    showingRevisionConfirmation = true
                } label: {
                    if isBeginningRevision {
                        Label("Preparing revision…", systemImage: "hourglass")
                    } else {
                        Label("Revise declined estimate", systemImage: "arrow.uturn.backward.circle")
                    }
                }
                .disabled(isBeginningRevision)
            }
        }
    }

    private func beginDeclinedRevision() {
        guard !isBeginningRevision else { return }
        isBeginningRevision = true
        Task { @MainActor in
            let outcome = await store.beginDeclinedEstimateRevision(jobID: jobID)
            isBeginningRevision = false
            switch outcome {
            case .revised:
                guard let draft = store.jobPricingDraft(jobID: jobID) else {
                    revisionErrorMessage = "The revision was preserved, but pricing could not be opened. Refresh the job and continue from Edit pricing."
                    return
                }
                pricingDraft = draft
            case .failure(let error):
                revisionErrorMessage = error.localizedDescription
            }
        }
    }

    private var revisionErrorText: String {
        revisionErrorMessage ?? "Refresh the job and try again."
    }

    private var revisionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { revisionErrorMessage != nil },
            set: { presented in if !presented { revisionErrorMessage = nil } }
        )
    }

    private func onMyWayIsPresented(jobID: String) -> Binding<Bool> {
        Binding(
            get: { store.pendingOnMyWayJobID == jobID },
            set: { presented in if !presented { store.dismissPendingOnMyWay(jobID: jobID) } }
        )
    }

    private func appointmentConfirmationIsPresented(jobID: String) -> Binding<Bool> {
        Binding(
            get: { store.pendingAppointmentConfirmationJobID == jobID },
            set: { presented in if !presented { store.dismissPendingAppointmentConfirmation(jobID: jobID) } }
        )
    }

    private func reviewRequestIsPresented(jobID: String) -> Binding<Bool> {
        Binding(
            get: { store.pendingReviewRequestJobID == jobID },
            set: { presented in if !presented { store.dismissPendingReviewRequest(jobID: jobID) } }
        )
    }

    private func estimateFollowUpDraft(jobID: String) -> Binding<NativeEstimateFollowUpDraft?> {
        Binding(
            get: {
                guard store.pendingEstimateFollowUpJobID == jobID else { return nil }
                return store.estimateFollowUpDraft(jobID: jobID)
            },
            set: { draft in
                if draft == nil { store.dismissPendingEstimateFollowUp(jobID: jobID) }
            }
        )
    }
}

private struct EstimateApprovalHistorySection: View {
    let approvals: [Canonical.EstimateApproval]

    var body: some View {
        if !approvals.isEmpty {
            Section("Estimate history") {
                ForEach(Array(approvals.enumerated()), id: \.offset) { index, approval in
                    EstimateApprovalHistoryRow(approval: approval, sequence: index + 1)
                }
            }
        }
    }
}

private struct EstimateApprovalHistoryRow: View {
    let approval: Canonical.EstimateApproval
    let sequence: Int

    private var title: String {
        "\((approval.decision ?? "reviewed").capitalized) estimate \(sequence)"
    }

    private func money(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).doubleValue.currency
    }

    var body: some View {
        DisclosureGroup {
            LabeledContent("Estimate", value: approval.snapshot.jobTitle)
            LabeledContent("Total", value: money(approval.snapshot.total))
            LabeledContent("Sent", value: approval.sentAt)
            if let signer = approval.signerName, !signer.isEmpty {
                LabeledContent("Customer", value: signer)
            }
            if let reason = approval.declineReason, !reason.isEmpty {
                LabeledContent("Reason", value: reason)
            }
            ForEach(Array(approval.snapshot.lineItems.enumerated()), id: \.offset) { _, line in
                LabeledContent(line.label, value: money(line.amount))
            }
        } label: {
            Text(title)
        }
    }
}

struct JobEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var job: Job
    @State private var isScheduled: Bool
    private let isNewRecord: Bool
    private let duplicateTemplate: Canonical.Job?

    init(job: Job, isNewRecord: Bool = false) {
        _job = State(initialValue: job)
        _isScheduled = State(initialValue: job.scheduledAt != nil)
        self.isNewRecord = isNewRecord
        duplicateTemplate = nil
    }

    init(duplicateDraft: NativeJobDuplicateDraft) {
        _job = State(initialValue: duplicateDraft.job)
        _isScheduled = State(initialValue: false)
        isNewRecord = true
        duplicateTemplate = duplicateDraft.canonicalTemplate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    Picker("Customer", selection: $job.customerId) {
                        Text("Choose a customer").tag("")
                        ForEach(store.customers) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: job.customerId) { _, id in if let c = store.customers.first(where: { $0.id == id }) { job.customerName = c.name; if job.address.isEmpty { job.address = c.address } } }
                }
                Section("Work") {
                    LabeledField(label: "Job title") { TextField("Replace kitchen faucet", text: $job.title) }
                    LabeledField(label: "Description") { TextField("What the job involves", text: $job.description, axis: .vertical).lineLimit(2...5) }
                    LabeledField(label: "Address") { TextField("Street, city, state ZIP", text: $job.address, axis: .vertical) }
                }
                Section("Schedule") {
                    Toggle("Scheduled", isOn: $isScheduled)
                        .onChange(of: isScheduled) { _, scheduled in
                            if scheduled, job.scheduledAt == nil {
                                let start = Date.now
                                job.scheduledAt = start
                                job.scheduledEnd = start.addingTimeInterval(3600)
                            }
                        }
                    if isScheduled {
                        DatePicker("Starts", selection: Binding(get: { job.scheduledAt ?? .now }, set: { job.scheduledAt = $0 }), displayedComponents: [.date, .hourAndMinute])
                        DatePicker("Ends", selection: Binding(get: { job.scheduledEnd ?? (job.scheduledAt ?? .now).addingTimeInterval(3600) }, set: { job.scheduledEnd = $0 }), displayedComponents: [.date, .hourAndMinute])
                    }
                }
                Section("Estimate") {
                    CurrencyField(title: "Estimate total", value: $job.estimateTotal)
                    LabeledContent("Labor hours") {
                        TextField("0", value: $job.laborHours, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    CurrencyField(title: "Hourly rate", value: $job.laborRate)
                }
                Section {
                    LabeledField(label: "Notes") { TextField("Anything worth remembering", text: $job.notes, axis: .vertical) }
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden).background(Color.tradeCanvas)
            .navigationTitle(
                duplicateTemplate != nil ? "Duplicate Job" : isNewRecord ? "New Job" : "Edit Job"
            )
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                DismissableFormToolbar(title: duplicateTemplate != nil ? "Duplicate" : isNewRecord ? "New Job" : "Job") {
                    if !isScheduled {
                        job.scheduledAt = nil
                        job.scheduledEnd = nil
                    }
                    job.status = JobStatus(lifecycleStatus: JobLifecycleRules.statusAfterScheduling(
                        job.status.lifecycleStatus,
                        hasSchedule: job.scheduledAt != nil
                    ))
                    let saved = if let duplicateTemplate {
                        store.createDuplicatedJob(job, template: duplicateTemplate)
                    } else {
                        store.upsert(job)
                    }
                    if saved { dismiss() }
                }
            }
        }
        .nativeAnalyticsScreen(.jobEditor)
    }
}
