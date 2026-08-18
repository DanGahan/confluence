import SwiftUI
import ConfluenceKit

/// Which of the signed-in accounts' own posts to show (#127).
enum OwnFeedScope: String, Identifiable, CaseIterable, Hashable {
    case combined, bluesky, mastodon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .combined: "Combined"
        case .bluesky: "Bluesky"
        case .mastodon: "Mastodon"
        }
    }

    /// Which scopes make sense given who's signed in: a per-network scope needs that network;
    /// Combined needs at least one.
    static func available(bluesky: Bool, mastodon: Bool) -> Set<OwnFeedScope> {
        var scopes: Set<OwnFeedScope> = []
        if bluesky { scopes.insert(.bluesky) }
        if mastodon { scopes.insert(.mastodon) }
        if !scopes.isEmpty { scopes.insert(.combined) }
        return scopes
    }
}

/// A sheet of the signed-in user's own posts, per scope. Fetches from the author feeds instead
/// of the home timelines, then reuses the standard feed row + mergeFeeds.
struct OwnFeedView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(\.dismiss) private var dismiss
    let scope: OwnFeedScope

    @State private var posts: [FeedItem] = []
    @State private var loading = true

    private let contentWidth: CGFloat = 448

    var body: some View {
        NavigationStack {
            Group {
                if !posts.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(posts) { post in
                                FeedRow(item: post).padding(.horizontal).padding(.vertical, 8)
                                Divider()
                            }
                        }
                        .frame(maxWidth: contentWidth, alignment: .leading)
                        .padding(16)
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Posts", systemImage: "square.and.pencil")
                }
            }
            .navigationTitle("My Posts — \(scope.title)")
        }
        #if os(macOS)
        .frame(width: contentWidth + 32, height: 620) // macOS sheet size; iOS fills the sheet
        #endif
        .overlay(alignment: .topLeading) { SheetCloseButton { dismiss() }.padding(12) }
        .handleProfileLinks()
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var groups: [[FeedItem]] = []
        if scope != .mastodon, bluesky.isLoggedIn {
            let items = try? await bluesky.withAuth { auth, did in try await BlueskyClient().authorFeed(auth: auth, actor: did, cursor: nil).items }
            groups.append(items ?? [])
        }
        if scope != .bluesky, let session = mastodon.session {
            let client = MastodonClient()
            // Mastodon needs the account id — fetch the signed-in account first.
            if let me = try? await client.currentAccount(host: session.host, accessToken: session.accessToken),
               let items = try? await client.accountStatuses(host: session.host, accessToken: session.accessToken, accountID: me.authorID, maxId: nil).items {
                groups.append(items)
            }
        }
        posts = mergeFeeds(groups)
    }
}
