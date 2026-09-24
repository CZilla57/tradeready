import Foundation

// MARK: - Typed catalog events (task 11.08; contract §9.3–§9.5)
//
// Every analytics call site builds its payload here, so no call site
// hand-builds a dictionary. Each constructor mirrors one RN `track(` call site
// in contract §9.5: the same event name, the same property keys, and typed
// values (numbers stay numbers, arrays stay arrays). The transport still runs
// every event through the §9.5 allow-list; these constructors only make the
// right payload the easy one to write.
//
// Pure Foundation. It references plain native enums (job status, trade,
// insight kind) but no view, store or SDK type.

/// One §9.5 catalog event: its name and typed properties.
struct NativeAnalyticsEvent: Equatable, Sendable {
    let name: String
    let properties: [String: NativeAnalyticsValue]

    init(_ name: String, _ properties: [String: NativeAnalyticsValue] = [:]) {
        self.name = name
        self.properties = properties
    }
}

extension NativeAnalyticsEvent {
    enum SignInMethod: String, Sendable { case password, apple, google }
    enum OnboardingStep: String, Sendable { case welcome, business, startingPoint = "starting_point" }
    enum PaywallContext: String, Sendable { case settings, onboardingGate = "onboarding_gate" }
    /// `review_request_sent` / `estimate_follow_up_sent` channel.
    enum MessageChannel: String, Sendable { case sms, email }
    /// `change_order_sent` / `bulk_invoice_reminders` channel.
    enum ComposerChannel: String, Sendable { case text, email }
    /// Where a review-request or follow-up flow was opened from. RN defaults
    /// an absent `source` to `notification` (`source ?? 'notification'`).
    enum MessageSource: String, Sendable { case notification, jobDetail = "job_detail" }
    enum FirstAction: String, Sendable { case addCustomer = "add_customer", createJob = "create_job" }
    enum ReceiptOutcome: String, Sendable { case filled, empty }
    enum ReceiptRoute: String, Sendable { case userKey = "user_key", backend }
    enum RefreshScreen: String, Sendable { case money = "MoneyScreen", jobs = "JobsScreen" }
    enum CoachSource: String, Sendable { case insightPrefill = "insight_prefill", organic }
    enum VehicleMethod: String, Sendable { case mileage, actual, unset }

    // MARK: Auth (AuthScreen.tsx)

    static func signIn(_ method: SignInMethod) -> Self { .init("sign_in", ["method": .string(method.rawValue)]) }
    static let signUp = Self("sign_up")
    static let signUpConfirmationResent = Self("sign_up_confirmation_resent")

    // MARK: Onboarding and subscription

    static func onboardingStepViewed(_ step: OnboardingStep) -> Self {
        .init("onboarding_step_viewed", ["step": .string(step.rawValue)])
    }

    static func onboardingCompleted(trade: NativeTypedAccountState.Trade) -> Self {
        .init("onboarding_completed", ["trade": .string(trade.rawValue)])
    }

    static func onboardingStartChoice(_ choice: NativeStartingPointChoice) -> Self {
        .init("onboarding_start_choice", ["choice": .string(choice.rawValue)])
    }

    static func subscriptionPaywallShown(_ context: PaywallContext) -> Self {
        .init("subscription_paywall_shown", ["context": .string(context.rawValue)])
    }

    static let subscriptionPurchased = Self("subscription_purchased")

    // MARK: Customers and jobs

    /// `first`: no prior non-sample customer existed before this save.
    static func customerCreated(first: Bool) -> Self { .init("customer_created", ["first": .bool(first)]) }

    static func customersMerged(jobs: Int, invoices: Int) -> Self {
        .init("customers_merged", ["jobs": .number(Double(jobs)), "invoices": .number(Double(invoices))])
    }

