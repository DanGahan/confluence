import SwiftUI
import ConfluenceKit

/// Which view fills the left (secondary) column when the Duo is unfolded in landscape.
enum DuoSecondaryPanel: String, CaseIterable {
    case dms = "dms"
    case search = "search"
    case blueskyFeed = "bluesky"
    case mastodonFeed = "mastodon"

    var label: String {
        switch self {
        case .dms: "Messages"
        case .search: "Search"
        case .blueskyFeed: "Bluesky Feed"
        case .mastodonFeed: "Mastodon Feed"
        }
    }

    var systemImage: String {
        switch self {
        case .dms: "envelope"
        case .search: "magnifyingglass"
        case .blueskyFeed: "bubble.left"
        case .mastodonFeed: "tusk"
        }
    }
}

/// Adaptive root for iOS: regular horizontal + compact vertical (Duo unfolded in landscape, or
/// Plus/Max in landscape) renders a 50/50 split with the primary feed on the right and a
/// configurable secondary panel on the left. Portrait on the Duo inner screen gives regular H +
/// regular V and correctly falls through to single-column. iPad and macOS are unaffected.
///
/// GeometryReader + ignoresSafeArea(.container, .horizontal) ensures the Divider aligns with
/// the physical crease regardless of safe-area insets on either side.
struct DuoLayout: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @AppStorage("duo.secondaryPanel") private var panel: DuoSecondaryPanel = .dms

    var body: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone,
           horizontalSizeClass == .regular,
           verticalSizeClass == .compact {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    DuoSecondaryPanelView(panel: panel)
                        .frame(width: geo.size.width / 2)
                    Divider()
                    FeedView()
                        .frame(width: geo.size.width / 2)
                }
            }
            .ignoresSafeArea(.container, edges: .horizontal)
        } else {
            FeedView()
        }
        #else
        FeedView()
        #endif
    }
}

// MARK: - Secondary panel (iOS only — macOS DuoLayout body never reaches these)

#if os(iOS)
private struct DuoSecondaryPanelView: View {
    let panel: DuoSecondaryPanel

    var body: some View {
        switch panel {
        case .dms:
            NavigationStack { DirectMessagesView(isInline: true) }
        case .search:
            NavigationStack { SearchView(isInline: true) }
        case .blueskyFeed:
            DuoFilteredFeedView(network: .bluesky)
        case .mastodonFeed:
            DuoFilteredFeedView(network: .mastodon)
        }
    }
}

// MARK: - Filtered feed panel

/// Single-network feed for the Duo left column. Owns its FeedStore so the main feed
/// in the right column is unaffected. Action stores (PostActionStore, FollowStore) are
/// shared via the environment and wired by FeedView's task.
private struct DuoFilteredFeedView: View {
    let network: Network
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(PostActionStore.self) private var postActions
    @State private var feed = FeedStore()
    @State private var topID: String?

    private var accountsKey: String {
        "\(bluesky.currentDID ?? "-")|\(mastodon.session?.host ?? "-")"
    }

    private var networkName: String { network == .bluesky ? "Bluesky" : "Mastodon" }

    private var isConnected: Bool {
        network == .bluesky ? bluesky.isLoggedIn : mastodon.session != nil
    }

    private var visibleItems: [FeedItem] {
        feed.combinedVisible.filter { !postActions.isDeleted($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isConnected {
                    ContentUnavailableView(
                        "No \(networkName) Account",
                        systemImage: "person.crop.circle.badge.xmark",
                        description: Text("Sign in to \(networkName) in Settings to see this feed.")
                    )
                } else {
                    feedContent
                }
            }
            .navigationTitle(networkName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var feedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !feed.failedNetworks.isEmpty {
                    Label("Couldn't refresh \(networkName). Showing what loaded.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal).padding(.top, 8)
                }
                ForEach(visibleItems) { item in
                    FeedRow(item: item)
                        .padding(.horizontal).padding(.vertical, 8)
                    Divider()
                }
                if feed.hasMore(for: network) && !visibleItems.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
                }
                Color.clear.frame(height: 72)
            }
            .scrollTargetLayout()
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $topID, anchor: .top)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height + 1200 >= geo.contentSize.height
        } action: { _, nearBottom in
            if nearBottom { Task { await feed.loadMore(preferring: network) } }
        }
        .refreshable { await feed.refresh() }
        .overlay {
            if visibleItems.isEmpty {
                if feed.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Posts Yet", systemImage: "tray",
                        description: Text("Pull down to refresh."))
                }
            }
        }
        .task(id: accountsKey) {
            let wiring = FeedWiring(bluesky: bluesky, mastodon: mastodon)
            if let fetcher = wiring.pageFetchers()[network] {
                feed.setFetchers([network: fetcher])
            }
            await feed.refresh()
        }
        .handleProfileLinks()
    }
}
#endif
