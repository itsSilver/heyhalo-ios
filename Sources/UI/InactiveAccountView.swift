// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Shown when the user is signed in but their Halo account isn't active yet.
/// Halo is a companion to the app on the user's own computer, so this screen
/// only *reads* whether the account is active and unlocks Reach when it is. It
/// never sells anything, names a price, or links out to a purchase — the only
/// actions are: re-check the account, or sign out.
struct InactiveAccountView: View {
    @EnvironmentObject private var account: HaloAccount

    var body: some View {
        ZStack {
            HaloiOSStyle.canvas

            VStack(spacing: 26) {
                Spacer()

                HaloPresenceMark(isThinking: false, diameter: 84)

                VStack(spacing: 10) {
                    Text("This account isn't active yet")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(HaloiOSStyle.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(bodyCopy)
                        .font(HaloiOSStyle.body)
                        .foregroundStyle(HaloiOSStyle.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)

                Button {
                    Task { await account.refreshAccount() }
                } label: {
                    Text(account.busy ? "Checking…" : "Check again")
                        .font(HaloiOSStyle.bodyEmphasis)
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(HaloiOSStyle.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(account.busy)

                Button("Sign out") { account.signOut() }
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
                    .padding(.top, 4)

                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 520)
        }
        .preferredColorScheme(.dark)
    }

    private var bodyCopy: String {
        if let email = account.account?.user.email, !email.isEmpty {
            return
                "You're signed in as \(email). Set up Halo on your computer with this same account, and texting it from here unlocks automatically."
        }
        return
            "Set up Halo on your computer with this same account, and texting it from here unlocks automatically."
    }
}