    /// RN spreads `duplicated: true` only for a duplicate and `customerId`
    /// only when one resolved; both keys are otherwise absent.
    static func jobCreated(first: Bool, customerID: String?, duplicated: Bool) -> Self {
        var properties: [String: NativeAnalyticsValue] = ["first": .bool(first)]
        if duplicated { properties["duplicated"] = .bool(true) }
        if let customerID, !customerID.isEmpty { properties["customerId"] = .string(customerID) }
        return .init("job_created", properties)
    }

    static func jobStatusChanged(from: JobStatus, to: JobStatus) -> Self {
        .init("job_status_changed", ["from": .string(from.rawValue), "to": .string(to.rawValue)])
    }

    static func timeTrackingStarted(jobID: String) -> Self {
        .init("time_tracking_started", ["jobId": .string(jobID)])
    }

    static let estimateSent = Self("estimate_sent")

    static func estimateFollowUpOpened(source: MessageSource) -> Self {
        .init("estimate_follow_up_opened", ["source": .string(source.rawValue)])
    }

    static func estimateFollowUpSent(channel: MessageChannel, source: MessageSource) -> Self {
        .init("estimate_follow_up_sent", ["channel": .string(channel.rawValue), "source": .string(source.rawValue)])
    }

    static func reviewRequestSent(channel: MessageChannel, source: MessageSource) -> Self {
        .init("review_request_sent", ["channel": .string(channel.rawValue), "source": .string(source.rawValue)])
    }

    static let onMyWaySent = Self("on_my_way_sent")
    static let appointmentConfirmSent = Self("appointment_confirm_sent")
    static let appointmentConfirmOpened = Self("appointment_confirm_opened")

    static func changeOrderCreated(amount: Decimal) -> Self {
        .init("change_order_created", ["amount": number(amount)])
    }

    static func changeOrderSent(amount: Decimal, channel: ComposerChannel) -> Self {
        .init("change_order_sent", ["amount": number(amount), "channel": .string(channel.rawValue)])
    }

    static func changeOrderDecided(_ decision: NativeChangeOrderManualDecision) -> Self {
        .init("change_order_decided", ["decision": .string(decision.rawValue), "channel": "manual"])
    }

    // MARK: Invoices and payments

    static func invoiceCreatedFromJob(mode: InvoiceScreenMode) -> Self {
        .init("invoice_created", ["source": "from_job", "mode": .string(invoiceModeValue(mode))])
    }

    static let invoiceFinalizedFromJob = Self("invoice_finalized", ["source": "from_job"])
    static let invoiceCreatedManually = Self("invoice_created", ["source": "manual"])

    static func invoiceCreatedOnCompletion(usedTrackedTime: Bool, autoEmailQueued: Bool) -> Self {
        .init("invoice_created", [
            "source": "auto_on_complete",
            "usedTrackedTime": .bool(usedTrackedTime),
            "autoEmailQueued": .bool(autoEmailQueued),
        ])
    }

    static func invoicePaid(amount: Double) -> Self { .init("invoice_paid", ["amount": .number(amount)]) }

    static func bulkInvoicesMarkedPaid(count: Int) -> Self {
        .init("bulk_invoices_marked_paid", ["count": .number(Double(count))])
    }

    static func bulkInvoiceReminders(channel: ComposerChannel, count: Int) -> Self {
        .init("bulk_invoice_reminders", ["channel": .string(channel.rawValue), "count": .number(Double(count))])
    }

    /// A finished bulk reminder run (RN `InvoicesScreen.tsx:303`). RN tracks
    /// once per run that had an eligible invoice, with `count` the composers
    /// it opened (possibly 0); native's run is the outreach-sheet chain, so
    /// `count` is the sheets it presented.
    static func bulkInvoiceReminderRun(channel: NativeBulkRemindChannel, presentedCount: Int) -> Self {
        .bulkInvoiceReminders(channel: channel == .email ? .email : .text, count: presentedCount)
    }

