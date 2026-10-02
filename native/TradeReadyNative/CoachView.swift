import SwiftUI

// MARK: - Coach UI and contextual prefill (task 10.13, requirements C3/C4/C5)
//
// Port of `screens/ChatScreen.tsx`. All policy lives elsewhere — 10.10's
// `NativeCoachTransport`/`NativeCoachPrompt`/`NativeChatMarkdown`/
// `NativeCoachQuickPrompts`, this task's own pure `NativeCoachTranscript`,
// and `AppStore.sendCoachMessage`/`consumePendingCoachPrefill`/
// `coachBusinessSnapshot`/`trackCoachMessageSent` — this view only renders
// and wires callbacks.
//
// Account-boundary note: this view carries NO AppStore-persisted transcript
// state. `RootView`'s top-level switch swaps `mainTabs` (which hosts this
// view) out entirely whenever `authenticationGateState` leaves `.signedIn`
// (every real sign-out/account-switch path sets it to `.signedOut` via
// `applyCompletedSignOutState`/`useAnotherAccount`/
// `applyRecoverySignedOutState`), which deallocates this view and its
// `@State` transcript along with it — the next signed-in account gets a
// freshly constructed `CoachView` with an empty transcript. No transcript
// text can leak across accounts because none of it is ever stored on
// `AppStore`.
struct CoachView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Owned by `RootView.mainTabs` so closing the sheet keeps the chat, while
    /// signing out (which tears `mainTabs` down) still drops it.
    @Binding var messages: [NativeCoachTranscriptMessage]
    @State private var input = ""
    @State private var sending = false
    /// RN's `prefillPending` ref: marks the NEXT send as insight-originated
    /// for the `ai_chat_sent` `source` property. Reset the instant a send
    /// starts, exactly like RN's `prefillPending.current = false`.
    @State private var prefillIsInsightOriginated = false
    @State private var copiedAlertText: String?
    /// Task 10.13 fix round 1: the in-flight `send()` task, so "New chat"
    /// can cancel it outright in addition to the ticket guard below —
    /// belt-and-suspenders, since a cancelled `Task` still races the ticket
    /// check on some paths (e.g. cooperative cancellation not observed
    /// until after the network call already returned).
    @State private var activeSendTask: Task<Void, Never>?

    /// Task 11.11 fix round 1: anything this screen presents over itself.
    private var isPresentingAnything: Bool { copiedAlertText != nil }

    /// ⌘N (new chat) never fires under the Copied alert.
    private var newShortcut: KeyboardShortcut? {
        isPresentingAnything ? nil : KeyboardShortcut("n", modifiers: .command)
    }

    private var quickPrompts: [NativeCoachQuickPrompt] {
        NativeCoachQuickPrompts.quickPrompts(snapshot: store.coachBusinessSnapshot())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty {
                    emptyState
                } else {
                    transcript
                }
                composer
            }
            .navigationTitle("Coach")
            .nativeKeyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { store.isCoachPresented = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    if NativeCoachTranscriptDisplay.shouldShowNewChat(messageCount: messages.count) {
                    // Task 10.13 fix round 1: cancel any in-flight send AND
                    // bump the conversation generation before clearing the
                    // transcript — a reply that resolves after this point
                    // must never append to the fresh, empty transcript.
                    Button("New chat") {
                        guard !isPresentingAnything else { return }
                        activeSendTask?.cancel()
                        activeSendTask = nil
                        store.bumpCoachConversationGeneration()
                        messages = []
                        sending = false
                    }
                    .keyboardShortcut(newShortcut)
                    }
                }
            }
            .onAppear { consumePrefillIfNeeded() }
            .onChange(of: store.pendingCoachPrefill) { _, _ in consumePrefillIfNeeded() }
            .alert("Copied", isPresented: Binding(
                get: { copiedAlertText != nil },
                set: { if !$0 { copiedAlertText = nil } }
            )) {
                Button("OK", role: .cancel) { copiedAlertText = nil }
            } message: {
                Text("Message copied to clipboard.")
            }
            // On the stack's root content, not the stack, so a pop back re-sends it.
            .nativeAnalyticsScreen(.coach)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
                    Text("AI Business Advisor").font(.title2.bold())
                    Text("Ask about your revenue, jobs, customers, or anything else about running your business.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                NativeCoachQuickPromptGrid(prompts: quickPrompts) { prompt in
                    send(override: prompt.text)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
        }
        .nativeContentColumn(.scroll)
    }

    /// RN uses an inverted `FlatList` over the reversed message array purely
    /// as a scroll-anchoring/performance trick — visually it reads exactly
    /// like a plain oldest-at-top, newest-at-bottom, auto-pinned-to-bottom
    /// chat list. This renders `messages` in that same natural chronological
    /// order and reproduces the auto-pin with `ScrollViewReader` instead.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        NativeCoachMessageBubble(message: message) { copiedText in
                            UIPasteboard.general.string = copiedText
                            copiedAlertText = copiedText
                        }
                        .id(message.id)
                    }
                    if sending {
                        NativeCoachTypingIndicator().id("typing")
                    }
                }
                .padding()
            }
            .nativeContentColumn(.scroll)
            .onChange(of: messages.count) { _, _ in scrollToLatest(proxy) }
            .onChange(of: sending) { _, _ in scrollToLatest(proxy) }
            .onAppear { scrollToLatest(proxy) }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        let target = sending ? "typing" : messages.last?.id
        guard let target else { return }
        withAnimation(NativeAccessibilityAudit.allowsCustomMotion(reduceMotion: reduceMotion) ? .default : nil) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom) {
            TextField("Ask anything...", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Chat message input")
                .onChange(of: input) { _, newValue in
                    let clamped = NativeCoachInputLimit.clamp(newValue)
                    if clamped != newValue { input = clamped }
                }
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            .accessibilityLabel("Send message")
        }
        .padding()
        .nativeContentColumnFrame()
        .background(.bar)
    }

    /// RN's prefill `useEffect`: fill the input once and clear the pending
    /// value so it can never re-fire. Called from BOTH `.onAppear` (the view
    /// mounts after `AppStore.installPendingCoachPrefill` already ran — the
    /// common "Ask coach" path, which switches tabs before this view even
    /// exists) and `.onChange(of: store.pendingCoachPrefill)` (this view is
    /// already on screen when a prefill is installed). `consumePendingCoachPrefill`
    /// is safe to call from both: it returns `nil` on the second call.
    private func consumePrefillIfNeeded() {
        guard let prompt = store.consumePendingCoachPrefill() else { return }
        input = NativeCoachInputLimit.clamp(prompt)
        prefillIsInsightOriginated = true
    }

    private func send(override: String? = nil) {
        let text = NativeCoachInputLimit.clamp((override ?? input).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, !sending else { return }

        store.trackCoachMessageSent(sourceIsInsightPrefill: prefillIsInsightOriginated)
        prefillIsInsightOriginated = false
        input = ""

        let userMessage = NativeCoachTranscriptMessage(id: UUID().uuidString, role: .user, text: text)
        var history = messages
        history.append(userMessage)
        messages = history
        sending = true

        // Task 10.13 fix round 1: capture the ticket for THIS transcript
        // before the network await, and cancel any previous in-flight send
        // (defensive — the composer/quick-prompts are disabled while
        // `sending` is true, so at most one send should ever be in flight,
        // but "New chat" can start a new one right after cancelling this
        // block's task, and a stale reference here would leak it).
        let ticket = store.coachConversationTicket()
        activeSendTask?.cancel()
        activeSendTask = Task {
            let outcome: NativeCoachTranscriptMessage
            do {
                let reply = try await store.sendCoachMessage(
                    history: history.map { NativeCoachMessage(role: $0.role == .user ? .user : .assistant, text: $0.text) }
                )
                outcome = NativeCoachTranscriptMessage(id: UUID().uuidString, role: .assistant, text: reply)
            } catch let error as NativeCoachTransportError {
                outcome = NativeCoachTranscriptMessage(
                    id: UUID().uuidString, role: .assistant,
                    text: NativeCoachErrorBubble.text(for: error), isError: true
                )
            } catch {
                outcome = NativeCoachTranscriptMessage(
                    id: UUID().uuidString, role: .assistant,
                    text: NativeCoachErrorBubble.text(forUntyped: error), isError: true
                )
            }
            // "New chat", a sign-out, or an account switch since `ticket` was
            // captured means this reply no longer belongs to the transcript
            // (or account) currently on screen — drop it instead of
            // appending it to state that has moved on.
            guard !Task.isCancelled, store.coachReplyStillValid(ticket) else { return }
            messages.append(outcome)
            sending = false
            activeSendTask = nil
        }
    }
}
