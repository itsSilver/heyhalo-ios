// SPDX-License-Identifier: Apache-2.0
import CloudKit
import Foundation
import HaloReachKit
import os

private let log = Logger(subsystem: "com.silvercommerce.halo", category: "reach.ios")

/// CloudKit-relayed "text Halo from your phone" — the **phone side** (spec §7,
/// ADR 0036). The phone writes an encrypted `ReachMessage{role:user}` record to
/// the user's PRIVATE CloudKit database; Apple relays it to the Mac, which runs
/// the agent loop and writes back a `role:halo` reply (and, for a gated tool, a
/// `role:system` / `needs-confirm` prompt). Apple relays those to the phone.
/// No Halo backend sits in the message path.
///
/// This client owns the zone / subscription / fetch / save side effects and
/// surfaces an ordered conversation for the chat screen to render. The pure
/// `ReachMessage` value type owns the CKRecord mapping (so the wire format
/// stays testable and in lockstep with the Mac).
///
/// **Same iCloud account = same private DB.** There is no pairing step: the
/// phone and the Mac are signed into the same iCloud account, so they share one
/// private database. There is exactly one correct recipient (the user).
@MainActor
final class ReachCloudKitClient: ObservableObject {

    // MARK: - Published conversation state (drives the chat UI)

    /// The flat, time-ordered conversation (oldest first). Includes the user's
    /// own sent messages, Halo's replies, and `needs-confirm` prompts.
    ///
    /// Persisted to a local cache on every change (the `didSet`) and reloaded in
    /// `init`, so a chat's history is on the phone the instant it relaunches —
    /// `fetch()` is a token-delta that won't re-download an already-seen
    /// conversation, so without this cache the list shows a chat (from persisted
    /// `chats`) while the detail renders empty. Demo mode is excluded: its canned
    /// thread must never leak into a real user's cache.
    @Published private(set) var messages: [ReachMessage] = [] {
        didSet { if !isDemo { persistMessages() } }
    }

    /// Mutation seam for the breadcrumb pruner in `+Chats` — `messages`'s
    /// setter is file-private (`private(set)`), so the extension can't call
    /// `removeAll` directly. Keeps the "only this class mutates `messages`"
    /// contract while letting the prune logic live next to the coalescer.
    func removeMessages(where shouldRemove: (ReachMessage) -> Bool) {
        messages.removeAll(where: shouldRemove)
    }
    /// High-level connection / account state, surfaced honestly in the UI
    /// (spec §8 — show the truth rather than spin). This reflects ONLY what the
    /// phone can verify: the iCloud account side. It deliberately does NOT claim
    /// the Mac is listening — the phone can't see the Mac's toggle. The real
    /// end-to-end proof is ``endToEndConfirmed``, flipped on the first reply.
    @Published private(set) var connection: ConnectionState = .checking
    /// True from the moment the user sends until Halo's reply lands — drives
    /// the "delivered, Halo is answering…" footer.
    @Published private(set) var isAwaitingReply = false {
        didSet {
            // A reply / confirm arriving (or a send failing) clears this; kill
            // the stall timer so a turn that WAS answered can't later flash a
            // false "couldn't reach your computer" notice, and drop the wait clock.
            if !isAwaitingReply {
                replyTimeoutTask?.cancel()
                replyTimeoutTask = nil
                awaitingSince = nil
            }
        }
    }
    /// When the current turn started waiting (set on delivery, cleared when the
    /// reply/confirm lands). Drives the "Waiting 20s… · Retry" affordance.
    @Published private(set) var awaitingSince: Date?
    /// True when the most recent turn hit the 75s stall with no reply — the Mac
    /// isn't answering right now. Cleared by any fresh reply. Lets the
    /// connection status downgrade from a stale "Connected" to "not responding"
    /// instead of claiming a path we've since seen fail.
    @Published private(set) var lastTurnStalled = false
    /// The latest breadcrumb the Mac published this turn ("Looking that up…"),
    /// shown in the in-app answering row — the same line the Live Activity shows
    /// (ADR 0037 §17). Cleared when the reply lands or a new turn starts. Non-
    /// private setter so the cross-file `+Chats` extension can update it.
    @Published var thinkingLine: String?
    /// Confirm prompts the user has already answered (keyed by `confirmToken`),
    /// so the approve/deny card renders its resolved state and can't double-submit.
    @Published private(set) var answeredConfirmTokens: Set<String> = []
    /// True when signed in via the App Review demo email — the chat runs fully
    /// offline (canned replies, no CloudKit). See the demo section at the end.
    @Published private(set) var isDemo = false
    /// The honest end-to-end signal: `true` once a real `halo` reply has ever
    /// arrived on this device. iCloud being signed in only proves the phone
    /// half; a reply is the first moment we know the Mac is listening on the
    /// same account with the toggle on. Persisted so a returning user who's
    /// already connected once doesn't get demoted back to "needs your computer."
    @Published private(set) var endToEndConfirmed: Bool =
        UserDefaults.standard.bool(forKey: endToEndConfirmedDefaultsKey)

