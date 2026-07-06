import SwiftUI
import AppKit
import ConfluenceKit

/// Which network(s) the feed shows. Filtering is client-side over the already-merged list.
enum FeedFilter { case both, bluesky, mastodon }

struct FeedView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(FollowStore.self) private var follows
    @Environment(NotificationStore.self) private var notifications
    @Environment(SearchStore.self) private var search
    @Environment(ComposerStore.self) private var composer
    @Environment(PostActionStore.self) private var postActions
    @Environment(\.scenePhase) private var scenePhase
    @State private var feed = FeedStore()
    @State private var showingBlueskyLogin = false
    @State private var showingMastodonLogin = false
    @State private var showingNotifications = false
    @State private var showingSearch = false
    @State private var showingComposer = false
    @State private var networkFilter: FeedFilter = .both
    @State private var topID: String?
    @State private var didRestore = false
    @State private var saveTask: Task<Void, Never>?
    private let position = FeedPositionStore()

    private var accountsKey: String {
        "\(bluesky.session?.did ?? "-")|\(mastodon.session?.host ?? "-")"
    }

    private var bothConnected: Bool { bluesky.isLoggedIn && mastodon.isLoggedIn }

    /// Feed items after applying the network filter (client-side over the merged list).
    /// Filtering only applies when both networks are connected; otherwise there's one network.
    private var visibleItems: [FeedItem] {
        guard bothConnected else { return feed.items }
        switch networkFilter {
        case .both: return feed.items
        case .bluesky: return feed.items.filter { $0.network == .bluesky }
        case .mastodon: return feed.items.filter { $0.network == .mastodon }
        }
    }

    private var filterHelp: String {
        switch networkFilter {
        case .both: "Showing both networks"
        case .bluesky: "Showing Bluesky only"
        case .mastodon: "Showing Mastodon only"
        }
    }

    private var isScrolledAway: Bool {
        guard let topID, let first = visibleItems.first else { return false }
        return topID != first.id
    }

    private func scrollToTop() {
        guard let first = visibleItems.first else { return }
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
                ForEach(visibleItems) { item in
                    FeedRow(item: item)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    Divider()
                }
                if feed.hasMore && !visibleItems.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
                }
                Color.clear.frame(height: 72) // clearance for the floating compose button
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
            if visibleItems.isEmpty {
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
            postActions.setActions(makePostActions())
            notifications.setFetchers(makeNotificationFetchers())
            search.setFetchers(makeSearchFetchers())
            // Configure the composer concurrently — it awaits the Mastodon character-limit
            // network call (slow instances stall it for seconds). Awaiting it before the feed
            // refresh left the feed empty on open until a manual refresh (#76).
            async let composerReady: Void = configureComposer()
            await feed.refresh()
            await seedMastodonFollowState()
            await restoreScrollPosition()
            await composerReady
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
        .focusedSceneValue(\.openSearch) { showingSearch = true }
        .overlay(alignment: .bottom) { followToast }
        .overlay(alignment: .bottomTrailing) { composeButton }
        .toolbar { feedToolbar }
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
        .sheet(isPresented: $showingNotifications) { NotificationsView() }
        .sheet(isPresented: $showingSearch) { SearchView() }
        .sheet(isPresented: $showingComposer, onDismiss: {
            if composer.didPostAll { composer.reset(); Task { await feed.refresh() } }
        }) { ComposerView() }
        .handleProfileLinks()
    }

    @ToolbarContentBuilder private var feedToolbar: some ToolbarContent {
        ToolbarItem {
            Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                .help("Search (⌘S)")
                .accessibilityLabel("Search")
        }
        ToolbarItem {
            Menu {
                if bothConnected {
                    Picker("Show", selection: $networkFilter) {
                        Label("Both Networks", systemImage: "person.2").tag(FeedFilter.both)
                        Label("Bluesky", systemImage: "person").tag(FeedFilter.bluesky)
                        Label("Mastodon", systemImage: "person").tag(FeedFilter.mastodon)
                    }
                    .pickerStyle(.inline)
                }
                if !bluesky.isLoggedIn { Button("Add Bluesky Account") { showingBlueskyLogin = true } }
                if !mastodon.isLoggedIn { Button("Add Mastodon Account") { showingMastodonLogin = true } }
            } label: {
                Image(systemName: (networkFilter == .both && bothConnected) ? "person.2" : "person")
            }
            .help(filterHelp)
            .accessibilityLabel(filterHelp)
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

    private var composeButton: some View {
        Button { showingComposer = true } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.tint, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(20)
        .help("New Post (⌘N)")
        .accessibilityLabel("New Post")
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

    private func makePostActions() -> [Network: PostActions] {
        var actions: [Network: PostActions] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky
            let client = BlueskyClient()
            // Bluesky access tokens expire; refresh once and retry on invalidCredentials.
            @Sendable func withSession<T>(_ body: @Sendable (BlueskySession) async throws -> T) async throws -> T {
                guard let session = await store.session else { throw BlueskyError.invalidCredentials }
                do { return try await body(session) }
                catch BlueskyError.invalidCredentials {
                    try await store.refresh()
                    guard let fresh = await store.session else { throw BlueskyError.invalidCredentials }
                    return try await body(fresh)
                }
            }
            actions[.bluesky] = PostActions(
                repost: { item in
                    guard let cid = item.cid else { return }
                    _ = try await withSession { try await client.repost(accessToken: $0.accessJwt, repoDID: $0.did, uri: item.rawId, cid: cid) }
                },
                like: { item in
                    guard let cid = item.cid else { return }
                    _ = try await withSession { try await client.like(accessToken: $0.accessJwt, repoDID: $0.did, uri: item.rawId, cid: cid) }
                },
                block: { item in
                    _ = try await withSession { try await client.block(accessToken: $0.accessJwt, repoDID: $0.did, subjectDID: item.authorID) }
                }
            )
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            actions[.mastodon] = PostActions(
                repost: { item in try await client.reblog(host: session.host, accessToken: session.accessToken, statusID: item.threadID) },
                like: { item in try await client.favourite(host: session.host, accessToken: session.accessToken, statusID: item.threadID) },
                block: { item in try await client.block(host: session.host, accessToken: session.accessToken, accountID: item.authorID) }
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

    /// Mastodon timelines omit follow-state; fetch relationships for loaded Mastodon authors.
    private func seedMastodonFollowState() async {
        guard let session = mastodon.session else { return }
        let ids = Array(Set(feed.items.filter { $0.network == .mastodon }.map(\.authorID))).prefix(40)
        guard !ids.isEmpty else { return }
        let states = await MastodonClient().relationships(host: session.host, accessToken: session.accessToken, accountIDs: Array(ids))
        follows.seed([.mastodon: states])
    }

    private func configureComposer() async {
        var posters: [Network: Poster] = [:]
        var limits: [Network: Int] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky
            let client = BlueskyClient()
            posters[.bluesky] = { text, images in
                guard let session = await store.session else { throw BlueskyError.invalidCredentials }
                func attempt(_ s: BlueskySession) async throws {
                    var blobs: [Data] = []
                    for data in images {
                        blobs.append(try await client.uploadImage(accessToken: s.accessJwt, data: data, mimeType: "image/jpeg"))
                    }
                    _ = try await client.post(accessToken: s.accessJwt, repoDID: s.did, text: text, imageBlobs: blobs)
                }
                do { try await attempt(session) }
                catch BlueskyError.invalidCredentials {
                    try await store.refresh()
                    guard let fresh = await store.session else { throw BlueskyError.invalidCredentials }
                    try await attempt(fresh)
                }
            }
            limits[.bluesky] = 300
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            posters[.mastodon] = { text, images in
                var mediaIDs: [String] = []
                for (i, data) in images.enumerated() {
                    mediaIDs.append(try await client.uploadImage(host: session.host, accessToken: session.accessToken,
                                                                 data: data, filename: "image\(i).jpg", mimeType: "image/jpeg"))
                }
                try await client.post(host: session.host, accessToken: session.accessToken, text: text, mediaIDs: mediaIDs)
            }
            limits[.mastodon] = await client.characterLimit(host: session.host)
        }
        composer.configure(posters: posters, limits: limits)
    }

    @ViewBuilder private var followToast: some View {
        if let message = follows.lastError ?? postActions.lastError {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    follows.lastError = nil
                    postActions.lastError = nil
                }
        }
    }
}

private struct FeedRow: View {
    @Environment(FollowStore.self) private var follows
    @Environment(PostActionStore.self) private var postActions
    @Environment(\.openURL) private var openURL
    @AppStorage(PostAppearance.fontNameKey) private var fontName = PostAppearance.defaultName
    @AppStorage(PostAppearance.fontSizeKey) private var fontSize = PostAppearance.defaultSize
    @AppStorage(PostAppearance.linkColorKey) private var linkColorHex = PostAppearance.defaultLinkColorHex
    let item: FeedItem
    @State private var showingProfile = false
    @State private var showingThread = false
    @State private var lightbox: LightboxItem?
    @State private var confirmingBlock = false

    private var isFollowing: Bool { follows.isFollowing(item) }
    private var networkName: String { item.network == .bluesky ? "Bluesky" : "Mastodon" }
    private var followLabel: String {
        (isFollowing ? "Unfollow @" : "Follow @") + item.authorHandle + " (\(networkName))"
    }
    private var threadLabel: String {
        switch item.replyCount {
        case 0: "Show thread"
        case 1: "1 reply"
        default: "\(item.replyCount) replies"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { showingProfile = true } label: {
                Avatar(url: item.avatarURL, size: 44)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingProfile) {
                ProfileView(network: item.network, authorID: item.authorID, handle: item.authorHandle)
            }
            .sheet(isPresented: $showingThread) { ThreadView(item: item) }

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
                    RichTextLabel(attributed: item.attributedText, openURL: openURL, fontName: fontName, fontSize: fontSize, linkColorHex: linkColorHex)
                }
                if !item.imageURLs.isEmpty {
                    // Non-scrolling row — a nested horizontal ScrollView steals the List's
                    // vertical scroll gesture on macOS. Both networks cap posts at 4 images.
                    HStack(spacing: 6) {
                        let images = Array(item.imageURLs.prefix(4))
                        ForEach(Array(images.enumerated()), id: \.element) { i, url in
                            Button { lightbox = LightboxItem(urls: images, start: i) } label: {
                                RemoteImage(url) { Color.secondary.opacity(0.15) }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let card = item.linkCard {
                    LinkCardView(card: card)
                }
                if item.hasThread {
                    Button { showingThread = true } label: {
                        Label(threadLabel, systemImage: "bubble.left.and.bubble.right")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        // Hittable-but-invisible backing so right-click works on the row's gaps too. Using a
        // background (not .contentShape) keeps SwiftUI from owning the cursor, so the text
        // view's pointing-hand hover over links still wins.
        .background(Color.black.opacity(0.001))
        .contextMenu { postMenu }
        .confirmationDialog("Block @\(item.authorHandle)?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await postActions.block(item) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see posts from this account. You can undo this in the \(networkName) app.")
        }
        .sheet(item: $lightbox) { ImageLightbox(item: $0) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAction(named: followLabel) { Task { await follows.toggle(item) } }
    }

    @ViewBuilder private var postMenu: some View {
        Button(postActions.isReposted(item) ? "Reposted" : "Repost", systemImage: "arrow.2.squarepath") {
            Task { await postActions.repost(item) }
        }
        .disabled(postActions.isReposted(item))
        Button(postActions.isLiked(item) ? "Liked" : "Like",
               systemImage: postActions.isLiked(item) ? "star.fill" : "star") {
            Task { await postActions.like(item) }
        }
        .disabled(postActions.isLiked(item))
        if let url = item.postURL {
            Divider()
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            Button("Add to Reading List", systemImage: "eyeglasses") {
                NSSharingService(named: .addToSafariReadingList)?.perform(withItems: [url])
            }
        }
        Divider()
        Button(followLabel, systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus") {
            Task { await follows.toggle(item) }
        }
        Button("Block @\(item.authorHandle)", systemImage: "hand.raised", role: .destructive) {
            confirmingBlock = true
        }
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
