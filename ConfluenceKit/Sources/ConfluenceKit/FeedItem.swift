import Foundation

/// A shared-link preview attached to a post (Bluesky `app.bsky.embed.external`).
public struct LinkCard: Sendable, Equatable {
    public let url: URL
    public let title: String
    public let description: String
    public let thumbURL: URL?

    public init(url: URL, title: String, description: String, thumbURL: URL?) {
        self.url = url
        self.title = title
        self.description = description
        self.thumbURL = thumbURL
    }
}

/// A video/GIF attached to a post: a playable URL (Bluesky HLS playlist or Mastodon mp4)
/// and an optional poster frame to show before playback.
public struct PostVideo: Sendable, Equatable, Identifiable {
    public let url: URL
    public let thumbnailURL: URL?

    public init(url: URL, thumbnailURL: URL?) {
        self.url = url
        self.thumbnailURL = thumbnailURL
    }

    public var id: String { url.absoluteString }
}

/// A single post in the combined feed, normalized across networks.
public struct FeedItem: Identifiable, Sendable, Equatable {
    public let network: Network
    public let rawId: String
    /// Stable author identity for follow actions: Bluesky DID, or Mastodon account id.
    public let authorID: String
    public let authorName: String
    public let authorHandle: String
    public let avatarURL: URL?
    public let createdAt: Date
    public let text: String
    /// Rich version of `text` with `.link` runs for URLs and @-mentions. Defaults to plain text.
    public let attributedText: AttributedString
    public let imageURLs: [URL]
    /// Videos/GIFs attached to the post (Bluesky video embed, Mastodon video/gifv).
    public let videos: [PostVideo]
    /// A shared-link preview card, when the post embeds one and has no images.
    public let linkCard: LinkCard?
    /// Display name of the reposter/booster, if this appeared via a repost/boost.
    public let repostedBy: String?
    /// Whether the signed-in user already follows the author, when known at fetch time.
    public let isFollowing: Bool
    /// Bluesky follow-record URI (needed to unfollow); nil for Mastodon or when not following.
    public let followURI: String?
    /// Post id to fetch the conversation for: Bluesky post URI, or Mastodon status id
    /// (the original status for a boost). Defaults to `rawId`.
    public let threadID: String
    /// Number of direct replies, when known — drives the "show thread" affordance.
    public let replyCount: Int
    /// Whether this post is itself a reply to another post.
    public let isReply: Bool
    /// Bluesky post CID — the content hash needed alongside the URI to repost/like. nil for Mastodon.
    public let cid: String?
    /// Public web URL for the post (Share, Reading List). bsky.app / instance permalink.
    public let postURL: URL?

    public var id: String { "\(network.rawValue):\(rawId)" }
    /// Identity key for the author across items (follow state is tracked per author).
    public var authorKey: String { "\(network.rawValue):\(authorID)" }
    /// Whether this post is part of a conversation worth opening.
    public var hasThread: Bool { replyCount > 0 || isReply }

    public init(network: Network, rawId: String, authorID: String = "", authorName: String, authorHandle: String,
                avatarURL: URL?, createdAt: Date, text: String, attributedText: AttributedString? = nil,
                imageURLs: [URL] = [], videos: [PostVideo] = [], linkCard: LinkCard? = nil, repostedBy: String? = nil,
                isFollowing: Bool = false, followURI: String? = nil,
                threadID: String? = nil, replyCount: Int = 0, isReply: Bool = false,
                cid: String? = nil, postURL: URL? = nil) {
        self.network = network
        self.rawId = rawId
        self.authorID = authorID
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.text = text
        self.attributedText = attributedText ?? AttributedString(text)
        self.imageURLs = imageURLs
        self.videos = videos
        self.linkCard = linkCard
        self.repostedBy = repostedBy
        self.isFollowing = isFollowing
        self.followURI = followURI
        self.threadID = threadID ?? rawId
        self.replyCount = replyCount
        self.isReply = isReply
        self.cid = cid
        self.postURL = postURL
    }
}

/// A conversation: every post in the thread in chronological order, plus which one to highlight.
public struct PostThread: Sendable, Equatable {
    public let items: [FeedItem]
    public let focusID: String

    public init(items: [FeedItem], focusID: String) {
        self.items = items
        self.focusID = focusID
    }
}

/// A page of feed items plus the cursor to fetch the next (older) page. No cursor = end.
public struct FeedPage: Sendable, Equatable {
    public let items: [FeedItem]
    public let nextCursor: String?

    public init(items: [FeedItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// De-duplicates and sorts a thread oldest-first (chronological), tie-breaking by id.
public func chronological(_ items: [FeedItem]) -> [FeedItem] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
        .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
}

/// Merges per-network item lists into one list, newest first, de-duplicated.
/// Chronological only — no algorithmic ranking. Ties break by id for determinism.
public func mergeFeeds(_ groups: [[FeedItem]]) -> [FeedItem] {
    var seen = Set<String>()
    var all: [FeedItem] = []
    for group in groups {
        for item in group where seen.insert(item.id).inserted {
            all.append(item)
        }
    }
    return all.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
}
