import Foundation

/// A user's profile with follow counts. Follow-able like feed authors.
public struct Profile: Sendable, Equatable, Followable {
    public let network: Network
    public let authorID: String
    public let name: String
    public let handle: String
    public let avatarURL: URL?
    public let bio: String
    public let followersCount: Int
    public let followingCount: Int
    public let postsCount: Int
    public let isFollowing: Bool
    public let followURI: String?

    public var authorKey: String { "\(network.rawValue):\(authorID)" }

    public init(network: Network, authorID: String, name: String, handle: String, avatarURL: URL?,
                bio: String, followersCount: Int, followingCount: Int, postsCount: Int,
                isFollowing: Bool, followURI: String?) {
        self.network = network
        self.authorID = authorID
        self.name = name
        self.handle = handle
        self.avatarURL = avatarURL
        self.bio = bio
        self.followersCount = followersCount
        self.followingCount = followingCount
        self.postsCount = postsCount
        self.isFollowing = isFollowing
        self.followURI = followURI
    }
}

/// Which relationship list to load for a profile.
public enum FollowListKind: Sendable {
    case following
    case followers
}
