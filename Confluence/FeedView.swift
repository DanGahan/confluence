import SwiftUI
import ConfluenceKit

struct FeedView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(FollowStore.self) private var follows
    @State private var feed = FeedStore()
    @State private var showingBlueskyLogin = false
    @State private var showingMastodonLogin = false
    @State private var lastPagedTailID: String?
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

    var body: some View {
        // ScrollView + LazyVStack + scrollTargetLayout: List doesn't report the top
        // visible id via .scrollPosition on macOS, which F6 (position save) needs.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !feed.failedNetworks.isEmpty {
                    failureBanner.padding(.horizontal).padding(.top, 8)
                }
                ForEach(feed.items) { item in
                    FeedRow(item: item)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .onAppear {
                            // Page each tail at most once, else onAppear chain-loads everything.
                            guard item.id == feed.items.last?.id, item.id != lastPagedTailID else { return }
                            lastPagedTailID = item.id
                            Task { await feed.loadMore() }
                        }
                    Divider()
                }
                if feed.hasMore && !feed.items.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $topID, anchor: .top)
        .onChange(of: topID) { _, newID in
            // Debounce: save the topmost visible post's id after scrolling settles.
            guard let newID else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                position.save(itemID: newID)
            }
        }
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
            await feed.refresh()
            await restoreScrollPosition()
        }
        .overlay(alignment: .bottom) { followToast }
        .toolbar {
            ToolbarItem {
                Menu {
                    if !bluesky.isLoggedIn { Button("Add Bluesky Account") { showingBlueskyLogin = true } }
                    if !mastodon.isLoggedIn { Button("Add Mastodon Account") { showingMastodonLogin = true } }
                    if bluesky.isLoggedIn && mastodon.isLoggedIn {
                        Text("Both accounts connected")
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .help("Accounts")
            }
            if isScrolledAway {
                ToolbarItem {
                    Button { scrollToTop() } label: { Image(systemName: "arrow.up.to.line") }
                        .keyboardShortcut(.upArrow)
                        .help("Scroll to Top")
                }
            }
            ToolbarItem {
                Button { Task { await feed.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Refresh")
            }
        }
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
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

    @ViewBuilder private var followToast: some View {
        if let message = follows.lastError {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
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
                AsyncImage(url: item.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingProfile, arrowEdge: .trailing) { profilePopover }

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
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.secondary.opacity(0.15)
                            }
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

    private var profilePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AsyncImage(url: item.avatarURL) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                    .frame(width: 40, height: 40).clipShape(Circle())
                VStack(alignment: .leading) {
                    Text(item.authorName).fontWeight(.semibold)
                    Text("@\(item.authorHandle)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(followLabel, systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus") {
                Task { await follows.toggle(item) }
                showingProfile = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 260)
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
