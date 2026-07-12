// SPDX-License-Identifier: Apache-2.0
import Foundation
import HaloReachKit

// MARK: - Local-only notices (never written to CloudKit)
//
// Phone-only helpers on the shared `ReachMessage` wire type (ADR 0052 slice 0
// keeps the shared contract free of phone-only concerns, so these live here and
// not in HaloReachKit). The `.localNotice` status itself is part of the shared
// enum (it is forward-safe on the wire); only the minting helpers are iOS-side.

extension ReachMessage {
    /// Prefix for the id of a local-only notice (a stall note). A real CloudKit
    /// record is a UUID, so this prefix can never collide with one on the wire,
    /// which is what keeps the notice from being clobbered or duplicated by a
    /// later fetch's `upsert`.
    static let localNoticeIDPrefix = "local-notice-"

    /// True for a phone-authored, CloudKit-free notice (the stall record).
    var isLocalNotice: Bool { status == .localNotice }

    /// Build a local-only "couldn't reach your computer" stall note for a turn. It is
    /// appended to the thread so the stall is part of the visible history (a late
    /// reply lands *below* it rather than erasing it). `awaitedMessageID` is the
    /// user message we're still waiting on, folded into the id so a repeated
    /// stall for the same pending message can't add a second note.
    static func stallNotice(
        for awaitedMessageID: String,
        threadID: String?,
        createdAt: Date = Date()
    ) -> ReachMessage {
        ReachMessage(
            id: localNoticeIDPrefix + awaitedMessageID,
            role: .system,
            body: "Couldn't reach your computer — it may be asleep. I'll deliver this when it's back.",
            createdAt: createdAt,
            status: .localNotice,
            replyTo: awaitedMessageID,
            threadID: threadID
        )
    }
}
