import Foundation

struct NativeInvoicePDFLineItem: Equatable, Sendable {
    let label: String
    let amount: Decimal
    /// RN groups `category == "labor"` first, everything else under
    /// "Additional Charges" (`pdfTemplates.ts` parity).
    let isLabor: Bool
}

struct NativeInvoicePDFPayment: Equatable, Sendable {
    let date: String
    let methodLabel: String
    let amount: Decimal
}

enum NativeInvoicePDFStatus: String, Equatable, Sendable {
    case paid, partlyPaid, outstanding
}

/// Frozen customer-facing invoice content. It is intentionally detached from
/// the store so rendering cannot mutate, or observe changes to, local truth.
struct NativeInvoicePDFDocument: Equatable, Sendable {
    let businessName: String
    let businessContactName: String
    let businessPhone: String
    let businessEmail: String
    let businessAddress: String
    let paymentTerms: String
    let customerName: String
    let customerEmail: String
    let customerPhone: String
    let invoiceNumber: String
    let description: String
    let lineItems: [NativeInvoicePDFLineItem]
    let history: [NativeInvoicePDFPayment]
    let total: Decimal
    let paidToDate: Decimal
    let status: NativeInvoicePDFStatus
    let balance: Decimal
    let issueDate: String
    let due: String
    let currency: String

    init(invoice: Canonical.Invoice, settings: Canonical.Settings, now: Date = Date(), currency: String = "USD") {
        businessName = settings.businessName; businessContactName = settings.contactName
        businessPhone = settings.phone; businessEmail = settings.email; businessAddress = settings.address
        paymentTerms = settings.paymentNotes
        customerName = invoice.customer; customerEmail = invoice.email; customerPhone = invoice.phone
        invoiceNumber = invoice.number; description = invoice.desc
        lineItems = (invoice.lineItems ?? []).map {
            NativeInvoicePDFLineItem(label: $0.description, amount: $0.amount, isLabor: $0.category == "labor")
        }
        // The customer's copy excludes voided entries (internal bookkeeping)
        // and the synthesized legacy_<id> entry (internal migration language).
        history = (invoice.payments ?? []).filter { $0.voidedAt == nil && !$0.id.hasPrefix("legacy_") }.map {
            NativeInvoicePDFPayment(date: $0.date, methodLabel: Self.methodLabel($0.method), amount: $0.amount)
        }
        total = invoice.amount
        let ledger = LedgerInvoice(
            id: invoice.id, amount: invoice.amount, due: invoice.due, paid: invoice.paid,
            paidAt: invoice.paidAt, payments: invoice.payments?.map {
                LedgerPayment(id: $0.id, amount: $0.amount, date: $0.date, method: .other, note: $0.note, voidedAt: $0.voidedAt)
            }, depositRequest: nil
        )
        balance = PaymentLedger.balanceDue(ledger)
        paidToDate = PaymentLedger.amountPaid(ledger)
        status = PaymentLedger.isFullyPaid(ledger) ? .paid : PaymentLedger.isPartlyPaid(ledger) ? .partlyPaid : .outstanding
        issueDate = Self.displayDate(Self.issueDate(forInvoiceID: invoice.id, now: now))
        due = Self.displayDate(Self.date(fromDayString: invoice.due) ?? now)
        self.currency = currency
    }

    /// Description fallback (`pdfTemplates.ts` parity): with no line items the
    /// table shows the description, or "Services rendered" when that is blank.
    var tableDescription: String {
        if lineItems.isEmpty { return description.isEmpty ? "Services rendered" : description }
        return description
    }

    var primaryLineItems: [NativeInvoicePDFLineItem] { lineItems.filter(\.isLabor) }
    var additionalLineItems: [NativeInvoicePDFLineItem] { lineItems.filter { !$0.isLabor } }

