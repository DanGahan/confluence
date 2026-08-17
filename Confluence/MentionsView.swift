import SwiftUI
import ConfluenceKit

/// Mentions-only view over the notification stream, filterable by network (#197). Shares
/// NotificationStore data (`.mention` kind) and NotificationRow with NotificationsView, so
/// there's no extra fetching — it's a lens on what the bell already loads.
struct MentionsView: View {
    @Environment(NotificationStore.self) private var notifications
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(\.dismiss) private var dismiss
    @State private var networkFilter: FeedFilter = .both

    private var bothConnected: Bool { bluesky.isLoggedIn && mastodon.isLoggedIn }

    private var mentions: [NotificationItem] {
        let network: Network? = switch networkFilter {
        case .both: nil
        case .bluesky: .bluesky
        case .mastodon: .mastodon
        }
        return notifications.items.mentions(network: network)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mentions").font(.headline)
                Spacer()
                if bothConnected { filterMenu }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if mentions.isEmpty {
                ContentUnavailableView("No Mentions", systemImage: "at",
                                       description: Text("When someone mentions you on Bluesky or Mastodon, it’ll appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(mentions) { NotificationRow(item: $0) }
                    .listStyle(.inset)
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
        // Same profile-link routing as the other post surfaces.
        .handleProfileLinks()
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $networkFilter) {
                Label("Both Networks", systemImage: "person.2").tag(FeedFilter.both)
                Label("Bluesky", systemImage: "person").tag(FeedFilter.bluesky)
                Label("Mastodon", systemImage: "person").tag(FeedFilter.mastodon)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: networkFilter == .both ? "person.2" : "person")
        }
        .accessibilityLabel("Filter mentions by network")
    }
}
