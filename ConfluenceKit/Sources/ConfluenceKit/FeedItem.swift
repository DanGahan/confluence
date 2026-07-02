import Foundation

/// A single post in the combined feed, normalized across networks.
public struct FeedItem: Identifiable, Sendable, Equatable {
    public let network: Network
    public let rawId: String
    public let authorName: String
    public let authorHandle: String
    public let avatarURL: URL?
    public let createdAt: Date
    public let text: String
    public let imageURLs: [URL]
    /// Display name of the reposter/booster, if this appeared via a repost/boost.
    public let repostedBy: String?

    public var id: String { "\(network.rawValue):\(rawId)" }

    public init(network: Network, rawId: String, authorName: String, authorHandle: String,
                avatarURL: URL?, createdAt: Date, text: String, imageURLs: [URL] = [], repostedBy: String? = nil) {
        self.network = network
        self.rawId = rawId
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.text = text
        self.imageURLs = imageURLs
        self.repostedBy = repostedBy
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
