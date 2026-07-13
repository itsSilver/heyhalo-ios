// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Shown when the user is signed in but their Halo account isn't active yet.
/// This is the purchase surface: subscribe to Halo Cloud with Apple In-App
/// Purchase, or — if the account was already activated on the web or with a
/// license (BYOK) — just re-check it. Buying here activates the same account the
/// Mac uses, so texting Halo unlocks everywhere.
struct InactiveAccountView: View {
    @EnvironmentObject private var account: HaloAccount
    @EnvironmentObject private var store: StoreService

    private let termsURL = URL(string: "https://heyhalo.app/terms")!
    private let privacyURL = URL(string: "https://heyhalo.app/privacy-policy")!

    var body: some View {
        ZStack {
            HaloiOSStyle.canvas

            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 32)
                    header
                    priceCard
                    actions
                    disclosure
                    legalLinks
                    Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 4)
                    if account.isDemo {
                        demoContinue
                    } else {
                        alreadyActive
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            HaloPresenceMark(isThinking: store.phase == .purchasing, diameter: 76)
            VStack(spacing: 10) {
                Text("Unlock Halo Cloud")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Text Halo from your phone and get answers from the cloud, even when your computer is asleep. Your messages still travel privately through your own iCloud.")
                    .font(HaloiOSStyle.body)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Price

    private var priceCard: some View {
        VStack(spacing: 4) {
            if let price = store.displayPrice {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(price)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(HaloiOSStyle.textPrimary)
                    if let period = store.periodLabel {
                        Text("/ \(period)")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(HaloiOSStyle.textSecondary)
                    }
                }
                Text("Halo Cloud subscription. Cancel anytime.")
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
            } else if store.phase == .loading {
                ProgressView().tint(HaloiOSStyle.accent)
            } else {
                Text(store.lastError ?? "Pricing unavailable right now.")
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await store.purchase() }
            } label: {
                Group {
                    if store.phase == .purchasing {
                        ProgressView().tint(.black)
                    } else {
                        Text("Subscribe")
                    }
                }
                .font(HaloiOSStyle.bodyEmphasis)
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(HaloiOSStyle.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(store.product == nil || store.phase != .idle)
            .opacity(store.product == nil ? 0.5 : 1)

            Button {
                Task { await store.restore() }
            } label: {
                Text(store.phase == .restoring ? "Restoring…" : "Restore purchases")
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(store.phase != .idle)

            if let error = store.lastError, store.displayPrice != nil {
                Text(error)
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.attention)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Legal (required for auto-renewable subscriptions)

    private var disclosure: some View {
        Text("Payment is charged to your Apple Account at confirmation. The subscription renews automatically unless cancelled at least 24 hours before the period ends. Manage or cancel it anytime in your Apple Account settings.")
            .font(.system(size: 11))
            .foregroundStyle(HaloiOSStyle.textSecondary.opacity(0.75))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var legalLinks: some View {
        HStack(spacing: 18) {
            Link("Terms of Use", destination: termsURL)
            Link("Privacy Policy", destination: privacyURL)
        }
        .font(.system(size: 12, weight: .medium))
        .tint(HaloiOSStyle.textSecondary)
    }

    // MARK: - Already active elsewhere

    private var alreadyActive: some View {
        VStack(spacing: 10) {
            Text(alreadyActiveCopy)
                .font(HaloiOSStyle.caption)
                .foregroundStyle(HaloiOSStyle.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await account.refreshAccount() }
            } label: {
                Text(account.busy ? "Checking…" : "Check again")
                    .font(HaloiOSStyle.caption.weight(.semibold))
                    .foregroundStyle(HaloiOSStyle.accent)
            }
            .buttonStyle(.plain)
            .disabled(account.busy)

            Button("Sign out") { account.signOut() }
                .font(HaloiOSStyle.caption)
                .foregroundStyle(HaloiOSStyle.textSecondary.opacity(0.7))
                .padding(.top, 2)
        }
    }

    // MARK: - App Review demo

    /// Shown only in the App Review demo. Lets the reviewer proceed past the
    /// purchase screen into the working demo chat to verify functionality,
    /// without buying anything.
    private var demoContinue: some View {
        VStack(spacing: 8) {
            Text("App Review demo")
                .font(HaloiOSStyle.caption)
                .foregroundStyle(HaloiOSStyle.textSecondary)
            Button {
                account.continueDemo()
            } label: {
                Text("Continue to demo chat")
                    .font(HaloiOSStyle.bodyEmphasis)
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(HaloiOSStyle.accent.opacity(0.6), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button("Sign out") { account.signOut() }
                .font(HaloiOSStyle.caption)
                .foregroundStyle(HaloiOSStyle.textSecondary.opacity(0.7))
        }
    }

    private var alreadyActiveCopy: String {
        if let email = account.account?.user.email, !email.isEmpty {
            return "Signed in as \(email). Already subscribed on the web or with a license? Check again."
        }
        return "Already subscribed on the web or with a license? Check again."
    }
}
