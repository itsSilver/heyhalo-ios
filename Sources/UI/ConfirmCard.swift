// SPDX-License-Identifier: Apache-2.0
import HaloReachKit
import SwiftUI

/// A `role:system` / `needs-confirm` prompt rendered as an approve / deny card,
/// styled like the Mac's `ToolConfirmationCard` (cyan glass fill + stroke).
/// Tapping Approve / Not now writes the answer back over CloudKit
/// (`ReachCloudKitClient.answerConfirm`) — the marker the Mac routes to its
/// parked staged tool, which then runs (or skips) and replies. Once answered,
/// the card shows its resolved state so it can't be double-submitted.
struct ConfirmCard: View {
    @EnvironmentObject private var reach: ReachCloudKitClient
    let message: ReachMessage

    private var answered: Bool {
        guard let token = message.confirmToken else { return false }
        return reach.answeredConfirmTokens.contains(token)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HaloiOSStyle.accent)
                Text("I'd like your go-ahead")
                    .font(HaloiOSStyle.bodyEmphasis)
                    .foregroundStyle(HaloiOSStyle.textPrimary)
            }

            Text(message.body)
                .font(HaloiOSStyle.body)
                .foregroundStyle(HaloiOSStyle.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if answered {
                Text("Got it — sent your answer to your computer.")
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
            } else {
                HStack(spacing: 10) {
                    Button {
                        Task { await reach.answerConfirm(message, approved: true) }
                    } label: {
                        Text("Approve")
                            .font(HaloiOSStyle.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(HaloiOSStyle.accent.opacity(0.22))
                            )
                            .foregroundStyle(HaloiOSStyle.accent)
                    }

                    Button {
                        Task { await reach.answerConfirm(message, approved: false) }
                    } label: {
                        Text("Not now")
                            .font(HaloiOSStyle.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .foregroundStyle(HaloiOSStyle.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                .fill(HaloiOSStyle.confirmFill)
                .overlay(
                    RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                        .stroke(HaloiOSStyle.confirmStroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, 4)
    }
}
