// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.silvercommerce.halo", category: "reach.ios.account")

/// Owns sign-in + entitlement for the phone. Login is a GATE, not a chat
/// transport: it proves the Halo account is active (a cloud plan or the user's
/// own key) and powers the Account screen. Conversation content never goes near
/// this — that still rides CloudKit to the Mac.
///
/// Token flow: GitHub (ASWebAuthenticationSession) or email magic link →
/// Better Auth session token → Keychain → `Authorization: Bearer` on
/// `GET /v1/account/me`. (Token-capture wire details finalised against the
/// backend; see `handleCallback`.)
@MainActor
final class HaloAccount: ObservableObject {

    enum Access: Equatable {
        case loading  // restoring a saved session / first check
        case signedOut  // no token — show login
        case inactive  // signed in, but the account isn't active — show the inactive screen
        case entitled  // signed in + active license — unlock Reach
    }

    @Published private(set) var access: Access = .loading
    @Published private(set) var account: AccountMe?
    @Published var lastError: String?
    @Published var busy = false
    /// Set after a magic-link request so the UI can say "check your inbox".
    @Published var magicLinkSentTo: String?
    /// True when signed in via the App Review demo email — an offline, entitled
    /// session with no token and no network (see ``enterDemoMode``).
    @Published private(set) var isDemo = false

    /// Production relay by default; overridable via the same UserDefaults key the
    /// Mac uses, so a dev build can point at a local wrangler.
    static let baseURL: URL = {
        let raw =
            UserDefaults.standard.string(forKey: "halo.cloud.baseURL")
            ?? "https://api.heyhalo.app"
        return URL(string: raw) ?? URL(string: "https://api.heyhalo.app")!
    }()

    /// Custom URL scheme for OAuth / magic-link / license handoff callbacks.
    static let callbackScheme = "halo"

    /// Email that activates the offline App Review demo (disclosed in the App
    /// Store review notes). Typing it on the login screen signs in instantly —
    /// no magic link, no GitHub, no Mac — into a self-contained demo chat.
    /// Scoped to this one address; it grants only the canned demo experience and
    /// never touches real Reach, the backend, or anyone's data.
    static let demoEmail = "appreview@heyhalo.app"

    /// Better Auth redirects here after GitHub / magic-link succeed; this server
    /// route reads the session cookie and bounces to `halo://auth-callback?token=…`
    /// (it lives on the API origin, so it's a trusted callbackURL). See ADR 0037.
    static var nativeHandoffURL: String {
        baseURL.appendingPathComponent("v1/auth/native-handoff").absoluteString
    }

    /// A trusted web origin to stamp on auth POSTs. Better Auth rejects
    /// state-changing auth requests whose `Origin` isn't in `trustedOrigins`
    /// (CSRF protection); a browser sends this automatically, a native client
    /// must set it explicitly. Matches the site origin the backend trusts.
    static let webOrigin = "https://heyhalo.app"

    private let web = WebAuthService()

    private var token: String? {
        KeychainStore.read(account: KeychainStore.sessionTokenAccount)
    }

    var isSignedIn: Bool { token != nil }

    // MARK: - Lifecycle

    /// Restore a saved session on launch and re-check entitlement.
    func restore() async {
        if isDemo { return }
        guard token != nil else {
            access = .signedOut
            return
        }
        await refreshAccount()
    }

    /// Re-read `/v1/account/me` and recompute access.
    func refreshAccount() async {
        // The demo session is local and tokenless; never let a foreground
        // re-check sign the reviewer out from under the demo.
        if isDemo { return }
        guard let token else {
            access = .signedOut
            return
        }
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("v1/account/me"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("HaloiOS", forHTTPHeaderField: "x-halo-client")
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                log.notice("account/me 401 — clearing stale session")
                signOut()
                return
            }
            guard status < 500 else {
                lastError = "Our servers had trouble (HTTP \(status))."
                // Keep whatever access we had; don't sign the user out on a blip.
                if access == .loading { access = isSignedIn ? .inactive : .signedOut }
                return
            }
            let me = try JSONDecoder().decode(AccountMe.self, from: data)
            account = me
            access = me.isActive ? .entitled : .inactive
            lastError = nil
            log.notice("account refreshed active=\(me.isActive, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            if access == .loading { access = isSignedIn ? .inactive : .signedOut }
        }
    }

