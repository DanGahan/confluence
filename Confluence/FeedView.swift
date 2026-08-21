import SwiftUI
#if os(macOS)
import AppKit
#endif
import ConfluenceKit

/// Which network(s) the feed shows. Filtering is client-side over the already-merged list.
enum FeedFilter { case both, bluesky, mastodon }

extension FeedFilter {
    /// Window/tab title for this filter.
    var title: String {
        switch self { case .both: "Combined"; case .bluesky: "Bluesky"; case .mastodon: "Mastodon" }
    }
    /// Stable key for per-filter scroll-position persistence.
    var scope: String {
        switch self { case .both: "both"; case .bluesky: "bluesky"; case .mastodon: "mastodon" }
    }
}

struct FeedView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(FollowStore.self) private var follows
    @Environment(NotificationStore.self) private var notifications
    @Environment(DMStore.self) private var dms
    @Environment(SearchStore.self) private var search
    @Environment(ComposerStore.self) private var composer
    @Environment(PostActionStore.self) private var postActions
    @Environment(\.scenePhase) private var scenePhase
    @State private var feed = FeedStore()
    @State private var showingBlueskyLogin = false
    @State private var showingMastodonLogin = false
    @State private var showingNotifications = false
    @State private var showingMentions = false
    @State private var showingDMs = false
    @State private var showingSearch = false
    @State private var showingComposer = false
    #if !os(macOS)
    @State private var showingSettings = false // iOS has no Settings scene; reach it from the toolbar
    #endif
    @State private var networkFilter: FeedFilter = .both
    @State private var ownFeedScope: OwnFeedScope?
    @State private var topID: String?
    @State private var didRestore = false
    @State private var saveTask: Task<Void, Never>?
    /// Live/ticker mode: auto-refresh on an interval and keep the feed pinned to the top (#91).
    @State private var liveMode = false

    /// How often live mode polls. ponytail: fixed; make it a setting if people want control.
    /// Mock-feed UI tests use a short interval so the live-mode poll cadence is observable fast.
    private var livePollInterval: Duration { UITestLaunch.mockFeed ? .seconds(2) : .seconds(12) }
    private let position = FeedPositionStore()

    private var accountsKey: String {
        "\(bluesky.currentDID ?? "-")|\(mastodon.session?.host ?? "-")"
    }

    private var bothConnected: Bool { bluesky.isLoggedIn && mastodon.isLoggedIn }

    /// Feed items after applying the network filter (client-side over the merged list).
    /// Filtering only applies when both networks are connected; otherwise there's one network.
    private var visibleItems: [FeedItem] {
        let live = feed.items.filter { !postActions.isDeleted($0) }
        guard bothConnected else { return live }
        switch networkFilter {
        case .both: return live
        case .bluesky: return live.filter { $0.network == .bluesky }
        case .mastodon: return live.filter { $0.network == .mastodon }
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

    /// Snap to the newest post — used after each live-mode refresh so streamed-in posts keep
    /// the feed at the top rather than pushing the current anchor down.
    private func pinToTop() {
        if let first = visibleItems.first { topID = first.id }
    }

    // ScrollView + LazyVStack + scrollTargetLayout: List doesn't report the top
    // visible id via .scrollPosition on macOS, which F6 (position save) needs.
    private var feedScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !feed.rateLimitedNetworks.isEmpty {
                    rateLimitBanner.padding(.horizontal).padding(.top, 8)
                }
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
        .refreshable { await feed.refresh() } // pull-to-refresh (iOS); harmless on macOS
    }

    private func scheduleSave(_ id: String?) {
        // Debounce: save the topmost visible post's id after scrolling settles.
        guard let id else { return }
        saveTask?.cancel()
        let scope = networkFilter.scope
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            position.save(itemID: id, for: scope)
        }
    }

    var body: some View {
        #if os(macOS)
        // macOS gets its toolbar from the window; no NavigationStack needed.
        feedContent
        #else
        // iOS: a NavigationStack is required for `.toolbar` to render a navigation bar at all.
        NavigationStack { feedContent.navigationBarTitleDisplayMode(.inline) }
        #endif
    }

    private var feedContent: some View {
        feedScroll
        // Invisible live-mode poll counter for the #169 UI test; present only under -uiTestMockFeed.
        .overlay(alignment: .topLeading) {
            if UITestLaunch.mockFeed {
                Text(verbatim: "\(MockFeed.counter.fetches)")
                    .opacity(0.001)
                    .accessibilityIdentifier("mockFetchCount")
            }
        }
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
            if UITestLaunch.mockFeed {
                feed.setFetchers(MockFeed.fetchers())
                await feed.refresh()
                return
            }
            let wiring = FeedWiring(bluesky: bluesky, mastodon: mastodon)
            feed.setFetchers(wiring.pageFetchers())
            follows.setActions(wiring.followActions())
            postActions.setActions(wiring.postActions())
            notifications.setFetchers(wiring.notificationFetchers())
            search.setFetchers(wiring.searchFetchers())
            // Configure the composer concurrently — it awaits the Mastodon character-limit
            // network call (slow instances stall it for seconds). Awaiting it before the feed
            // refresh left the feed empty on open until a manual refresh (#76).
            async let composerReady: Void = configureComposer(wiring)
            await feed.refresh()
            await seedMastodonFollowState(wiring)
            await seedOwnership(wiring)
            await restoreScrollPosition()
            await composerReady
            dms.setActions(await wiring.dmActions())
            await notifications.refresh()
            await dms.refresh()
            // Poll while this window is frontmost (task is cancelled when accounts change).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                if scenePhase == .active {
                    await notifications.refresh()
                    await dms.refresh()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notifications.refresh(); await dms.refresh() } }
        }
        // Live mode: refresh on an interval and re-pin to the top, only while frontmost. The
        // task restarts when live mode toggles or the window's active state changes (so it
        // stops polling when backgrounded and resumes on refocus). #91.
        .task(id: liveMode && scenePhase == .active) {
            guard liveMode, scenePhase == .active else { return }
            while !Task.isCancelled {
                await feed.refresh()   // FeedStore guards against overlapping refreshes
                pinToTop()
                try? await Task.sleep(for: livePollInterval)
            }
        }
        .focusedSceneValue(\.refreshFeed, refreshAction)
        .focusedSceneValue(\.scrollFeedToTop, scrollToTop)
        .focusedSceneValue(\.newPost) { showingComposer = true }
        .focusedSceneValue(\.openSearch) { showingSearch = true }
        .focusedSceneValue(\.openOwnFeed) { ownFeedScope = $0 }
        .focusedSceneValue(\.availableOwnScopes, OwnFeedScope.available(bluesky: bluesky.isLoggedIn, mastodon: mastodon.isLoggedIn))
        .sheet(item: $ownFeedScope) { OwnFeedView(scope: $0) }
        .overlay(alignment: .bottom) { followToast }
        .overlay(alignment: .bottomTrailing) { composeButton }
        #if os(macOS)
        .toolbar { feedToolbar }
        #else
        .toolbar { feedToolbarIOS }
        #endif
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
        .sheet(isPresented: $showingNotifications) { NotificationsView() }
        .sheet(isPresented: $showingMentions) { MentionsView() }
        .sheet(isPresented: $showingDMs) { DirectMessagesView() }
        .sheet(isPresented: $showingSearch) { SearchView() }
        #if !os(macOS)
        .sheet(isPresented: $showingSettings) {
            SettingsView().environment(bluesky).environment(mastodon)
        }
        #endif
        .sheet(isPresented: $showingComposer, onDismiss: {
            if composer.didPostAll { composer.reset(); Task { await feed.refresh() } }
        }) { ComposerView() }
        .handleProfileLinks()
        .navigationTitle(networkFilter.title) // window/tab title reflects the current filter
        .onChange(of: networkFilter) { old, _ in
            // Remember where we were in the old filter; jump to the new filter's saved spot.
            if let topID { position.save(itemID: topID, for: old.scope) }
            if let saved = position.savedItemID(for: networkFilter.scope),
               visibleItems.contains(where: { $0.id == saved }) {
                topID = saved
            }
        }
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
        // Live mode pins to the top, so Scroll-to-Top and Refresh are redundant while it's on.
        if isScrolledAway && !liveMode {
            ToolbarItem {
                Button { scrollToTop() } label: { Image(systemName: "arrow.up.to.line") }
                    .help("Scroll to Top")
                    .accessibilityLabel("Scroll to top")
            }
        }
        // Order: Refresh, Notifications, Live mode, Mentions, Direct Messages.
        if !liveMode {
            ToolbarItem {
                Button { Task { await feed.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
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
            Button { liveMode.toggle() } label: {
                Image(systemName: liveMode ? "dot.radiowaves.left.and.right" : "dot.radiowaves.right")
                    .symbolEffect(.variableColor.iterative, isActive: liveMode)
                    .foregroundStyle(liveMode ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .help(liveMode ? "Live mode on — auto-refreshing" : "Live mode")
            .accessibilityLabel("Live mode")
            .accessibilityValue(liveMode ? "On" : "Off")
        }
        ToolbarItem {
            Button { showingMentions = true } label: { Image(systemName: "at") }
                .help("Mentions")
                .accessibilityLabel("Mentions")
        }
        ToolbarItem {
            Button { showingDMs = true } label: {
                Image(systemName: dms.unreadCount > 0 ? "envelope.badge.fill" : "envelope")
            }
            .help("Direct Messages")
            .accessibilityLabel(dms.unreadCount > 0 ? "Direct messages, \(dms.unreadCount) unread" : "Direct messages")
        }
    }

    #if !os(macOS)
    /// iPhone-fit toolbar: a couple of primary buttons plus an overflow menu, so everything
    /// stays reachable within the nav bar's limited width. Compose stays the floating button.
    @ToolbarContentBuilder private var feedToolbarIOS: some ToolbarContent {
        // Dedicated network-filter button (person.2 for combined, person for a single network),
        // matching macOS — in the slot Settings vacated (#188).
        ToolbarItem(placement: .topBarLeading) {
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
            .accessibilityLabel(filterHelp)
        }
        // Tap the feed title to scroll to top (#189).
        ToolbarItem(placement: .principal) {
            Button { scrollToTop() } label: {
                Text(networkFilter.title).font(.headline).foregroundStyle(.primary)
            }
            .accessibilityLabel("\(networkFilter.title) feed. Scroll to top.")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("Search")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingNotifications = true } label: {
                Image(systemName: notifications.unreadCount > 0 ? "bell.badge.fill" : "bell")
                    .overlay(alignment: .topTrailing) { unreadBadge }
            }
            .accessibilityLabel(notifications.unreadCount > 0 ? "Notifications, \(notifications.unreadCount) unread" : "Notifications")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button { liveMode.toggle() } label: {
                        Label(liveMode ? "Turn Off Live Mode" : "Live Mode",
                              systemImage: liveMode ? "dot.radiowaves.left.and.right" : "dot.radiowaves.right")
                    }
                    if !liveMode {
                        Button { Task { await feed.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    if isScrolledAway && !liveMode {
                        Button { scrollToTop() } label: { Label("Scroll to Top", systemImage: "arrow.up.to.line") }
                    }
                }
                Section {
                    Button { showingMentions = true } label: { Label("Mentions", systemImage: "at") }
                    Button { showingDMs = true } label: {
                        Label(dms.unreadCount > 0 ? "Messages (\(dms.unreadCount))" : "Messages", systemImage: "envelope")
                    }
                    Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }
    #endif

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
        #if !os(macOS)
        .padding(.bottom, -8) // sit a little lower for thumb reach (#192)
        #endif
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

    private var rateLimitBanner: some View {
        let names = feed.rateLimitedNetworks.map { $0 == .bluesky ? "Bluesky" : "Mastodon" }.sorted().joined(separator: " and ")
        return Label("\(names) is rate-limiting requests. Try again in a moment.", systemImage: "hourglass")
            .font(.caption)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    /// On launch, scroll to the last-seen post if it's within the first ~3 pages.
    private func restoreScrollPosition() async {
        guard !didRestore, let saved = position.savedItemID(for: networkFilter.scope) else { return }
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

    // The per-network networking closures live in FeedWiring (G11); these thin wrappers apply
    // its output to the app's stores.

    /// Identify the signed-in user per network so own-post actions (Delete) can appear.
    private func seedOwnership(_ wiring: FeedWiring) async {
        postActions.setOwnAuthorKeys(await wiring.ownAuthorKeys())
    }

    /// Mastodon timelines omit follow-state; fetch relationships for loaded Mastodon authors.
    private func seedMastodonFollowState(_ wiring: FeedWiring) async {
        let ids = Array(Set(feed.items.filter { $0.network == .mastodon }.map(\.authorID)).prefix(40))
        guard let states = await wiring.mastodonFollowState(authorIDs: ids) else { return }
        follows.seed([.mastodon: states])
    }

    private func configureComposer(_ wiring: FeedWiring) async {
        let config = await wiring.composerConfig()
        composer.configure(posters: config.posters, limits: config.limits)
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

/// One post row — used by the feed and by search results so both behave identically
/// (rich text + hover links, images/lightbox, link card, and the full right-click menu).
struct FeedRow: View {
    @Environment(FollowStore.self) private var follows
    @Environment(PostActionStore.self) private var postActions
    @Environment(\.openURL) private var openURL
    @AppStorage(PostAppearance.fontNameKey) private var fontName = PostAppearance.defaultName
    @AppStorage(PostAppearance.fontSizeKey) private var fontSize = PostAppearance.defaultSize
    @AppStorage(PostAppearance.linkColorKey) private var linkColorHex = PostAppearance.defaultLinkColorHex
    let item: FeedItem
    @State private var showingProfile = false
    @State private var showingThread = false
    @State private var parentThread: FeedItem?   // #212: the post this reply is responding to
    @State private var replyExpanded = false
    @State private var lightbox: LightboxItem?
    @State private var confirmingBlock = false
    @State private var confirmingDelete = false

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
            .sheet(item: $parentThread) { ThreadView(item: $0) }

            VStack(alignment: .leading, spacing: 4) {
                if let repostedBy = item.repostedBy {
                    Label("Reposted by \(repostedBy)", systemImage: "arrow.2.squarepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    AuthorLabel(item: item)
                    Spacer(minLength: 4)
                    networkBadge
                    Text(item.createdAt, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                }
                if !item.text.isEmpty {
                    RichTextLabel(attributed: item.attributedText, openURL: openURL, fontName: fontName, fontSize: fontSize, linkColorHex: linkColorHex)
                        #if !os(macOS)
                        // Make the post text itself a reliable, large reply-expand target (#187):
                        // a catcher behind the text so tapping non-link text toggles the reply
                        // box (finger taps near the top no longer land on the username). Links
                        // sit in front and still open.
                        .background(
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { replyExpanded.toggle() } }
                        )
                        #endif
                }
                if !item.imageURLs.isEmpty {
                    PostImages(urls: item.imageURLs, aspects: item.imageAspects, letterboxHeight: 140) { start, images in
                        lightbox = LightboxItem(urls: images, start: start)
                    }
                }
                ForEach(item.videos) { video in
                    PostVideoView(video: video)
                }
                if let card = item.linkCard {
                    LinkCardView(card: card)
                }
                if let parent = item.replyParent {
                    ReplyContextCard(reply: parent, network: item.network) {
                        parentThread = FeedItem(network: item.network, rawId: parent.threadID,
                                                authorName: parent.authorName, authorHandle: parent.authorHandle,
                                                avatarURL: nil, createdAt: item.createdAt, text: parent.snippet,
                                                threadID: parent.threadID)
                    }
                    .padding(.top, 2)
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
        // Click the post body (chrome/text — avatar, username, media, links and the "N replies"
        // button consume their own clicks) to expand an inline reply box. quickReply also
        // provides the invisible hittable backing right-click needs on the row's gaps.
        .quickReply(item, expanded: $replyExpanded)
        .contextMenu { postMenu }
        .confirmationDialog("Block @\(item.authorHandle)?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await postActions.block(item) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see posts from this account. You can undo this in the \(networkName) app.")
        }
        .confirmationDialog("Delete this post?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await postActions.delete(item) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the post on \(networkName).")
        }
        .sheet(item: $lightbox) { ImageLightbox(item: $0) }
        // Combine the row into one VoiceOver element normally; under UI tests keep children
        // addressable (combine collapses sub-element frames to the row, breaking tap targeting).
        .accessibilityElement(children: UITestLaunch.mockFeed ? .contain : .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAction(named: followLabel) { Task { await follows.toggle(item) } }
    }

    @ViewBuilder private var postMenu: some View {
        Button("Reply", systemImage: "arrowshape.turn.up.left") { replyExpanded = true }
        Divider()
        Button(postActions.isReposted(item) ? "Undo Repost" : "Repost", systemImage: "arrow.2.squarepath") {
            Task { await postActions.toggleRepost(item) }
        }
        Button(postActions.isLiked(item) ? "Unlike" : "Like",
               systemImage: postActions.isLiked(item) ? "star.fill" : "star") {
            Task { await postActions.toggleLike(item) }
        }
        if let url = item.postURL {
            Divider()
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            #if os(macOS)
            // Safari Reading List has no public iOS API; ShareLink covers sharing on iOS.
            Button("Add to Reading List", systemImage: "eyeglasses") {
                NSSharingService(named: .addToSafariReadingList)?.perform(withItems: [url])
            }
            #endif
        }
        Divider()
        if postActions.isOwn(item) {
            Button("Delete Post", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        } else {
            Button(followLabel, systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus") {
                Task { await follows.toggle(item) }
            }
            Button("Block @\(item.authorHandle)", systemImage: "hand.raised", role: .destructive) {
                confirmingBlock = true
            }
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
