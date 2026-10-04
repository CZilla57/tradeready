import Foundation

struct NativeEstimatePDFLineItem: Equatable, Sendable {
    let label: String
    let amount: Decimal
}

/// Phase 25 (good/better/best): one tier exactly as frozen in
/// `snapshot.options`, in the snapshot's order. `description` is empty when
/// the tier has none.
struct NativeEstimatePDFOption: Equatable, Sendable {
    let name: String
    let description: String
    let isRecommended: Bool
    let lineItems: [NativeEstimatePDFLineItem]
    let total: Decimal
}

/// Phase 25: one optional add-on as the customer sees it. The snapshot never
/// carries the owner's internal cost, so neither does the document.
struct NativeEstimatePDFAddOn: Equatable, Sendable {
    let label: String
    let description: String
    let amount: Decimal
}

/// Immutable, customer-facing input to the PDF renderer. It is built from the
/// reviewed approval snapshot so exporting cannot observe or flatten a newer
/// canonical job while the sheet is open.
///
/// Phase 25: `options`/`addOns` are populated only from an undecided options
/// snapshot (`snapshot.options`); a single-total or accepted estimate leaves
/// both empty. `lineItems`/`total` always mirror the snapshot's top level (the
/// recommended tier for an options snapshot), exactly as before.
///
/// Phase 32 (spec 2026-10-03 §6.6): `validUntil` is the reviewed snapshot's
/// frozen date (the one the customer is shown and the Worker enforces), and
/// `closingNote` is the customer copy the renderer draws, so the host suite
/// tests both without UIKit.
struct NativeEstimatePDFDocument: Equatable, Sendable {
    let businessName: String
    let businessContactName: String
    let businessPhone: String
    let businessEmail: String
    let businessAddress: String
    let customerName: String
    let customerPhone: String
    let customerEmail: String
    let customerAddress: String
    /// Phase 21: the job's address when it differs from the customer's
    /// (empty otherwise), printed as "Service address".
    let serviceAddress: String
    let jobTitle: String
    let jobDescription: String
    let lineItems: [NativeEstimatePDFLineItem]
    let total: Decimal
    let options: [NativeEstimatePDFOption]
    let addOns: [NativeEstimatePDFAddOn]
    let currency: String
    let issueDate: String
    /// Phase 32: inclusive `YYYY-MM-DD`, or `nil` when the estimate doesn't expire.
    let validUntil: String?

    /// "Nov 2, 2026" for the header's "Valid until" line; `nil` when undated.
    var validUntilDisplay: String? {
        validUntil.map { NativeQuoteExpiry.displayDate($0, style: .medium) }
    }

    /// The closing sentence under the estimate. Dated: "This estimate is valid
    /// until November 2, 2026. " followed by the call to action; undated: the
    /// call to action alone.
    var closingNote: String {
        let action = options.isEmpty
            ? "Reply to approve and we'll get you scheduled."
            : "Reply with the option you'd like and we'll get you scheduled."
        guard let validUntil else { return action }
        return "This estimate is valid until \(NativeQuoteExpiry.displayDate(validUntil, style: .long)). \(action)"
    }

    init(review: NativeEstimateReviewDraft, issuedAt: Date = .now, calendar: Calendar = .current) {
        businessName = review.snapshot.businessName
        businessContactName = review.businessContactName
        businessPhone = review.businessPhone
        businessEmail = review.businessEmail
        businessAddress = review.businessAddress
        customerName = review.snapshot.customerName
        customerPhone = review.customerPhone
        customerEmail = review.customerEmail
        customerAddress = review.customerAddress
        serviceAddress = review.serviceAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        jobTitle = review.snapshot.jobTitle
        jobDescription = review.jobDescription
        lineItems = review.snapshot.lineItems.map {
            NativeEstimatePDFLineItem(label: $0.label, amount: $0.amount)
        }
        total = review.snapshot.total
        let snapshotOptions = review.snapshot.options
        options = snapshotOptions?.tiers.map { tier in
            NativeEstimatePDFOption(
                name: tier.name,
                description: tier.description ?? "",
                isRecommended: tier.id == snapshotOptions?.recommendedTierId,
                lineItems: tier.lineItems.map {
                    NativeEstimatePDFLineItem(label: $0.label, amount: $0.amount)
                },
                total: tier.total
            )
        } ?? []
        addOns = snapshotOptions?.addOns.map {
            NativeEstimatePDFAddOn(label: $0.label, description: $0.description ?? "", amount: $0.amount)
        } ?? []
        currency = review.snapshot.currency
        validUntil = review.snapshot.validUntil

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        issueDate = formatter.string(from: issuedAt)
    }

