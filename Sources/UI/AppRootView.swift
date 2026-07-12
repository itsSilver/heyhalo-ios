// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Top-level flow shell. Owns the launch sequence and the access gate so the
/// rest of the app doesn't have to:
///
///   Splash  →  Login    (signed out)
///           →  Inactive (signed in, account not active)
///           →  RootView (active — the existing iCloud onboarding / chat)
///
/// Login is the gate (proves the account is active); it never carries chat —
/// messages still ride CloudKit to the Mac inside `RootView`.
struct AppRootView: View {
    @EnvironmentObject private var account: HaloAccount
    @EnvironmentObject private var reach: ReachCloudKitClient
    @Environment(\.scenePhase) private var scenePhase

    /// Minimum on-screen time so the splash sweep is actually seen.
    private static let minSplashSeconds: Double = 1.3
    /// Hard ceiling so a stuck network never traps the user on the splash.
    private static let maxSplashSeconds: Double = 8.0

    @State private var minTimeElapsed = false
    @State private var forcedReady = false

    private var resolved: Bool { account.access != .loading || forcedReady }
    private var showSplash: Bool { !(minTimeElapsed && resolved) }

    var body: some View {
        ZStack {
            gateContent
                .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashView(status: account.access == .loading ? "Checking your account…" : "Just a moment…")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: showSplash)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.minSplashSeconds * 1_000_000_000))
            minTimeElapsed = true
        }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.maxSplashSeconds * 1_000_000_000))
            forcedReady = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Re-check the account when the app comes forward, so a lapsed
                // license flips to the inactive screen instead of silently failing.
                Task { await account.refreshAccount() }
                // Resume the conversation poll — and fetch immediately, so a
                // reply that landed while backgrounded is on screen at once.
                reach.beginForegroundSync()
            } else {
                // Leaving the foreground: stop polling. Push takes over for
                // background/killed delivery and re-arms the poll on return.
                reach.endForegroundSync()
            }
        }
    }

    @ViewBuilder
    private var gateContent: some View {
        switch account.access {
        case .entitled:
            RootView()
        case .inactive:
            InactiveAccountView()
        case .signedOut, .loading:
            // `.loading` only reaches here if the max-splash ceiling fired while
            // a check was still in flight — fall back to login rather than hang.
            LoginView()
        }
    }
}