    /// `method` is a native payment-method string ("Cash", "Cheque", "card",
    /// "stripe", …); it is mapped onto the catalog `PaymentMethod` enum.
    static func paymentRecorded(amount: Double, method: String, balanceRemaining: Double) -> Self {
        .init("payment_recorded", [
            "amount": .number(amount),
            "method": .string(paymentMethod(method)),
            "balanceRemaining": .number(balanceRemaining),
        ])
    }

    static func paymentVoided(amount: Double, method: String) -> Self {
        .init("payment_voided", ["amount": .number(amount), "method": .string(paymentMethod(method))])
    }

    /// `provider` is the payment provider id (`stripe`, `paypal`, …), never a
    /// URL or key. `deposit`: the link was requested for a deposit amount.
    static func paymentLinkSent(provider: String, deposit: Bool) -> Self {
        .init("payment_link_sent", ["provider": .string(provider), "deposit": .bool(deposit)])
    }

    /// RN `App.tsx:427` sends `{ daysPastDue: data.daysPastDue }`; a payload
    /// without it sends the event with no key (§9.5 `daysPastDue?`).
    static func overdueOutreachOpened(daysPastDue: Int?) -> Self {
        .init("overdue_outreach_opened", daysPastDue.map { ["daysPastDue": .number(Double($0))] } ?? [:])
    }

    // MARK: Money and records

    static func expenseLogged(category: ExpenseCategory, linkedToJob: Bool) -> Self {
        .init("expense_logged", ["category": .string(category.rawValue), "linkedToJob": .bool(linkedToJob)])
    }

    static let tripLogged = Self("trip_logged")
    static let pricebookEntrySaved = Self("pricebook_entry_saved")

    /// RN: `hasIncomeRate: draft.taxIncomeRate !== undefined`,
    /// `vehicleMethod: draft.vehicleDeductionMethod ?? 'unset'`.
    static func taxSettingsSaved(hasIncomeRate: Bool, vehicleMethod: VehicleDeductionMethod?) -> Self {
        .init("tax_settings_saved", [
            "hasIncomeRate": .bool(hasIncomeRate),
            "vehicleMethod": .string(vehicleMethod?.rawValue ?? VehicleMethod.unset.rawValue),
        ])
    }

    static let receiptScanFailed = Self("receipt_scanned", ["outcome": "failed"])

    static func receiptScanned(_ outcome: ReceiptOutcome, route: ReceiptRoute) -> Self {
        .init("receipt_scanned", ["outcome": .string(outcome.rawValue), "route": .string(route.rawValue)])
    }

    static func pullToRefresh(_ screen: RefreshScreen) -> Self {
        .init("pull_to_refresh", ["screen": .string(screen.rawValue)])
    }

    // MARK: Today, insights, checklist, coach (10.12/10.13 call sites)

    static let sampleJobOpened = Self("sample_job_opened")

    static func firstActionTapped(_ action: FirstAction) -> Self {
        .init("first_action_tapped", ["action": .string(action.rawValue)])
    }

    static func setupChecklistDismissed(doneCount: Int) -> Self {
        .init("setup_checklist_dismissed", ["doneCount": .number(Double(doneCount))])
    }

    static func setupChecklistTaskOpened(_ task: NativeSetupTaskID) -> Self {
        .init("setup_checklist_task_opened", ["task": .string(task.rawValue)])
    }

    static func insightShown(kinds: [NativeInsightKind], ids: [String]) -> Self {
        .init("insight_shown", ["kinds": .strings(kinds.map(\.rawValue)), "ids": .strings(ids)])
    }

    static func insightTapped(_ kind: NativeInsightKind) -> Self {
        .init("insight_tapped", ["kind": .string(kind.rawValue)])
    }

    static func insightCoachOpened(_ kind: NativeInsightKind) -> Self {
        .init("insight_coach_opened", ["kind": .string(kind.rawValue)])
    }

