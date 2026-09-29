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

    /// Truncates to `maxLength` Swift grapheme clusters (`String.count`) the
    /// same way RN's `TextInput` clamps keystrokes past its `maxLength` prop
    /// — never throws, never rejects, just clips. RN's `maxLength` actually
    /// counts UTF-16 code units, not grapheme clusters; no RN oracle test
    /// pins this exact limit, so the small divergence for multi-code-unit
    /// characters (emoji, some CJK) is accepted rather than hand-rolling
    /// UTF-16 counting for an untested edge (task 10.13 report, deviation 4).
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

/// Task 10.13 fix round 1: identifies ONE in-flight coach send so a reply
/// that resolves after the transcript it was sent for is no longer current
/// — "New chat" was tapped, the user signed out, or the user switched
/// accounts — can be detected and dropped instead of landing in a
/// transcript (or an account) it no longer belongs to. Two independent
/// signals, both must still match:
///   - `generation`: bumped by `AppStore.bumpCoachConversationGeneration()`,
///     called on every "New chat" tap AND at every real account boundary
///     (`resetTodayOwnerState()`); a stale ticket from before either bump
///     can never match again.
///   - `ownerBinding`: the verified account binding at send time; a
///     sign-out (`nil`) or a switch to a different account (a different
///     hex string) invalidates the ticket even if the generation counter
///     somehow didn't change.
/// This check does NOT depend on the view (`CoachView`) still being alive —
/// it is a plain value comparison `AppStore` can run at any time, so it
/// still protects correctness even if a future refactor changes how/whether
/// the view is torn down at an account boundary.
struct NativeCoachConversationTicket: Equatable {
    var generation: Int
    var ownerBinding: String?
}

enum NativeCoachConversationGuard {
    /// `true` only when neither the generation nor the owner binding moved
    /// between `sent` (captured immediately before the network call) and
    /// `current` (captured immediately after it resolves).
    static func shouldAppend(sent: NativeCoachConversationTicket, current: NativeCoachConversationTicket) -> Bool {
        sent.generation == current.generation && sent.ownerBinding == current.ownerBinding
    }
}
