import SwiftUI
import ConfluenceKit

/// A user's profile: header (avatar, bio, counts, follow) + their recent posts.
/// Following/followers counts push a FollowListView.
struct ProfileView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(FollowStore.self) private var follows
    @Environment(\.dismiss) private var dismiss

    let network: Network
    let authorID: String
    let handle: String

    @State private var profile: Profile?
    @State private var posts: [FeedItem] = []
    @State private var loading = true

    private let contentWidth: CGFloat = 448

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let profile {
                        header(profile)
                    } else if loading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    } else {
                        ContentUnavailableView("Profile Unavailable", systemImage: "person.slash")
                    }
                    Divider()
                    ForEach(posts) { ProfilePostRow(post: $0) }
                    if posts.isEmpty && !loading {
                        Text("No posts.").foregroundStyle(.secondary).padding()
                    }
                }
                .frame(width: contentWidth, alignment: .leading) // hard width: a long URL can't stretch the sheet
                .padding(16)
            }
            .navigationTitle("@\(handle)")
        }
        .frame(width: contentWidth + 32, height: 620)
        .overlay(alignment: .topLeading) { SheetCloseButton { dismiss() }.padding(12) }
        .handleProfileLinks()
        .task { await load() }
    }

    @ViewBuilder private func header(_ profile: Profile) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(url: profile.avatarURL, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.title3).fontWeight(.semibold)
                    NetworkBadge(network: profile.network)
                    Spacer()
                    Button(follows.isFollowing(profile) ? "Following" : "Follow") {
                        Task { await follows.toggle(profile) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("@\(profile.handle)").font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !profile.bio.isEmpty {
                    Text(profile.bio).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                HStack(spacing: 16) {
                    NavigationLink { FollowListView(network: network, authorID: authorID, kind: .following) } label: {
                        countLabel(profile.followingCount, "Following")
                    }
                    NavigationLink { FollowListView(network: network, authorID: authorID, kind: .followers) } label: {
                        countLabel(profile.followersCount, "Followers")
                    }
                    countLabel(profile.postsCount, "Posts").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    private func countLabel(_ count: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(count)").fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        switch network {
        case .bluesky:
            guard let session = bluesky.session else { return }
            let client = BlueskyClient()
            profile = try? await client.profile(accessToken: session.accessJwt, actor: authorID)
            posts = (try? await client.authorFeed(accessToken: session.accessJwt, actor: authorID, cursor: nil))?.items ?? []
        case .mastodon:
            guard let session = mastodon.session else { return }
            let client = MastodonClient()
            profile = try? await client.profile(host: session.host, accessToken: session.accessToken, accountID: authorID)
            posts = (try? await client.accountStatuses(host: session.host, accessToken: session.accessToken, accountID: authorID, maxId: nil))?.items ?? []
        }
    }
}

private struct ProfilePostRow: View {
    @Environment(\.openURL) private var openURL
    @AppStorage(PostAppearance.fontNameKey) private var fontName = PostAppearance.defaultName
    @AppStorage(PostAppearance.fontSizeKey) private var fontSize = PostAppearance.defaultSize
    @AppStorage(PostAppearance.linkColorKey) private var linkColorHex = PostAppearance.defaultLinkColorHex
    let post: FeedItem
    @State private var showingThread = false
    @State private var lightbox: LightboxItem?
    private var threadLabel: String {
        switch post.replyCount {
        case 0: "Show thread"
        case 1: "1 reply"
        default: "\(post.replyCount) replies"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let repostedBy = post.repostedBy {
                Label("Reposted by \(repostedBy)", systemImage: "arrow.2.squarepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(post.createdAt, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.secondary)
            if !post.text.isEmpty {
                RichTextLabel(attributed: post.attributedText, openURL: openURL, fontName: fontName, fontSize: fontSize, linkColorHex: linkColorHex)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !post.imageURLs.isEmpty {
                HStack(spacing: 6) {
                    let images = Array(post.imageURLs.prefix(4))
                    ForEach(Array(images.enumerated()), id: \.element) { i, url in
                        Button { lightbox = LightboxItem(urls: images, start: i) } label: {
                            RemoteImage(url) { Color.secondary.opacity(0.15) }
                                .frame(maxWidth: .infinity).frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ForEach(post.videos) { video in
                PostVideoView(video: video)
            }
            if let card = post.linkCard {
                LinkCardView(card: card)
            }
            if post.hasThread {
                Button { showingThread = true } label: {
                    Label(threadLabel, systemImage: "bubble.left.and.bubble.right").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Divider()
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingThread) { ThreadView(item: post) }
        .sheet(item: $lightbox) { ImageLightbox(item: $0) }
    }
}