    static func insightReasonViewed(_ kind: NativeInsightKind) -> Self {
        .init("insight_reason_viewed", ["kind": .string(kind.rawValue)])
    }

    static func insightDismissed(_ kind: NativeInsightKind, insightID: String) -> Self {
        .init("insight_dismissed", ["kind": .string(kind.rawValue), "insightId": .string(insightID)])
    }

    static func insightSnoozed(_ kind: NativeInsightKind, insightID: String, days: Int) -> Self {
        .init("insight_snoozed", [
            "kind": .string(kind.rawValue),
            "insightId": .string(insightID),
            "days": .number(Double(days)),
        ])
    }

    /// `provider` is `NativeCoachProviderSummary.analyticsName`
    /// (`anthropic` | `groq` | `backend`).
    static func aiChatSent(_ source: CoachSource, provider: String) -> Self {
        .init("ai_chat_sent", ["source": .string(source.rawValue), "provider": .string(provider)])
    }

    // MARK: Notification and deep-link opens (App.tsx)

    static let bookingRequestOpened = Self("booking_request_opened")
    static let bookingUpdateOpened = Self("booking_update_opened")

    /// `type` is `NativeDeepLinkRoutingPolicy.analyticsType(_:)` (`job` | `onmyway`).
    static func widgetDeepLinkOpened(type: String) -> Self {
        .init("widget_deep_link_opened", ["type": .string(type)])
    }

    // MARK: Pure value mapping

    /// RN `PaymentMethod` (`types/models.ts:436`): stripe, cash, check, card,
    /// other. Native payments carry display strings ("Cheque") or ledger raw
    /// values ("bank_transfer"); anything outside the enum is `other`.
    static func paymentMethod(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "stripe": "stripe"
        case "cash": "cash"
        case "check", "cheque": "check"
        case "card": "card"
        default: "other"
        }
    }

    static func invoiceModeValue(_ mode: InvoiceScreenMode) -> String {
        switch mode {
        case .create: "create"
        case .requestDeposit: "requestDeposit"
        case .finalize: "finalize"
        }
    }

    /// RN `STEP_EVENT_NAMES = ["welcome", "business"]`; any other index has
    /// no step event.
    static func onboardingStep(index: Int) -> OnboardingStep? {
        switch index {
        case 0: .welcome
        case 1: .business
        default: nil
        }
    }

    /// A catalog `number` from a money `Decimal`.
    static func number(_ value: Decimal) -> NativeAnalyticsValue {
        .number(NSDecimalNumber(decimal: value).doubleValue)
    }
}

// MARK: - Identity lifecycle (contract §9.4)

/// Decides the `identify`/`reset` calls at each identity boundary. The store
/// applies the actions in order on the analytics seam.
///
/// - `verified(_:)`: the authenticated Supabase user id was verified. The same
///   id again is a no-op; a different id than the last identified one is an
///   account switch, so `reset` runs before the new `identify`.
/// - `boundary()`: sign-out, account switch start, account deletion. Resets
///   (RN `resetUser()` is unconditional) and forgets the id. A boundary that
///   directly follows another (deletion resets as soon as the server confirms,
///   then its sign-out teardown reaches the same boundary) is one reset, not
///   two: nothing was identified in between.
struct NativeAnalyticsIdentityLifecycle: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case identify(String)
        case reset
    }

    private(set) var identifiedUserID: String?
    private(set) var isAtBoundary = false

    mutating func verified(_ userID: String) -> [Action] {
        guard !userID.isEmpty, userID != identifiedUserID else { return [] }
        var actions: [Action] = []
        if identifiedUserID != nil { actions.append(.reset) }
        identifiedUserID = userID
        isAtBoundary = false
        actions.append(.identify(userID))
        return actions
    }

    mutating func boundary() -> [Action] {
        guard !isAtBoundary else { return [] }
        identifiedUserID = nil
        isAtBoundary = true
        return [.reset]
    }
}