    /// `invoiceIssueDate` parity: recognized `inv<ms>` timestamp IDs supply the
    /// issue date; legacy IDs fall back to the injected render date. The range
    /// guard rejects all-digit IDs that are not plausible timestamps.
    static func issueDate(forInvoiceID id: String, now: Date = Date()) -> Date {
        let raw = id.hasPrefix("inv") ? String(id.dropFirst(3)) : id
        guard raw.allSatisfy(\.isNumber), let ms = Double(raw) else { return now }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        guard year >= 2000, year <= 2100 else { return now }
        return date
    }

    /// `METHOD_LABELS` parity (customer-facing history table).
    static func methodLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "cash": return "Cash"
        case "check": return "Cheque"
        case "card", "stripe": return "Card"
        case "other": return "Payment"
        default: return raw
        }
    }

    static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func date(fromDayString raw: String) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
    }

    var filename: String {
        let component = invoiceNumber.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let value = String(String.UnicodeScalarView(component)).prefix(60)
        return value.isEmpty ? "Invoice.pdf" : "Invoice-\(value).pdf"
    }
}

#if canImport(UIKit)
import UIKit

enum NativeInvoicePDFError: LocalizedError { case renderFailed, temporaryFileFailed
    var errorDescription: String? { "The invoice PDF could not be created. Your invoice was not changed." }
}

enum NativeInvoicePDFRenderer {
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 48
    // Every color comes from the audited document palette (11.13, A30).
    private static let accent = UIColor(document: NativeAccessibilityAudit.DocumentPalette.accent)
    private static let ink = UIColor(document: NativeAccessibilityAudit.DocumentPalette.ink)
    private static let secondary = UIColor(document: NativeAccessibilityAudit.DocumentPalette.secondary)
    private static let rule = UIColor(document: NativeAccessibilityAudit.DocumentPalette.rule)
    private static let totalWash = UIColor(document: NativeAccessibilityAudit.DocumentPalette.totalWash)

    /// Renders the frozen document. A missing or unreadable logo omits only
    /// the logo; sharing the result never mutates invoice state.
    static func data(for document: NativeInvoicePDFDocument, logoReference: String? = nil) throws -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Invoice \(document.invoiceNumber)",
            kCGPDFContextCreator as String: "TradeReady"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        let logo = localImage(reference: logoReference)

        let result = renderer.pdfData { context in
            var y: CGFloat = 0
            var pageNumber = 0

            func drawFooter() {
                guard pageNumber > 0 else { return }
                let footer = "Thank you for your business  •  Page \(pageNumber)"
                _ = draw(footer, x: margin, y: page.height - 38, width: page.width - margin * 2,
                         font: .systemFont(ofSize: 9), color: secondary, alignment: .center)
            }

            func beginPage(continued: Bool = false) {
                drawFooter()
                context.beginPage()
                pageNumber += 1
                y = margin
                if continued {
                    _ = draw("INVOICE \(document.invoiceNumber) — CONTINUED",
                             x: margin, y: y, width: page.width - margin * 2,
                             font: .systemFont(ofSize: 11, weight: .semibold), color: secondary)
                    y += 28
                }
            }

            func require(_ height: CGFloat) {
                if y + height > page.height - 58 { beginPage(continued: true) }
            }

            func drawTableHeader() {
                _ = draw("DESCRIPTION", x: margin, y: y, width: 390,
                         font: .systemFont(ofSize: 10, weight: .bold), color: secondary)
                _ = draw("AMOUNT", x: 448, y: y, width: 116,
                         font: .systemFont(ofSize: 10, weight: .bold), color: secondary, alignment: .right)
                y += 18
                strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: rule)
                y += 6
            }