    /// The user's chats (ADR 0037 §15). Each is one `threadID`; the phone owns
    /// this list locally. Mutated only through the ``ReachCloudKitClient+Chats``
    /// helpers (new/select/ensure/reconcile), which also persist; the
    /// non-private setter exists only so that cross-file extension can write it.
    @Published var chats: [ReachChat] = []
    /// The chat currently open. Outgoing messages are tagged with it; the chat
    /// screen renders only this thread's messages (``currentMessages``).
    @Published var currentThreadID: String?

    /// Set by a Live Activity / island deep link ("halo://chat/<id>"); the chat
    /// list observes it, pushes that thread, then clears it back to nil.
    @Published var deepLinkThread: String?

    /// Threads the user deleted — tombstoned so a later fetch / reconcile can't
    /// resurrect them. Persisted; their records are also removed from CloudKit
    /// best-effort on delete.
    var deletedThreadIDs: Set<String> = []

    /// Account / connectivity state for the one-screen UI. Mirrors the
    /// `CKAccountStatus` cases the phone can actually observe — nothing here
    /// asserts anything about the Mac (see ``endToEndConfirmed``).
    enum ConnectionState: Equatable {
        /// Querying `accountStatus` on launch.
        case checking
        /// `CKAccountStatus.available` + zone ready: the phone is signed into
        /// iCloud and can write to the shared private DB. Does NOT mean the Mac
        /// is listening — that's `endToEndConfirmed`.
        case signedIn
        /// `.noAccount` — no iCloud account on the device (surface honestly).
        case noAccount
        /// `.restricted` — iCloud is restricted (e.g. parental / MDM controls).
        case restricted
        /// `.couldNotDetermine` / `.temporarilyUnavailable`, or no CloudKit
        /// entitlement on this build. Carries an honest, human reason.
        case couldNotDetermine(String)
    }

    // MARK: - Dependencies

    /// The Halo CloudKit container identifier — the user's own private DB.
    /// Sourced from the wire type so the client and `ReachConfirmIntent` (which
    /// writes outside the client) can never address different containers.
    static let containerIdentifier = ReachMessage.containerIdentifier

    /// The container + its private database, created **lazily** inside
    /// ``start()`` rather than at init. `CKContainer(identifier:)` traps at
    /// runtime when the app's entitlements don't list the container (e.g. an
    /// unsigned simulator build with no iCloud capability applied), so building
    /// it eagerly in the initializer would crash the app before any UI renders.
    /// Deferring it lets the app come up and report `.couldNotDetermine`
    /// honestly when CloudKit isn't provisioned. On a signed device with the
    /// capability added, this is set on the first `start()`.
    private var container: CKContainer?
    private var database: CKDatabase?
    private let zoneID: CKRecordZone.ID
    private let crypto: ReachMessageCrypto

    /// Injected container for tests (a fake). When set, `start()` skips the
    /// lazy real-container creation. Production leaves it nil.
    private let injectedContainer: CKContainer?

    /// Stable subscription id so re-registering is a server-side no-op.
    private static let subscriptionID = "halo-reach-ios-zone-subscription"
    /// A VISIBLE-alert query subscription on `role == halo` records, so a reply /
    /// nudge notification reaches a suspended OR force-quit app without an app
    /// wake (the zone subscription is silent-only — iOS throttles silent pushes
    /// for suspended apps and never delivers them to a killed one). Stable id ⇒
    /// re-registering is an idempotent server-side no-op.
    private static let alertSubscriptionID = "halo-reach-ios-halo-alert"
    /// Where the persisted server change token lives between launches.
    private static let changeTokenDefaultsKey = "reach.cloudkit.ios.changeToken"
    /// Where the "we've heard back from the Mac at least once" flag lives, so a
    /// returning user who's already connected isn't re-shown the setup state.
    private static let endToEndConfirmedDefaultsKey = "reach.cloudkit.ios.endToEndConfirmed"
    /// Persisted local cache of the conversation, so history survives a relaunch
    /// without re-fetching (the token-delta `fetch()` won't re-pull seen records).
    static let messagesDefaultsKey = "reach.cloudkit.ios.messages"
    /// Persisted chat list (metadata only) + last-open chat.
    static let chatsDefaultsKey = "reach.cloudkit.ios.chats"
    static let currentThreadDefaultsKey = "reach.cloudkit.ios.currentThread"
    /// Persisted tombstones for deleted chats.
    static let deletedThreadsDefaultsKey = "reach.cloudkit.ios.deletedThreads"
    /// Bucket for pre-multi-chat records that carry no `threadID`.
    static let legacyThreadID = "legacy-main"

    /// New `halo` reply ids the caller hasn't been notified of yet — drained by
    /// ``drainNewHaloReplies()`` so the app delegate can post a local
    /// notification when backgrounded.
    private var pendingReplyNotifications: [ReachMessage] = []
    private var didEnsureZone = false

    /// The foreground sync loop. While the app is active we POLL the zone on a
    /// short cadence: the Mac's reply rides a silent `content-available` push,
    /// which iOS heavily throttles — and in the Development environment routinely
    /// delays for minutes or drops outright — so a foreground app that waits on
    /// the push alone hangs on "answering…". The poll is the reliable path; the
    /// push just gets us a head start (and wakes a backgrounded app). Cancelled
    /// when we leave the foreground.
    private var foregroundSyncTask: Task<Void, Never>?
    /// Reentrancy guard: the poll and a concurrent push-driven `fetch()` must not
    /// both be in flight, or they race the change-token advance / double-decode.
    private var isFetching = false
    /// Phone-side poll cadence while foregrounded — a touch slower than the Mac's
    /// 3s loop to stay battery-kind; still well under "feels instant" for a reply.
    static let foregroundPollInterval: TimeInterval = 4

