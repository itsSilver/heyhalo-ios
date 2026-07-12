// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import os

private let log = Logger(subsystem: "com.silvercommerce.halo", category: "reach.ios")

/// The welcome / first-run moment (and the fallback whenever the phone isn't
/// signed into iCloud). It introduces Halo with the breathing presence orb and
/// warm first-person copy, then shows the **honest** connection status:
///
/// - The phone can only verify its OWN side (the iCloud account). It cannot see
///   whether the Mac is awake or has the toggle on, so it never claims
///   "Connected to your computer" on iCloud status alone — it says "Signed into
///   iCloud" and points the user at the one thing the phone can't do for them
///   (turn the Mac toggle on). The first real reply is the only end-to-end
///   proof, and that promotes the indicator to "Connected" inside the chat.
///
/// Reuses ``HaloPresenceOrb`` and ``HaloiOSStyle`` so it's the same product on
/// a phone — no bespoke styling.
struct OnboardingView: View {
    @EnvironmentObject private var reach: ReachCloudKitClient

    /// Called when the user taps "Start" from the signed-in state — the host
    /// records first-run done and drops into the chat.
    var onStart: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            HaloiOSStyle.canvas

            VStack(spacing: 0) {
                Spacer(minLength: 24)
                intro
                Spacer(minLength: 28)
                statusPanel
                Spacer(minLength: 24)
                action
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 520)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
        }
    }

    // MARK: - Intro (orb + warm copy)

    private var intro: some View {
        VStack(spacing: 22) {
            HaloPresenceMark(isThinking: reach.connection == .checking, diameter: 96)
                .scaleEffect(appeared ? 1 : 0.85)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 10) {
                Text("Halo")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                Text("Text Halo on your computer, from right here.")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                    .multilineTextAlignment(.center)
                Text(
                    "Your message rides your own iCloud. The thinking happens on your computer, and nothing passes through anyone else's servers."
                )
                .font(HaloiOSStyle.body)
                .foregroundStyle(HaloiOSStyle.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
        }
    }

    // MARK: - Status panel (the honest part)

    private var statusPanel: some View {
        let status = ConnectionStatusDescriptor(
            connection: reach.connection,
            endToEndConfirmed: reach.endToEndConfirmed,
            recentStall: reach.lastTurnStalled
        )
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ConnectionDot(status: status)
                Text(status.headline)
                    .font(HaloiOSStyle.bodyEmphasis)
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                Spacer(minLength: 0)
            }

            Text(status.detail)
                .font(HaloiOSStyle.body)
                .foregroundStyle(HaloiOSStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .opacity(appeared ? 1 : 0)
    }

    // MARK: - Action (Start when signed in, Retry otherwise)

    @ViewBuilder
    private var action: some View {
        switch reach.connection {
        case .signedIn:
            primaryButton(title: "Start", action: onStart)
        case .checking:
            // Mid-check: keep the button present but inert so the layout is
            // stable; it becomes Start / Retry the moment the check resolves.
            primaryButton(title: "Just a moment…", action: {})
                .disabled(true)
                .opacity(0.6)
        case .noAccount, .restricted, .couldNotDetermine:
            primaryButton(title: "Retry") {
                Task { await reach.retry() }
            }
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
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
    }
}
