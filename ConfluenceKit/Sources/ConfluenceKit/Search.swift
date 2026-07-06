import Foundation

extension FeedItem: Followable {}

/// A person in search results, follow-able like a feed author.
public struct SearchActor: Identifiable, Sendable, Equatable, Followable {
    public let network: Network
    public let authorID: String
    public let name: String
    public let handle: String
    public let avatarURL: URL?
    public let isFollowing: Bool
    public let followURI: String?
    /// Account bio / description, if any.
    public let bio: String

    public var id: String { "\(network.rawValue):\(authorID)" }
    public var authorKey: String { id }

    public init(network: Network, authorID: String, name: String, handle: String, avatarURL: URL?,
                isFollowing: Bool = false, followURI: String? = nil, bio: String = "") {
        self.network = network
        self.authorID = authorID
        self.name = name
        self.handle = handle
        self.avatarURL = avatarURL
        self.isFollowing = isFollowing
        self.followURI = followURI
        self.bio = bio
    }
}

/// One network's search response: people + posts, or a failure flag.
public struct SearchResults: Sendable, Equatable {
    public var people: [SearchActor]
    public var posts: [FeedItem]
    public var failed: Bool
    /// Opaque cursor for the next page of posts (Bluesky cursor / Mastodon offset); nil at end.
    public var postsCursor: String?

    public init(people: [SearchActor] = [], posts: [FeedItem] = [], failed: Bool = false, postsCursor: String? = nil) {
        self.people = people
        self.posts = posts
        self.failed = failed
        self.postsCursor = postsCursor
    }
}
