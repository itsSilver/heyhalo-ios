// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The Account screen (a sheet from the chat). Shows who you are and your usage
/// this period, with sign-out and account deletion. All of it comes from
/// `/v1/account/me` — the same source as the Mac's account card.
struct AccountView: View {
    @EnvironmentObject private var account: HaloAccount
    @EnvironmentObject private var reach: ReachCloudKitClient
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                HaloiOSStyle.canvas

                ScrollView {
                    VStack(spacing: 18) {
                        identityCard
                        if let usage = account.account?.usage {
                            usageCard(usage)
                        }
                        accountActions
                    }
                    .padding(20)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HaloiOSStyle.accent)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .task { await account.refreshAccount() }
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HaloPresenceMark(isThinking: false, diameter: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.account?.user.email ?? "Signed in")
                        .font(HaloiOSStyle.bodyEmphasis)
                        .foregroundStyle(HaloiOSStyle.textPrimary)
                    Text(account.account?.statusLabel ?? "Halo")
                        .font(HaloiOSStyle.caption)
                        .foregroundStyle(HaloiOSStyle.accent)
                }
                Spacer()
            }
            if let renews = renewalLine {
                Text(renews)
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
                    .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func usageCard(_ usage: AccountMe.Usage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This period")
                .font(HaloiOSStyle.caption)
                .foregroundStyle(HaloiOSStyle.textSecondary)

            usageRow(
                label: "Messages",
                used: usage.messages,
                cap: usage.caps?.messages,
                remaining: usage.messages_remaining
            )
            usageRow(
                label: "Words processed",
                used: usage.tokens_total,
                cap: usage.caps?.tokens,
                remaining: usage.tokens_remaining
            )

            if let resets = resetLine(usage) {
                Text(resets)
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func usageRow(label: String, used: Int, cap: Int?, remaining: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(HaloiOSStyle.body)
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                Spacer()
                if let remaining {
                    Text("\(remaining.formatted()) left")
                        .font(HaloiOSStyle.caption)
                        .foregroundStyle(HaloiOSStyle.textSecondary)
                }
            }
            if let cap, cap > 0 {
                ProgressView(value: min(1, Double(used) / Double(cap)))
                    .tint(HaloiOSStyle.accent)
            }
        }
    }

    private var accountActions: some View {
        VStack(spacing: 12) {
            Button {
                account.signOut()
                dismiss()
            } label: {
                Text("Sign out")
                    .font(HaloiOSStyle.bodyEmphasis)
                    .foregroundStyle(HaloiOSStyle.attention)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            // App Store guideline 5.1.1(v): account deletion must be reachable
            // from inside the app, not only on the web.
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Text(account.busy ? "Deleting…" : "Delete account")
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(account.busy)

            if let error = account.lastError, !error.isEmpty {
                Text(error)
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.attention)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            "Delete your Halo account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task {
                    if await account.deleteAccount() {
                        // Erase the local conversation cache too, so nothing
                        // survives on the device (and to fully simulate deletion
                        // for the demo account, which has no server data).
                        reach.purgeLocalData()
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and all its data. This can't be undone.")
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var renewalLine: String? {
        guard let sub = account.account?.subscription else { return nil }
        let date: Double?
        let verb: String
        if sub.status == "trialing", let trial = sub.trial_end {
            date = trial
            verb = "Trial ends"
        } else if let end = sub.period_end {
            date = end
            verb = sub.status == "active" ? "Renews" : "Ends"
        } else {
            return nil
        }
        guard let ms = date else { return nil }
        return "\(verb) \(Self.format(ms))"
    }

    private func resetLine(_ usage: AccountMe.Usage) -> String? {
        guard let resets = usage.resets_at else { return nil }
        return "Resets \(Self.format(resets))"
    }

    private static func format(_ epochMillis: Double) -> String {
        let date = Date(timeIntervalSince1970: epochMillis / 1000.0)
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}
