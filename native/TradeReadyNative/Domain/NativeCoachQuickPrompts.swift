import Foundation

// MARK: - Coach quick prompts (task 10.10, requirement C3)
//
// Pure port of `screens/ChatScreen.tsx#getQuickPrompts`. Always four cards;
// the last two branch on live snapshot figures so the prompt text carries the
// actual overdue total / average job value rather than a generic ask. Like
// `buildSystemPrompt`, there is no dedicated RN oracle test (the function
// lives inside the screen component) — the fixtures in `CoachQuickPromptsTests`
// were captured by running the exact function body through a scratch Node
// probe (see the 10.10 report).
//
// This module only decides which four prompts to show; 10.13 renders them.

struct NativeCoachQuickPrompt: Equatable {
    var id: String
    var icon: String
    var label: String
    var text: String
}

enum NativeCoachQuickPrompts {
    /// `getQuickPrompts(snapshot)`. `snapshot == nil` reproduces RN's
    /// `snapshot?.field || 0` fallback for every branch (the "no-snapshot
    /// fallback" the task brief calls out).
    static func quickPrompts(snapshot: NativeBusinessSnapshot?) -> [NativeCoachQuickPrompt] {
        let overdue = snapshot?.overdueCount ?? 0
        let overdueAmount = snapshot?.overdueTotal ?? 0
        let avgJob = snapshot?.avgCompletedJobValue ?? 0

        let third: NativeCoachQuickPrompt
        if overdue > 0 {
            let plural = overdue == 1 ? "" : "s"
            third = NativeCoachQuickPrompt(
                id: "overdue",
                icon: "alert-circle-outline",
                label: "Follow up on overdue",
                text: "I have \(overdue) overdue invoice\(plural) totaling $\(NativeCoachPrompt.toFixed0(overdueAmount)). " +
                    "Write a professional but firm follow-up message I can send."
            )
        } else {
            third = NativeCoachQuickPrompt(
                id: "estimate",
                icon: "document-text-outline",
                label: "Write an estimate",
                text: "Help me write a professional estimate to send to a customer."
            )
        }

        let fourth: NativeCoachQuickPrompt
        if avgJob > 0 {
            fourth = NativeCoachQuickPrompt(
                id: "profit",
                icon: "bulb-outline",
                label: "Increase job value",
                text: "My average completed job is around $\(NativeCoachPrompt.toFixed0(avgJob)). " +
                    "What are practical ways I can increase my average job value and profit margin?"
            )
        } else {
            fourth = NativeCoachQuickPrompt(
                id: "price",
                icon: "pricetag-outline",
                label: "Price a job",
                text: "I need help pricing a job. What details do you need from me?"
            )
        }

        return [
            NativeCoachQuickPrompt(
                id: "month",
                icon: "trending-up-outline",
                label: "How's my month?",
                text: "Give me a summary of how my business is performing this month — revenue, " +
                    "outstanding invoices, and any key recommendations."
            ),
            NativeCoachQuickPrompt(
                id: "unpaid",
                icon: "wallet-outline",
                label: "Who owes me?",
                text: "Who are my unpaid customers and how should I prioritize following up with them?"
            ),
            third,
            fourth,
        ]
    }
}
