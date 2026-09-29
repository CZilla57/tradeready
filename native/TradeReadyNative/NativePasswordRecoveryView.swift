import SwiftUI

struct NativePasswordRecoveryView: View {
    @EnvironmentObject private var store: AppStore
    let email: String?

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case password, confirmation }
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 40

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "lock.rotation")
                            .font(.system(size: iconSize, weight: .semibold))
                            .foregroundStyle(.tint)
                        Text("Choose a new password")
                            .font(.title.bold())
                        Text(email.map { "Updating the password for \($0)." }
                             ?? "Enter a new password for your account.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(Color.tradeDangerText)
                                .accessibilityIdentifier("recovery-error")
                        }

                        SecureField("New password", text: $password)
                            .textContentType(.newPassword)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .password)
                            .onSubmit { focusedField = .confirmation }
                            .accessibilityLabel("New password")
                        SecureField("Confirm new password", text: $confirmation)
                            .textContentType(.newPassword)
                            .focused($focusedField, equals: .confirmation)
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityLabel("Confirm new password")

                        Text("Use at least 8 characters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(action: submit) {
                            Group {
                                if isSubmitting { ProgressView().tint(.white) }
                                else { Text("Update Password").fontWeight(.semibold) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .tradeReadyProminentButtonStyle()
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("recovery-submit")

                        Button("Cancel and return to sign in", role: .cancel) {
                            Task { await store.cancelPasswordRecovery() }
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(isSubmitting)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(20)
                    .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.quaternary) }
                    .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
            .nativeContentColumn(.scroll)
            .background(Color.tradeCanvas)
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        errorMessage = nil
        guard password.count >= 8 else {
            errorMessage = NativePasswordRecoveryError.passwordTooShort.localizedDescription
            return
        }
        guard password == confirmation else {
            errorMessage = "Passwords do not match."
            return
        }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await store.updateRecoveredPassword(password)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Password update failed. Please try again."
            }
        }
    }
}
