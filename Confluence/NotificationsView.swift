import SwiftUI
import ConfluenceKit

struct NotificationsView: View {
    @Environment(NotificationStore.self) private var notifications
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if notifications.items.isEmpty {
                ContentUnavailableView("No Notifications", systemImage: "bell",
                                       description: Text("Follows, mentions, and reposts will appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(notifications.items) { item in
                    NotificationRow(item: item)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 380, minHeight: 480)
        .onAppear { notifications.markSeen() }
    }
}

private struct NotificationRow: View {
    let item: NotificationItem

    private var icon: String {
        switch item.kind {
        case .follow: "person.badge.plus"
        case .mention: "at"
        case .repost: "arrow.2.squarepath"
        }
    }
    private var actionText: String {
        switch item.kind {
        case .follow: "followed you"
        case .mention: "mentioned you"
        case .repost: "reposted"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Avatar(url: item.avatarURL, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.actorName).fontWeight(.semibold).lineLimit(1)
                    Text(actionText).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    networkBadge
                    Text(item.createdAt, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !item.snippet.isEmpty {
                    Text(item.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.actorName) \(actionText) on \(item.network == .bluesky ? "Bluesky" : "Mastodon"). \(item.snippet)")
    }

    private var networkBadge: some View {
        let isBluesky = item.network == .bluesky
        return Text(isBluesky ? "Bluesky" : "Mastodon")
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((isBluesky ? Color.blue : Color.purple).opacity(0.15), in: Capsule())
            .foregroundStyle(isBluesky ? Color.blue : Color.purple)
    }
}
