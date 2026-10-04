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
    /// Phase 32 (spec 2026-10-03 §6.6): the reviewed snapshot's frozen
    /// valid-until date adds one sentence to each channel. An undated
    /// snapshot produces exactly the earlier copy.
    private static func emailValidityLine(_ snapshot: Canonical.EstimateApprovalSnapshot) -> String? {
        snapshot.validUntil.map { "This estimate is valid until \(NativeQuoteExpiry.displayDate($0, style: .long))." }
    }

    private static func textValidityPart(_ snapshot: Canonical.EstimateApprovalSnapshot) -> String? {
        snapshot.validUntil.map { "Valid until \(NativeQuoteExpiry.displayDate($0, style: .short))." }
    }

    static func prepare(
        review: NativeEstimateReviewDraft,
        channel: NativeEstimateMessageChannel,
        approvalLink: URL? = nil
    ) -> NativeEstimatePreparedMessage {
        let amount: (Decimal) -> String = {
            NSDecimalNumber(decimal: $0).doubleValue.currency
        }
        if let options = review.snapshot.options {
            return prepareOptions(
                options,
                review: review,
                channel: channel,
                approvalLink: approvalLink,
                amount: amount
            )
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
            if let validity = textValidityPart(review.snapshot) { parts.append(validity) }
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
        if let validity = emailValidityLine(review.snapshot) {
            lines.append(contentsOf: ["", validity])
        }
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

    /// Phase 25 (good/better/best): copy for an undecided options snapshot.
    /// Every tier is listed in snapshot order with the recommended one marked
    /// in words, then the add-ons, and the call to action asks for a choice
    /// rather than a yes. An accepted estimate's snapshot has no `options`, so
    /// it never reaches here and reads as the single chosen estimate.
    private static func prepareOptions(
        _ options: Canonical.EstimateApprovalSnapshot.Options,
        review: NativeEstimateReviewDraft,
        channel: NativeEstimateMessageChannel,
        approvalLink: URL?,
        amount: (Decimal) -> String
    ) -> NativeEstimatePreparedMessage {
        let recommended = { (tier: Canonical.EstimateApprovalSnapshot.OptionTier) in
            tier.id == options.recommendedTierId
        }
        if channel == .text {
            var parts = [
                "Hi \(review.snapshot.customerName), \(review.snapshot.businessName) here.",
                "Options for \"\(review.snapshot.jobTitle)\":"
            ]
            parts.append(contentsOf: options.tiers.map {
                "\($0.name): \(amount($0.total))\(recommended($0) ? " (recommended)" : "")."
            })
            parts.append(contentsOf: options.addOns.map {
                "Add-on \($0.label): +\(amount($0.amount))."
            })
            if let validity = textValidityPart(review.snapshot) { parts.append(validity) }
            let contact = if let approvalLink {
                "View your options and approve: \(approvalLink.absoluteString)"
            } else if review.businessPhone.isEmpty {
                "Reply with the option you'd like."
            } else {
                "Reply with the option you'd like or call \(review.businessPhone)."
            }
            parts.append(contact)
            return .init(subject: "", body: parts.joined(separator: " "))
        }

        var lines = [
            "Hi \(review.snapshot.customerName),",
            "",
            "Thank you for reaching out. Here are your options for \(review.snapshot.jobTitle):"
        ]
        for (index, tier) in options.tiers.enumerated() {
            lines.append("")
            lines.append("Option \(index + 1): \(tier.name)\(recommended(tier) ? " (recommended)" : "")")
            if let description = tier.description, !description.isEmpty {
                lines.append(description)
            }
            lines.append(contentsOf: tier.lineItems.map {
                "  \($0.label)  \(amount($0.amount))"
            })
            lines.append("  ────────────────────────────────────")
            lines.append("  OPTION TOTAL  \(amount(tier.total))")
        }
        if let validity = emailValidityLine(review.snapshot) {
            lines.append(contentsOf: ["", validity])
        }
        if !options.addOns.isEmpty {
            lines.append(contentsOf: ["", "Optional add-ons (added to the option you choose):"])
            for addOn in options.addOns {
                lines.append("  \(addOn.label)  +\(amount(addOn.amount))")
                if let description = addOn.description, !description.isEmpty {
                    lines.append("    \(description)")
                }
            }
        }
        if !review.jobDescription.isEmpty {
            lines.append(contentsOf: ["", review.jobDescription])
        }
        lines.append(contentsOf: [
            "",
            "Reply with the option you'd like, or give me a call.",
            "I can typically schedule work within a few business days of approval."
        ])
        if let approvalLink {
            lines.append(contentsOf: [
                "",
                "View your options and approve here:\n\(approvalLink.absoluteString)"
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
