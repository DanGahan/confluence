import SwiftUI
import ConfluenceKit
import os

/// Breadcrumbs for the thread-open path — the suspected culprit behind the beachball in #102.
/// A live capture (`log show --predicate 'subsystem == "com.dangahan.confluence"' --last 5m`)
/// shows the open → loaded/failed gap; if it hangs after "loaded", the stall is in rendering.
private let log = Logger(subsystem: "com.dangahan.confluence", category: "thread")

/// The full conversation around a post, per-network, in chronological order with the tapped
/// post highlighted. Fetched via getPostThread (Bluesky) / statuses/:id/context (Mastodon).
struct ThreadView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(\.dismiss) private var dismiss

    let item: FeedItem

    @State private var thread: PostThread?
    @State private var loading = true

    private let contentWidth: CGFloat = 448

    var body: some View {
        NavigationStack {
            Group {
                if let thread, !thread.items.isEmpty {
                    threadList(thread)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Conversation Unavailable", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationTitle("Thread")
        }
        .frame(width: contentWidth + 32, height: 620)
        .overlay(alignment: .topLeading) { SheetCloseButton { dismiss() }.padding(12) }
        .handleProfileLinks()
        .task { await load() }
    }

    private func threadList(_ thread: PostThread) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(thread.items) { post in
                        ThreadPostRow(post: post, isFocus: post.id == thread.focusID)
                            .id(post.id)
                        Divider()
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(16)
            }
            .onAppear {
                // Land on the tapped post rather than the top of a long ancestor chain.
                proxy.scrollTo(thread.focusID, anchor: .center)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        // Thread/post ids are public identifiers (no secrets), safe to log %{public}.
        // .notice (not .info) so the breadcrumb persists to the log archive and is retrievable
        // after a hang — info-level messages can be pruned before you go looking.
        log.notice("opening thread \(item.threadID, privacy: .public) on \(item.network.rawValue, privacy: .public)")
        do {
            switch item.network {
            case .bluesky:
                guard let session = bluesky.session else { log.error("thread open: no Bluesky session"); return }
                thread = try await BlueskyClient().postThread(accessToken: session.accessJwt, uri: item.threadID)
            case .mastodon:
                guard let session = mastodon.session else { log.error("thread open: no Mastodon session"); return }
                thread = try await MastodonClient().statusContext(host: session.host, accessToken: session.accessToken, statusID: item.threadID)
            }
            log.notice("thread \(item.threadID, privacy: .public) loaded \(thread?.items.count ?? 0, privacy: .public) posts")
        } catch {
            // Previously swallowed by `try?`; log so a failed (vs hung) load is distinguishable.
            log.error("thread \(item.threadID, privacy: .public) load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct ThreadPostRow: View {
    @Environment(FollowStore.self) private var follows
    @AppStorage(PostAppearance.fontNameKey) private var fontName = PostAppearance.defaultName
    @AppStorage(PostAppearance.fontSizeKey) private var fontSize = PostAppearance.defaultSize
    @AppStorage(PostAppearance.linkColorKey) private var linkColorHex = PostAppearance.defaultLinkColorHex
    let post: FeedItem
    let isFocus: Bool
    @State private var showingProfile = false

    private var isFollowing: Bool { follows.isFollowing(post) }
    private var networkName: String { post.network == .bluesky ? "Bluesky" : "Mastodon" }
    private var followLabel: String {
        (isFollowing ? "Unfollow @" : "Follow @") + post.authorHandle + " (\(networkName))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { showingProfile = true } label: {
                Avatar(url: post.avatarURL, size: 40)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingProfile) {
                ProfileView(network: post.network, authorID: post.authorID, handle: post.authorHandle)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    AuthorLabel(item: post)
                    Spacer(minLength: 4)
                    NetworkBadge(network: post.network)
                    Text(post.createdAt, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary).font(.caption).lineLimit(1)
                }
                if !post.text.isEmpty {
                    Text(post.attributedText).textSelection(.enabled)
                        .font(PostAppearance.font(name: fontName, size: fontSize))
                        .tint(PostAppearance.linkColor(hex: linkColorHex))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !post.imageURLs.isEmpty {
                    PostImages(urls: post.imageURLs, letterboxHeight: 120)
                }
                ForEach(post.videos) { video in
                    PostVideoView(video: video)
                }
                if let card = post.linkCard {
                    LinkCardView(card: card)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isFocus ? 8 : 0)
        .background(isFocus ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .quickReply(post)
        .contextMenu {
            Button(followLabel, systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus") {
                Task { await follows.toggle(post) }
            }
        }
    }
}
