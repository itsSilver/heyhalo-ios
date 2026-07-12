// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The home screen once you're in: your chats, newest-active first, with a New
/// chat action and the Account entry (ADR 0037 §15). Each row opens a
/// thread-scoped ``ChatView``.
struct ChatListView: View {
    @EnvironmentObject private var reach: ReachCloudKitClient
    @State private var path: [String] = []
    @State private var showAccount = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                HaloiOSStyle.canvas
                content
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { threadID in
                ChatView(threadID: threadID)
            }
            .sheet(isPresented: $showAccount) { AccountView() }
            .onChange(of: reach.deepLinkThread) { _, id in routeDeepLink(id) }
            .onAppear { routeDeepLink(reach.deepLinkThread) }
        }
        .preferredColorScheme(.dark)
    }

    /// Push a thread opened from an island / Live Activity tap, de-duping if
    /// it's already on top, then clear the signal so it only fires once.
    private func routeDeepLink(_ id: String?) {
        guard let id else { return }
        if path.last != id { path.append(id) }
        reach.deepLinkThread = nil
    }

    @ViewBuilder
    private var content: some View {
        if reach.orderedChats.isEmpty {
            emptyState
        } else {
            List {
                ForEach(reach.orderedChats) { summary in
                    // A Button (not a NavigationLink) drives the path so the List
                    // doesn't add its own trailing disclosure chevron on top of
                    // the one inside the card. Navigation still flows through
                    // `navigationDestination(for: String.self)`.
                    Button {
                        path.append(summary.chat.id)
                    } label: {
                        chatRow(summary)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            withAnimation { reach.deleteChat(summary.chat.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func chatRow(_ summary: ReachCloudKitClient.ChatSummary) -> some View {
        HStack(spacing: 12) {
            HaloPresenceMark(isThinking: false, diameter: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.chat.title)
                    .font(HaloiOSStyle.bodyEmphasis)
                    .foregroundStyle(HaloiOSStyle.textPrimary)
                    .lineLimit(1)
                Text(summary.preview)
                    .font(HaloiOSStyle.caption)
                    .foregroundStyle(HaloiOSStyle.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HaloiOSStyle.textSecondary.opacity(0.6))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloiOSStyle.cardRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            HaloPresenceMark(isThinking: false, diameter: 72)
            Text("No chats yet")
                .font(HaloiOSStyle.title)
                .foregroundStyle(HaloiOSStyle.textPrimary)
            Text("Start a chat and text Halo on your computer from right here.")
                .font(HaloiOSStyle.body)
                .foregroundStyle(HaloiOSStyle.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: startNewChat) {
                Text("Start a chat")
                    .font(HaloiOSStyle.bodyEmphasis)
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(HaloiOSStyle.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showAccount = true
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(HaloiOSStyle.textSecondary)
            }
            .accessibilityLabel("Account")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: startNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(HaloiOSStyle.accent)
            }
            .accessibilityLabel("New chat")
        }
    }

    private func startNewChat() {
        let id = reach.newChat()
        path.append(id)
    }
}