    /// Fires if a delivered message gets no reply within `replyTimeout`, so the
    /// UI stops spinning and shows an honest stall notice (the Mac may be
    /// asleep / offline / Reach off) instead of hanging on "On it…" forever.
    /// Cancelled the instant a reply or confirm lands (via `isAwaitingReply`'s
    /// didSet).
    private var replyTimeoutTask: Task<Void, Never>?
    /// Matches the spec's ~75s "no answer yet" budget.
    static let replyTimeout: TimeInterval = 75

    /// Production: pass nothing — the real container is created lazily in
    /// ``start()``. Tests: inject a fake container.
    init(container: CKContainer? = nil, crypto: ReachMessageCrypto = .plaintext) {
        self.injectedContainer = container
        self.zoneID = CKRecordZone.ID(zoneName: ReachMessage.zoneName)
        self.crypto = crypto
        self.chats = Self.loadChats()
        self.currentThreadID = UserDefaults.standard.string(forKey: Self.currentThreadDefaultsKey)
        self.deletedThreadIDs = Self.loadDeletedThreads()
        // Restore the cached conversation up front so a chat's history is visible
        // immediately on relaunch (init assignments don't fire `didSet`, so this
        // load doesn't write back). Drop any thread the user has since deleted.
        self.messages = Self.loadMessages().filter {
            !self.deletedThreadIDs.contains($0.threadID ?? Self.legacyThreadID)
        }
    }

    // MARK: - Lifecycle

    /// Bring the client online: create the container (guarded), check the iCloud
    /// account, ensure the zone + silent-push subscription, then do an initial
    /// fetch. Safe to call again (e.g. on foreground) — every step is
    /// idempotent.
    func start() async {
        if isDemo {
            connection = .signedIn
            return
        }
        guard let container = resolveContainer() else {
            // No CloudKit entitlement applied (e.g. an unsigned build). Surface
            // it honestly instead of trapping. On a signed device with the
            // iCloud capability + the Halo container added, this path is taken.
            log.notice("Reach iOS: CloudKit container unavailable (no iCloud capability?)")
            connection = .couldNotDetermine("Add this app to your iCloud to reach your computer.")
            return
        }

        logCloudKitEnvironment()

        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            log.error("Reach iOS: account status check failed: \(error.localizedDescription, privacy: .public)")
            connection = .couldNotDetermine("I can't reach iCloud right now.")
            return
        }

        switch status {
        case .available:
            break
        case .noAccount:
            log.notice("Reach iOS: no iCloud account on this device")
            connection = .noAccount
            return
        case .restricted:
            log.notice("Reach iOS: iCloud is restricted on this device")
            connection = .restricted
            return
        case .temporarilyUnavailable, .couldNotDetermine:
            log.notice("Reach iOS: iCloud unavailable (status raw \(status.rawValue, privacy: .public))")
            connection = .couldNotDetermine("iCloud isn't available right now.")
            return
        @unknown default:
            connection = .couldNotDetermine("iCloud isn't available right now.")
            return
        }

