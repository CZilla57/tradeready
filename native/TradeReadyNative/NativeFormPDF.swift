import Foundation

// MARK: - Phase 20: job form PDF report (spec §5)
//
// Same structure as the estimate and invoice PDFs: an immutable, host-tested
// document model built from the canonical form, then a `UIGraphicsPDFRenderer`
// renderer (iOS only). The model resolves every photo id against the job's
// photos, so the renderer only draws.

/// A result badge, always drawn as text (never color alone).
enum NativeFormPDFBadge: String, Equatable, Sendable {
    case pass
    case fail
    case na
    case checked
    case notChecked
    case noResult

    var label: String {
        switch self {
        case .pass: "PASS"
        case .fail: "FAIL"
        case .na: "N/A"
        case .checked: "CHECKED"
        case .notChecked: "NOT CHECKED"
        case .noResult: "NO RESULT"
        }
    }

    /// The badge's color pair in `DocumentPalette`.
    enum Tone: Equatable, Sendable { case success, danger, neutral }

    var tone: Tone {
        switch self {
        case .pass, .checked: .success
        case .fail: .danger
        case .na, .notChecked, .noResult: .neutral
        }
    }
}

/// One photo under an item. `isAvailable` is false when this device has the
/// photo's record but not its bytes: the renderer draws a placeholder.
struct NativeFormPDFPhoto: Equatable, Sendable {
    let id: String
    let isAvailable: Bool
}

struct NativeFormPDFRow: Equatable, Sendable {
    let itemID: String
    let label: String
    /// Check and pass/fail items; nil for a text item.
    let badge: NativeFormPDFBadge?
    /// A text item's answer ("No answer" when blank); empty for the others.
    let answer: String
    let isAnswered: Bool
    /// Empty when the item has no note.
    let note: String
    let photos: [NativeFormPDFPhoto]
}

struct NativeFormPDFSection: Equatable, Sendable {
    /// Empty for the items before the form's first section heading.
    let title: String
    let rows: [NativeFormPDFRow]
}

struct NativeFormPDFDocument: Equatable, Sendable {
    static let unansweredText = "No answer"
    static let photoUnavailableText = "Photo not available on this device"

    let businessName: String
    let businessContactName: String
    let businessPhone: String
    let businessEmail: String
    let businessAddress: String
    let jobTitle: String
    let customerName: String
    let jobAddress: String
    let formTitle: String
    /// "Completed Oct 3, 2026" or "In progress".
    let statusText: String
    /// "7 of 12 answered".
    let progressText: String
    let sections: [NativeFormPDFSection]

    /// Built from the stored form and the job's photo records. A photo id
    /// that no longer resolves to one of `jobPhotos` is left out; one whose
    /// bytes are not in `availablePhotoIDs` renders as a placeholder. Items
    /// of a kind this version does not know are left out, as are section
    /// headings with no item under them.
    init(
        form: Canonical.Form,
        jobTitle: String,
        customerName: String,
        jobAddress: String,
        businessName: String,
        businessContactName: String,
        businessPhone: String,
        businessEmail: String,
        businessAddress: String,
        jobPhotos: [Canonical.JobPhoto],
        availablePhotoIDs: Set<String>,
        calendar: Calendar = .current
    ) {
        self.businessName = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.businessContactName = businessContactName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.businessPhone = businessPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        self.businessEmail = businessEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.businessAddress = businessAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.jobTitle = jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.customerName = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.jobAddress = jobAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        formTitle = form.title
        statusText = NativeJobFormsPresentation.statusText(form, calendar: calendar)
        progressText = NativeJobFormsPresentation.progressText(NativeJobForms.progress(form))

        let existing = Set(jobPhotos.filter { form.jobId == nil || $0.jobId == form.jobId }.map(\.id))
        sections = NativeJobFormsPresentation.itemGroups(form).compactMap { group in
            let rows = group.items.compactMap { Self.row($0, existing: existing, available: availablePhotoIDs) }
            guard !rows.isEmpty else { return nil }
            return NativeFormPDFSection(title: group.title ?? "", rows: rows)
        }
    }

    /// Every photo the renderer draws, in document order.
    var photoIDs: [String] {
        sections.flatMap { $0.rows.flatMap { $0.photos.map(\.id) } }
    }

    /// "Form-<form title>-<customer>.pdf", ASCII letters and digits only.
    var filename: String {
        let suffix = [Self.filenameComponent(formTitle), Self.filenameComponent(customerName)]
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return suffix.isEmpty ? "Form.pdf" : "Form-\(suffix).pdf"
    }

