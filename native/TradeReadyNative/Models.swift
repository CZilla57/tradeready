import Foundation
import SwiftUI

private enum NativeRecordID {
    static let generator = LocalIDGenerator()
    static func customer() -> String { generator.customerID() }
    static func job() -> String { generator.jobID() }
    static func payment() -> String { generator.paymentID() }
    static func invoice() -> String { generator.manualInvoiceID() }
    static func expense() -> String { generator.expenseID() }
}

enum JobStatus: String, Codable, CaseIterable, Identifiable {
    case lead, estimateSent = "estimate_sent", approved, scheduled, inProgress = "in_progress"
    case complete, invoiced, paid, declined

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lead: "Lead"
        case .estimateSent: "Estimate sent"
        case .approved: "Approved"
        case .scheduled: "Scheduled"
        case .inProgress: "In progress"
        case .complete: "Complete"
        case .invoiced: "Invoiced"
        case .paid: "Paid"
        case .declined: "Declined"
        }
    }
    var color: Color {
        switch self {
        case .lead: .tradeInfoText
        case .estimateSent: .tradeWarningText
        case .approved: .tradeMintText
        case .scheduled: .tradeIndigoText
        case .inProgress: .tradePurpleText
        case .complete, .paid: .tradeSuccessText
        case .invoiced: .tradeCyanText
        case .declined: .secondary
        }
    }
    var isActive: Bool { ![.paid, .declined].contains(self) }
}

extension JobStatus {
    var lifecycleStatus: JobLifecycleStatus {
        JobLifecycleStatus(rawValue: rawValue) ?? .lead
    }

    init(lifecycleStatus: JobLifecycleStatus) {
        self = JobStatus(rawValue: lifecycleStatus.rawValue) ?? .lead
    }
}

struct Customer: Identifiable, Codable, Hashable {
    var id = NativeRecordID.customer()
    var name = ""
    var email = ""
    var phone = ""
    var address = ""
    var notes = ""
    var createdAt = Date()
    /// Presence hides the record from active customer lists without rewriting
    /// invoices, jobs, or historical totals. Keep the canonical string intact.
    var archivedAt: String?
}

struct Job: Identifiable, Codable, Hashable {
    var id = NativeRecordID.job()
    var customerId = ""
    var customerName = ""
    var title = ""
    var description = ""
    var status: JobStatus = .lead
    var scheduledAt: Date?
    var scheduledEnd: Date?
    var address = ""
    var estimateTotal = 0.0
    var laborHours = 0.0
    var laborRate = 85.0
    var notes = ""
    var invoiceId: String?
    var createdAt = Date()
    var archivedAt: String?
}

extension Job {
    var lifecycleJob: LifecycleJob {
        LifecycleJob(id: id, status: status.lifecycleStatus, invoiceID: invoiceId)
    }
}

struct Payment: Identifiable, Codable, Hashable {
    var id = NativeRecordID.payment()
    var amount = 0.0
    var date = Date()
    var method = "Card"
    var note = ""
    var voidedAt: Date?
}

struct Invoice: Identifiable, Codable, Hashable {
    var id = NativeRecordID.invoice()
    var customerId = ""
    var customer = ""
    var number = ""
    var amount = 0.0
    var due = Date()
    var email = ""
    var phone = ""
    var description = ""
    var payments: [Payment] = []
    /// Compatibility state for legacy canonical invoices that were marked paid
    /// before the payment ledger existed. Deliberately excluded from store.json.
    var legacyPaid = false
    /// The original settlement date for a pre-ledger paid invoice. This stays
    /// transient, but lets the UI materialize an accurate correction history.
    var legacyPaidAt: Date?

    var amountPaid: Double { ledgerAmount(PaymentLedger.amountPaid(workflowLedger)) }
    var balance: Double { ledgerAmount(PaymentLedger.balanceDue(workflowLedger)) }
    var isPaid: Bool { PaymentLedger.isFullyPaid(workflowLedger) }
    var isPartlyPaid: Bool { PaymentLedger.isPartlyPaid(workflowLedger) }
    var overpaidAmount: Double { ledgerAmount(PaymentLedger.overpaidAmount(workflowLedger)) }
    var isOverdue: Bool { !isPaid && due < Calendar.current.startOfDay(for: .now) }
    var effectivePayments: [Payment] {
        PaymentLedger.materializeLegacyLedger(workflowLedger).map(Payment.init(ledger:))
    }