            func drawRow(label: String, amount: Decimal, currency: String) {
                let labelHeight = measuredHeight(label, width: 375, font: .systemFont(ofSize: 12.5))
                let rowHeight = max(30, labelHeight + 14)
                if y + rowHeight > page.height - 100 {
                    beginPage(continued: true)
                    drawTableHeader()
                }
                _ = draw(label, x: margin, y: y + 6, width: 375,
                         font: .systemFont(ofSize: 12.5), color: ink)
                _ = draw(money(amount, currency), x: 438, y: y + 6, width: 126,
                         font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium), color: ink, alignment: .right)
                y += rowHeight
                strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: rule)
            }

            beginPage()

            if let logo {
                logo.draw(in: aspectFit(image: logo, inside: CGRect(x: margin, y: y, width: 118, height: 50)))
            }
            let businessX = logo == nil ? margin : margin + 132
            _ = draw(document.businessName, x: businessX, y: y, width: 270,
                     font: .systemFont(ofSize: 21, weight: .bold), color: accent)
            let businessContact = [document.businessContactName, document.businessPhone, document.businessEmail]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "  •  ")
            if !businessContact.isEmpty {
                _ = draw(businessContact, x: businessX, y: y + 29, width: 300,
                         font: .systemFont(ofSize: 9.5), color: secondary)
            }
            if !document.businessAddress.isEmpty {
                _ = draw(document.businessAddress, x: businessX, y: y + 44, width: 300,
                         font: .systemFont(ofSize: 9.5), color: secondary)
            }
            _ = draw("INVOICE", x: 400, y: y + 2, width: 164,
                     font: .systemFont(ofSize: 25, weight: .light), color: secondary,
                     alignment: .right, characterSpacing: 3)
            y += 76
            strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: accent, width: 2)
            y += 28

            _ = draw("BILL TO", x: margin, y: y, width: 230,
                     font: .systemFont(ofSize: 10, weight: .bold), color: secondary, characterSpacing: 1)
            _ = draw("INVOICE \(document.invoiceNumber)", x: 310, y: y, width: 254,
                     font: .systemFont(ofSize: 10, weight: .bold), color: secondary,
                     alignment: .right, characterSpacing: 1)
            y += 18
            _ = draw(document.customerName, x: margin, y: y, width: 240,
                     font: .systemFont(ofSize: 14, weight: .semibold), color: ink)
            y += 21
            let customerContact = [document.customerEmail, document.customerPhone]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            let contactHeight = draw(customerContact, x: margin, y: y, width: 240,
                                     font: .systemFont(ofSize: 10), color: secondary)
            _ = draw("Issue date  \(document.issueDate)\nDue date  \(document.due)", x: 330, y: y, width: 234,
                     font: .systemFont(ofSize: 10), color: secondary, alignment: .right)
            y += max(contactHeight, 34) + 10
            drawBadge(document.status, x: 330, y: y, width: 234)
            y += 30

            drawTableHeader()
            let items = document.primaryLineItems + document.additionalLineItems
            if items.isEmpty {
                drawRow(label: document.tableDescription, amount: document.total, currency: document.currency)
            } else {
                for item in document.primaryLineItems {
                    drawRow(label: item.label, amount: item.amount, currency: document.currency)
                }
                if !document.additionalLineItems.isEmpty {
                    require(30)
                    _ = draw("ADDITIONAL CHARGES", x: margin, y: y, width: 390,
                             font: .systemFont(ofSize: 10, weight: .bold), color: secondary)
                    y += 20
                    for item in document.additionalLineItems {
                        drawRow(label: item.label, amount: item.amount, currency: document.currency)
                    }
                }
            }

            require(80)
            y += 14
            if document.status == .partlyPaid {
                y += draw("Invoice total", x: margin, y: y, width: 300,
                          font: .systemFont(ofSize: 12), color: secondary)
                y += draw(money(document.total, document.currency), x: 388, y: y, width: 176,
                          font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: ink, alignment: .right) + 4
                y += draw("Paid to date", x: margin, y: y, width: 300,
                          font: .systemFont(ofSize: 12), color: secondary)
                y += draw("−\(money(document.paidToDate, document.currency))", x: 388, y: y, width: 176,
                          font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: ink, alignment: .right) + 8
            }
            let totalRect = CGRect(x: margin, y: y, width: page.width - margin * 2, height: 56)
            totalWash.setFill()
            UIBezierPath(roundedRect: totalRect, cornerRadius: 8).fill()
            _ = draw(document.status == .partlyPaid ? "BALANCE DUE" : "TOTAL DUE",
                     x: margin + 16, y: y + 19, width: 220,
                     font: .systemFont(ofSize: 12, weight: .semibold), color: ink)
            _ = draw(money(document.status == .partlyPaid ? document.balance : document.total, document.currency),
                     x: 330, y: y + 13, width: 218,
                     font: .monospacedDigitSystemFont(ofSize: 22, weight: .bold), color: accent, alignment: .right)
            y += 78

            if !document.history.isEmpty {
                require(52)
                _ = draw("PAYMENT HISTORY", x: margin, y: y, width: 280,
                         font: .systemFont(ofSize: 10, weight: .bold), color: secondary, characterSpacing: 1)
                y += 18
                for payment in document.history {
                    let labelHeight = measuredHeight("\(payment.date)  •  \(payment.methodLabel)",
                                                     width: 375, font: .systemFont(ofSize: 12))
                    let rowHeight = max(28, labelHeight + 12)
                    if y + rowHeight > page.height - 100 {
                        beginPage(continued: true)
                        _ = draw("PAYMENT HISTORY — CONTINUED", x: margin, y: y, width: 280,
                                 font: .systemFont(ofSize: 10, weight: .bold), color: secondary, characterSpacing: 1)
                        y += 18
                    }
                    _ = draw("\(payment.date)  •  \(payment.methodLabel)", x: margin, y: y + 5, width: 375,
                             font: .systemFont(ofSize: 12), color: secondary)
                    _ = draw(money(payment.amount, document.currency), x: 438, y: y + 5, width: 126,
                             font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: ink, alignment: .right)
                    y += rowHeight
                }
                y += 8
            }

            let notes = [
                document.lineItems.isEmpty ? nil : document.description,
                document.paymentTerms
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for (index, note) in notes.enumerated() {
                var remaining = note
                var firstPage = true
                while !remaining.isEmpty {
                    require(52)
                    _ = draw(index == 0 && firstPage ? "DESCRIPTION" : (index == 0 ? "DESCRIPTION — CONTINUED" : "PAYMENT TERMS"),
                             x: margin, y: y, width: 280,
                             font: .systemFont(ofSize: 10, weight: .bold), color: secondary, characterSpacing: 1)
                    y += 18
                    let availableHeight = max(18, page.height - 58 - y)
                    let split = splitText(remaining, width: page.width - margin * 2, maximumHeight: availableHeight,
                                          font: .systemFont(ofSize: 11))
                    y += draw(split.page, x: margin, y: y, width: page.width - margin * 2,
                              font: .systemFont(ofSize: 11), color: ink)
                    remaining = split.remainder
                    firstPage = false
                    if !remaining.isEmpty { beginPage(continued: true) }
                }
                y += 18
            }

            drawFooter()
        }
        guard result.starts(with: Data("%PDF-".utf8)) else { throw NativeInvoicePDFError.renderFailed }
        return result
    }

    private static func drawBadge(_ status: NativeInvoicePDFStatus, x: CGFloat, y: CGFloat, width: CGFloat) {
        let label: String
        let fill: UIColor
        let text: UIColor
        switch status {
        case .paid:
            label = "PAID"; fill = UIColor(document: NativeAccessibilityAudit.DocumentPalette.paidBadgeFill)
            text = UIColor(document: NativeAccessibilityAudit.DocumentPalette.paidBadgeText)
        case .partlyPaid:
            label = "PARTLY PAID"; fill = UIColor(document: NativeAccessibilityAudit.DocumentPalette.partlyPaidBadgeFill)
            text = UIColor(document: NativeAccessibilityAudit.DocumentPalette.partlyPaidBadgeText)
        case .outstanding:
            label = "OUTSTANDING"; fill = UIColor(document: NativeAccessibilityAudit.DocumentPalette.outstandingBadgeFill)
            text = UIColor(document: NativeAccessibilityAudit.DocumentPalette.outstandingBadgeText)
        }
        let font = UIFont.systemFont(ofSize: 11, weight: .bold)
        let textWidth = ceil(NSString(string: label).size(withAttributes: [.font: font]).width)
        let badgeWidth = min(width, textWidth + 32)
        let rect = CGRect(x: x + width - badgeWidth, y: y, width: badgeWidth, height: 24)
        fill.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 12).fill()
        _ = draw(label, x: rect.minX, y: y + 5, width: badgeWidth,
                 font: font, color: text, alignment: .center)
    }

    static func temporaryFile(for document: NativeInvoicePDFDocument, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent(".tradeready-\(UUID().uuidString)-\(document.filename)")
        do { try data(for: document).write(to: url, options: .atomic) } catch { throw NativeInvoicePDFError.temporaryFileFailed }
        return url
    }

    static func withTemporaryFile<T>(for document: NativeInvoicePDFDocument, _ body: (URL) throws -> T) throws -> T {
        let url = try temporaryFile(for: document)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    private static func localImage(reference: String?) -> UIImage? {
        guard let reference, !reference.isEmpty,
              let url = URL(string: reference), url.isFileURL,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return nil }
        return UIImage(data: data)
    }

    private static func aspectFit(image: UIImage, inside bounds: CGRect) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.minX, y: bounds.minY + (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private static func money(_ value: Decimal, _ currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.isEmpty ? "USD" : currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "$0.00"
    }

    @discardableResult
    private static func draw(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left,
        characterSpacing: CGFloat = 0
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: characterSpacing
        ]
        let height = measuredHeight(text, width: width, font: font, attributes: attributes)
        NSString(string: text).draw(
            in: CGRect(x: x, y: y, width: width, height: height + 1),
            withAttributes: attributes
        )
        return height
    }

    private static func measuredHeight(
        _ text: String,
        width: CGFloat,
        font: UIFont,
        attributes supplied: [NSAttributedString.Key: Any]? = nil
    ) -> CGFloat {
        let attributes = supplied ?? [.font: font]
        return ceil(NSString(string: text).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        ).height)
    }

    private static func splitText(
        _ text: String,
        width: CGFloat,
        maximumHeight: CGFloat,
        font: UIFont
    ) -> (page: String, remainder: String) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return ("", "") }
        var accepted: [String] = []
        for word in words {
            let candidate = (accepted + [word]).joined(separator: " ")
            if measuredHeight(candidate, width: width, font: font) <= maximumHeight {
                accepted.append(word)
            } else {
                break
            }
        }
        if !accepted.isEmpty {
            return (
                accepted.joined(separator: " "),
                words.dropFirst(accepted.count).joined(separator: " ")
            )
        }

        var fitted = ""
        let characters = Array(words[0])
        var splitIndex = characters.endIndex
        for (index, character) in characters.enumerated() {
            let candidate = fitted + String(character)
            if fitted.isEmpty || measuredHeight(candidate, width: width, font: font) <= maximumHeight {
                fitted = candidate
            } else {
                splitIndex = index
                break
            }
        }
        let remainderOfFirst = String(characters[splitIndex...])
        let remainingWords = ([remainderOfFirst] + Array(words.dropFirst()))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (fitted, remainingWords)
    }

    private static func strokeLine(from start: CGPoint, to end: CGPoint, color: UIColor, width: CGFloat = 1) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }
}

extension UIColor {
    /// An opaque sRGB color from the audited palette (11.13, A30).
    convenience init(document color: NativeAccessibilityAudit.RGB) {
        self.init(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1)
    }
}

#endif