    static func filenameComponent(_ value: String) -> String {
        var output = ""
        var needsSeparator = false
        for scalar in value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
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

    private static func row(
        _ item: Canonical.FormItem,
        existing: Set<String>,
        available: Set<String>
    ) -> NativeFormPDFRow? {
        guard let kind = item.itemKind, kind.isAnswerable else { return nil }
        let badge: NativeFormPDFBadge?
        var answer = ""
        switch kind {
        case .check:
            badge = item.checked == true ? .checked : .notChecked
        case .passFail:
            switch item.passFailResult {
            case .pass: badge = .pass
            case .fail: badge = .fail
            case .na: badge = .na
            case nil: badge = .noResult
            }
        case .text:
            badge = nil
            let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            answer = text.isEmpty ? unansweredText : text
        case .section:
            return nil
        }
        var seen = Set<String>()
        let photos = NativeJobForms.resolvedPhotoIDs(item, existingPhotoIDs: existing)
            .filter { seen.insert($0).inserted }
            .map { NativeFormPDFPhoto(id: $0, isAvailable: available.contains($0)) }
        return NativeFormPDFRow(
            itemID: item.id,
            label: item.label,
            badge: badge,
            answer: answer,
            isAnswered: NativeJobForms.isAnswered(item),
            note: (item.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            photos: photos
        )
    }
}

#if canImport(UIKit)
import ImageIO
import UIKit

enum NativeFormPDFError: LocalizedError {
    case renderFailed

    var errorDescription: String? {
        "The form PDF could not be created. Your form was not changed."
    }
}

enum NativeFormPDFRenderer {
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 48
    private static var contentWidth: CGFloat { page.width - margin * 2 }
    /// Nothing starts below this line; the band underneath holds the footer.
    private static var bottomLimit: CGFloat { page.height - 64 }
    // Every color comes from the audited document palette (11.13, A30).
    private static let accent = UIColor(document: NativeAccessibilityAudit.DocumentPalette.accent)
    private static let ink = UIColor(document: NativeAccessibilityAudit.DocumentPalette.ink)
    private static let secondary = UIColor(document: NativeAccessibilityAudit.DocumentPalette.secondary)
    private static let rule = UIColor(document: NativeAccessibilityAudit.DocumentPalette.rule)
    private static let totalWash = UIColor(document: NativeAccessibilityAudit.DocumentPalette.totalWash)

    /// Photos: up to four per row. Each is downscaled to fit 160 pt (at 2×)
    /// and JPEG-recompressed before drawing (spec §5).
    private static let photosPerRow = 4
    private static let photoGap: CGFloat = 10
    private static var photoCell: CGFloat { (contentWidth - photoGap * CGFloat(photosPerRow - 1)) / CGFloat(photosPerRow) }
    private static let photoFitPoints: CGFloat = 160
    private static let photoJPEGQuality: CGFloat = 0.7

    private static let badgeFont = UIFont.systemFont(ofSize: 9, weight: .bold)
    private static let labelFont = UIFont.systemFont(ofSize: 12)
    private static let answerFont = UIFont.systemFont(ofSize: 11)
    private static let noteFont = UIFont.systemFont(ofSize: 10)

    /// `photoData` holds the bytes of the available photos by id; a photo
    /// whose bytes are missing or unreadable draws the placeholder.
    static func data(
        for document: NativeFormPDFDocument,
        logoReference: String?,
        photoData: [String: Data]
    ) throws -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: document.formTitle,
            kCGPDFContextCreator as String: "TradeReady"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        let logo = localImage(reference: logoReference)

        let result = renderer.pdfData { context in
            var y: CGFloat = 0
            var pageNumber = 0

            func drawFooter() {
                guard pageNumber > 0 else { return }
                let parts = [document.businessName, document.formTitle, "Page \(pageNumber)"].filter { !$0.isEmpty }
                _ = draw(parts.joined(separator: "  •  "), x: margin, y: page.height - 38, width: contentWidth,
                         font: .systemFont(ofSize: 9), color: secondary, alignment: .center)
            }

            func beginPage(continued: Bool) {
                drawFooter()
                context.beginPage()
                pageNumber += 1
                y = margin
                if continued {
                    _ = draw("\(document.formTitle)  •  CONTINUED", x: margin, y: y, width: contentWidth,
                             font: .systemFont(ofSize: 11, weight: .semibold), color: secondary)
                    y += 26
                }
            }

            func require(_ height: CGFloat) {
                if y + height > bottomLimit { beginPage(continued: true) }
            }

            /// Wrapped text that may run onto following pages.
            func drawFlowing(_ text: String, x: CGFloat, width: CGFloat, font: UIFont, color: UIColor) {
                var remaining = text
                while !remaining.isEmpty {
                    let lineHeight = ceil(font.lineHeight)
                    require(lineHeight)
                    let split = splitText(remaining, width: width, maximumHeight: max(lineHeight, bottomLimit - y), font: font)
                    y += draw(split.page, x: x, y: y, width: width, font: font, color: color)
                    remaining = split.remainder
                    if !remaining.isEmpty { beginPage(continued: true) }
                }
            }

            beginPage(continued: false)

            // Header: logo, business name and contact, then the report label.
            if let logo {
                logo.draw(in: aspectFit(image: logo, inside: CGRect(x: margin, y: y, width: 118, height: 50)))
            }
            let businessX = logo == nil ? margin : margin + 132
            _ = draw(document.businessName, x: businessX, y: y, width: 270,
                     font: .systemFont(ofSize: 21, weight: .bold), color: accent)
            let businessContact = [document.businessContactName, document.businessPhone, document.businessEmail]
                .filter { !$0.isEmpty }
                .joined(separator: "  •  ")
            if !businessContact.isEmpty {
                _ = draw(businessContact, x: businessX, y: y + 29, width: 300,
                         font: .systemFont(ofSize: 9.5), color: secondary)
            }
            if !document.businessAddress.isEmpty {
                _ = draw(document.businessAddress, x: businessX, y: y + 44, width: 300,
                         font: .systemFont(ofSize: 9.5), color: secondary)
            }
            _ = draw("REPORT", x: 400, y: y + 2, width: 164,
                     font: .systemFont(ofSize: 25, weight: .light), color: secondary,
                     alignment: .right, characterSpacing: 3)
            y += 76
            strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: accent, width: 2)
            y += 24

            // Job (left) and form (right).
            let columnWidth = (contentWidth - 24) / 2
            let rightX = margin + columnWidth + 24
            _ = draw("JOB", x: margin, y: y, width: columnWidth,
                     font: .systemFont(ofSize: 10, weight: .bold), color: secondary, characterSpacing: 1)
            _ = draw("FORM", x: rightX, y: y, width: columnWidth,
                     font: .systemFont(ofSize: 10, weight: .bold), color: secondary,
                     alignment: .right, characterSpacing: 1)
            y += 18
            var left = draw(document.jobTitle, x: margin, y: y, width: columnWidth,
                            font: .systemFont(ofSize: 14, weight: .semibold), color: ink)
            var right = draw(document.formTitle, x: rightX, y: y, width: columnWidth,
                             font: .systemFont(ofSize: 14, weight: .semibold), color: ink, alignment: .right)
            let jobLines = [document.customerName, document.jobAddress].filter { !$0.isEmpty }.joined(separator: "\n")
            left += 4 + draw(jobLines, x: margin, y: y + left + 4, width: columnWidth,
                             font: .systemFont(ofSize: 10), color: secondary)
            right += 4 + draw("\(document.statusText)\n\(document.progressText)", x: rightX, y: y + right + 4,
                              width: columnWidth, font: .systemFont(ofSize: 10), color: secondary, alignment: .right)
            y += max(left, right) + 26

            for section in document.sections {
                // A heading never sits alone at the foot of a page.
                let headingHeight: CGFloat = section.title.isEmpty ? 0 : 28
                require(headingHeight + headerHeight(section.rows.first))
                if !section.title.isEmpty {
                    _ = draw(section.title.uppercased(), x: margin, y: y, width: contentWidth,
                             font: .systemFont(ofSize: 10.5, weight: .bold), color: secondary, characterSpacing: 1)
                    y += 17
                    strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: rule)
                    y += 11
                }
                for row in section.rows {
                    require(headerHeight(row))
                    let badgeWidth = row.badge.map(badgeSize) ?? 0
                    let labelWidth = contentWidth - (badgeWidth > 0 ? badgeWidth + 12 : 0)
                    let labelHeight = draw(row.label, x: margin, y: y, width: labelWidth, font: labelFont, color: ink)
                    if let badge = row.badge { drawBadge(badge, rightEdge: page.width - margin, y: y) }
                    y += max(labelHeight, row.badge == nil ? 0 : 18) + 4
                    if !row.answer.isEmpty {
                        drawFlowing(row.answer, x: margin + 10, width: contentWidth - 10, font: answerFont,
                                    color: row.isAnswered ? ink : secondary)
                        y += 3
                    }
                    if !row.note.isEmpty {
                        drawFlowing("Note: \(row.note)", x: margin + 10, width: contentWidth - 10, font: noteFont, color: secondary)
                        y += 3
                    }
                    if !row.photos.isEmpty {
                        y += 4
                        for start in stride(from: 0, to: row.photos.count, by: photosPerRow) {
                            require(photoCell)
                            for (offset, photo) in row.photos[start ..< min(start + photosPerRow, row.photos.count)].enumerated() {
                                let rect = CGRect(x: margin + CGFloat(offset) * (photoCell + photoGap), y: y,
                                                  width: photoCell, height: photoCell)
                                drawPhoto(photo, data: photoData[photo.id], in: rect)
                            }
                            y += photoCell + photoGap
                        }
                    }
                    y += 8
                    strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: page.width - margin, y: y), color: rule)
                    y += 10
                }
                y += 10
            }

            drawFooter()
        }
        guard result.starts(with: Data("%PDF-".utf8)) else { throw NativeFormPDFError.renderFailed }
        return result
    }

    /// The label line (and badge) of a row: kept off the foot of a page.
    private static func headerHeight(_ row: NativeFormPDFRow?) -> CGFloat {
        guard let row else { return 0 }
        let badgeWidth = row.badge.map(badgeSize) ?? 0
        let width = contentWidth - (badgeWidth > 0 ? badgeWidth + 12 : 0)
        return max(measuredHeight(row.label, width: width, font: labelFont), 18) + 22
    }

    private static func badgeSize(_ badge: NativeFormPDFBadge) -> CGFloat {
        ceil(NSString(string: badge.label).size(withAttributes: [.font: badgeFont, .kern: 0.5]).width) + 20
    }

    private static func drawBadge(_ badge: NativeFormPDFBadge, rightEdge: CGFloat, y: CGFloat) {
        let palette = NativeAccessibilityAudit.DocumentPalette.self
        let (fill, text): (UIColor, UIColor) = switch badge.tone {
        case .success: (UIColor(document: palette.paidBadgeFill), UIColor(document: palette.paidBadgeText))
        case .danger: (UIColor(document: palette.failBadgeFill), UIColor(document: palette.failBadgeText))
        case .neutral: (UIColor(document: palette.neutralBadgeFill), UIColor(document: palette.neutralBadgeText))
        }
        let width = badgeSize(badge)
        let rect = CGRect(x: rightEdge - width, y: y, width: width, height: 18)
        fill.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 9).fill()
        _ = draw(badge.label, x: rect.minX, y: y + 3.5, width: width, font: badgeFont, color: text,
                 alignment: .center, characterSpacing: 0.5)
    }

    private static func drawPhoto(_ photo: NativeFormPDFPhoto, data: Data?, in rect: CGRect) {
        let frame = UIBezierPath(roundedRect: rect, cornerRadius: 6)
        if photo.isAvailable, let data, let image = downscaledPhoto(data) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.saveGState()
            frame.addClip()
            totalWash.setFill()
            frame.fill()
            image.draw(in: aspectFit(image: image, inside: rect))
            context.restoreGState()
            rule.setStroke()
            frame.lineWidth = 0.75
            frame.stroke()
        } else {
            totalWash.setFill()
            frame.fill()
            rule.setStroke()
            frame.lineWidth = 0.75
            frame.stroke()
            let font = UIFont.systemFont(ofSize: 8.5)
            let text = NativeFormPDFDocument.photoUnavailableText
            let height = measuredHeight(text, width: rect.width - 16, font: font)
            _ = draw(text, x: rect.minX + 8, y: rect.midY - height / 2, width: rect.width - 16,
                     font: font, color: secondary, alignment: .center)
        }
    }

    /// Decodes straight to a thumbnail (no full-size decode), then recompresses
    /// it as JPEG so the PDF stays small.
    static func downscaledPhoto(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(photoFitPoints * 2)
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail, scale: 2, orientation: .up)
        guard let jpeg = image.jpegData(compressionQuality: photoJPEGQuality),
              let recompressed = UIImage(data: jpeg, scale: 2)
        else { return image }
        return recompressed
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
        return CGRect(x: bounds.minX + (bounds.width - size.width) / 2, y: bounds.minY + (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
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

    /// The words of `text` that fit `maximumHeight`, and the rest. A single
    /// word wider than a line is split by character. Line breaks are kept.
    private static func splitText(
        _ text: String,
        width: CGFloat,
        maximumHeight: CGFloat,
        font: UIFont
    ) -> (page: String, remainder: String) {
        if measuredHeight(text, width: width, font: font) <= maximumHeight { return (text, "") }
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
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
            let rest = words.dropFirst(accepted.count).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (accepted.joined(separator: " "), rest)
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
        let rest = ([remainderOfFirst] + Array(words.dropFirst()))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (fitted, rest)
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
#endif