// MARK: - Gate-driven events (onboarding steps, paywall, root screens)

/// The events and root screen a first-run gate transition implies. RN renders
/// one root route per gate (`App.tsx:601-630`); native derives the same
/// moments from `AppStore.authenticationGateState` so they need no view hook.
enum NativeAnalyticsGatePolicy {
    struct Output: Equatable {
        var events: [NativeAnalyticsEvent] = []
        var screen: NativeAnalyticsScreen?
        /// Whether the current paywall presentation already sent
        /// `subscription_paywall_shown`.
        var paywallTracked: Bool
    }

    static func transition(
        from old: NativeAuthenticationGateState,
        to new: NativeAuthenticationGateState,
        paywallTracked: Bool
    ) -> Output {
        var output = Output(paywallTracked: paywallTracked)
        let oldScreen = rootScreen(for: old)
        let newScreen = rootScreen(for: new)
        if let newScreen, newScreen != oldScreen { output.screen = newScreen }

        switch (old, new) {
        case (.onboarding(let before), .onboarding(let after)):
            if before.step != after.step, let step = NativeAnalyticsEvent.onboardingStep(index: after.step) {
                output.events.append(.onboardingStepViewed(step))
            }
        case (_, .onboarding(let draft)):
            if let step = NativeAnalyticsEvent.onboardingStep(index: draft.step) {
                output.events.append(.onboardingStepViewed(step))
            }
        case (.startingPoint, .startingPoint):
            break
        case (_, .startingPoint):
            output.events.append(.onboardingStepViewed(.startingPoint))
        default:
            break
        }

        switch new {
        case .paywall:
            // RN fires once per PaywallScreen mount; a retry (paywall →
            // subscriptionLoading → paywall) reloads offerings in the same
            // mount, so it does not fire again.
            if !paywallTracked {
                output.events.append(.subscriptionPaywallShown(.onboardingGate))
                output.paywallTracked = true
            }
        case .subscriptionLoading:
            break
        default:
            output.paywallTracked = false
        }
        return output
    }

    /// The RN root route each gate renders; `nil` when the gate has no RN
    /// route of its own (`.signedIn` screens come from the tab views).
    static func rootScreen(for gate: NativeAuthenticationGateState) -> NativeAnalyticsScreen? {
        switch gate {
        case .signedOut: .auth
        case .onboarding: .onboarding
        case .paywall: .paywall
        case .startingPoint: .startingPoint
        default: nil
        }
    }
}

// MARK: - Screen appearance (contract §9.3)

/// One destination view's appearance cycle, the only `$screen` dedupe.
///
/// RN sends `$screen` on every navigation state change with no dedupe, so a
/// pop back to a list and a second visit to the same detail both send again.
/// Native sends on `onAppear`, which SwiftUI can call more than once for a
/// single on-screen appearance (for example while a tab or stack
/// re-evaluates). `appear()` is `true` only for the first call since the last
/// `disappear()`, so those duplicates are dropped and every real return is not.
struct NativeAnalyticsScreenAppearance: Equatable, Sendable {
    private(set) var isVisible = false

    mutating func appear() -> Bool {
        guard !isVisible else { return false }
        isVisible = true
        return true
    }

    mutating func disappear() {
        isVisible = false
    }
}

// MARK: - Screen map (contract §9.3)

