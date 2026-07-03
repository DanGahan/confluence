import SwiftUI
import ConfluenceKit

struct FeedView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(FollowStore.self) private var follows
    @Environment(NotificationStore.self) private var notifications
    @Environment(SearchStore.self) private var search
    @Environment(ComposerStore.self) private var composer
    @Environment(\.scenePhase) private var scenePhase
    @State private var feed = FeedStore()
    @State private var showingBlueskyLogin = false
    @State private var showingMastodonLogin = false
    @State private var showingNotifications = false
    @State private var showingSearch = false
    @State private var showingComposer = false
    @State private var topID: String?
    @State private var didRestore = false
    @State private var saveTask: Task<Void, Never>?
    private let position = FeedPositionStore()

    private var accountsKey: String {
        "\(bluesky.session?.did ?? "-")|\(mastodon.session?.host ?? "-")"
    }

    private var isScrolledAway: Bool {
        guard let topID, let first = feed.items.first else { return false }
        return topID != first.id
    }

    private func scrollToTop() {
        guard let first = feed.items.first else { return }
        withAnimation { topID = first.id }
        Task { await feed.refresh() } // fresh-content check once at top
    }

    private var refreshAction: () -> Void { { Task { await feed.refresh() } } }

    // ScrollView + LazyVStack + scrollTargetLayout: List doesn't report the top
    // visible id via .scrollPosition on macOS, which F6 (position save) needs.
    private var feedScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !feed.failedNetworks.isEmpty {
                    failureBanner.padding(.horizontal).padding(.top, 8)
                }
                ForEach(feed.items) { item in
                    FeedRow(item: item)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    Divider()
                }
                if feed.hasMore && !feed.items.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 600)          // cap reading width
            .frame(maxWidth: .infinity)    // center the column when the window is wider
        }
        .scrollPosition(id: $topID, anchor: .top)
        .onChange(of: topID) { _, newID in scheduleSave(newID) }
        .onScrollGeometryChange(for: Bool.self) { geo in
            // Near the bottom: within ~1200pt of the end.
            geo.contentOffset.y + geo.containerSize.height + 1200 >= geo.contentSize.height
        } action: { _, nearBottom in
            if nearBottom { Task { await feed.loadMore() } }
        }
    }

    private func scheduleSave(_ id: String?) {
        // Debounce: save the topmost visible post's id after scrolling settles.
        guard let id else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            position.save(itemID: id)
        }
    }

    var body: some View {
        feedScroll
        .overlay {
            if feed.items.isEmpty {
                if feed.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Posts Yet", systemImage: "tray", description: Text("Pull down to refresh."))
                }
            }
        }
        .task(id: accountsKey) {
            feed.setFetchers(makeFetchers())
            follows.setActions(makeFollowActions())
            notifications.setFetchers(makeNotificationFetchers())
            search.setFetchers(makeSearchFetchers())
            await configureComposer()
            await feed.refresh()
            await restoreScrollPosition()
            await notifications.refresh()
            // Poll while this window is frontmost (task is cancelled when accounts change).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                if scenePhase == .active { await notifications.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notifications.refresh() } }
        }
        .focusedSceneValue(\.refreshFeed, refreshAction)
        .focusedSceneValue(\.scrollFeedToTop, scrollToTop)
        .focusedSceneValue(\.newPost) { showingComposer = true }
        .overlay(alignment: .bottom) { followToast }
        .toolbar { feedToolbar }
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
        .sheet(isPresented: $showingNotifications) { NotificationsView() }
        .sheet(isPresented: $showingSearch) { SearchView() }
        .sheet(isPresented: $showingComposer, onDismiss: {
            if composer.didPostAll { composer.reset(); Task { await feed.refresh() } }
        }) { ComposerView() }
    }

    @ToolbarContentBuilder private var feedToolbar: some ToolbarContent {
        ToolbarItem {
            Button { showingComposer = true } label: { Image(systemName: "square.and.pencil") }
                .help("New Post")
                .accessibilityLabel("New Post")
        }
        ToolbarItem {
            Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                .keyboardShortcut("f")
                .help("Search")
                .accessibilityLabel("Search")
        }
        ToolbarItem {
            Menu {
                if !bluesky.isLoggedIn { Button("Add Bluesky Account") { showingBlueskyLogin = true } }
                if !mastodon.isLoggedIn { Button("Add Mastodon Account") { showingMastodonLogin = true } }
                if bluesky.isLoggedIn && mastodon.isLoggedIn { Text("Both accounts connected") }
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .help("Accounts")
            .accessibilityLabel("Accounts")
        }
        if isScrolledAway {
            ToolbarItem {
                Button { scrollToTop() } label: { Image(systemName: "arrow.up.to.line") }
                    .help("Scroll to Top")
                    .accessibilityLabel("Scroll to top")
            }
        }
        ToolbarItem {
            Button { showingNotifications = true } label: {
                Image(systemName: notifications.unreadCount > 0 ? "bell.badge.fill" : "bell")
                    .overlay(alignment: .topTrailing) { unreadBadge }
            }
            .help(notificationsTooltip)
            .accessibilityLabel(notifications.unreadCount > 0 ? "Notifications, \(notifications.unreadCount) unread" : "Notifications")
        }
        ToolbarItem {
            Button { Task { await feed.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .accessibilityLabel("Refresh")
        }
    }

    @ViewBuilder private var unreadBadge: some View {
        if notifications.unreadCount > 0 {
            Text("\(min(notifications.unreadCount, 99))")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(.red, in: Capsule())
                .offset(x: 8, y: -8)
        }
    }

    private var notificationsTooltip: String {
        guard notifications.unreadCount > 0 else { return "Notifications" }
        let parts = notifications.perNetworkUnread
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key == .bluesky ? "Bluesky" : "Mastodon"): \($0.value)" }
        return "Notifications — " + parts.joined(separator: ", ")
    }

    private var failureBanner: some View {
        let names = feed.failedNetworks.map { $0 == .bluesky ? "Bluesky" : "Mastodon" }.sorted().joined(separator: " and ")
        return Label("Couldn't refresh \(names). Showing what loaded.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    /// On launch, scroll to the last-seen post if it's within the first ~3 pages.
    private func restoreScrollPosition() async {
        guard !didRestore, let saved = position.savedItemID() else { return }
        didRestore = true
        var extraPages = 0
        while !feed.items.contains(where: { $0.id == saved }) && feed.hasMore && extraPages < 2 {
            await feed.loadMore()
            extraPages += 1
        }
        guard feed.items.contains(where: { $0.id == saved }) else { return }
        try? await Task.sleep(for: .milliseconds(50)) // let rows render before scrolling
        topID = saved
    }

    private func makeFetchers() -> [Network: PageFetcher] {
        var fetchers: [Network: PageFetcher] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky
            let client = BlueskyClient()
            fetchers[.bluesky] = { cursor in
                guard let token = await store.session?.accessJwt else { throw BlueskyError.invalidCredentials }
                do {
                    return try await client.timeline(accessToken: token, cursor: cursor)
                } catch BlueskyError.invalidCredentials {
                    // Access token expired — refresh once and retry.
                    try await store.refresh()
                    guard let fresh = await store.session?.accessJwt else { throw BlueskyError.invalidCredentials }
                    return try await client.timeline(accessToken: fresh, cursor: cursor)
                }
            }
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            fetchers[.mastodon] = { cursor in
                try await client.homeTimeline(host: session.host, accessToken: session.accessToken, maxId: cursor)
            }
        }
        return fetchers
    }

    private func makeFollowActions() -> [Network: FollowActions] {
        var actions: [Network: FollowActions] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky
            let client = BlueskyClient()
            actions[.bluesky] = FollowActions(
                follow: { did in
                    guard let session = await store.session else { throw BlueskyError.invalidCredentials }
                    return try await client.follow(accessToken: session.accessJwt, repoDID: session.did, subjectDID: did)
                },
                unfollow: { _, followURI in
                    guard let session = await store.session, let followURI else { return }
                    try await client.unfollow(accessToken: session.accessJwt, followURI: followURI)
                }
            )
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            actions[.mastodon] = FollowActions(
                follow: { id in
                    try await client.follow(host: session.host, accessToken: session.accessToken, accountID: id)
                    return nil
                },
                unfollow: { id, _ in
                    try await client.unfollow(host: session.host, accessToken: session.accessToken, accountID: id)
                }
            )
        }
        return actions
    }

    private func makeNotificationFetchers() -> [Network: NotificationFetcher] {
        var fetchers: [Network: NotificationFetcher] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky
            let client = BlueskyClient()
            fetchers[.bluesky] = {
                guard let token = await store.session?.accessJwt else { throw BlueskyError.invalidCredentials }
                do {
                    return try await client.notifications(accessToken: token)
                } catch BlueskyError.invalidCredentials {
                    try await store.refresh()
                    guard let fresh = await store.session?.accessJwt else { throw BlueskyError.invalidCredentials }
                    return try await client.notifications(accessToken: fresh)
                }
            }
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            fetchers[.mastodon] = {
                try await client.notifications(host: session.host, accessToken: session.accessToken)
            }
        }
        return fetchers
    }

    private func makeSearchFetchers() -> [Network: SearchFetcher] {
        var fetchers: [Network: SearchFetcher] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky
            let client = BlueskyClient()
            fetchers[.bluesky] = { query in
                guard let token = await store.session?.accessJwt else { return SearchResults(failed: true) }
                return await client.search(accessToken: token, query: query)
            }
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            fetchers[.mastodon] = { query in
                await client.search(host: session.host, accessToken: session.accessToken, query: query)
            }
        }
        return fetchers
    }

    private func configureComposer() async {
        var posters: [Network: Poster] = [:]
        var limits: [Network: Int] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky
            let client = BlueskyClient()
            posters[.bluesky] = { text in
                guard let session = await store.session else { throw BlueskyError.invalidCredentials }
                do {
                    _ = try await client.post(accessToken: session.accessJwt, repoDID: session.did, text: text)
                } catch BlueskyError.invalidCredentials {
                    try await store.refresh()
                    guard let fresh = await store.session else { throw BlueskyError.invalidCredentials }
                    _ = try await client.post(accessToken: fresh.accessJwt, repoDID: fresh.did, text: text)
                }
            }
            limits[.bluesky] = 300
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            posters[.mastodon] = { text in
                try await client.post(host: session.host, accessToken: session.accessToken, text: text)
            }
            limits[.mastodon] = await client.characterLimit(host: session.host)
        }
        composer.configure(posters: posters, limits: limits)
    }

    @ViewBuilder private var followToast: some View {
        if let message = follows.lastError {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    follows.lastError = nil
                }
        }
    }
}

