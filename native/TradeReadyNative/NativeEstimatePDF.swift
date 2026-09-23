import Foundation

struct NativeEstimatePDFLineItem: Equatable, Sendable {
    let label: String
    let amount: Decimal
}

/// Immutable, customer-facing input to the PDF renderer. It is built from the
/// reviewed approval snapshot so exporting cannot observe or flatten a newer
/// canonical job while the sheet is open.
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
    let jobTitle: String
    let jobDescription: String
    let lineItems: [NativeEstimatePDFLineItem]
    let total: Decimal
    let currency: String
    let issueDate: String

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
        jobTitle = review.snapshot.jobTitle
        jobDescription = review.jobDescription
        lineItems = review.snapshot.lineItems.map {
            NativeEstimatePDFLineItem(label: $0.label, amount: $0.amount)
        }
        total = review.snapshot.total
        currency = review.snapshot.currency

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
    private static let accent = UIColor(red: 0, green: 0.478, blue: 1, alpha: 1)
    private static let ink = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    private static let secondary = UIColor(red: 0.39, green: 0.39, blue: 0.42, alpha: 1)
    private static let rule = UIColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)

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

            func drawTableHeader() {
                _ = draw("ITEM", x: margin, y: y, width: 390,
                         font: .systemFont(ofSize: 10, weight: .bold), color: secondary)
                _ = draw("AMOUNT", x: 448, y: y, width: 116,
                         font: .systemFont(ofSize: 10, weight: .bold), color: secondary,
                         alignment: .right)
                y += 18
                strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: rule)
                y += 6
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
            let contactHeight = draw(customerContact, x: margin, y: y, width: 240,
                                     font: .systemFont(ofSize: 10), color: secondary)
            _ = draw("Date  \(document.issueDate)\nPending approval", x: 330, y: y, width: 234,
                     font: .systemFont(ofSize: 10), color: secondary, alignment: .right)
            y += max(contactHeight, 34) + 28

            drawTableHeader()
            for item in document.lineItems {
                let labelHeight = measuredHeight(item.label, width: 375, font: .systemFont(ofSize: 12.5))
                let rowHeight = max(30, labelHeight + 14)
                if y + rowHeight > page.height - 100 {
                    beginPage(continued: true)
                    drawTableHeader()
                }
                _ = draw(item.label, x: margin, y: y + 6, width: 375,
                         font: .systemFont(ofSize: 12.5), color: ink)
                _ = draw(money(item.amount, currency: document.currency), x: 438, y: y + 6, width: 126,
                         font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium), color: ink,
                         alignment: .right)
                y += rowHeight
                strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: rule)
            }

            require(74)
            y += 14
            let totalRect = CGRect(x: margin, y: y, width: page.width - margin * 2, height: 56)
            UIColor(red: 0.94, green: 0.97, blue: 1, alpha: 1).setFill()
            UIBezierPath(roundedRect: totalRect, cornerRadius: 8).fill()
            _ = draw("TOTAL ESTIMATE", x: margin + 16, y: y + 19, width: 220,
                     font: .systemFont(ofSize: 12, weight: .semibold), color: ink)
            _ = draw(money(document.total, currency: document.currency), x: 330, y: y + 13, width: 218,
                     font: .monospacedDigitSystemFont(ofSize: 22, weight: .bold), color: accent,
                     alignment: .right)
            y += 78

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
            _ = draw("This estimate is valid for 30 days. Reply to approve and we'll get you scheduled.",
                     x: margin, y: y, width: page.width - margin * 2,
                     font: .systemFont(ofSize: 10.5), color: secondary)

            drawFooter()
        }
        guard result.starts(with: Data("%PDF-".utf8)) else { throw NativeEstimatePDFError.renderFailed }
        return result
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
