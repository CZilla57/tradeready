import SwiftUI
import AuthenticationServices
#if canImport(GoogleSignInSwift)
import GoogleSignInSwift
#endif

struct NativeAuthView: View {
    private enum Mode { case signIn, signUp, reset }
    private enum Field: Hashable { case email, password }

    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var pendingConfirmationEmail: String?
    @State private var lastEmailSentAt: Date?
    @State private var emailClock = Date()
    @State private var appleRawNonce: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("TradeReady")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Built to work. Ready to grow.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    VStack(alignment: .leading, spacing: 16) {
                        Text(title).font(.title2.bold())
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("auth-error")
                        }
                        if let noticeMessage {
                            Label(noticeMessage, systemImage: "envelope.badge.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(mode == .reset ? .go : .next)
                            .focused($focusedField, equals: .email)
                            .onSubmit(submitEmail)
                            .accessibilityLabel("Email address")

                        if mode != .reset {
                            HStack {
                                Group {
                                    if showsPassword {
                                        TextField("Password", text: $password)
                                            .focused($focusedField, equals: .password)
                                    } else {
                                        SecureField("Password", text: $password)
                                            .focused($focusedField, equals: .password)
                                    }
                                }
                                .textContentType(mode == .signUp ? .newPassword : .password)
                                .submitLabel(.go)
                                .onSubmit(submit)
                                Button(showsPassword ? "Hide" : "Show") {
                                    // Swapping the field drops focus; keep the keyboard on the password.
                                    let keepFocus = focusedField == .password
                                    showsPassword.toggle()
                                    if keepFocus { focusedField = .password }
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                        }

                        if mode == .signIn {
                            Button("Forgot password?") { switchMode(.reset) }
                                .font(.subheadline.weight(.semibold))
                        }

                        Button(action: submit) {
                            Group {
                                if isSubmitting { ProgressView().tint(.white) }
                                else { Text(submitTitle).fontWeight(.semibold) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .tradeReadyProminentButtonStyle()
                        .disabled(isSubmitting || (mode == .reset && !canSendEmail))
                        .accessibilityIdentifier("auth-submit")

                        Button(toggleTitle) {
                            switchMode(mode == .signUp ? .signIn : .signUp)
                        }
                        .frame(maxWidth: .infinity)

                        if let pendingConfirmationEmail {
                            Button("Resend confirmation email") {
                                resendConfirmation(to: pendingConfirmationEmail)
                            }
                            .frame(maxWidth: .infinity)
                                .disabled(isSubmitting || !canSendEmail)
                        }


                        if mode != .reset {
                            HStack {
                                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                                Text("or").font(.caption).foregroundStyle(.secondary)
                                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                            }

                            SignInWithAppleButton(.continue) { request in
                                prepareAppleRequest(request)
                            } onCompletion: { result in
                                completeAppleRequest(result)
                            }
                            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                            .frame(height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .disabled(isSubmitting)
                            .accessibilityIdentifier("auth-apple")

                            #if canImport(GoogleSignInSwift)
                            GoogleSignInButton(action: beginGoogleSignIn)
                                .frame(height: 48)
                                .disabled(isSubmitting)
                                .accessibilityIdentifier("auth-google")
                            #endif
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(20)
                    .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.quaternary) }
                    .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .background(Color.tradeCanvas)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    emailClock = .now
                }
            }
        }
    }

    private var title: String {
        switch mode { case .signIn: "Sign in"; case .signUp: "Create account"; case .reset: "Reset your password" }
    }

    private var submitTitle: String {
        switch mode { case .signIn: "Sign In"; case .signUp: "Create Account"; case .reset: "Send Reset Link" }
    }

    private var toggleTitle: String {
        mode == .signUp ? "Already have an account? Sign in" : "New to TradeReady? Create account"
    }

    private var canSendEmail: Bool {
        guard let lastEmailSentAt else { return true }
        return emailClock.timeIntervalSince(lastEmailSentAt) >= 60
    }

    private func switchMode(_ next: Mode) {
        mode = next
        errorMessage = nil
        noticeMessage = nil
    }

    /// The email field's return key: "Go" sends the reset link; "Next" moves
    /// to the password field (it previously did nothing).
    private func submitEmail() {
        if mode == .reset { submit() } else { focusedField = .password }
    }

    private func submit() {
        guard !isSubmitting, mode != .reset || canSendEmail else { return }
        errorMessage = nil
        noticeMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                switch mode {
                case .signIn:
                    try await store.signIn(email: email, password: password)
                case .signUp:
                    let result = try await store.signUp(email: email, password: password)
                    if case .confirmationRequired(let address) = result {
                        pendingConfirmationEmail = address
                        lastEmailSentAt = .now
                        noticeMessage = "Check your email to confirm your account, then sign in here."
                        mode = .signIn
                        password = ""
                    }
                case .reset:
                    try await store.requestPasswordReset(email: email)
                    lastEmailSentAt = .now
                    noticeMessage = "A password reset link is on its way."
                    mode = .signIn
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Something went wrong. Please try again."
            }
        }
    }

    private func resendConfirmation(to address: String) {
        guard canSendEmail, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await store.resendSignUpConfirmation(email: address)
                lastEmailSentAt = .now
                noticeMessage = "Confirmation email sent. Check your inbox and spam folder."
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Something went wrong. Please try again."
            }
        }
    }

    private func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        errorMessage = nil
        noticeMessage = nil
        do {
            let rawNonce = try NativeAppleSignInNonce.generate()
            appleRawNonce = rawNonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = NativeAppleSignInNonce.hashedValue(for: rawNonce)
        } catch {
            appleRawNonce = nil
            errorMessage = error.localizedDescription
        }
    }

    private func completeAppleRequest(
        _ result: Result<ASAuthorization, any Error>
    ) {
        guard let rawNonce = appleRawNonce else {
            if errorMessage == nil {
                errorMessage = NativeAppleSignInNonceError.unavailable.localizedDescription
            }
            return
        }
        appleRawNonce = nil
        switch result {
        case .failure(let error as ASAuthorizationError) where error.code == .canceled:
            return
        case .failure:
            errorMessage = "Sign in with Apple failed. Please try again."
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  !idToken.isEmpty
            else {
                errorMessage = "Apple did not return an identity token. Please try again."
                return
            }
            isSubmitting = true
            Task {
                defer { isSubmitting = false }
                do {
                    try await store.signInWithApple(idToken: idToken, rawNonce: rawNonce)
                } catch {
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "Sign in with Apple failed. Please try again."
                }
            }
        }
    }

    private func beginGoogleSignIn() {
        guard !isSubmitting else { return }
        errorMessage = nil
        noticeMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                let credential = try await NativeGoogleSignInProvider.signIn()
                try await store.signInWithGoogle(
                    idToken: credential.idToken,
                    rawNonce: credential.rawNonce
                )
            } catch NativeGoogleSignInError.cancelled {
                return
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Sign in with Google failed. Please try again."
            }
        }
    }
}
