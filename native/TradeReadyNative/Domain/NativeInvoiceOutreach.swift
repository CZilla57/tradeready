import Foundation

/// Pure reviewed-outreach policy mirroring `utils/invoiceHelpers.ts`
/// (`buildGenericMessage`, `describeAmountOwed`, `describeDepositAsk`) and
/// `utils/bulkInvoiceActions.ts` (`splitEmailSubject`).
///
/// Standalone-compilable (Foundation only). This produces deterministic
/// offline-capable content only; callers must present a user-reviewed system
/// composer and must never send a message automatically. Amounts arrive
/// precomputed so this file never touches the ledger.
enum NativeInvoiceOutreachChannel: String, Equatable, Sendable {
    case email, text
}

struct NativeInvoiceOutreachInvoice: Equatable, Sendable {
    var customer: String
    var number: String
    var description: String
    var total: Double
    var balance: Double
    var isPartlyPaid: Bool
    /// `daysPastDue` parity: > 0 overdue, 0 due today, < 0 due in the future.
    var daysPastDue: Int
}

struct NativeInvoiceOutreachBusiness: Equatable, Sendable {
    var businessName: String
    var contactName: String
    var phone: String
    var paymentNotes: String
}

struct NativeInvoiceOutreachPlan: Equatable, Sendable {
    var installments: String
    var frequency: String
}

enum NativeInvoiceOutreachResolution: Equatable, Sendable {
    /// A confirmed send also supersedes the pending automatic request.
    case recordSent
    case keepDraft
    case keepDraftWithSavedNotice
    case keepDraftWithFailureNotice
}

enum NativeInvoiceOutreach {
    /// Deterministic template (`buildGenericMessage` parity). The partly-paid
    /// line names BOTH numbers so the customer sees their deposit credited.
    static func message(
        invoice: NativeInvoiceOutreachInvoice,
        channel: NativeInvoiceOutreachChannel,
        business: NativeInvoiceOutreachBusiness,
        paymentLink: String?,
        plan: NativeInvoiceOutreachPlan?,
        deposit: NativeDepositAsk?
    ) -> String {
        let amount = describeAmountOwed(invoice)
        let overdue = overdueText(invoice.daysPastDue)
        let depositText = deposit.map { " \(describeDepositAsk($0, hasLink: paymentLink != nil, channel: channel))" } ?? ""
        let planText = plan.map { describePlan($0, balance: invoice.balance) } ?? ""

        if channel == .text {
            let linkPart = paymentLink.map { " Pay here: \($0)" } ?? ""
            return "Hi \(invoice.customer), this is \(business.businessName). Invoice \(invoice.number) — \(amount), \(overdue).\(depositText)\(planText)\(linkPart) — \(business.phone)"
        }

        let linkSection = paymentLink.map { "You can pay securely online here:\nPay now → \($0)\n" } ?? ""
        return """
            Subject: Payment reminder – \(invoice.number)

            Hi \(invoice.customer),

            I hope you're doing well. I'm reaching out regarding invoice \(invoice.number) — \(amount), currently \(overdue).\(depositText)

            \(linkSection)\(planText.isEmpty ? "" : "\(planText)\n\n")If you have any questions or concerns, please don't hesitate to get in touch.

            \(business.paymentNotes.isEmpty ? "" : "\(business.paymentNotes)\n\n")Best regards,
            \(business.contactName)
            \(business.businessName)
            \(business.phone)
            """
    }

    static func fallbackSubject(invoiceNumber: String) -> String {
        "Payment reminder – \(invoiceNumber)"
    }

    /// Splits a generated email into subject/body the way OutreachScreen does.
    static func splitEmailSubject(_ raw: String, fallbackSubject: String) -> (subject: String, body: String) {
        guard raw.hasPrefix("Subject:") else { return (fallbackSubject, raw) }
        let lines = raw.components(separatedBy: "\n")
        let subject = lines[0].replacingOccurrences(of: "Subject:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject.isEmpty ? fallbackSubject : subject, lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Composer-outcome policy. Only an explicit `.sent` records delivery;
    /// cancel keeps the draft, a saved Mail draft is explained (not claimed),
    /// failure keeps the draft for retry. Delivery evidence stays separate
    /// from automatic-send suppression: `.sent` is the only outcome that
    /// supersedes a pending automatic request.
    static func resolution(for outcome: NativeMessageComposeOutcome) -> NativeInvoiceOutreachResolution {
        switch outcome {
        case .sent: .recordSent
        case .cancelled: .keepDraft
        case .saved: .keepDraftWithSavedNotice
        case .failed: .keepDraftWithFailureNotice
        }
    }

    static func supersedesAutoRequest(_ resolution: NativeInvoiceOutreachResolution) -> Bool {
        resolution == .recordSent
    }

    // MARK: - Private

    private static func describeAmountOwed(_ invoice: NativeInvoiceOutreachInvoice) -> String {
        if invoice.isPartlyPaid {
            return "\(formatMoney(invoice.balance)) of \(formatMoney(invoice.total)) still outstanding"
        }
        return formatMoney(invoice.balance)
    }

    private static func overdueText(_ days: Int) -> String {
        if days > 0 { return "\(days) days overdue" }
        if days == 0 { return "due today" }
        return "due in \(abs(days)) days"
    }

    private static func describeDepositAsk(
        _ deposit: NativeDepositAsk,
        hasLink: Bool,
        channel: NativeInvoiceOutreachChannel
    ) -> String {
        // JavaScript prints whole percents without decimals ("50", not "50.0").
        var percentClause = ""
        if let percent = deposit.percent {
            let text = percent == percent.rounded() ? String(Int(percent)) : String(percent)
            percentClause = " (\(text)% of the total)"
        }
        let base = "We're asking for a deposit of \(formatMoney(deposit.amount))\(percentClause) for now"
        guard hasLink else { return "\(base)." }
        return channel == .email
            ? "\(base) — the payment link below is for that amount."
            : "\(base) — the payment link is for that amount."
    }

    private static func describePlan(_ plan: NativeInvoiceOutreachPlan, balance: Double) -> String {
        let count = Int(plan.installments) ?? 0
        guard count > 0 else { return "" }
        let per = formatMoney(balance / Double(count))
        return " We can also arrange \(plan.installments) payments of \(per) \(plan.frequency.lowercased()) if that works better for you."
    }

    /// `formatMoney` parity: en-US USD with grouping and two decimals.
    static func formatMoney(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}
