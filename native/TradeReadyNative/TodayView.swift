import SwiftUI

/// The Today tab (task 10.11, requirements D1, D2, D3, D6).
///
/// Section-for-section port of `screens/TodayScreen.tsx`: header, week strip,
/// 3-stat summary row, first-action hero, setup-checklist/insights slot hooks
/// (10.12 fills these), booking-attention rows, overdue-invoice and
/// follow-up briefing sections, the awaiting-estimates row, and the
/// selected-day schedule with its "Plan Route"/empty-schedule actions. Every
/// row/action routes through `AppStore.routeToToday`, the non-view
/// destination router (task 10.04's `NativeTodayDestination` executed
/// against the live snapshot) — no selection/cap/order/label policy lives in
/// this file; it only renders what `AppStore`'s `today*` wiring and
/// `NativeTodayComponents` hand it.
struct TodayView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var followUpNotifications: NativeEstimateFollowUpNotificationCoordinator

    @State private var editingJob: Job?
    @State private var creatingNewJob = false
    @State private var creatingNewCustomer = false
    @State private var invoiceFromJobDraft: NativeInvoiceFromJobDraft?
    @State private var showingRoute = false
    @State private var showingCalendar = false
    @State private var showingGlobalSearch = false
    @State private var showingSettings = false
    @State private var bookingAlertRow: NativeBookingAttention.Row?
    @State private var busyBookingRequestIDs: Set<String> = []
    /// Task 10.12: the setup-checklist card's one-shot deep-link
    /// (`store.pendingSettingsDestination`) mirrored into local sheet state.
    @State private var settingsDestination: SettingsDestination?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header

                    if let strip = store.todayWeekStrip {
                        NativeTodayWeekStripView(
                            strip: strip,
                            onSelectDay: { handle(.selectDate(date: $0)) },
                            onPrevWeek: { store.shiftTodaySelectedWeek(by: -7) },
                            onNextWeek: { store.shiftTodaySelectedWeek(by: 7) }
                        )
                    }

                    NativeTodayStatsRowView(
                        earnings: store.todayEarnings,
                        overdueTotal: store.todayOverdueTotal,
                        overdueCount: store.todayOverdueInvoices.count,
                        leadCount: store.todayLeadJobs.count,
                        onEarningsTap: { handle(.jobs) },
                        onOverdueTap: { handle(.invoices) },
                        onLeadsTap: { handle(.jobs) }
                    )

                    if let hero = store.todayHero {
                        NativeTodayHeroCardView(hero: hero) { handleRouteResult(store.handleTodayHeroTap(hero)) }
                    }

                    // Post-onboarding setup checklist — exact RN position.
                    NativeSetupChecklistCardView()

                    // Proactive insights — takes the checklist's slot once
                    // setup is done; hidden while the first-action hero is up
                    // (AppStore owns the gate, `todayInsightsVisible`). Exact
                    // RN position.
                    NativeInsightsCardView(onRoute: handleRouteResult)

                    ForEach(store.todayBookingAttentionRows, id: \.request.id) { row in
                        NativeTodayBookingAttentionRow(row: row) { bookingAlertRow = row }
                    }

                    overdueSection
                    awaitingEstimatesRow
                    followUpSection
                    scheduleSection
                }
                .padding()
            }
            .nativeContentColumn(.scroll)
            .background(Color.tradeCanvas)
            .navigationTitle(store.settings.businessName)
            .refreshable { await store.performPullToRefresh() }
            .sheet(isPresented: $showingGlobalSearch) { NativeGlobalSearchView() }
            .sheet(isPresented: $showingCalendar) { NativeCalendarView() }
            .sheet(isPresented: $showingSettings, onDismiss: { settingsDestination = nil }) {
                SettingsView(initialDestination: settingsDestination)
            }
            .onChange(of: store.pendingSettingsDestination) { _, newValue in
                guard let newValue else { return }
                settingsDestination = SettingsDestination(setupRoute: newValue)
                showingSettings = true
                store.pendingSettingsDestination = nil
            }
            .task {
                await followUpNotifications.refreshPermissionState()
                store.notificationsGranted = followUpNotifications.permissionState == .authorized
            }
            .onChange(of: followUpNotifications.permissionState) { _, newValue in
                store.notificationsGranted = newValue == .authorized
            }
            .sheet(isPresented: $showingRoute) { NavigationStack { NativeRouteView() } }
            .sheet(item: $editingJob) { JobEditor(job: $0) }
            .sheet(isPresented: $creatingNewJob) {
                JobEditor(job: Job(laborRate: store.settings.laborRate), isNewRecord: true)
            }
            .sheet(isPresented: $creatingNewCustomer) {
                CustomerEditor(customer: Customer(), mode: .create)
            }
            .sheet(item: $invoiceFromJobDraft) { NativeCreateInvoiceFromJobView(draft: $0) }
            .confirmationDialog(
                bookingAlertRow.map { NativeTodayBriefing.bookingRowPresentation($0).title } ?? "",
                isPresented: bookingAlertPresented,
                titleVisibility: .visible,
                presenting: bookingAlertRow
            ) { row in
                bookingAlertActions(for: row)
            } message: { row in
                Text(NativeTodayBriefing.bookingRowPresentation(row).body)
            }
            // On the stack's root content, not the stack, so a pop back re-sends it.
            .nativeAnalyticsScreen(.today)
        }
    }

    private var bookingAlertPresented: Binding<Bool> {
        Binding(get: { bookingAlertRow != nil }, set: { if !$0 { bookingAlertRow = nil } })
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.todayHeader.greeting.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(store.todayHeader.dateLabel).font(.largeTitle.bold())
            }
            Spacer()
            Button { handle(.calendar) } label: { Image(systemName: "calendar") }
                .accessibilityLabel("Open calendar")
            Button { handle(.search) } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("Search everything")
            Button { handle(.settings) } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Open settings")
        }
    }

    // MARK: - Overdue invoices

    @ViewBuilder
    private var overdueSection: some View {
        let overdue = store.todayOverdueInvoices
        if !overdue.isEmpty {
            let capped = store.todayOverdueCapped
            NativeTodayBriefingSection(
                title: "Overdue Invoices",
                actionLabel: "View all",
                onAction: { handle(.invoices) }
            ) {
                NativeTodayListCard(danger: true) {
                    ForEach(Array(capped.visible.enumerated()), id: \.element.id) { index, invoice in
                        NativeTodayOverdueInvoiceRow(
                            invoice: invoice,
                            daysPastDue: NativeTodayBriefing.daysPastDue(invoice.due, now: Date()),
                            isLast: index == capped.visible.count - 1 && capped.extraCount <= 0,
                            onTap: { handle(.invoice(invoiceId: invoice.id)) }
                        )
                    }
                    if capped.extraCount > 0 {
                        NativeTodaySeeMoreRow(label: "See \(capped.extraCount) more →") { handle(.invoices) }
                    }
                }
            }
        }
    }

    // MARK: - Estimates awaiting response

    @ViewBuilder
    private var awaitingEstimatesRow: some View {
        if let row = store.todayAwaitingEstimatesRow {
            Button { handle(.jobs) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hourglass").font(.subheadline).foregroundStyle(Color.tradeWarningText)
                    Text(row.label).font(.subheadline.weight(.medium)).foregroundStyle(Color.tradeWarningText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("›").font(.title3).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.tradeWarningText.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.label)
        }
    }

    // MARK: - Follow up (leads)

    @ViewBuilder
    private var followUpSection: some View {
        let leads = store.todayLeadJobs
        if !leads.isEmpty {
            let capped = store.todayLeadCapped
            NativeTodayBriefingSection(
                title: "Follow Up",
                actionLabel: "View all",
                onAction: { handle(.jobs) }
            ) {
                NativeTodayListCard {
                    ForEach(Array(capped.visible.enumerated()), id: \.element.id) { index, job in
                        NativeTodayLeadRow(
                            job: job,
                            daysAgo: nativeTodayDaysAgo(job.createdAt),
                            isLast: index == capped.visible.count - 1 && capped.extraCount <= 0,
                            onTap: { handle(.job(jobId: job.id)) }
                        )
                    }
                    if capped.extraCount > 0 {
                        NativeTodaySeeMoreRow(label: "See \(capped.extraCount) more →") { handle(.jobs) }
                    }
                }
            }
        }
    }

    // MARK: - Selected-day schedule

    private var scheduleSection: some View {
        let jobs = store.todaySelectedDaySchedule
        return NativeTodayBriefingSection(
            title: store.todayScheduleSectionTitle,
            actionLabel: store.todayIsSelectedDateToday && !jobs.isEmpty ? "Plan Route" : nil,
            onAction: { handle(.route) }
        ) {
            if jobs.isEmpty {
                NativeTodayEmptySchedule { handle(.newJob) }
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        NativeTodayScheduleStop(
                            job: job,
                            isLast: index == jobs.count - 1,
                            onTap: { handle(.job(jobId: job.id)) },
                            onOnMyWay: { handle(.onMyWay(jobId: job.id)) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Destination routing

    private func handle(_ destination: NativeTodayDestination) {
        handleRouteResult(store.routeToToday(destination))
    }

    /// Shared by every route source (row taps, the hero card, insight taps):
    /// each installs its own side effects (deep-link, analytics, sample-tour
    /// flag) on `AppStore` first, then hands the resulting
    /// `NativeTodayRouteResult` here for the one `.present*` → sheet-state
    /// mapping every caller shares.
    private func handleRouteResult(_ result: AppStore.NativeTodayRouteResult) {
        switch result {
        case .handled, .none:
            break
        case .presentJobEditor(let jobID):
            editingJob = store.jobs.first { $0.id == jobID }
        case .presentNewJobEditor:
            creatingNewJob = true
        case .presentNewCustomerEditor:
            creatingNewCustomer = true
        case .presentInvoiceFromJob(let jobID):
            invoiceFromJobDraft = store.invoiceFromJobDraft(jobID: jobID)
        case .presentRoute:
            showingRoute = true
        case .presentCalendar:
            showingCalendar = true
        case .presentSearch:
            showingGlobalSearch = true
        case .presentSettings:
            showingSettings = true
        }
    }

    // MARK: - Booking-row actions (RN's `handleBookingRowPress` Alert.alert)
    //
    // RN presents up to four actions (reschedule_requested: View job / I've
    // rescheduled it / Decline booking / Cancel), which SwiftUI's two-button
    // `Alert` cannot express — `.confirmationDialog` is the native
    // equivalent for a multi-action prompt and carries the identical title/
    // message/button copy from `NativeTodayBriefing.bookingRowPresentation`
    // (10.04) and RN's own alert-building code.
    @ViewBuilder
    private func bookingAlertActions(for row: NativeBookingAttention.Row) -> some View {
        let presentation = NativeTodayBriefing.bookingRowPresentation(row)
        switch row.kind {
        case .rescheduleRequested:
            Button("View job") { handle(presentation.jobDestination) }
            Button("I've rescheduled it") { resolveBookingReschedule(row) }
            Button("Decline booking", role: .destructive) { declineBooking(row) }
            Button("Cancel", role: .cancel) {}
        case .portalChange:
            Button("View job") { handle(presentation.jobDestination) }
            Button("Done") { markBookingHandled(row) }
            Button("Cancel", role: .cancel) {}
        case .cancelled:
            Button("View job") { handle(presentation.jobDestination) }
            Button("OK", role: .cancel) {}
        case .missingJob, .unconvertedActive:
            // Native-only rows (Phase 8 addition); RN has no alert copy for
            // these. "View job" always falls back to the Jobs tab per
            // `bookingRowPresentation`'s documented no-dead-action rule.
            Button("View job") { handle(presentation.jobDestination) }
            Button("OK", role: .cancel) {}
        }
    }

    private func markBookingHandled(_ row: NativeBookingAttention.Row) {
        guard !busyBookingRequestIDs.contains(row.request.id) else { return }
        busyBookingRequestIDs.insert(row.request.id)
        defer { busyBookingRequestIDs.remove(row.request.id) }
        _ = store.stampBookingRequestHandled(requestID: row.request.id)
    }

    private func declineBooking(_ row: NativeBookingAttention.Row) {
        guard !busyBookingRequestIDs.contains(row.request.id) else { return }
        busyBookingRequestIDs.insert(row.request.id)
        Task {
            _ = await store.declineBookingRequest(requestID: row.request.id)
            await MainActor.run { _ = busyBookingRequestIDs.remove(row.request.id) }
        }
    }

    /// Mirrors `NativeBookingRequestsView.resolveReschedule`: stages a
    /// proof against the request's own slot, then resolves it. A job-less
    /// row (no `convertedJobId`) has nothing to reschedule against and is a
    /// no-op, matching that screen's existing guard.
    private func resolveBookingReschedule(_ row: NativeBookingAttention.Row) {
        guard !busyBookingRequestIDs.contains(row.request.id), let jobID = row.jobID else { return }
        busyBookingRequestIDs.insert(row.request.id)
        Task {
            let prepareOutcome = await store.prepareBookingReschedule(
                requestID: row.request.id,
                scheduleDraft: .init(
                    jobID: jobID,
                    baselineDate: nil, baselineStart: nil, baselineEnd: nil,
                    baselineStatus: row.request.status,
                    date: row.request.slot?.date,
                    start: row.request.slot?.start,
                    end: row.request.slot?.end
                )
            )
            if case .proofReady(let proof) = prepareOutcome {
                _ = await store.resolveBookingReschedule(requestID: row.request.id, proof: proof)
            }
            await MainActor.run { _ = busyBookingRequestIDs.remove(row.request.id) }
        }
    }
}