    var filename: String {
        let job = Self.filenameComponent(jobTitle)
        let customer = Self.filenameComponent(customerName)
        let suffix = [job, customer].filter { !$0.isEmpty }.joined(separator: "-")
        return suffix.isEmpty ? "Estimate.pdf" : "Estimate-\(suffix).pdf"
    }

    static func filenameComponent(_ value: String) -> String {
        var output = ""
        var needsSeparator = false
        for scalar in value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !output.isEmpty { output.append("-") }
                output.unicodeScalars.append(scalar)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
            if output.count >= 60 { break }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

enum NativeEstimatePDFError: LocalizedError {
    case renderFailed

    var errorDescription: String? {
        "The estimate PDF could not be created. Your job and estimate were not changed."
    }
}

enum NativeEstimatePDFRenderer {
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 48
    // Every color comes from the audited document palette (11.13, A30).
    private static let accent = UIColor(document: NativeAccessibilityAudit.DocumentPalette.accent)
    private static let ink = UIColor(document: NativeAccessibilityAudit.DocumentPalette.ink)
    private static let secondary = UIColor(document: NativeAccessibilityAudit.DocumentPalette.secondary)
    private static let rule = UIColor(document: NativeAccessibilityAudit.DocumentPalette.rule)
    private static let totalWash = UIColor(document: NativeAccessibilityAudit.DocumentPalette.totalWash)

    static func data(for document: NativeEstimatePDFDocument, logoReference: String?) throws -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Estimate for \(document.jobTitle)",
            kCGPDFContextCreator as String: "TradeReady"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        let logo = localImage(reference: logoReference)

        let result = renderer.pdfData { context in
            var y: CGFloat = 0
            var pageNumber = 0

            func drawFooter() {
                guard pageNumber > 0 else { return }
                let footer = "Thank you for considering \(document.businessName)  •  Page \(pageNumber)"
                _ = draw(footer, x: margin, y: page.height - 38, width: page.width - margin * 2,
                         font: .systemFont(ofSize: 9), color: secondary, alignment: .center)
            }

            func beginPage(continued: Bool = false) {
                drawFooter()
                context.beginPage()
                pageNumber += 1
                y = margin
                if continued {
                    _ = draw(
                        "\(document.businessName)  •  ESTIMATE CONTINUED",
                        x: margin,
                        y: y,
                        width: page.width - margin * 2,
                        font: .systemFont(ofSize: 11, weight: .semibold),
                        color: secondary
                    )
                    y += 28
                }
            }

            func require(_ height: CGFloat) {
                if y + height > page.height - 58 { beginPage(continued: true) }
            }

            func drawTableHeader(item: String = "ITEM", amount: String = "AMOUNT") {
                _ = draw(item, x: margin, y: y, width: 390,
                         font: .systemFont(ofSize: 10, weight: .bold), color: secondary)
                _ = draw(amount, x: 448, y: y, width: 116,
                         font: .systemFont(ofSize: 10, weight: .bold), color: secondary,
                         alignment: .right)
                y += 18
                strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: rule)
                y += 6
            }

            /// One ITEM/AMOUNT table row. A row that would cross the bottom
            /// band starts a continued page and runs `redrawHeader` first, so
            /// every page of a table carries its column header. Phase 25 adds
            /// the optional secondary `detail` line (add-on descriptions).
            func drawRow(
                _ label: String,
                detail: String = "",
                amount: String,
                redrawHeader: () -> Void
            ) {
                let height = rowHeight(label, detail: detail)
                if y + height > rowBandBottom {
                    beginPage(continued: true)
                    redrawHeader()
                }
                _ = draw(label, x: margin, y: y + 6, width: 375,
                         font: .systemFont(ofSize: 12.5), color: ink)
                if !detail.isEmpty {
                    let labelHeight = measuredHeight(label, width: 375, font: .systemFont(ofSize: 12.5))
                    _ = draw(detail, x: margin, y: y + 9 + labelHeight, width: 375,
                             font: .systemFont(ofSize: 10), color: secondary)
                }
                _ = draw(amount, x: 438, y: y + 6, width: 126,
                         font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium), color: ink,
                         alignment: .right)
                y += height
                strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: rule)
            }

