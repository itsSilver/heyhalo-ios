// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import os

private let log = Logger(subsystem: "com.silvercommerce.halo", category: "reach.ios")

/// The phone companion: text Halo on your computer from your iPhone. The
/// message rides your own iCloud (Apple relays it), the thinking happens on your
/// computer, and nothing passes through Halo's servers.
///
/// One flat conversation, one screen (spec §7). Login gates on an active
/// account; iCloud carries the conversation via CloudKit.
@main
struct HaloiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The single source of truth for the conversation + CloudKit I/O. Owned at
    /// the app root so the app delegate's push handler can reach the same client
    /// the UI is bound to.
    @StateObject private var reach = ReachCloudKitClient()

    /// Sign-in + entitlement gate (login proves the account is active; it never
    /// carries chat — that still rides CloudKit to the Mac).
    @StateObject private var account = HaloAccount()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(reach)
                .environmentObject(account)
                .onChange(of: account.isDemo) { _, isDemo in
                    // App Review demo: when the demo email signs in, switch the
                    // chat client into its offline canned-reply mode too.
                    if isDemo { reach.enableDemoMode() }
                }
                .task {
                    // Hand the live client to the delegate so a silent push can
                    // drive a fetch on the same instance the UI renders.
                    appDelegate.reach = reach
                    // Relay ActivityKit push tokens to the backend so the
                    // island can update while the app is suspended (ADR 0044).
                    ReachLiveActivityController.onPushToken = { hex, thread in
                        await account.registerActivityToken(hex, threadID: thread)
                    }
                    await reach.start()
                    // Launch lands in `.active`, but `scenePhase`'s `onChange`
                    // only fires on a CHANGE — so start the poll here too.
                    reach.beginForegroundSync()
                }
                .task {
                    // Restore a saved session and re-check entitlement.
                    await account.restore()
                }
                .onOpenURL { url in
                    switch url.host {
                    case "auth-callback", "signin":
                        // Magic-link / license-key handoff (the GitHub sheet
                        // resolves inline). Capture the token, refresh access.
                        Task { await account.handleCallback(url: url) }
                    case "chat":
                        // Island / Live Activity tap. "halo://chat/<threadID>"
                        // opens that conversation; bare "halo://chat" just
                        // brings the app forward to wherever it was.
                        let id =
                            url.path.hasPrefix("/")
                            ? String(url.path.dropFirst()) : url.path
                        if !id.isEmpty { reach.openThread(id) }
                    default:
                        break
                    }
                }
        }
    }
}
