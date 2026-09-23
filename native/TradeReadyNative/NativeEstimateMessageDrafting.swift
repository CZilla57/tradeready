import Foundation

enum NativeEstimateMessageChannel: String, CaseIterable, Identifiable, Sendable {
    case email
    case text

    var id: String { rawValue }
    var title: String { self == .email ? "Email" : "Text" }
}

struct NativeEstimatePreparedMessage: Equatable, Sendable {
    let subject: String
    let body: String

    func clipboardText(channel: NativeEstimateMessageChannel) -> String {
        channel == .email && !subject.isEmpty
            ? "Subject: \(subject)\n\n\(body)"
            : body
    }
}

enum NativeEstimateMessageDrafting {
    static func prepare(
        review: NativeEstimateReviewDraft,
        channel: NativeEstimateMessageChannel,
        approvalLink: URL? = nil
    ) -> NativeEstimatePreparedMessage {
        let amount: (Decimal) -> String = {
            NSDecimalNumber(decimal: $0).doubleValue.currency
        }
        if channel == .text {
            var parts = [
                "Hi \(review.snapshot.customerName), \(review.snapshot.businessName) here.",
                "Estimate for \"\(review.snapshot.jobTitle)\":"
            ]
            parts.append(contentsOf: review.snapshot.lineItems
                .filter { $0.label != "Overhead & operating costs" }
                .map { "\($0.label): \(amount($0.amount))" })
            parts.append("Total: \(amount(review.snapshot.total)).")
            let contact = if let approvalLink {
                "View & approve: \(approvalLink.absoluteString)"
            } else if review.businessPhone.isEmpty {
                "Reply YES to approve."
            } else {
                "Reply YES to approve or call \(review.businessPhone)."
            }
            parts.append(contact)
            return .init(subject: "", body: parts.joined(separator: " "))
        }

        var lines = [
            "Hi \(review.snapshot.customerName),",
            "",
            "Thank you for reaching out. Here's your estimate for \(review.snapshot.jobTitle):",
            ""
        ]
        lines.append(contentsOf: review.snapshot.lineItems.map {
            "  \($0.label)  \(amount($0.amount))"
        })
        lines.append("  ────────────────────────────────────")
        lines.append("  TOTAL ESTIMATE  \(amount(review.snapshot.total))")
        if !review.jobDescription.isEmpty {
            lines.append(contentsOf: ["", review.jobDescription])
        }
        lines.append(contentsOf: [
            "",
            "To approve this estimate, simply reply to this email or give me a call.",
            "I can typically schedule work within a few business days of approval."
        ])
        if let approvalLink {
            lines.append(contentsOf: [
                "",
                "View and approve your estimate here:\n\(approvalLink.absoluteString)"
            ])
        }
        lines.append(contentsOf: [
            "",
            "Best regards,",
            review.businessContactName,
            review.snapshot.businessName,
            review.businessPhone
        ])
        return .init(
            subject: "Estimate for \(review.snapshot.jobTitle) – \(review.snapshot.businessName)",
            body: lines.joined(separator: "\n")
        )
    }
}
