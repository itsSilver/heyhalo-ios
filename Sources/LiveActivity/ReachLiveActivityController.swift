// SPDX-License-Identifier: Apache-2.0
@preconcurrency import ActivityKit
import Foundation
import os

private let log = Logger(subsystem: "com.silvercommerce.halo", category: "reach.ios.liveactivity")

/// Drives the Reach Live Activity (the iOS "notch") from the chat lifecycle:
/// start when the user sends, update with breadcrumbs / confirm prompts as the
/// Mac works, end when the reply lands. Foreground/local-driven this round —
/// background push is Phase 2 (ADR 0037 §16).
///
/// Methods are `async` and await ActivityKit directly on the main actor (rather
/// than spawning a Task) so the non-Sendable `Activity` never crosses an
/// isolation boundary — Swift 6 strict concurrency.
@MainActor
enum ReachLiveActivityController {

    private static var current: Activity<ReachActivityAttributes>?

    /// Set at app launch to relay each activity's ActivityKit push token to the
    /// backend (HaloAccount.registerActivityToken) so the Worker can update the
    /// island while the app is suspended (ADR 0044). Optional: the controller
    /// works without it (foreground/wake updates still flow via CloudKit).
    static var onPushToken: (@Sendable (_ tokenHex: String, _ threadID: String) async -> Void)?

    private static var enabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Begin a turn: "delivered, waiting for your computer". Clears any orphaned
    /// island first (from a prior turn / force-quit) so the new turn gets a
    /// fresh activity with the correct threadID — never a duplicate or a stale
    /// one routing to the wrong chat.
    static func start(threadID: String?, chatTitle: String) async {
        await endNow()
        await set(
            .init(
                phase: .thinking,
                line: "Delivered, waiting for your computer…",
                chatTitle: title(chatTitle),
                confirm: nil
            ),
            threadID: threadID
        )
    }

    /// Interim breadcrumb ("Looking that up…").
    static func breadcrumb(_ line: String, threadID: String?, chatTitle: String) async {
        await set(.init(phase: .thinking, line: line, chatTitle: title(chatTitle), confirm: nil), threadID: threadID)
    }

    /// A yes/no the user must answer (starts an activity if none is live).
    static func confirm(_ confirm: ReachActivityAttributes.Confirm, chatTitle: String) async {
        await set(
            .init(phase: .needsConfirm, line: confirm.preview, chatTitle: title(chatTitle), confirm: confirm),
            threadID: confirm.threadID
        )
    }

    /// The reply landed — show it briefly, then dismiss.
    static func finish(reply: String, chatTitle: String) async {
        guard let activity = adoptedCurrent() else { return }
        current = nil
        let state = ReachActivityAttributes.ContentState(
            phase: .done,
            line: reply,
            chatTitle: title(chatTitle),
            confirm: nil
        )
        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 3))
        await endStragglers(keeping: activity)
        log.info("Live Activity finished")
    }

    /// Settle the activity with a final line (no answer yet / send failed), then
    /// dismiss after a few seconds — so the island never spins forever.
    static func settle(line: String, chatTitle: String) async {
        guard let activity = adoptedCurrent() else { return }
        current = nil
        let state = ReachActivityAttributes.ContentState(
            phase: .done,
            line: line,
            chatTitle: title(chatTitle),
            confirm: nil
        )
        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4))
        await endStragglers(keeping: activity)
    }

    /// End immediately (e.g. a new turn started) — EVERY live Reach activity,
    /// so a force-quit can't leave an orphaned island spinning behind.
    static func endNow() async {
        current = nil
        for activity in Activity<ReachActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Resolve the activity to act on. `current` is our in-memory handle, but it
    /// is lost when the app is force-quit / relaunched WHILE the Activity itself
    /// survives — so re-adopt it from ActivityKit's live list. Without this, a
    /// reply that lands after a relaunch can't end the island and it spins
    /// "Delivered, waiting for your computer…" forever (field 2026-06-24).
    private static func adoptedCurrent() -> Activity<ReachActivityAttributes>? {
        if let current { return current }
        current = Activity<ReachActivityAttributes>.activities.last
        return current
    }

    /// End any OTHER live Reach activities — defends against orphan pileup if
    /// several turns were started across force-quits.
    private static func endStragglers(keeping kept: Activity<ReachActivityAttributes>) async {
        for activity in Activity<ReachActivityAttributes>.activities where activity.id != kept.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Create the activity if none is live, otherwise update it. `threadID` is
    /// baked into the (immutable) attributes at creation so a tap on the island
    /// can route to this turn's chat; it is ignored on a plain content update.
    private static func set(_ state: ReachActivityAttributes.ContentState, threadID: String?) async {
        guard enabled else { return }
        if let activity = adoptedCurrent() {
            await activity.update(.init(state: state, staleDate: nil))
            return
        }
        do {
            let activity = try Activity.request(
                attributes: ReachActivityAttributes(sessionID: UUID().uuidString, threadID: threadID),
                content: .init(state: state, staleDate: nil),
                pushType: .token
            )
            current = activity
            log.info("Live Activity started")
            observePushToken(activity, threadID: threadID)
        } catch {
            log.error("Live Activity start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stream this activity's ActivityKit push token to the registration hook
    /// (ADR 0044). The token can rotate, so keep observing for the activity's
    /// lifetime; the loop ends when the activity does.
    private static func observePushToken(
        _ activity: Activity<ReachActivityAttributes>,
        threadID: String?
    ) {
        guard let threadID, !threadID.isEmpty, onPushToken != nil else { return }
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await onPushToken?(hex, threadID)
            }
        }
    }

    private static func title(_ t: String) -> String { t.isEmpty ? "Halo" : t }
}
