import SwiftUI

// MARK: - Coach UI components (task 10.13, requirements C3/C4)
//
// Presentation only: `NativeCoachView` supplies the data (quick prompts from
// 10.10's `NativeCoachQuickPrompts`, transcript messages from
// `NativeCoachTranscript`) and the callbacks; nothing here decides which
// prompts to show, formats a reply, or picks an error copy — that policy
// lives in `NativeCoachQuickPrompts` (10.10), `NativeChatMarkdown` (10.10),
// and `NativeCoachTranscript` (10.13's own pure module).

/// RN's `EmptyState`'s `quickGrid` — one full-width card per
/// `NativeCoachQuickPrompt`, tapping sends its `.text` untouched.
struct NativeCoachQuickPromptGrid: View {
    let prompts: [NativeCoachQuickPrompt]
    let onSelect: (NativeCoachQuickPrompt) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(prompts, id: \.id) { prompt in
                Button {
                    onSelect(prompt)
                } label: {
                    Label(prompt.label, systemImage: Self.symbol(for: prompt.icon))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("coach-quick-prompt-\(prompt.id)")
            }
        }
    }

    /// `NativeCoachQuickPrompt.icon` carries RN's Ionicons name
    /// (`"trending-up-outline"`, etc.); SF Symbols has no matching catalog,
    /// so each is mapped to the closest SF Symbol one time here rather than
    /// leaving the raw Ionicons string to leak into a `Label` and render
    /// nothing.
    static func symbol(for ionicon: String) -> String {
        switch ionicon {
        case "trending-up-outline": return "chart.line.uptrend.xyaxis"
        case "wallet-outline": return "wallet.pass"
        case "alert-circle-outline": return "exclamationmark.circle"
        case "document-text-outline": return "doc.text"
        case "bulb-outline": return "lightbulb"
        case "pricetag-outline": return "tag"
        default:
            // Task 10.13 fix round 1: an unmapped icon silently fell back to
            // "sparkles" for every caller, including a future
            // `NativeCoachQuickPrompts` icon this map was never updated for
            // — fail loudly in DEBUG (caught by host tests / development
            // builds) while keeping the graceful fallback in release so a
            // shipped app never renders nothing.
            assertionFailure("NativeCoachQuickPromptGrid.symbol(for:) has no SF Symbol mapping for Ionicons icon \"\(ionicon)\" — add one.")
            return "sparkles"
        }
    }
}

/// RN's `Bubble`. Long-press copies `NativeCoachTranscriptDisplay.displayText`
/// (the already-formatted text, matching RN's `Clipboard.setStringAsync(displayText)`
/// call on the SAME transformed string the bubble shows).
struct NativeCoachMessageBubble: View {
    let message: NativeCoachTranscriptMessage
    let onCopy: (String) -> Void

    private var isUser: Bool { message.role == .user }
    private var displayText: String { NativeCoachTranscriptDisplay.displayText(for: message) }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 42) }
            Text(displayText)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(message.isError ? Color.tradeDangerText.opacity(0.5) : .clear)
                )
                .onLongPressGesture(minimumDuration: 0.3) { onCopy(displayText) }
                .accessibilityLabel(displayText)
                .accessibilityHint("Long press to copy this message")
            if !isUser { Spacer(minLength: 42) }
        }
    }

    private var bubbleColor: Color {
        if message.isError { return Color.tradeDangerText.opacity(0.12) }
        return isUser ? Color.tradeReady.opacity(0.18) : Color(.secondarySystemBackground)
    }
}

/// RN's `ListFooterComponent` typing indicator — an `ActivityIndicator`
/// inside an AI-side bubble shell while `sending` is true.
struct NativeCoachTypingIndicator: View {
    var body: some View {
        HStack {
            ProgressView()
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            Spacer(minLength: 42)
        }
        .accessibilityLabel("Coach is typing")
    }
}