    mutating func recordPayment(_ payment: Payment) {
        guard !payments.contains(where: { $0.id == payment.id }) else { return }
        legacyPaid = false
        payments.append(payment)
    }

    private enum CodingKeys: String, CodingKey {
        case id, customerId, customer, number, amount, due, email, phone, description, payments
    }

    init(
        id: String = NativeRecordID.invoice(), customerId: String = "", customer: String = "", number: String = "",
        amount: Double = 0, due: Date = Date(), email: String = "", phone: String = "",
        description: String = "", payments: [Payment] = [], legacyPaid: Bool = false,
        legacyPaidAt: Date? = nil
    ) {
        self.id = id; self.customerId = customerId; self.customer = customer; self.number = number
        self.amount = amount; self.due = due; self.email = email; self.phone = phone
        self.description = description; self.payments = payments; self.legacyPaid = legacyPaid
        self.legacyPaidAt = legacyPaidAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? NativeRecordID.invoice()
        customerId = try c.decodeIfPresent(String.self, forKey: .customerId) ?? ""
        customer = try c.decodeIfPresent(String.self, forKey: .customer) ?? ""
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        due = try c.decodeIfPresent(Date.self, forKey: .due) ?? Date()
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        payments = try c.decodeIfPresent([Payment].self, forKey: .payments) ?? []
        legacyPaid = false
        legacyPaidAt = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(customerId, forKey: .customerId)
        try c.encode(customer, forKey: .customer); try c.encode(number, forKey: .number)
        try c.encode(amount, forKey: .amount); try c.encode(due, forKey: .due)
        try c.encode(email, forKey: .email); try c.encode(phone, forKey: .phone)
        try c.encode(description, forKey: .description); try c.encode(payments, forKey: .payments)
    }

    var workflowLedger: LedgerInvoice {
        LedgerInvoice(
            id: id,
            amount: FinancialDecimal.value(String(amount)),
            due: due.dateOnlyString,
            paid: legacyPaid,
            paidAt: legacyPaidAt?.dateOnlyString,
            payments: payments.map(\.ledgerPayment)
        )
    }

    func applying(_ payment: Payment) -> Invoice {
        applying(PaymentLedger.apply(payment.ledgerPayment, to: workflowLedger),
                 preferredPayments: [payment.id: payment])
    }

    func settlingRemaining(on date: Date, paymentID: String) -> Invoice {
        let result = PaymentLedger.settleRemaining(
            workflowLedger,
            on: date.dateOnlyString,
            paymentID: paymentID
        )
        let payment = Payment(id: paymentID, amount: balance, date: date, method: "Other")
        return applying(result, preferredPayments: [paymentID: payment])
    }

    func voidingPayment(id paymentID: String, on date: Date) -> Invoice {
        applying(
            PaymentLedger.voidPayment(
                id: paymentID,
                on: workflowLedger,
                voidedAt: date.dateOnlyString
            ),
            preferredPayments: [:]
        )
    }

    private func applying(_ ledger: LedgerInvoice, preferredPayments: [String: Payment]) -> Invoice {
        let existing = Dictionary(uniqueKeysWithValues: effectivePayments.map { ($0.id, $0) })
        var updated = self
        updated.legacyPaid = false
        updated.legacyPaidAt = nil
        updated.payments = (ledger.payments ?? []).map { entry in
            var payment = preferredPayments[entry.id] ?? existing[entry.id] ?? Payment(ledger: entry)
            payment.amount = NSDecimalNumber(decimal: entry.amount).doubleValue
            payment.voidedAt = entry.voidedAt.flatMap(Self.date(fromDay:))
            return payment
        }
        return updated
    }

    static func date(fromDay value: String) -> Date? {
        let fields = value.split(separator: "-")
        guard fields.count == 3,
              let year = Int(fields[0]),
              let month = Int(fields[1]),
              let day = Int(fields[2])
        else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    private func ledgerAmount(_ amount: Decimal) -> Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }
}

