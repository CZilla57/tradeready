import Foundation

enum NativeConfirmationIntent: Equatable, Sendable {
    case deleteJob(recordID: String)
    case deleteInvoice(recordID: String)
    case deleteCustomer(recordID: String)
    case mergeCustomer(loserID: String, winnerID: String)
}

enum NativeConfirmationEmphasis: Equatable, Sendable {
    case standard
    case destructive
}

struct NativeConfirmationRequest: Equatable, Identifiable, Sendable {
    let intent: NativeConfirmationIntent
    let title: String
    let message: String
    let actionTitle: String
    let emphasis: NativeConfirmationEmphasis

    var id: String {
        switch intent {
        case .deleteJob(let recordID): "delete-job:\(recordID)"
        case .deleteInvoice(let recordID): "delete-invoice:\(recordID)"
        case .deleteCustomer(let recordID): "delete-customer:\(recordID)"
        case .mergeCustomer(let loserID, let winnerID): "merge-customer:\(loserID):\(winnerID)"
        }
    }

    static func deleteJob(id: String, title: String) -> NativeConfirmationRequest {
        .init(
            intent: .deleteJob(recordID: id),
            title: "Delete job?",
            message: "\"\(displayName(title, fallback: "This job"))\" will be removed. "
                + "You can undo for a few seconds.",
            actionTitle: "Delete job",
            emphasis: .destructive
        )
    }

    static func deleteInvoice(id: String, number: String, customer: String) -> NativeConfirmationRequest {
        let invoice = displayName(number, fallback: "This invoice")
        let owner = customer.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = owner.isEmpty ? "" : " for \(owner)"
        return .init(
            intent: .deleteInvoice(recordID: id),
            title: "Delete invoice?",
            message: "\(invoice)\(suffix) and its payment history will be removed. "
                + "You can undo for a few seconds.",
            actionTitle: "Delete invoice",
            emphasis: .destructive
        )
    }

    static func deleteCustomer(id: String, name: String) -> NativeConfirmationRequest {
        let customer = displayName(name, fallback: "This customer")
        return .init(
            intent: .deleteCustomer(recordID: id),
            title: "Delete customer?",
            message: "\(customer) will be removed. Their jobs and invoices will remain, but will no longer link to a saved customer record. "
                + "You can undo for a few seconds.",
            actionTitle: "Delete customer",
            emphasis: .destructive
        )
    }

    static func mergeCustomer(
        loserID: String,
        loserName: String,
        winnerID: String,
        winnerName: String,
        warnsAboutPortalLink: Bool
    ) -> NativeConfirmationRequest {
        let loser = displayName(loserName, fallback: "This customer")
        let winner = displayName(winnerName, fallback: "the selected customer")
        let portalWarning = warnsAboutPortalLink ? " \(loser)'s portal link will stop working." : ""
        return .init(
            intent: .mergeCustomer(loserID: loserID, winnerID: winnerID),
            title: "Merge into \(winner)?",
            message: "\(loser)'s jobs, invoices, and recurring plans will move to \(winner). "
                + "You can undo briefly after merging."
                + portalWarning,
            actionTitle: "Merge",
            emphasis: .destructive
        )
    }

    private static func displayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

#if !NATIVE_CONFIRMATION_PURE_TESTS
import SwiftUI

private struct NativeConfirmationModifier: ViewModifier {
    @Binding var request: NativeConfirmationRequest?
    let onConfirm: (NativeConfirmationIntent) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            request?.title ?? "Confirm action",
            isPresented: Binding(
                get: { request != nil },
                set: { if !$0 { request = nil } }
            ),
            titleVisibility: .visible,
            presenting: request
        ) { presented in
            Button(
                presented.actionTitle,
                role: presented.emphasis == .destructive ? .destructive : nil
            ) {
                request = nil
                onConfirm(presented.intent)
            }
            Button("Cancel", role: .cancel) { request = nil }
        } message: { presented in
            Text(presented.message)
        }
    }
}

extension View {
    func nativeConfirmation(
        _ request: Binding<NativeConfirmationRequest?>,
        onConfirm: @escaping (NativeConfirmationIntent) -> Void
    ) -> some View {
        modifier(NativeConfirmationModifier(request: request, onConfirm: onConfirm))
    }
}
#endif