/// Native destinations and the RN route name each sends as `$screen`.
///
/// RN's `useNavigationTracker` (posthog-react-native 4.54.5,
/// `dist/hooks/useNavigationTracker.js`) calls `posthog.screen` with
/// `navigation.getCurrentRoute().name`: the focused **leaf** route. So the
/// Today tab reports `TodayHome`, not the tab name `Today`, and the Invoices
/// tab reports `InvoiceList`. Destinations whose RN counterpart is a modal
/// component rather than a route (the expense sheet, the payment sheet, the
/// invoice detail modal, the composer review sheets) and native-only
/// destinations send nothing (`routeName == nil`).
enum NativeAnalyticsScreen: String, CaseIterable, Sendable {
    // Root gates
    case auth, onboarding, paywall, startingPoint
    // Tabs
    case today, jobList, invoiceList, customerList, money, coach
    // Today stack
    case calendar, route, search, settings
    case settingsBusiness, settingsSchedule, settingsAppearance, settingsPricing
    case settingsInvoiceNumbering, settingsAI, settingsReviews, settingsNotifications
    case settingsPayments, settingsBooking, settingsSubscription, settingsAccount, settingsImport
    // Jobs stack
    case jobDetail, jobEditor, changeOrderEditor, pricingCalculator, createInvoiceFromJob
    case estimateReview, recurringJobs, reviewRequest, estimateFollowUp
    // Invoices stack
    case invoiceEditor, outreach, recurringInvoices, recurringInvoiceEditor
    // Customers stack
    case customerDetail, customerEditor
    // Money stack
    case mileageLog, tripEditor, pricebook, pricebookEntry, exportData
    // No RN route (native-only or an RN modal component)
    case expenseEditor, paymentEditor, invoiceDetail, onMyWayReview, appointmentConfirmationReview
    case changeOrderReview, bookingRequests, customerPortal, jobPhotos, syncSettings, passwordRecovery

    var routeName: String? {
        switch self {
        case .auth: "Auth"
        case .onboarding: "Onboarding"
        case .paywall: "Paywall"
        case .startingPoint: "StartingPoint"
        case .today: "TodayHome"
        case .jobList: "JobList"
        case .invoiceList: "InvoiceList"
        case .customerList: "CustomerList"
        case .money: "MoneyHome"
        case .coach: "ChatHome"
        case .calendar: "Calendar"
        case .route: "Route"
        case .search: "Search"
        case .settings: "Settings"
        case .settingsBusiness: "SettingsBusiness"
        case .settingsSchedule: "SettingsSchedule"
        case .settingsAppearance: "SettingsAppearance"
        case .settingsPricing: "SettingsPricing"
        case .settingsInvoiceNumbering: "SettingsInvoiceNumbering"
        case .settingsAI: "SettingsAI"
        case .settingsReviews: "SettingsReviews"
        case .settingsNotifications: "SettingsNotifications"
        case .settingsPayments: "SettingsPayments"
        case .settingsBooking: "SettingsBooking"
        case .settingsSubscription: "SettingsSubscription"
        case .settingsAccount: "SettingsAccount"
        case .settingsImport: "SettingsImport"
        case .jobDetail: "JobDetail"
        case .jobEditor: "AddJob"
        case .changeOrderEditor: "AddChangeOrder"
        case .pricingCalculator: "PricingCalculator"
        case .createInvoiceFromJob: "CreateInvoiceFromJob"
        case .estimateReview: "SendEstimate"
        case .recurringJobs: "RecurringJobs"
        case .reviewRequest: "ReviewRequest"
        case .estimateFollowUp: "EstimateFollowUp"
        case .invoiceEditor: "AddInvoice"
        case .outreach: "Outreach"
        case .recurringInvoices: "RecurringInvoices"
        case .recurringInvoiceEditor: "AddRecurringInvoice"
        case .customerDetail: "CustomerDetail"
        case .customerEditor: "AddCustomer"
        case .mileageLog: "MileageLog"
        case .tripEditor: "AddTrip"
        case .pricebook: "Pricebook"
        case .pricebookEntry: "PricebookEntry"
        case .exportData: "ExportData"
        case .expenseEditor, .paymentEditor, .invoiceDetail, .onMyWayReview, .appointmentConfirmationReview,
             .changeOrderReview, .bookingRequests, .customerPortal, .jobPhotos, .syncSettings, .passwordRecovery:
            nil
        }
    }
}