private extension Payment {
    var ledgerPayment: LedgerPayment {
        let ledgerMethod: LedgerPaymentMethod = switch method.lowercased() {
        case "cash": .cash
        case "check", "cheque": .check
        case "card": .card
        case "ach", "bank transfer", "bank_transfer": .bankTransfer
        default: .other
        }
        return LedgerPayment(
            id: id,
            amount: FinancialDecimal.value(String(amount)),
            date: date.dateOnlyString,
            method: ledgerMethod,
            note: note.isEmpty ? nil : note,
            voidedAt: voidedAt?.dateOnlyString
        )
    }

    init(ledger: LedgerPayment) {
        self.init(
            id: ledger.id,
            amount: NSDecimalNumber(decimal: ledger.amount).doubleValue,
            date: Invoice.date(fromDay: ledger.date) ?? .distantPast,
            method: ledger.method.displayName,
            note: ledger.note ?? "",
            voidedAt: ledger.voidedAt.flatMap(Invoice.date(fromDay:))
        )
    }
}

extension LedgerPaymentMethod {
    init(displayName: String) {
        self = switch displayName.lowercased() {
        case "cash": .cash
        case "check", "cheque": .check
        case "card": .card
        case "stripe": .stripe
        case "ach", "bank transfer", "bank_transfer": .bankTransfer
        default: .other
        }
    }

    var displayName: String {
        switch self {
        case .cash: "Cash"
        case .check: "Cheque"
        case .card: "Card"
        case .stripe: "Stripe"
        case .bankTransfer: "Bank transfer"
        case .other: "Other"
        }
    }
}

enum ExpenseCategory: String, Codable, CaseIterable, Identifiable {
    case materials, tools, fuel, labor, insurance, software, marketing, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Expense: Identifiable, Codable, Hashable {
    var id = NativeRecordID.expense()
    var merchant = ""
    var amount = 0.0
    var date = Date()
    var category: ExpenseCategory = .materials
    var notes = ""
    /// Optional job link (exact canonical id) — nil means "not linked".
    var jobId: String?
    /// Device-local receipt image path. Never synced as bytes; the canonical
    /// record carries the reference only.
    var receiptUri: String?
    /// Import provenance marker (set on import-created records only).
    var importBatchId: String?
}

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

struct BusinessSettings: Codable, Hashable {
    var businessName = "Your Business Name"
    var contactName = ""
    var phone = ""
    var email = ""
    var address = ""
    var region = ""
    /// Local file URL of the business logo (`logos/logo_<id>.png`), "" when none. Only
    /// the reference syncs with the settings blob; the bytes stay on the device, as in RN.
    var logoPhoto = ""
    var trade = "Plumbing"
    var paymentNotes = "Payment due upon completion. We accept check, card, or bank transfer."
    var paymentProvider = "stripe"
    var paymentProviderKey = ""
    var paymentProviderKeys: [String: String] = [:]
    var laborRate = 85.0
    var materialMarkup = 20.0
    var overheadPercent = 15.0
    var marginPercent = 20.0
    var minimumJobFee = 75.0
    var emergencyMultiplier = 1.5
    var mileageRate = 0.70
    var ownerLaborCostRate = 0.0
    /// Optional effective income-tax percentage. `nil` means "unset" and must
    /// never be coerced to a value (an explicitly cleared field is a separate
    /// user act, handled by the settings edit path).
    var taxIncomeRate: Double?
    /// "mileage" | "actual". Kept as the raw wire string so an unknown future
    /// election round-trips instead of being dropped by an enum decode.
    var vehicleDeductionMethod: String?
    var workDayStart = 8
    var workDayEnd = 17
    var workDays: Set<Int> = [2, 3, 4, 5, 6]
    var appointmentMinutes = 120
    var bufferMinutes = 15
    var invoicePrefix = "INV-"
    var invoiceStart = 1
    var autoOutreachEnabled = false
    var autoSendEmailEnabled = false
    var appointmentRemindersEnabled = false
    var appointmentConfirmTemplate = ""
    var onMyWayTemplate = ""
    var estimateFollowUpsEnabled = true
    var autoInvoiceOnComplete = false
    var autoSendRecurringInvoicesEnabled = false
    var bookingEnabled = false
    var bookableSlotsEnabled = false
    var reviewRequestEnabled = false
    var googleReviewLink = ""
    var reviewRequestDelayHours = 3
    var reviewRequestTemplate = "Hi {customerName}, thanks for choosing {businessName}! If you were happy with the work, we'd really appreciate a Google review: {googleReviewLink}"
    var appearance: Appearance = .system

