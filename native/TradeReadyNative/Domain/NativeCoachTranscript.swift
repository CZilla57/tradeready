import Foundation

// MARK: - Coach transcript, input-limit, and error-bubble policy (task 10.13,
// requirements C3/C4/C5).
//
// Pure port of the transcript-shaping pieces of `screens/ChatScreen.tsx` that
// are policy, not layout: the local message shape, the `maxLength={2000}`
// input guard, the `Something went wrong: <message>` error-bubble copy, and
// the "AI reply gets `formatChatText`, the user's own words stay verbatim"
// display-text rule from `Bubble`. `N/CoachView.swift` and
// `N/NativeCoachComponents.swift` render these; no branch logic lives there.

/// RN's `LocalMessage` (`screens/ChatScreen.tsx`). `id` is a plain string so
/// the view can seed it however it likes (RN uses `Date.now()`-derived ids);
/// `isError` marks the distinct error-bubble style.
struct NativeCoachTranscriptMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }

    var id: String
    var role: Role
    var text: String
    var isError: Bool = false
}

/// RN's `TextInput maxLength={2000}` on the composer — the only input-length
/// guard `ChatScreen.tsx` enforces; the `600`-token cap on the reply is
/// already enforced by `NativeCoachTransport.maxTokens` (task 10.10) and is
/// not re-enforced here.
enum NativeCoachInputLimit {
    static let maxLength = 2000

    /// Truncates to `maxLength` UTF-16 code units the same way RN's
    /// `TextInput` clamps keystrokes past its `maxLength` prop — never
    /// throws, never rejects, just clips.
    static func clamp(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength))
    }
}

/// RN's catch block: ``reportError(err, { context: 'aiChat' }); const msg =
/// (err as Error).message || ""; `Something went wrong: ${msg}`` — this port
/// renders the identical copy for every `NativeCoachTransportError` case
/// (`error.message` mirrors RN's `Error.message`) and for any other thrown
/// error via `localizedDescription`.
enum NativeCoachErrorBubble {
    static func text(for error: NativeCoachTransportError) -> String {
        "Something went wrong: \(error.message)"
    }

    static func text(forUntyped error: Error) -> String {
        "Something went wrong: \(error.localizedDescription)"
    }
}

/// RN's `Bubble`: `const displayText = isUser ? message.text :
/// formatChatText(message.text);` — the AI reply gets the markdown-lite pass,
/// the user's own words never do.
enum NativeCoachTranscriptDisplay {
    static func displayText(for message: NativeCoachTranscriptMessage) -> String {
        message.role == .user ? message.text : NativeChatMarkdown.formatChatText(message.text)
    }

    /// RN's `messages.length > 0` gate on the "New chat" header action.
    static func shouldShowNewChat(messageCount: Int) -> Bool {
        messageCount > 0
    }
}
