import SwiftUI
import ConfluenceKit

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
            .toolbar { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .frame(width: contentWidth + 32, height: 620)
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
        switch item.network {
        case .bluesky:
            guard let session = bluesky.session else { return }
            thread = try? await BlueskyClient().postThread(accessToken: session.accessJwt, uri: item.threadID)
        case .mastodon:
            guard let session = mastodon.session else { return }
            thread = try? await MastodonClient().statusContext(host: session.host, accessToken: session.accessToken, statusID: item.threadID)
        }
    }
}

private struct ThreadPostRow: View {
    @Environment(FollowStore.self) private var follows
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
                    Text(post.authorName).fontWeight(.semibold).lineLimit(1)
                    Text("@\(post.authorHandle)").foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    NetworkBadge(network: post.network)
                    Text(post.createdAt, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary).font(.caption).lineLimit(1)
                }
                if !post.text.isEmpty {
                    Text(post.attributedText).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !post.imageURLs.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(post.imageURLs.prefix(4), id: \.self) { url in
                            RemoteImage(url) { Color.secondary.opacity(0.15) }
                                .frame(maxWidth: .infinity).frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if let card = post.linkCard {
                    LinkCardView(card: card)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isFocus ? 8 : 0)
        .background(isFocus ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button(followLabel, systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus") {
                Task { await follows.toggle(post) }
            }
        }
    }
}