    init(
        businessName: String = "Your Business Name", contactName: String = "", phone: String = "",
        email: String = "", address: String = "", region: String = "", trade: String = "Plumbing"
    ) {
        self.businessName = businessName; self.contactName = contactName; self.phone = phone
        self.email = email; self.address = address; self.region = region; self.trade = trade
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            businessName: try c.decodeIfPresent(String.self, forKey: .businessName) ?? "Your Business Name",
            contactName: try c.decodeIfPresent(String.self, forKey: .contactName) ?? "",
            phone: try c.decodeIfPresent(String.self, forKey: .phone) ?? "",
            email: try c.decodeIfPresent(String.self, forKey: .email) ?? "",
            address: try c.decodeIfPresent(String.self, forKey: .address) ?? "",
            region: try c.decodeIfPresent(String.self, forKey: .region) ?? "",
            trade: try c.decodeIfPresent(String.self, forKey: .trade) ?? "Plumbing"
        )
        logoPhoto = try c.decodeIfPresent(String.self, forKey: .logoPhoto) ?? ""
        paymentNotes = try c.decodeIfPresent(String.self, forKey: .paymentNotes) ?? paymentNotes
        laborRate = try c.decodeIfPresent(Double.self, forKey: .laborRate) ?? laborRate
        materialMarkup = try c.decodeIfPresent(Double.self, forKey: .materialMarkup) ?? materialMarkup
        overheadPercent = try c.decodeIfPresent(Double.self, forKey: .overheadPercent) ?? overheadPercent
        marginPercent = try c.decodeIfPresent(Double.self, forKey: .marginPercent) ?? marginPercent
        minimumJobFee = try c.decodeIfPresent(Double.self, forKey: .minimumJobFee) ?? minimumJobFee
        emergencyMultiplier = try c.decodeIfPresent(Double.self, forKey: .emergencyMultiplier) ?? emergencyMultiplier
        mileageRate = try c.decodeIfPresent(Double.self, forKey: .mileageRate) ?? mileageRate
        ownerLaborCostRate = try c.decodeIfPresent(Double.self, forKey: .ownerLaborCostRate) ?? ownerLaborCostRate
        taxIncomeRate = try c.decodeIfPresent(Double.self, forKey: .taxIncomeRate)
        vehicleDeductionMethod = try c.decodeIfPresent(String.self, forKey: .vehicleDeductionMethod)
        workDayStart = try c.decodeIfPresent(Int.self, forKey: .workDayStart) ?? workDayStart
        workDayEnd = try c.decodeIfPresent(Int.self, forKey: .workDayEnd) ?? workDayEnd
        workDays = try c.decodeIfPresent(Set<Int>.self, forKey: .workDays) ?? workDays
        appointmentMinutes = try c.decodeIfPresent(Int.self, forKey: .appointmentMinutes) ?? appointmentMinutes
        bufferMinutes = try c.decodeIfPresent(Int.self, forKey: .bufferMinutes) ?? bufferMinutes
        invoicePrefix = try c.decodeIfPresent(String.self, forKey: .invoicePrefix) ?? invoicePrefix
        invoiceStart = try c.decodeIfPresent(Int.self, forKey: .invoiceStart) ?? invoiceStart
        autoOutreachEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoOutreachEnabled) ?? autoOutreachEnabled
        autoSendEmailEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSendEmailEnabled) ?? autoSendEmailEnabled
        appointmentRemindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .appointmentRemindersEnabled) ?? appointmentRemindersEnabled
        appointmentConfirmTemplate = try c.decodeIfPresent(String.self, forKey: .appointmentConfirmTemplate) ?? appointmentConfirmTemplate
        onMyWayTemplate = try c.decodeIfPresent(String.self, forKey: .onMyWayTemplate) ?? onMyWayTemplate
        estimateFollowUpsEnabled = try c.decodeIfPresent(Bool.self, forKey: .estimateFollowUpsEnabled) ?? estimateFollowUpsEnabled
        autoInvoiceOnComplete = try c.decodeIfPresent(Bool.self, forKey: .autoInvoiceOnComplete) ?? autoInvoiceOnComplete
        autoSendRecurringInvoicesEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSendRecurringInvoicesEnabled) ?? autoSendRecurringInvoicesEnabled
        bookingEnabled = try c.decodeIfPresent(Bool.self, forKey: .bookingEnabled) ?? bookingEnabled
        bookableSlotsEnabled = try c.decodeIfPresent(Bool.self, forKey: .bookableSlotsEnabled) ?? bookableSlotsEnabled
        reviewRequestEnabled = try c.decodeIfPresent(Bool.self, forKey: .reviewRequestEnabled) ?? reviewRequestEnabled
        googleReviewLink = try c.decodeIfPresent(String.self, forKey: .googleReviewLink) ?? googleReviewLink
        reviewRequestDelayHours = try c.decodeIfPresent(Int.self, forKey: .reviewRequestDelayHours) ?? reviewRequestDelayHours
        reviewRequestTemplate = try c.decodeIfPresent(String.self, forKey: .reviewRequestTemplate) ?? reviewRequestTemplate
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? appearance
        paymentProvider = try c.decodeIfPresent(String.self, forKey: .paymentProvider) ?? paymentProvider
        paymentProviderKey = try c.decodeIfPresent(String.self, forKey: .paymentProviderKey) ?? paymentProviderKey
        paymentProviderKeys = try c.decodeIfPresent([String: String].self, forKey: .paymentProviderKeys) ?? paymentProviderKeys
    }

    /// Stored key for a provider, mirroring `getProviderKey`: Stripe reads the
    /// legacy single key, every other provider reads its per-provider entry.
    func providerKey(for provider: String? = nil) -> String {
        let p = provider ?? paymentProvider
        if p == "stripe" { return paymentProviderKey }
        return paymentProviderKeys[p] ?? ""
    }

    mutating func setProviderKey(_ value: String, for provider: String? = nil) {
        let p = provider ?? paymentProvider
        if p == "stripe" { paymentProviderKey = value } else { paymentProviderKeys[p] = value }
    }
}