private struct FeedRow: View {
    @Environment(FollowStore.self) private var follows
    let item: FeedItem
    @State private var showingProfile = false

    private var isFollowing: Bool { follows.isFollowing(item) }
    private var networkName: String { item.network == .bluesky ? "Bluesky" : "Mastodon" }
    private var followLabel: String {
        (isFollowing ? "Unfollow @" : "Follow @") + item.authorHandle + " (\(networkName))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { showingProfile = true } label: {
                RemoteImage(item.avatarURL) { Color.secondary.opacity(0.2) }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingProfile) {
                ProfileView(network: item.network, authorID: item.authorID, handle: item.authorHandle)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let repostedBy = item.repostedBy {
                    Label("Reposted by \(repostedBy)", systemImage: "arrow.2.squarepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(item.authorName).fontWeight(.semibold).lineLimit(1)
                    Text("@\(item.authorHandle)").foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    networkBadge
                    Text(item.createdAt, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                }
                if !item.text.isEmpty {
                    Text(item.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !item.imageURLs.isEmpty {
                    // Non-scrolling row — a nested horizontal ScrollView steals the List's
                    // vertical scroll gesture on macOS. Both networks cap posts at 4 images.
                    HStack(spacing: 6) {
                        ForEach(item.imageURLs.prefix(4), id: \.self) { url in
                            RemoteImage(url) { Color.secondary.opacity(0.15) }
                                .frame(maxWidth: .infinity)
                                .frame(height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(followLabel, systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus") {
                Task { await follows.toggle(item) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAction(named: followLabel) { Task { await follows.toggle(item) } }
    }


    private var networkBadge: some View {
        let isBluesky = item.network == .bluesky
        return Text(isBluesky ? "Bluesky" : "Mastodon")
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((isBluesky ? Color.blue : Color.purple).opacity(0.15), in: Capsule())
            .foregroundStyle(isBluesky ? Color.blue : Color.purple)
    }

    private var accessibilitySummary: String {
        let network = item.network == .bluesky ? "Bluesky" : "Mastodon"
        let repost = item.repostedBy.map { "Reposted by \($0). " } ?? ""
        return "\(repost)\(item.authorName) on \(network): \(item.text)"
    }
}
