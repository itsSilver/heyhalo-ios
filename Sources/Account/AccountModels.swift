// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The shape of `GET /v1/account/me` (services/api/src/routes/account.ts). Only
/// the fields the phone shows or gates on are decoded; unknown fields are
/// ignored. Times are epoch milliseconds (the API uses `Date.getTime()`).
struct AccountMe: Decodable, Sendable, Equatable {
    var authenticated: Bool
    var user: User
    var subscription: Subscription?
    var license: License?
    var team: Team?
    var usage: Usage?

    struct User: Decodable, Sendable, Equatable {
        var id: String
        var email: String
        var name: String?
        var role: String?
    }

    struct Subscription: Decodable, Sendable, Equatable {
        var status: String
        var period_end: Double?
        var trial_end: Double?
        var plan: String?
    }

    /// The one-time Halo license (`halo_pro_license` / `lifetime`) — the
    /// bring-your-own-key path. The backend returns this only when it's active,
    /// so its mere presence means an active license that entitles Reach without
    /// any cloud subscription. See `/v1/account/me` (`hasCustomServerLicense`).
    struct License: Decodable, Sendable, Equatable {
        var key: String?
        var tier: String?
    }

    struct Team: Decodable, Sendable, Equatable {
        var id: String
        var name: String
        var role: String?
        var seats: Int?
        var status: String?
        var period_end: Double?
    }

    struct Usage: Decodable, Sendable, Equatable {
        var period: String?
        var messages: Int
        var tokens_total: Int
        var est_cost_usd: Double?
        var caps: Caps?
        var messages_remaining: Int?
        var tokens_remaining: Int?
        var over_cap: Bool?
        var resets_at: Double?

        struct Caps: Decodable, Sendable, Equatable {
            var messages: Int?
            var tokens: Int?
        }
    }

    // MARK: - Derived

    /// True when the account has the admin role — bypasses the entitlement
    /// gate entirely (aligns with the backend's admin bypass + the Mac's
    /// `EntitlementStore`). `role` is admin-assigned server-side only.
    var isAdmin: Bool { user.role == "admin" }

    /// True when this account has an ACTIVE Halo license — the single gate for
    /// unlocking Reach. Mirrors the Mac's `isPremiumEntitled`
    /// (`EntitlementStore.canUseCustomServer`): active via ANY of
    ///   • a cloud subscription (trialing / active / past_due, unexpired),
    ///   • a one-time Halo license — the bring-your-own-key path (`license`),
    ///   • an active team seat,
    ///   • the admin role.
    /// This is an account-active check, not a paywall — the phone never sells or
    /// references a purchase (App Store multiplatform-service pattern).
    var isActive: Bool {
        if isAdmin { return true }
        if hasActiveSubscription { return true }
        if license != nil { return true }
        if hasActiveTeam { return true }
        return false
    }

    /// A cloud subscription in a granting state whose period hasn't lapsed.
    private var hasActiveSubscription: Bool {
        Self.isGranting(status: subscription?.status, periodEndMillis: subscription?.period_end)
    }

    /// An active team seat entitles Reach exactly like a personal subscription
    /// (the seat is billed at the team level).
    private var hasActiveTeam: Bool {
        Self.isGranting(status: team?.status, periodEndMillis: team?.period_end)
    }

    /// Shared granting-state test: one of trialing / active / past_due AND, if a
    /// period boundary is present, still in the future. Mirrors the relay's
    /// `grantingStates` (inference.ts).
    private static func isGranting(status: String?, periodEndMillis: Double?) -> Bool {
        guard let status else { return false }
        let granting: Set<String> = ["trialing", "active", "past_due"]
        guard granting.contains(status) else { return false }
        if let end = periodEndMillis {
            return Date().timeIntervalSince1970 < end / 1000.0
        }
        return true
    }

    /// A warm, human status label for the account header. Describes what the
    /// account HAS — never a plan to buy.
    var statusLabel: String {
        if isAdmin { return "Admin" }
        if let team, !team.name.isEmpty { return "\(team.name) team" }
        if subscription?.status == "trialing" { return "Free trial" }
        return isActive ? "Active" : "Not active"
    }
}

// MARK: - App Review demo

extension AccountMe {
    /// A synthetic, active account used only by the App Review demo
    /// (`HaloAccount.enterDemoMode`, gated to the demo email). Never comes from
    /// the network. Active via a license rather than the admin role, so it
    /// reaches the chat without unlocking any admin-only surface — and with zero
    /// subscription framing.
    static func demo(email: String) -> AccountMe {
        AccountMe(
            authenticated: true,
            user: User(id: "demo-reviewer", email: email, name: "App Review", role: nil),
            subscription: nil,
            license: License(key: "DEMO", tier: "lifetime"),
            team: nil,
            usage: nil
        )
    }
}
