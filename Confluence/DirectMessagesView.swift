import SwiftUI
import ConfluenceKit

/// Unified DM inbox (F15): conversations across both networks, most-recent first. Tap one to open
/// its thread. Mastodon conversations are flagged not-private.
struct DirectMessagesView: View {
    @Environment(DMStore.self) private var dms
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Conversation?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The app-password DM-scope hint only applies to app-password sessions; under OAuth
                // a chat failure is a scope/other issue, not a missing DM app password.
                if dms.failedNetworks.contains(.bluesky) && !bluesky.isOAuth { blueskyChatHint }
                if dms.conversations.isEmpty {
                    ContentUnavailableView("No Messages", systemImage: "envelope",
                        description: Text(dms.isLoading
                            ? "Loading…"
                            : "Your Bluesky and Mastodon direct messages will appear here."))
                        .frame(maxHeight: .infinity)
                } else {
                    List(dms.conversations) { convo in
                        Button { selected = convo } label: { ConversationRow(conversation: convo) }
                            .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Messages")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(item: $selected) { ConversationView(conversation: $0) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .task { await dms.refresh() }
    }

    /// Bluesky's chat service needs an app password with DM access — a normal one gets rejected.
    /// Surface that as guidance rather than a bare failure (SPEC F15).
    private var blueskyChatHint: some View {
        Label("Bluesky messages need an app password with **direct-message access**. Create one at bsky.app → Settings → App Passwords (tick \u{201C}Allow access to your direct messages\u{201D}) and sign in again.",
              systemImage: "lock.badge.exclamationmark")
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.yellow.opacity(0.12))
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: conversation.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(conversation.title).fontWeight(.semibold).lineLimit(1)
                    if conversation.unread { Circle().fill(.tint).frame(width: 8, height: 8) }
                    Spacer(minLength: 4)
                    NetworkTag(network: conversation.network)
                    Text(conversation.lastActivity, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !conversation.lastSnippet.isEmpty {
                    Text(conversation.lastSnippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if !conversation.isPrivate {
                    Label("Not private", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.title)\(conversation.unread ? ", unread" : ""). \(conversation.network == .bluesky ? "Bluesky" : "Mastodon").")
    }
}

/// Small per-network chip, matching the notifications badge styling.
struct NetworkTag: View {
    let network: Network
    var body: some View {
        let bsky = network == .bluesky
        Text(bsky ? "Bluesky" : "Mastodon")
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((bsky ? Color.blue : Color.purple).opacity(0.15), in: Capsule())
            .foregroundStyle(bsky ? Color.blue : Color.purple)
    }
}