/// Decode-only shape used to upgrade the earliest native prototype store.
/// It is never written after the canonical snapshot migration.
struct LegacyNativeStoreSnapshot: Codable {
    var customers: [Customer]
    var jobs: [Job]
    var invoices: [Invoice]
    var expenses: [Expense]
    var settings: BusinessSettings
}

enum AppTab: Hashable { case today, jobs, invoices, customers, money, coach }

// Brand palette. The literals must equal `NativeAccessibilityAudit.Palette`
// (task 11.10a; the accessibility host suite parses this block).
extension Color {
    static let tradeInk = Color(red: 0.078, green: 0.129, blue: 0.239)
#if os(iOS)
    /// Tint for text, icons, outlines and graphics. Light is RN `lightColors.accent`;
    /// dark is RN `darkColors.accent` (the light value measured 2.61:1 on the dark canvas).
    static let tradeReady = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.357, green: 0.608, blue: 0.859, alpha: 1) : UIColor(red: 0.114, green: 0.361, blue: 0.620, alpha: 1) })
    /// Filled surfaces under white text or icons (selected chips, prominent buttons).
    static let tradeReadyFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.184, green: 0.471, blue: 0.769, alpha: 1) : UIColor(red: 0.114, green: 0.361, blue: 0.620, alpha: 1) })
    static let tradeCanvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.063, green: 0.094, blue: 0.149, alpha: 1) : UIColor(red: 0.961, green: 0.961, blue: 0.945, alpha: 1) })
    /// Destructive filled surfaces under white text (the clock-out button and, from A29, the
    /// destructive swipe actions). Light is RN `lightColors.danger`; dark is native only
    /// (system red measured about 3.3:1 under white).
    static let tradeDangerFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.800, green: 0.290, blue: 0.188, alpha: 1) : UIColor(red: 0.722, green: 0.263, blue: 0.169, alpha: 1) })
    /// Error and destructive text (11.10b A28, darkened by A29). Light is RN's
    /// `lightColors.danger` rust darkened to hold 4.5:1 on the 13% status washes; dark is
    /// native only. System red text measured 3.55:1 on a white list row.
    static let tradeDangerText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.934, green: 0.567, blue: 0.480, alpha: 1) : UIColor(red: 0.650, green: 0.237, blue: 0.152, alpha: 1) })
    /// Semantic text colors (11.10b A29): each light variant is the system hue darkened to
    /// hold 4.5:1 on every light ground and its own 13% wash; each dark variant is the
    /// system dark value where that passes. Native difference from RN's palette; the
    /// audit palette carries the same literals. Text, glyphs, dots and washes use these.
    static let tradeSuccessText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1) : UIColor(red: 0.112, green: 0.429, blue: 0.192, alpha: 1) })
    static let tradeWarningText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1.000, green: 0.624, blue: 0.039, alpha: 1) : UIColor(red: 0.550, green: 0.321, blue: 0.000, alpha: 1) })
    static let tradeInfoText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.366, green: 0.682, blue: 1.000, alpha: 1) : UIColor(red: 0.000, green: 0.361, blue: 0.755, alpha: 1) })
    static let tradeMintText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.388, green: 0.902, blue: 0.886, alpha: 1) : UIColor(red: 0.000, green: 0.421, blue: 0.402, alpha: 1) })
    static let tradeIndigoText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.640, green: 0.636, blue: 0.944, alpha: 1) : UIColor(red: 0.321, green: 0.314, blue: 0.780, alpha: 1) })
    static let tradePurpleText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.828, green: 0.557, blue: 0.965, alpha: 1) : UIColor(red: 0.525, green: 0.246, blue: 0.666, alpha: 1) })
    static let tradeCyanText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.392, green: 0.824, blue: 1.000, alpha: 1) : UIColor(red: 0.116, green: 0.400, blue: 0.532, alpha: 1) })
    /// Swipe-action fills under white text and glyphs (A29); never a text color.
    static let tradeSuccessFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.139, green: 0.530, blue: 0.237, alpha: 1) : UIColor(red: 0.135, green: 0.515, blue: 0.230, alpha: 1) })
    static let tradeWarningFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.674, green: 0.394, blue: 0.000, alpha: 1) : UIColor(red: 0.655, green: 0.383, blue: 0.000, alpha: 1) })