    /// Register this device's ActivityKit push token for a Reach thread so the
    /// backend can update the Live Activity (the island) while the app is
    /// suspended (ADR 0044). Best-effort: failures are logged, never surfaced,
    /// and the foreground/wake CloudKit path keeps the island moving regardless.
    func registerActivityToken(_ activityToken: String, threadID: String) async {
        if isDemo { return }
        guard let token else { return }
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("v1/reach/activity-token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("HaloiOS", forHTTPHeaderField: "x-halo-client")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "activity_token": activityToken,
            "thread_id": threadID
        ])
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                log.notice("activity-token register failed: HTTP \(status, privacy: .public)")
            }
        } catch {
            log.notice("activity-token register error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Permanently delete the Halo account and all its data (App Store guideline
    /// 5.1.1(v): a signed-in user must be able to delete their account from
    /// inside the app). Calls `DELETE /v1/account` with the required
    /// `{ confirm: true }`; the backend cancels billing and cascades the user's
    /// licenses, usage, devices, teams, and OAuth links. On success we sign out
    /// locally. Returns true when the account was deleted.
    @discardableResult
    func deleteAccount() async -> Bool {
        // The App Review demo account is local and has nothing on the server to
        // delete — just tear the session down so the button still "works".
        if isDemo {
            signOut()
            return true
        }
        guard let token else { signOut(); return true }
        busy = true
        lastError = nil
        defer { busy = false }
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("v1/account"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("HaloiOS", forHTTPHeaderField: "x-halo-client")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["confirm": true])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                log.notice("Account deleted")
                signOut()
                return true
            }
            // 409 when the caller owns a team with other members — surface the
            // server's plain-language reason so they know what to resolve first.
            if let message = (try? JSONSerialization.jsonObject(with: data)
                as? [String: Any])?["message"] as? String, !message.isEmpty {
                lastError = message
            } else {
                lastError = "Couldn't delete your account (HTTP \(status)). Please try again."
            }
            return false
        } catch {
            lastError = "Couldn't delete your account. \(error.localizedDescription)"
            return false
        }
    }

    func signOut() {
        KeychainStore.delete(account: KeychainStore.sessionTokenAccount)
        account = nil
        magicLinkSentTo = nil
        isDemo = false
        access = .signedOut
    }

    /// Sign into the offline App Review demo: a synthetic entitled account, no
    /// token, no network. Activated only from the demo email on the login
    /// screen. The chat itself runs offline too — see
    /// `ReachCloudKitClient.enableDemoMode`, bridged in `HaloiOSApp`.
    func enterDemoMode() {
        account = .demo(email: Self.demoEmail)
        isDemo = true
        lastError = nil
        magicLinkSentTo = nil
        access = .entitled
        log.notice("Entered App Review demo mode")
    }

    // MARK: - Sign in

    /// GitHub OAuth via the system auth sheet. Asks the relay for the provider
    /// URL, runs the sheet, then captures the token from the `halo://` callback.
    func signInWithGitHub() async {
        busy = true
        lastError = nil
        defer { busy = false }
        // Open the server-side `native-start` route directly in the auth sheet so
        // the WHOLE OAuth flow (state cookie → GitHub → callback → session →
        // handoff) lives in one web context. Initiating via URLSession instead
        // set the OAuth state cookie in a different jar, so the GitHub callback
        // failed state verification and showed Better Auth's error page (ADR 0037).
        var comps = URLComponents(
            url: Self.baseURL.appendingPathComponent("v1/auth/native-start"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "provider", value: "github")]
        guard let startURL = comps?.url else {
            lastError = "Couldn't start GitHub sign-in."
            return
        }
        do {
            let callback = try await web.authenticate(url: startURL, scheme: Self.callbackScheme)
            await handleCallback(url: callback)
        } catch WebAuthError.cancelled {
            // User dismissed the sheet — not an error worth surfacing loudly.
            log.notice("GitHub sign-in cancelled by user")
        } catch {
            lastError = "Couldn't sign in with GitHub. \(error.localizedDescription)"
        }
    }

    /// Email magic link, mirroring the web. Sends the link; the user taps it and
    /// the `halo://` callback brings them back signed in.
    @discardableResult
    func sendMagicLink(email: String) async -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else {
            lastError = "That doesn't look like an email address."
            return false
        }
        // App Review demo: this one address signs in instantly, offline. A
        // reviewer can't click a magic link sent to an inbox they don't have, so
        // the demo skips the round-trip entirely (disclosed in the review notes).
        if trimmed.caseInsensitiveCompare(Self.demoEmail) == .orderedSame {
            enterDemoMode()
            return true
        }
        busy = true
        lastError = nil
        defer { busy = false }
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("v1/auth/sign-in/magic-link"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(Self.webOrigin, forHTTPHeaderField: "origin")
        let body: [String: String] = ["email": trimmed, "callbackURL": Self.nativeHandoffURL]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status < 400 else {
                lastError = "Couldn't send the link (HTTP \(status))."
                return false
            }
            magicLinkSentTo = trimmed
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Handle a `halo://` deep link: an OAuth/magic-link callback carrying a
    /// session token, or a `halo://signin?key=HALO-…` license-key handoff.
    func handleCallback(url: URL) async {
        guard url.scheme == Self.callbackScheme else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        // The server bounced back with an error (e.g. social_init_failed,
        // auth_failed) — surface it instead of silently doing nothing.
        if let reason = items.first(where: { $0.name == "error" })?.value, !reason.isEmpty {
            log.notice("Auth callback error: \(reason, privacy: .public)")
            lastError = "Sign-in didn't complete. Please try again."
            return
        }

        // License-key handoff (secondary path, shared with the Mac).
        if url.host == "signin", let key = items.first(where: { $0.name == "key" })?.value, !key.isEmpty {
            await signInWithLicenseKey(key)
            return
        }

        // Better Auth callback: the token arrives as a query item. Accept the
        // common names so we're robust to the exact backend wiring.
        let tokenKeys = ["token", "session_token", "sessionToken", "set-auth-token"]
        if let token = items.first(where: { tokenKeys.contains($0.name) })?.value, !token.isEmpty {
            KeychainStore.write(token, account: KeychainStore.sessionTokenAccount)
            access = .loading
            await refreshAccount()
            return
        }

        // No token in the URL — the session may be cookie-only. Fall back to a
        // get-session exchange (finalised once the backend wire is confirmed).
        await exchangeSessionCookie()
    }

    /// License-key sign-in: validate against the relay, then persist the key as
    /// the Bearer credential (the relay accepts a license key as Bearer too).
    private func signInWithLicenseKey(_ rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("v1/license/validate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_name": "iPhone"])
        struct ValidateResponse: Decodable { let valid: Bool? }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try? JSONDecoder().decode(ValidateResponse.self, from: data)
            guard decoded?.valid == true else {
                lastError = "That license key wasn't accepted."
                return
            }
            KeychainStore.write(key, account: KeychainStore.sessionTokenAccount)
            access = .loading
            await refreshAccount()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Placeholder for the cookie→token exchange if Better Auth returns the
    /// session as a cookie rather than a callback param. Finalised against the
    /// backend (see ADR 0037 §18 open question).
    private func exchangeSessionCookie() async {
        lastError = "Couldn't complete sign-in. Please try again."
    }
}