            /// Keeps a heading block (of `leadHeight`) on the same page as the
            /// first row it introduces, using the same band `drawRow` checks.
            func keepWithFirstRow(leadHeight: CGFloat, firstRowHeight: CGFloat) {
                if y + leadHeight + firstRowHeight > rowBandBottom { beginPage(continued: true) }
            }

            /// Phase 25: "OPTION 2 · Better" with a text "RECOMMENDED" tag (the
            /// meaning never rides on color alone). The continued form repeats
            /// the heading on a new page so orphaned rows keep their option.
            func drawOptionHeading(_ option: NativeEstimatePDFOption, number: Int, continued: Bool) {
                let layout = optionHeadingLayout(option, number: number, continued: continued)
                _ = draw(layout.text, x: margin, y: y, width: layout.textWidth,
                         font: optionHeadingFont, color: ink)
                if option.isRecommended {
                    let tagRect = CGRect(x: page.width - margin - layout.tagWidth, y: y,
                                         width: layout.tagWidth, height: 20)
                    totalWash.setFill()
                    UIBezierPath(roundedRect: tagRect, cornerRadius: 10).fill()
                    _ = draw(recommendedTag, x: tagRect.minX, y: y + 4.5, width: layout.tagWidth,
                             font: recommendedTagFont, color: accent, alignment: .center,
                             characterSpacing: 1)
                }
                y += layout.height
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
            _ = draw("ESTIMATE", x: 400, y: y + 2, width: 164,
                     font: .systemFont(ofSize: 25, weight: .light), color: secondary,
                     alignment: .right, characterSpacing: 3)
            y += 76
            strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: accent, width: 2)
            y += 28

            _ = draw("PREPARED FOR", x: margin, y: y, width: 230,
                     font: .systemFont(ofSize: 10, weight: .bold), color: secondary,
                     characterSpacing: 1)
            _ = draw("JOB", x: 330, y: y, width: 234,
                     font: .systemFont(ofSize: 10, weight: .bold), color: secondary,
                     alignment: .right, characterSpacing: 1)
            y += 18
            _ = draw(document.customerName, x: margin, y: y, width: 240,
                     font: .systemFont(ofSize: 14, weight: .semibold), color: ink)
            _ = draw(document.jobTitle, x: 310, y: y, width: 254,
                     font: .systemFont(ofSize: 14, weight: .semibold), color: ink,
                     alignment: .right)
            y += 21
            let customerContact = [document.customerEmail, document.customerPhone, document.customerAddress]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            var contactHeight = draw(customerContact, x: margin, y: y, width: 240,
                                     font: .systemFont(ofSize: 10), color: secondary)
            if !document.serviceAddress.isEmpty {
                // Phase 21: where the work is, when it isn't the customer's address.
                let top = y + contactHeight + (contactHeight > 0 ? 8 : 0)
                let labelHeight = draw("SERVICE ADDRESS", x: margin, y: top, width: 240,
                                       font: .systemFont(ofSize: 9, weight: .bold), color: secondary,
                                       characterSpacing: 1)
                let addressHeight = draw(document.serviceAddress, x: margin, y: top + labelHeight + 2, width: 240,
                                         font: .systemFont(ofSize: 10), color: ink)
                contactHeight = top - y + labelHeight + 2 + addressHeight
            }
            // Phase 32: the "Valid until" line appears only on a dated estimate.
            let validityLine = document.validUntilDisplay.map { "\nValid until  \($0)" } ?? ""
            _ = draw("Date  \(document.issueDate)\(validityLine)\nPending approval", x: 330, y: y, width: 234,
                     font: .systemFont(ofSize: 10), color: secondary, alignment: .right)
            y += max(contactHeight, document.validUntilDisplay == nil ? 34 : 48) + 28

