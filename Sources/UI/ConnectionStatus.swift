// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The single source of truth for how Halo's connection state reads to a human
/// — the dot color, the short header label, and the longer onboarding copy all
/// derive from one place so they can never tell different stories.
///
/// **Honesty contract.** The phone can verify exactly one thing: its own iCloud
/// account. It cannot see whether the Mac is awake or has "Listen for messages
/// from my phone" turned on. So:
///
/// - iCloud signed in, no reply yet → "Signed into iCloud" (NOT "Connected").
///   The copy names the one step the phone can't do for the user: turn the Mac
///   toggle on, then send a message — if Halo replies, you're connected.
/// - First real `halo` reply received (`endToEndConfirmed`) → "Connected." This
///   is the only state that claims the full path works, because it's the only
///   one we've actually observed working.
struct ConnectionStatusDescriptor {
    let connection: ReachCloudKitClient.ConnectionState
    let endToEndConfirmed: Bool
    /// True when the most recent turn stalled (75s, no reply): the path worked
    /// once, but the Mac isn't answering right now. Default false so existing
    /// call sites (and tests) are unaffected.
    var recentStall: Bool = false

    /// The honest "shapes" of the state, driving dot color + tone.
    enum Tone: Equatable {
        /// Verified end to end (a reply has landed). Calm cyan.
        case connected
        /// Working on the phone side, awaiting the Mac. Amber "almost there."
        case signedInPendingMac
        /// Was connected, but the last message stalled — Mac asleep / Reach off.
        case macUnresponsive
        /// Checking / in motion. Dim.
        case checking
        /// Needs the user to act on iCloud. Amber.
        case needsAttention
    }

    var tone: Tone {
        switch connection {
        case .checking:
            return .checking
        case .signedIn:
            // Never heard back yet → pending. Heard back once but the last
            // turn stalled → downgrade to "not responding" (honest: don't keep
            // claiming Connected when the Mac just failed to answer).
            if !endToEndConfirmed { return .signedInPendingMac }
            return recentStall ? .macUnresponsive : .connected
        case .noAccount, .restricted, .couldNotDetermine:
            return .needsAttention
        }
    }

    /// The dot color for the chosen tone.
    var dotColor: Color {
        switch tone {
        case .connected: return HaloiOSStyle.accent
        case .signedInPendingMac, .needsAttention, .macUnresponsive: return HaloiOSStyle.attention
        case .checking: return HaloiOSStyle.textSecondary
        }
    }

    /// Whether the dot should breathe (used while checking / awaiting).
    var dotPulses: Bool {
        switch tone {
        case .checking, .signedInPendingMac, .macUnresponsive: return true
        case .connected, .needsAttention: return false
        }
    }

    /// Short label for the chat header — a few words, no claims we can't back.
    var headerLabel: String {
        switch tone {
        case .connected: return "Connected"
        case .signedInPendingMac: return "Signed into iCloud"
        case .macUnresponsive: return "Computer not responding"
        case .checking: return "Checking iCloud…"
        case .needsAttention:
            switch connection {
            case .noAccount: return "Not signed into iCloud"
            case .restricted: return "iCloud is restricted"
            default: return "iCloud unavailable"
            }
        }
    }

    /// The onboarding headline — slightly warmer than the header label.
    var headline: String {
        switch tone {
        case .connected: return "Connected ✓"
        case .signedInPendingMac: return "Signed into iCloud ✓"
        case .macUnresponsive: return "Your computer isn't answering"
        case .checking: return "Checking iCloud…"
        case .needsAttention:
            switch connection {
            case .noAccount: return "Sign into iCloud to continue"
            case .restricted: return "iCloud is restricted on this iPhone"
            default: return "iCloud isn't available right now"
            }
        }
    }

    /// The honest, longer onboarding detail copy.
    var detail: String {
        switch tone {
        case .connected:
            return "You've heard back from Halo on your computer, so the whole path is working. Just text it anything."
        case .macUnresponsive:
            return
                "You've connected before, but your last message hasn't come back. Your computer may be asleep, or \"Listen for messages from my phone\" may be off over there. It'll go through once your computer is awake with Reach on."
        case .signedInPendingMac:
            return
                "Open Halo on your computer and turn on \"Listen for messages from my phone\" (the same iCloud account as this iPhone). Send a message here, and if Halo replies, you're fully connected. I can only see the iCloud side from here, so your computer needs that toggle on."
        case .checking:
            return "One moment while I check your iCloud account."
        case .needsAttention:
            switch connection {
            case .noAccount:
                return
                    "Sign into iCloud in Settings, on the same account as your computer. That shared account is what lets this iPhone and your computer reach each other, with no address to type."
            case .restricted:
                return
                    "iCloud is restricted on this iPhone (for example by Screen Time or a device profile). Allow iCloud, on the same account as your computer, to reach it from here."
            case .couldNotDetermine(let reason):
                return reason
            case .checking, .signedIn:
                return ""  // unreachable in this tone
            }
        }
    }
}

/// A small breathing dot for the connection state — sits in the chat header and
/// the onboarding status panel. Color + pulse come from the descriptor so the
/// dot and the words can't disagree.
struct ConnectionDot: View {
    let status: ConnectionStatusDescriptor
    var diameter: CGFloat = 9

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.dotColor)
            .frame(width: diameter, height: diameter)
            .shadow(color: status.dotColor.opacity(0.7), radius: pulse ? 5 : 2)
            .scaleEffect(status.dotPulses && pulse ? 1.18 : 1)
            .opacity(status.dotPulses && pulse ? 0.7 : 1)
            .onAppear { startPulsing() }
            .onChange(of: status.dotPulses) { _, _ in startPulsing() }
            .accessibilityHidden(true)
    }

    private func startPulsing() {
        guard status.dotPulses else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