        await ensureZoneAndSubscription()
        connection = .signedIn
        await fetch()
    }

    /// Log the build's effective CloudKit environment (Development vs
    /// Production). The two sides MUST match: a Development phone and a
    /// Production Mac silently read/write SEPARATE datastores in the same
    /// container under the same iCloud account — which looks exactly like "the
    /// Mac never answers." Logging it on each side turns that invisible split
    /// into a fact you can read in `log show`. `.notice` so it persists.
    ///
    /// We pin `com.apple.developer.icloud-container-environment = Production` in
    /// the entitlements so EVERY build (including an Xcode Run to device) hits
    /// the same Production database the notarized Mac uses. When that pin is
    /// present it is authoritative for the database; the separate
    /// `aps-environment` only governs which APNs delivers the silent push (dev
    /// on a Run build), and the 4s foreground poll + background refresh cover a
    /// push that the dev environment throttles.
    private func logCloudKitEnvironment() {
        // iOS has no public API to read the running process's own entitlements
        // (`SecTask*` is macOS-only), so read them out of the embedded
        // provisioning profile instead.
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let xmlStart = data.range(of: Data("<?xml".utf8)),
            let xmlEnd = data.range(of: Data("</plist>".utf8)),
            let plist = try? PropertyListSerialization.propertyList(
                from: Data(data[xmlStart.lowerBound..<xmlEnd.upperBound]),
                format: nil
            ) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any]
        else {
            log.notice("Reach iOS: CloudKit environment = unknown (App Store build ⇒ Production)")
            return
        }
        // The explicit pin is authoritative for which database CloudKit uses.
        if let pin = entitlements["com.apple.developer.icloud-container-environment"] as? String {
            let aps = entitlements["aps-environment"] as? String ?? "unknown"
            log.notice(
                "Reach iOS: CloudKit environment = \(pin, privacy: .public) (pinned; push APNs=\(aps, privacy: .public))"
            )
            return
        }
        // No pin → CloudKit derives it from code signing, which tracks
        // `aps-environment`: a development-signed (Run) build is Development.
        let aps = entitlements["aps-environment"] as? String ?? "unknown"
        log.notice("Reach iOS: CloudKit environment = \(aps, privacy: .public) (unpinned; derived from signing)")
    }

    /// Resolve the CloudKit container, caching it. Returns the injected fake in
    /// tests, otherwise lazily builds the real container. `CKContainer(identifier:)`
    /// traps without the matching entitlement, so this is only ever reached once
    /// `start()` runs (never at `@StateObject` init), keeping an unsigned build
    /// launchable. On a signed device the trap can't fire — the entitlement is
    /// present — so the lazy build is safe there.
    private func resolveContainer() -> CKContainer? {
        if let container { return container }
        if let injectedContainer {
            container = injectedContainer
            database = injectedContainer.privateCloudDatabase
            return injectedContainer
        }
        // `CKContainer(identifier:)` hard-traps (SIGTRAP) when the process lacks
        // the `com.apple.developer.icloud-services` entitlement. That's exactly
        // the case for an unsigned simulator build (signing off, no iCloud
        // capability applied), so constructing it there would crash the app
        // before any UI is usable. Skip it on that one configuration so the
        // app stays launchable for design / UI work; it then reports
        // `.couldNotDetermine` honestly. Every real configuration (a signed device,
        // or a signed simulator build with the iCloud capability added)
        // constructs the container normally.
        guard Self.canConstructContainer else { return nil }
        let resolved = CKContainer(identifier: Self.containerIdentifier)
        container = resolved
        database = resolved.privateCloudDatabase
        return resolved
    }

    /// False only for an unsigned DEBUG simulator build — the one configuration
    /// where `CKContainer(identifier:)` traps for lack of the entitlement. A
    /// signed simulator build (with the iCloud capability added in Xcode) opts
    /// back in with the `-reachEnableCloudKit` launch argument. Always true on
    /// device and in Release.
    private static let canConstructContainer: Bool = {
        #if targetEnvironment(simulator) && DEBUG
        return ProcessInfo.processInfo.arguments.contains("-reachEnableCloudKit")
        #else
        return true
        #endif
    }()

    /// Create the `HaloReach` zone if absent and register a silent-push zone
    /// subscription. Best-effort + idempotent: an "already exists" error is a
    /// success (we ignore it). Runs once.
    private func ensureZoneAndSubscription() async {
        guard !didEnsureZone, let database else { return }

        do {
            let zone = CKRecordZone(zoneID: zoneID)
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        } catch {
            // "Zone already exists" lands here — treat as present and move on.
            log.debug(
                "Reach iOS: ensure-zone reported \(error.localizedDescription, privacy: .public) (treating as present)"
            )
        }

        // Silent zone subscription — wakes the app to fetch + sync the whole
        // zone on any change (best-effort; throttled when suspended).
        let zoneSub = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let silent = CKSubscription.NotificationInfo()
        silent.shouldSendContentAvailable = true
        zoneSub.notificationInfo = silent

        // VISIBLE alert subscription — the "tap on the shoulder" that has to land
        // even when the app is suspended or force-quit. A `role == halo` reply or
        // nudge fires a user-visible push that CloudKit (Apple) delivers WITHOUT
        // needing the app to run, so the notification no longer depends on iOS
        // choosing to wake us for a silent push. The predicate fires ONLY for
        // Halo's own replies / proactive nudges — never the user's own sends,
        // status flips, or breadcrumbs — so there's no self-notification spam.
        // Privacy-first: the body is generic; the message text stays in iCloud
        // and is shown in-app on tap, never in the APNs payload.
        let haloSub = CKQuerySubscription(
            recordType: ReachMessage.recordType,
            predicate: NSPredicate(format: "role == %@", ReachMessage.Role.halo.rawValue),
            subscriptionID: Self.alertSubscriptionID,
            options: [.firesOnRecordCreation]
        )
        let alert = CKSubscription.NotificationInfo()
        alert.alertBody = "I've got something for you. Tap to read."
        alert.soundName = "default"
        // Let the Notification Service Extension (ADR 0040 follow-up) rewrite the
        // generic body with the actual reply text before it's shown. The body
        // stays out of the APNs payload (privacy); the NSE fetches it from the
        // user's private DB by the push's recordID. Harmless without the NSE
        // wired — iOS just shows the generic `alertBody` above.
        alert.shouldSendMutableContent = true
        haloSub.notificationInfo = alert

        do {
            _ = try await database.modifySubscriptions(saving: [zoneSub, haloSub], deleting: [])
        } catch {
            log.debug(
                "Reach iOS: ensure-subscription reported \(error.localizedDescription, privacy: .public) (treating as present)"
            )
        }

        didEnsureZone = true
    }

    // MARK: - Send

    /// Write a `role:user` `ReachMessage` for the user's typed text and append
    /// it to the conversation immediately (optimistic — it's our own record, so
    /// there's no race). Flips into the "Halo is answering…" state. Returns the
    /// sent message so callers can correlate (tests).
    @discardableResult
    func send(_ rawBody: String, image: ReachMessage.ImageAttachment? = nil) async -> ReachMessage? {
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        // A photo with no caption is a valid send (the Mac's vision turn supplies
        // a default question, ADR 0052 §6): require at least text OR an image.
        guard !body.isEmpty || image != nil else { return nil }
        if isDemo { return await sendDemo(body) }
        _ = resolveContainer()
        guard let database else {
            connection = .couldNotDetermine("Add this app to your iCloud to reach your computer.")
            return nil
        }

        // Tag the message with the active chat so the Mac can echo the thread on
        // its reply and the phone routes it back to the right chat.
        let threadID = activeThreadID()
        let message = ReachMessage(role: .user, body: body, status: .sent, threadID: threadID, image: image)
        // Optimistic insert: show the user their words (and their photo) instantly.
        // The CKAsset uploads with the record via makeRecord below; the local
        // bubble renders from the same temp file until it does.
        upsert([message])
        // First message in a fresh chat names it (a photo-only send seeds "Photo").
        ensureChat(for: threadID, titleSeed: body.isEmpty ? "Photo" : body)
        isAwaitingReply = true
        thinkingLine = nil
        // Light up the Live Activity (the iOS notch) for this turn.
        await ReachLiveActivityController.start(threadID: threadID, chatTitle: chatTitle(for: threadID))

        let record = message.makeRecord(in: zoneID, crypto: crypto)
        do {
            // Inspect the PER-RECORD result, not just the operation-level throw:
            // CloudKit reports a record-type / permission failure in `saveResults`,
            // NOT as a thrown error, so discarding it would mark a never-saved
            // message "Delivered" (it did, against Production before the schema
            // deploy). Re-throw the per-record failure into the catch below.
            let response = try await database.modifyRecords(saving: [record], deleting: [])
            if case .failure(let saveError)? = response.saveResults[record.recordID] {
                throw saveError
            }
            log.info("Reach iOS: sent user message id=\(message.id, privacy: .public)")
            markDelivered(message.id)
            // Start the wait clock + arm the 75s stall timer now that it's
            // actually on the wire.
            awaitingSince = Date()
            startReplyTimeout(awaited: message.id, threadID: threadID)
        } catch {
            log.error("Reach iOS: send failed: \(error.localizedDescription, privacy: .public)")
            isAwaitingReply = false
            // Surface the failure HONESTLY and ACTIONABLY — never a blank screen or
            // a vague "iCloud isn't available". Map the CloudKit error to a clear
            // cause + fix. A genuinely-disconnected error (signed out, no
            // permission) flips the connection state so the connect screen handles
            // it; everything else (full iCloud, offline, busy) stays IN the chat as
            // a notice row, so the conversation survives and the fix is right there.
            let failure = Self.sendFailureNotice(for: error)
            if failure.connectionLevel {
                connection = .couldNotDetermine(failure.message)
            } else {
                appendLocalNotice(failure.message)
            }
            await ReachLiveActivityController.settle(
                line: failure.liveActivityLine,
                chatTitle: chatTitle(for: threadID)
            )
        }
        return message
    }

    /// Map a CloudKit send failure to an honest, actionable message + how to route
    /// it. `connectionLevel == true` means the user genuinely isn't connected
    /// (signed out / no permission) → flip the connection state so the connect
    /// screen takes over; otherwise keep them in the chat with an inline notice so
    /// the conversation isn't lost and the fix sits right under their message.
    static func sendFailureNotice(
        for error: Error
    ) -> (message: String, connectionLevel: Bool, liveActivityLine: String) {
        guard let ck = error as? CKError else {
            return ("I couldn't send that just now. Mind trying again?", false, "Couldn't send your message.")
        }
        switch ck.code {
        case .quotaExceeded:
            return (
                "Your iCloud storage is full, so I couldn't save your message. Free up space in Settings → your name → iCloud → Manage Account Storage, then send again.",
                false,
                "Your iCloud is full — free up space."
            )
        case .notAuthenticated:
            return (
                "You're signed out of iCloud. Sign back in from Settings → your name, then try again.",
                true,
                "Sign into iCloud to reach your computer."
            )
        case .networkUnavailable, .networkFailure:
            return (
                "I can't reach iCloud right now — check your internet connection, then send again.",
                false,
                "Offline — check your connection."
            )
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return (
                "iCloud is busy at the moment. Give it a few seconds, then send again.",
                false,
                "iCloud's busy — try again shortly."
            )
        case .permissionFailure:
            return (
                "Halo doesn't have iCloud permission yet. Turn it on in Settings → your name → iCloud, then try again.",
                true,
                "Halo needs iCloud permission."
            )
        default:
            return ("I couldn't send that just now. Mind trying again?", false, "Couldn't send your message.")
        }
    }

    /// Append a LOCAL-only system notice to the current thread — never written to
    /// CloudKit, rendered as a quiet notice row — so a send failure shows up IN the
    /// conversation (with its fix) instead of blanking to the connect screen.
    private func appendLocalNotice(_ text: String) {
        let notice = ReachMessage(
            role: .system,
            body: text,
            status: .localNotice,
            threadID: activeThreadID()
        )
        upsert([notice])
    }

    // MARK: - Receive

    /// Fetch zone changes since the last token, decode them, and merge new
    /// `halo` / `system` records (and any of our own `user` echoes) into the
    /// conversation. Best-effort — a transient error skips this tick.
    ///
    /// Wired from: ``start()``, foreground, the periodic poll, and a silent push.
    func fetch() async {
        if isDemo { return }
        // Don't overlap a poll tick with a push-driven fetch (or two polls if a
        // tick ran long) — that would race the change token below.
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        _ = resolveContainer()
        guard let database else { return }
        let token = loadChangeToken()

        let changed: [CKRecord]
        let newToken: CKServerChangeToken?
        do {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            changed = result.modificationResultsByID.values.compactMap { try? $0.get().record }
            newToken = result.changeToken
        } catch let error as CKError where error.code == .changeTokenExpired {
            // The server forgot our cursor — drop it and re-fetch from scratch
            // next tick rather than getting wedged.
            log.notice("Reach iOS: change token expired, resetting")
            saveChangeToken(nil)
            return
        } catch {
            log.debug("Reach iOS: fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Only advance the cursor when the fetch actually RETURNED records.
        // Saving the token on an EMPTY fetch can skip a record that was
        // committed but not yet in the change feed (the write/fetch race) —
        // permanently, because the next fetch reads from after that record's
        // position. Holding the last record-bearing token re-queries from
        // before the race until the record propagates. (This exact bug was
        // found + fixed on the Mac side — keep both ends consistent.)
        if !changed.isEmpty {
            saveChangeToken(newToken)
        }

        let incoming =
            changed
            .compactMap { ReachMessage(record: $0, crypto: crypto) }
            // Never resurrect a deleted chat's records.
            .filter { !deletedThreadIDs.contains(threadKey(of: $0)) }
            // Drop our OWN confirm-answer control records (role:user carrying a
            // confirmToken) — they drive the Mac's staged action, they're not
            // conversation, so they must never render as a stray "yes"/"no" bubble.
            .filter { !($0.role == .user && $0.confirmToken != nil) }
        guard !incoming.isEmpty else { return }

        // Note which `halo` replies are genuinely new so we can fire a local
        // notification, and clear the "answering…" footer.
        let knownIDs = Set(messages.map(\.id))
        let freshHaloReplies = incoming.filter { $0.role == .halo && !knownIDs.contains($0.id) }
        if !freshHaloReplies.isEmpty {
            pendingReplyNotifications.append(contentsOf: freshHaloReplies)
            isAwaitingReply = false
            // A reply landed — the Mac IS responding; clear any prior stall so
            // the status climbs back to "Connected".
            lastTurnStalled = false
            // First real reply == the only honest proof the Mac is listening on
            // the same account with the toggle on. Promote to "connected" and
            // remember it so a returning user isn't demoted to the setup state.
            confirmEndToEnd()
        }
        // A `needs-confirm` prompt is ALSO the Mac responding — it's now waiting
        // on YOU, so stop the "answering…" footer and let the approve/deny card
        // take over. (An `in-progress` breadcrumb is NOT a response — those keep
        // the footer alive because the Mac is still working.)
        let freshConfirms = incoming.filter {
            $0.role == .system && $0.status == .needsConfirm && !knownIDs.contains($0.id)
        }
        if !freshConfirms.isEmpty {
            isAwaitingReply = false
            confirmEndToEnd()
        }

        log.info(
            "Reach iOS: fetch returned \(changed.count, privacy: .public) record(s) → \(incoming.count, privacy: .public) decoded → \(freshHaloReplies.count, privacy: .public) new reply(ies)"
        )
        upsert(incoming)
        // Retention: drop breadcrumbs whose turn just got its answer (or that
        // aged out), so the in-memory log doesn't accumulate dead progress lines.
        pruneBreadcrumbs()
        // Make sure every thread seen on the wire has a chat in the list (so
        // replies / legacy records show up even if the phone didn't start them).
        reconcileChats(from: incoming)
        // Reflect breadcrumbs / confirms / the reply on the Live Activity.
        await updateLiveActivity(from: incoming)
    }

    /// Drain the queue of newly arrived `halo` replies the UI hasn't surfaced as
    /// a notification yet. Called by the app delegate after a background fetch.
    func drainNewHaloReplies() -> [ReachMessage] {
        defer { pendingReplyNotifications.removeAll() }
        return pendingReplyNotifications
    }

    // MARK: - Foreground sync loop

    /// Start (or restart) the foreground poll: fetch now, then again every
    /// ``foregroundPollInterval`` seconds until cancelled. This is what makes a
    /// reply appear while you're sitting in the chat, independent of whether the
    /// silent push ever arrives. Idempotent — a second call replaces the loop.
    /// Driven by the scene becoming active.
    func beginForegroundSync() {
        guard !isDemo else { return }
        foregroundSyncTask?.cancel()
        foregroundSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetch()
                try? await Task.sleep(nanoseconds: UInt64(Self.foregroundPollInterval * 1_000_000_000))
            }
        }
    }

    /// Stop the foreground poll (the app left the foreground). Background
    /// delivery falls back to the silent zone push + the visible-alert
    /// subscription, which re-arm the poll on the next `.active`.
    func endForegroundSync() {
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
    }

    /// Arm the stall timer for a just-delivered message. If no reply lands
    /// within `replyTimeout`, append a local "couldn't reach your computer" notice
    /// (folded by id so a repeat can't double it) and drop the awaiting state
    /// so the "On it…" footer disappears. A real reply that arrives later still
    /// shows below the notice, and the notice never fires once a reply/confirm
    /// clears `isAwaitingReply`.
    private func startReplyTimeout(awaited messageID: String, threadID: String?) {
        replyTimeoutTask?.cancel()
        replyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.replyTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isAwaitingReply else { return }
            self.upsert([ReachMessage.stallNotice(for: messageID, threadID: threadID)])
            // Downgrade the connection status: we just saw the Mac fail to
            // answer within the window.
            self.lastTurnStalled = true
            self.isAwaitingReply = false
        }
    }

    /// Re-run the account check. Wired to the onboarding "Retry" button so a
    /// user who just signed into iCloud (or fixed a restriction) can re-resolve
    /// without relaunching. Resets to `.checking` first so the UI shows motion.
    func retry() async {
        connection = .checking
        await start()
    }

    // MARK: - End-to-end confirmation

    /// Mark the round-trip proven (a real `halo` reply landed) and persist it.
    /// Idempotent — once true it stays true across launches.
    private func confirmEndToEnd() {
        guard !endToEndConfirmed else { return }
        endToEndConfirmed = true
        UserDefaults.standard.set(true, forKey: Self.endToEndConfirmedDefaultsKey)
        log.info("Reach iOS: end-to-end confirmed (first reply from the Mac)")
    }

    // MARK: - Confirm answers (approve / deny a gated action)

    /// Answer a `needs-confirm` prompt from the phone. Writes a `role:user`
    /// record carrying the prompt's `confirmToken` — the marker the Mac routes to
    /// its parked staged action (run it on approve, skip on deny) instead of
    /// treating as a fresh question — plus a Y/N body. On approve we go back into
    /// "answering…" to await the outcome reply; on deny the turn is done.
    func answerConfirm(_ prompt: ReachMessage, approved: Bool) async {
        guard let token = prompt.confirmToken else { return }
        _ = resolveContainer()
        guard let database else { return }
        answeredConfirmTokens.insert(token)
        isAwaitingReply = approved

        let answer = ReachMessage(
            role: .user,
            body: approved ? "yes" : "no",
            status: .sent,
            confirmToken: token,
            threadID: prompt.threadID
        )
        let record = answer.makeRecord(in: zoneID, crypto: crypto)
        do {
            let response = try await database.modifyRecords(saving: [record], deleting: [])
            if case .failure(let saveError)? = response.saveResults[record.recordID] {
                throw saveError
            }
            log.info(
                "Reach iOS: sent confirm answer approved=\(approved, privacy: .public) token=\(token, privacy: .public)"
            )
        } catch {
            log.error("Reach iOS: confirm answer failed: \(error.localizedDescription, privacy: .public)")
            answeredConfirmTokens.remove(token)
            isAwaitingReply = false
        }
    }

    // MARK: - Chat deletion

    /// Delete a chat: drop it from the list, tombstone its thread so a later
    /// fetch / reconcile can't resurrect it, remove its messages locally, and
    /// best-effort delete the records from CloudKit so the conversation is
    /// actually gone (the tombstone covers a failed / offline removal).
    func deleteChat(_ id: String) {
        chats.removeAll { $0.id == id }
        deletedThreadIDs.insert(id)
        let goneRecordIDs =
            messages
            .filter { threadKey(of: $0) == id }
            .map { CKRecord.ID(recordName: $0.id, zoneID: zoneID) }
        messages.removeAll { threadKey(of: $0) == id }
        if currentThreadID == id {
            currentThreadID = nil
            persistCurrentThread()
        }
        persistChats()
        persistDeletedThreads()

        guard !goneRecordIDs.isEmpty else { return }
        Task { [weak self] in
            guard let self, let database = self.database else { return }
            do {
                _ = try await database.modifyRecords(saving: [], deleting: goneRecordIDs)
            } catch {
                log.debug(
                    "Reach iOS: chat delete — CloudKit removal failed, tombstoned locally: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func persistDeletedThreads() {
        UserDefaults.standard.set(Array(deletedThreadIDs), forKey: Self.deletedThreadsDefaultsKey)
    }

    static func loadDeletedThreads() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: deletedThreadsDefaultsKey) ?? [])
    }

    /// Write the conversation cache. Called from `messages`'s `didSet` on every
    /// change (demo mode excepted). Best-effort: a failed encode just skips this
    /// write — the next mutation re-attempts, and a stale cache is reconciled by
    /// `fetch()` anyway.
    private func persistMessages() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        UserDefaults.standard.set(data, forKey: Self.messagesDefaultsKey)
    }

    static func loadMessages() -> [ReachMessage] {
        guard let data = UserDefaults.standard.data(forKey: messagesDefaultsKey),
            let decoded = try? JSONDecoder().decode([ReachMessage].self, from: data)
        else { return [] }
        return decoded
    }

    // MARK: - Conversation merge

    /// Merge `incoming` into `messages` by id (so re-fetched records update in
    /// place rather than duplicate), then keep the log time-ordered. The Mac's
    /// server `creationDate` is the tiebreak via `createdAt` (mapping handles
    /// the fallback).
    private func upsert(_ incoming: [ReachMessage]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in incoming {
            byID[message.id] = message
        }
        messages = byID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    /// Locally mark our own sent message `delivered` once the save returns
    /// (CloudKit accepted it). Halo flips it to `answered` server-side after it
    /// runs the turn; we'll pick that up on the next fetch.
    private func markDelivered(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        var updated = messages[index]
        guard updated.status == .sent else { return }
        updated.status = .delivered
        messages[index] = updated
    }

    // MARK: - Change-token persistence

    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.changeTokenDefaultsKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        )
    }

    private func saveChangeToken(_ token: CKServerChangeToken?) {
        guard let token else {
            UserDefaults.standard.removeObject(forKey: Self.changeTokenDefaultsKey)
            return
        }
        guard
            let data = try? NSKeyedArchiver.archivedData(
                withRootObject: token,
                requiringSecureCoding: true
            )
        else { return }
        UserDefaults.standard.set(data, forKey: Self.changeTokenDefaultsKey)
    }

    // MARK: - Local erasure

    /// Wipe every trace of the conversation from this device — the in-memory
    /// state the chat UI is bound to and all on-disk caches. Called when the
    /// account is deleted (App Store guideline 5.1.1(v)) so nothing lingers
    /// locally after erasure, and to simulate deletion for the offline App
    /// Review demo, which has no server account to delete.
    func purgeLocalData() {
        // In-memory state the UI renders.
        messages = []
        chats = []
        currentThreadID = nil
        deepLinkThread = nil
        thinkingLine = nil
        answeredConfirmTokens = []
        deletedThreadIDs = []
        endToEndConfirmed = false
        isAwaitingReply = false
        isDemo = false

        // On-disk caches.
        let defaults = UserDefaults.standard
        for key in [
            Self.messagesDefaultsKey,
            Self.chatsDefaultsKey,
            Self.currentThreadDefaultsKey,
            Self.deletedThreadsDefaultsKey,
            Self.changeTokenDefaultsKey,
            Self.endToEndConfirmedDefaultsKey,
        ] {
            defaults.removeObject(forKey: key)
        }
        log.notice("Purged local Reach data")
    }

    // MARK: - App Review demo mode
    //
    // A self-contained demo for App Review, turned on only when the user signs
    // in with the demo email (`HaloAccount.enterDemoMode`, bridged in
    // `HaloiOSApp`). Reach is normally answered on the user's paired Mac, which a
    // reviewer can't replicate — so the demo skips CloudKit entirely and gets
    // REAL answers from the public demo endpoint (`POST /v1/reach/demo-chat`),
    // falling back to a warm canned line if it's unreachable. Disclosed in the
    // App Store review notes; nothing here touches a real account or anyone's
    // iCloud.

    /// Switch the client into the offline demo: a connected-looking state and a
    /// seeded welcome thread. Idempotent.
    func enableDemoMode() {
        guard !isDemo else { return }
        isDemo = true
        connection = .signedIn
        endToEndConfirmed = true
        let threadID = "demo-thread"
        deletedThreadIDs.remove(threadID)
        currentThreadID = threadID
        ensureChat(for: threadID, titleSeed: "Welcome to Halo")
        upsert([
            ReachMessage(
                role: .halo,
                body:
                    "Hi! This is a live demo of Halo. Ask me anything and I'll answer right here, the same way I would from your computer.",
                status: .answered,
                threadID: threadID
            )
        ])
    }

    /// Demo send: optimistic user insert, then a REAL reply from the public
    /// demo endpoint so a reviewer gets a genuine answer with no paired Mac.
    /// Mirrors the real `send` shape so the UI behaves identically.
    private func sendDemo(_ body: String) async -> ReachMessage? {
        let threadID = activeThreadID()
        let message = ReachMessage(role: .user, body: body, status: .delivered, threadID: threadID)
        upsert([message])
        ensureChat(for: threadID, titleSeed: body)
        isAwaitingReply = true
        thinkingLine = "Thinking…"

        let reply = await Self.fetchDemoReply(for: body)
        guard isDemo else { return message }

        upsert([
            ReachMessage(
                role: .halo,
                body: reply,
                status: .answered,
                threadID: threadID
            )
        ])
        isAwaitingReply = false
        thinkingLine = nil
        return message
    }

    /// Ask the public demo endpoint (`POST /v1/reach/demo-chat`) for a real
    /// model answer. No auth and no CloudKit — it exists so App Review can test
    /// with genuine responses. Returns a warm fallback line on any network /
    /// parse failure so the demo never dead-ends.
    private static func fetchDemoReply(for prompt: String) async -> String {
        var req = URLRequest(
            url: HaloAccount.baseURL.appendingPathComponent("v1/reach/demo-chat")
        )
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("HaloiOS", forHTTPHeaderField: "x-halo-client")
        req.timeoutInterval = 30
        // Clamp to the endpoint's message cap so an over-long prompt gets a real
        // answer rather than a 400 → fallback.
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["message": String(prompt.prefix(500))]
        )
        struct DemoResponse: Decodable { let reply: String? }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status),
                let decoded = try? JSONDecoder().decode(DemoResponse.self, from: data),
                let reply = decoded.reply?.trimmingCharacters(in: .whitespacesAndNewlines),
                !reply.isEmpty
            else {
                return demoFallbackReply
            }
            return reply
        } catch {
            return demoFallbackReply
        }
    }

    /// Shown only when the demo endpoint can't be reached.
    private static let demoFallbackReply =
        "I couldn't reach my brain for this demo just now. On your own computer I answer straight from what I remember — please try again in a moment."
}