            if document.options.isEmpty {
                drawTableHeader()
                for item in document.lineItems {
                    drawRow(item.label, amount: money(item.amount, currency: document.currency)) {
                        drawTableHeader()
                    }
                }

                require(74)
                y += 14
                let totalRect = CGRect(x: margin, y: y, width: page.width - margin * 2, height: 56)
                totalWash.setFill()
                UIBezierPath(roundedRect: totalRect, cornerRadius: 8).fill()
                _ = draw("TOTAL ESTIMATE", x: margin + 16, y: y + 19, width: 220,
                         font: .systemFont(ofSize: 12, weight: .semibold), color: ink)
                _ = draw(money(document.total, currency: document.currency), x: 330, y: y + 13, width: 218,
                         font: .monospacedDigitSystemFont(ofSize: 22, weight: .bold), color: accent,
                         alignment: .right)
                y += 78
            } else {
                // Phase 25: one block per tier in snapshot order, replacing the
                // single table and TOTAL ESTIMATE box.
                for (index, option) in document.options.enumerated() {
                    let number = index + 1
                    let description = option.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    let descriptionHeight = description.isEmpty
                        ? 0 : measuredHeight(description, width: page.width - margin * 2,
                                             font: .systemFont(ofSize: 10.5)) + 8
                    // Heading, description, column header and the first row
                    // stay together.
                    keepWithFirstRow(
                        leadHeight: optionHeadingLayout(option, number: number, continued: false).height
                            + descriptionHeight + tableHeaderHeight,
                        firstRowHeight: option.lineItems.first.map { rowHeight($0.label) } ?? 0
                    )
                    drawOptionHeading(option, number: number, continued: false)
                    if !description.isEmpty {
                        _ = draw(description, x: margin, y: y, width: page.width - margin * 2,
                                 font: .systemFont(ofSize: 10.5), color: secondary)
                        y += descriptionHeight
                    }
                    drawTableHeader()
                    for item in option.lineItems {
                        drawRow(item.label, amount: money(item.amount, currency: document.currency)) {
                            drawOptionHeading(option, number: number, continued: true)
                            drawTableHeader()
                        }
                    }

                    require(56)
                    y += 8
                    let optionTotalRect = CGRect(x: margin, y: y, width: page.width - margin * 2, height: 40)
                    totalWash.setFill()
                    UIBezierPath(roundedRect: optionTotalRect, cornerRadius: 8).fill()
                    _ = draw("OPTION \(number) TOTAL", x: margin + 16, y: y + 13, width: 220,
                             font: .systemFont(ofSize: 11, weight: .semibold), color: ink,
                             characterSpacing: 0.5)
                    _ = draw(money(option.total, currency: document.currency), x: 330, y: y + 9, width: 218,
                             font: .monospacedDigitSystemFont(ofSize: 17, weight: .bold), color: accent,
                             alignment: .right)
                    y += 40 + 26
                }

                if let firstAddOn = document.addOns.first {
                    func drawAddOnHeader(continued: Bool) {
                        _ = draw(continued ? "OPTIONAL ADD-ONS — CONTINUED" : "OPTIONAL ADD-ONS",
                                 x: margin, y: y, width: 280,
                                 font: .systemFont(ofSize: 10, weight: .bold), color: secondary,
                                 characterSpacing: 1)
                        y += 20
                        drawTableHeader(item: "ADD-ON", amount: "PRICE")
                    }
                    keepWithFirstRow(
                        leadHeight: 20 + tableHeaderHeight,
                        firstRowHeight: rowHeight(
                            firstAddOn.label,
                            detail: firstAddOn.description.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                    drawAddOnHeader(continued: false)
                    for addOn in document.addOns {
                        drawRow(
                            addOn.label,
                            detail: addOn.description.trimmingCharacters(in: .whitespacesAndNewlines),
                            amount: "+" + money(addOn.amount, currency: document.currency)
                        ) {
                            drawAddOnHeader(continued: true)
                        }
                    }
                    y += 16
                }

                let choiceNote = document.addOns.isEmpty
                    ? "Choose one option."
                    : "Choose one option. Add-ons are optional and added to the option you choose."
                require(40)
                y += draw(choiceNote, x: margin, y: y, width: page.width - margin * 2,
                          font: .systemFont(ofSize: 10.5, weight: .medium), color: ink)
                y += 28
            }

            if !document.jobDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var remaining = document.jobDescription
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var firstScopePage = true
                while !remaining.isEmpty {
                    require(52)
                    _ = draw(firstScopePage ? "SCOPE OF WORK" : "SCOPE OF WORK — CONTINUED",
                             x: margin, y: y, width: 280,
                             font: .systemFont(ofSize: 10, weight: .bold), color: secondary,
                             characterSpacing: 1)
                    y += 18
                    let availableHeight = max(18, page.height - 58 - y)
                    let split = splitText(
                        remaining,
                        width: page.width - margin * 2,
                        maximumHeight: availableHeight,
                        font: .systemFont(ofSize: 11)
                    )
                    y += draw(split.page, x: margin, y: y,
                              width: page.width - margin * 2,
                              font: .systemFont(ofSize: 11), color: ink)
                    remaining = split.remainder
                    firstScopePage = false
                    if !remaining.isEmpty { beginPage(continued: true) }
                }
                y += 22
            }

            require(50)
            _ = draw(document.closingNote,
                     x: margin, y: y, width: page.width - margin * 2,
                     font: .systemFont(ofSize: 10.5), color: secondary)

            drawFooter()
        }
        guard result.starts(with: Data("%PDF-".utf8)) else { throw NativeEstimatePDFError.renderFailed }
        return result
    }

    /// Table rows never start below this line; the band underneath is left for
    /// the totals and the footer.
    private static var rowBandBottom: CGFloat { page.height - 100 }
    /// `drawTableHeader`'s advance: label line plus rule spacing.
    private static let tableHeaderHeight: CGFloat = 24
    private static let recommendedTag = "RECOMMENDED"
    private static var recommendedTagFont: UIFont { .systemFont(ofSize: 9, weight: .bold) }
    private static var optionHeadingFont: UIFont { .systemFont(ofSize: 14, weight: .semibold) }

    private static func rowHeight(_ label: String, detail: String = "") -> CGFloat {
        let labelHeight = measuredHeight(label, width: 375, font: .systemFont(ofSize: 12.5))
        let detailHeight = detail.isEmpty
            ? 0 : measuredHeight(detail, width: 375, font: .systemFont(ofSize: 10)) + 3
        return max(30, labelHeight + detailHeight + 14)
    }

    /// Phase 25: one source for the option heading's text and geometry, so the
    /// keep-together check and the drawing cannot disagree.
    private static func optionHeadingLayout(
        _ option: NativeEstimatePDFOption,
        number: Int,
        continued: Bool
    ) -> (text: String, textWidth: CGFloat, tagWidth: CGFloat, height: CGFloat) {
        let tagWidth = option.isRecommended
            ? ceil(NSString(string: recommendedTag)
                .size(withAttributes: [.font: recommendedTagFont, .kern: 1]).width) + 24
            : 0
        let textWidth = page.width - margin * 2 - (option.isRecommended ? tagWidth + 12 : 0)
        let text = "OPTION \(number) · \(option.name)" + (continued ? " (continued)" : "")
        let textHeight = measuredHeight(text, width: textWidth, font: optionHeadingFont)
        return (text, textWidth, tagWidth, max(textHeight, 20) + 6)
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

    private static func money(_ value: Decimal, currency: String) -> String {
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

struct NativeActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
