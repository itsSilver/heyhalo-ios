// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The sign-in gate. Mirrors the web: continue with GitHub, or get a magic link
/// by email. Login proves the Halo account is active; it never carries chat —
/// messages still ride your own iCloud to your computer, and are answered
/// privately there.
struct LoginView: View {
    @EnvironmentObject private var account: HaloAccount
    @State private var email = ""
    @FocusState private var emailFocused: Bool

    var body: some View {
        ZStack {
            HaloiOSStyle.canvas

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    header
                    Spacer(minLength: 40)
                    actions
                    Spacer(minLength: 24)
                    footer
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 26)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header (mark + copy)

    private var header: some View {
        VStack(spacing: 20) {
            HaloPresenceMark(isThinking: account.busy, diameter: 84)

            VStack(spacing: 12) {
                Text("Halo")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(HaloiOSStyle.textPrimary)

                Text("Sign in to text Halo from your phone.")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                    .multilineTextAlignment(.center)

                Text(
                    "Your messages are secured end-to-end through your own iCloud and answered privately on your computer. Nothing you send is ever stored on Halo's servers."
                )
                .font(.system(size: 15))
                .foregroundStyle(HaloiOSStyle.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions (GitHub + magic link)

    private var actions: some View {
        VStack(spacing: 16) {
            githubButton
            dividerOr
            magicLink

            if let error = account.lastError {
                Text(error)
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.attention)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
    }

    private var githubButton: some View {
        Button {
            Task { await account.signInWithGitHub() }
        } label: {
            HStack(spacing: 10) {
                if account.busy {
                    ProgressView().tint(.black)
                } else {
                    Image("GitHubMark")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                Text("Continue with GitHub")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(HaloiOSStyle.accent)
            )
            .shadow(color: HaloiOSStyle.accent.opacity(0.28), radius: 14, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(account.busy)
        .opacity(account.busy ? 0.7 : 1)
    }

    private var dividerOr: some View {
        HStack(spacing: 14) {
            line
            Text("or")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HaloiOSStyle.textSecondary.opacity(0.8))
            line
        }
        .padding(.vertical, 2)
    }

    private var line: some View {
        Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
    }

    @ViewBuilder
    private var magicLink: some View {
        if let sentTo = account.magicLinkSentTo {
            VStack(spacing: 8) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 24))
                    .foregroundStyle(HaloiOSStyle.accent)
                Text("Check your inbox")
                    .font(HaloiOSStyle.bodyEmphasis)
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                Text("We sent a sign-in link to \(sentTo). Tap it to come back signed in.")
                    .font(HaloiOSStyle.body)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )
            )
            .transition(.opacity)
        } else {
            VStack(spacing: 12) {
                emailField
                Button(action: sendLink) {
                    Text("Email me a sign-in link")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSendLink ? HaloiOSStyle.accent : HaloiOSStyle.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(
                                    canSendLink ? HaloiOSStyle.confirmStroke : Color.white.opacity(0.1),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSendLink)
            }
        }
    }

    private var emailField: some View {
        HStack(spacing: 11) {
            Image(systemName: "envelope")
                .font(.system(size: 16))
                .foregroundStyle(HaloiOSStyle.textSecondary)
            ZStack(alignment: .leading) {
                if email.isEmpty {
                    // Custom placeholder so it's a quiet grey — not the tinted
                    // blue the default placeholder picked up.
                    Text("you@example.com")
                        .foregroundStyle(HaloiOSStyle.textSecondary.opacity(0.55))
                }
                TextField("", text: $email)
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                    .tint(HaloiOSStyle.accent)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .focused($emailFocused)
                    .submitLabel(.go)
                    .onSubmit(sendLink)
            }
        }
        .font(HaloiOSStyle.body)
        .padding(.horizontal, 15)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(emailFocused ? HaloiOSStyle.confirmStroke : Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
            Text("Private by design. Secured by your iCloud.")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(HaloiOSStyle.textSecondary.opacity(0.6))
    }

    private var canSendLink: Bool {
        !account.busy && email.contains("@")
    }

    private func sendLink() {
        guard canSendLink else { return }
        emailFocused = false
        Task { await account.sendMagicLink(email: email) }
    }
}
