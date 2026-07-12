// SPDX-License-Identifier: Apache-2.0
import HaloReachKit
import PhotosUI
import SwiftUI
import UIKit

/// The one screen (spec §7): a flat, time-ordered conversation with your computer's
/// Halo. User bubbles trail right, Halo bubbles lead left, a `needs-confirm`
/// prompt renders as a card, and the footer shows the honest delivery state.
///
/// Access is gated upstream at the app root (the login gate + the
/// `/v1/account/me` entitlement check, ADR 0037 slice D), so by the time this
/// view is on screen the user is signed in and entitled.
struct ChatView: View {
    @EnvironmentObject private var reach: ReachCloudKitClient
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    /// The photo the user picked to attach, if any (ADR 0052 slice 1). The
    /// preview renders `pendingImage`; the send encodes from `pendingData` off
    /// the main actor (Data is Sendable, UIImage is not).
    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var pendingData: Data?

    /// The chat to show. Set on appear so the client filters to this thread even
    /// when navigated back to (ADR 0037 §15).
    var threadID: String?

    var body: some View {
        ZStack {
            HaloiOSStyle.canvas

            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.06))
                conversation
                composer
            }
        }
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Keep iOS's edge swipe-back even though the system back button is hidden.
        .background(EnableSwipeBack())
        .onAppear { if let threadID { reach.selectChat(threadID) } }
        .onChange(of: reach.connection) { _, _ in }  // re-render on state change
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(HaloiOSStyle.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to chats")

            HaloPresenceMark(isThinking: reach.isAwaitingReply, diameter: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(chatTitle)
                    .font(HaloiOSStyle.title)
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                    .lineLimit(1)
                if !connectionSubtitle.isEmpty {
                    Text(connectionSubtitle)
                        .font(HaloiOSStyle.caption)
                        .foregroundStyle(HaloiOSStyle.textSecondary)
                }
            }
            Spacer()
            connectionIndicator
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The open chat's title (falls back to "Halo" before it's named).
    private var chatTitle: String {
        guard let tid = reach.currentThreadID,
            let chat = reach.chats.first(where: { $0.id == tid }),
            chat.title != ReachChat.defaultTitle
        else { return "Halo" }
        return chat.title
    }

    /// The small dot + label that reflects the honest connection state:
    /// signed-in / connected-after-first-reply / not-signed-in. Reads from the
    /// shared ``ConnectionStatusDescriptor`` so it can never disagree with the
    /// onboarding copy.
    private var connectionIndicator: some View {
        let status = ConnectionStatusDescriptor(
            connection: reach.connection,
            endToEndConfirmed: reach.endToEndConfirmed,
            recentStall: reach.lastTurnStalled
        )
        return HStack(spacing: 6) {
            ConnectionDot(status: status)
            Text(status.headerLabel)
                .font(HaloiOSStyle.caption)
                .foregroundStyle(HaloiOSStyle.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color.white.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(status.headerLabel)")
    }

    private var connectionSubtitle: String {
        switch reach.connection {
        case .checking:
            return "Connecting you to your computer…"
        case .signedIn:
            if reach.isAwaitingReply { return reach.thinkingLine ?? "On it…" }
            // Once the round-trip is confirmed, the "Connected" pill says it all —
            // no subtitle. Only nudge when the toggle still needs turning on.
            return reach.endToEndConfirmed
                ? ""
                : "Turn on the toggle on your computer, then say hi"
        case .noAccount:
            return "Sign into iCloud to reach your computer"
        case .restricted:
            return "iCloud is restricted on this iPhone"
        case .couldNotDetermine(let message):
            return message
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if reach.currentMessages.isEmpty {
                        emptyState
                    }
                    ForEach(reach.currentMessages) { message in
                        row(for: message)
                            .id(message.id)
                    }
                    if reach.isAwaitingReply {
                        workingRow
                            .id(Self.answeringRowID)
                    }
                    // The stall is now a PERSISTED `NoticeRow` inside
                    // `currentMessages` (appended on timeout), not a transient
                    // banner — so it scrolls with history and survives
                    // backgrounding, and a late reply lands beneath it.
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .onChange(of: reach.currentMessages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: reach.isAwaitingReply) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    @ViewBuilder
    private func row(for message: ReachMessage) -> some View {
        switch message.role {
        case .user, .halo:
            MessageBubble(message: message)
        case .system:
            // A `system` record is one of three things, in priority order:
            //  • a live breadcrumb the Mac is publishing this turn → dim bubble,
            //  • a local-only stall note → quiet notice row, else
            //  • a real `needs-confirm` tool prompt → approve/deny card.
            if message.status == .inProgress {
                // The live breadcrumb is surfaced by `workingRow` as one updating
                // activity line (Jarvis-style), not a pile of inline rows.
                EmptyView()
            } else if message.isLocalNotice {
                NoticeRow(message: message)
            } else {
                ConfirmCard(message: message)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            HaloPresenceMark(isThinking: false, diameter: 56)
                .padding(.bottom, 4)
            Text("Text me anything")
                .font(HaloiOSStyle.bodyEmphasis)
                .foregroundStyle(HaloiOSStyle.textPrimary)
            Text(
                "I'm on your computer. Ask me to recall something, draft a note, or check on your day. I answer from what I remember, and this never leaves your iCloud."
            )
            .font(HaloiOSStyle.body)
            .foregroundStyle(HaloiOSStyle.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// The live "Halo is doing something" row — a breathing mark beside the
    /// CURRENT activity. It shows the Mac's live breadcrumb when there is one
    /// ("Checking your calendar…", "Reading the thread…") and a confident
    /// first-person opener otherwise, so the wait always reads as Halo *working*,
    /// never a delivery receipt or a dead spinner. Jarvis, not a chat app.
    private var workingRow: some View {
        HStack(spacing: 10) {
            HaloPresenceMark(isThinking: true, diameter: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(reach.thinkingLine ?? "On it…")
                    .font(HaloiOSStyle.body)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: HaloiOSStyle.bubbleRadius, style: .continuous)
                            .fill(HaloiOSStyle.haloBubble)
                    )
                if let since = reach.awaitingSince {
                    waitingHint(since: since)
                }
            }
            Spacer(minLength: 48)
        }
        .animation(.easeInOut(duration: 0.25), value: reach.thinkingLine)
    }

    /// After ~10s of waiting, surface the elapsed seconds + a manual "Retry"
    /// that forces a fetch — so a user who suspects a dropped push has an out
    /// well before the 75s stall notice. Live-ticks via TimelineView, so there's
    /// no stored timer to leak, and it vanishes the moment the reply lands.
    @ViewBuilder
    private func waitingHint(since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(since))
            if elapsed >= 10 {
                HStack(spacing: 8) {
                    Text("Waiting \(elapsed)s…")
                        .font(HaloiOSStyle.caption)
                        .foregroundStyle(HaloiOSStyle.textSecondary)
                    Button("Retry") { Task { await reach.fetch() } }
                        .buttonStyle(.plain)
                        .font(HaloiOSStyle.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(HaloiOSStyle.accent)
                }
                .padding(.leading, 4)
                .transition(.opacity)
            }
        }
    }

    private static let answeringRowID = "halo-answering-row"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // While awaiting, ride the presence row; otherwise pin to the last real
        // message (which, after a timeout, is the persisted stall `NoticeRow`).
        let target =
            reach.isAwaitingReply
            ? Self.answeringRowID
            : reach.currentMessages.last?.id
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let pendingImage {
                pendingImagePreview(pendingImage)
            }
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(HaloiOSStyle.textSecondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach a photo")

                TextField("Message Halo", text: $draft, axis: .vertical)
                    .font(HaloiOSStyle.body)
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                    .tint(HaloiOSStyle.accent)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                    .onSubmit(sendDraft)

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canSend ? Color.black : HaloiOSStyle.textSecondary)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle().fill(canSend ? HaloiOSStyle.accent : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.6))
        .onChange(of: pickerItem) { _, newItem in
            Task { await loadPickedImage(newItem) }
        }
    }

    /// The attached-photo chip above the composer, with a remove button.
    private func pendingImagePreview(_ image: UIImage) -> some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    clearPendingImage()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove photo")
            }
            Spacer()
        }
    }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || pendingData != nil) && reach.connection == .signedIn
    }

    private func loadPickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
            let image = UIImage(data: data)
        else { return }
        pendingData = data
        pendingImage = image
    }

    private func clearPendingImage() {
        pendingImage = nil
        pendingData = nil
        pickerItem = nil
    }

    private func sendDraft() {
        let body = draft
        let data = pendingData
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || data != nil else { return }
        draft = ""
        clearPendingImage()
        Task {
            // Downscale + JPEG-encode off the main actor (Data is Sendable).
            var attachment: ReachMessage.ImageAttachment?
            if let data {
                attachment = await Task.detached(priority: .userInitiated) {
                    ReachImageEncoder.makeAttachment(from: data)
                }.value
            }
            await reach.send(body, image: attachment)
        }
    }
}

/// A persisted, quiet system notice inside the thread (today: the "couldn't
/// reach your computer" stall record). Mirrors the look of the transient `stalledRow`
/// — moon icon + soft glass pill — but it's a real, scrolling history row that a
/// later reply lands beneath rather than a banner that vanishes.
private struct NoticeRow: View {
    let message: ReachMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(HaloiOSStyle.attention)
                .padding(.top, 3)
            Text(message.body)
                .font(HaloiOSStyle.body)
                .foregroundStyle(HaloiOSStyle.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: HaloiOSStyle.bubbleRadius, style: .continuous)
                        .fill(HaloiOSStyle.haloBubble)
                )
            Spacer(minLength: 36)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Halo: \(message.body)")
    }
}
