import SwiftUI

struct CoachMessage: Identifiable { let id = UUID(); let role: Role; let text: String; enum Role { case user, assistant } }

struct CoachView: View {
    @EnvironmentObject private var store: AppStore
    @State private var messages: [CoachMessage] = []
    @State private var input = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty {
                    VStack(spacing: 24) {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Your business coach").font(.title2.bold())
                            Text("Ask about pricing, overdue invoices, or what to focus on next.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        VStack(spacing: 10) {
                            prompt("How’s my business doing?", "chart.line.uptrend.xyaxis")
                            prompt("Who should I follow up with?", "person.crop.circle.badge.questionmark")
                            prompt("Help me price a job", "tag")
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(messages) { message in
                                HStack {
                                    if message.role == .assistant {
                                        bubble(message, color: Color(.secondarySystemBackground))
                                        Spacer(minLength: 42)
                                    } else {
                                        Spacer(minLength: 42)
                                        bubble(message, color: .tradeReady.opacity(0.18))
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) { TextField("Ask your coach", text: $input, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder); Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending) }.padding().background(.bar)
            }
            .navigationTitle("Coach")
            .toolbar { if !messages.isEmpty { Button("New chat") { messages = [] } } }
        }
    }

    private func prompt(_ text: String, _ symbol: String) -> some View { Button { input = text; send(text) } label: { Label(text, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding().background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain) }
    private func bubble(_ message: CoachMessage, color: Color) -> some View { Text(message.text).textSelection(.enabled).padding(12).background(color, in: RoundedRectangle(cornerRadius: 16)) }

    private func send(_ override: String? = nil) {
        let text = (override ?? input).trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        input = ""; messages.append(CoachMessage(role: .user, text: text)); sending = true
        Task {
            do { let reply = try await CoachService.reply(to: text, history: messages, store: store); messages.append(CoachMessage(role: .assistant, text: reply)) }
            catch { messages.append(CoachMessage(role: .assistant, text: "I couldn’t reach the coach right now. \(error.localizedDescription)")) }
            sending = false
        }
    }
}

enum CoachService {
    @MainActor
    static func reply(to text: String, history: [CoachMessage], store: AppStore) async throws -> String {
        let url = try BuildEnvironment.endpoint("api/ai-chat", sendsUserData: true)
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let outstanding = store.invoices.reduce(0) { $0 + $1.balance }
        let system = "Assistant for \(store.settings.businessName), a \(store.settings.trade) business. Labor is \(store.settings.laborRate.currency)/hr. Outstanding invoices: \(outstanding.currency). Be brief and practical."
        let body: [String: Any] = ["messages": history.map { ["role": $0.role == .user ? "user" : "assistant", "text": $0.text] }, "systemPrompt": system]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let reply = (json?["reply"] ?? json?["message"] ?? json?["content"]) as? String else { throw URLError(.cannotParseResponse) }
        return reply
    }
}