#else
    static let tradeReady = Color(red: 0.114, green: 0.361, blue: 0.620)
    static let tradeReadyFill = Color(red: 0.114, green: 0.361, blue: 0.620)
    static let tradeCanvas = Color(red: 0.961, green: 0.961, blue: 0.945)
    static let tradeDangerFill = Color(red: 0.722, green: 0.263, blue: 0.169)
    static let tradeDangerText = Color(red: 0.650, green: 0.237, blue: 0.152)
    static let tradeSuccessText = Color(red: 0.112, green: 0.429, blue: 0.192)
    static let tradeWarningText = Color(red: 0.550, green: 0.321, blue: 0.000)
    static let tradeInfoText = Color(red: 0.000, green: 0.361, blue: 0.755)
    static let tradeMintText = Color(red: 0.000, green: 0.421, blue: 0.402)
    static let tradeIndigoText = Color(red: 0.321, green: 0.314, blue: 0.780)
    static let tradePurpleText = Color(red: 0.525, green: 0.246, blue: 0.666)
    static let tradeCyanText = Color(red: 0.116, green: 0.400, blue: 0.532)
    static let tradeSuccessFill = Color(red: 0.135, green: 0.515, blue: 0.230)
    static let tradeWarningFill = Color(red: 0.655, green: 0.383, blue: 0.000)
#endif
}

extension Double {
    var currency: String { formatted(.currency(code: "USD").precision(.fractionLength(0...2))) }
}

extension Date {
    var shortDate: String { formatted(date: .abbreviated, time: .omitted) }
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
    var dateOnlyString: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
