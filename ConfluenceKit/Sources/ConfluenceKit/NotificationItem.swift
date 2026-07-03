import Foundation

/// A notification, normalized across networks. MVP kinds only: follow, mention, repost.
public struct NotificationItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case follow, mention, repost
    }

    public let network: Network
    public let rawId: String
    public let kind: Kind
    public let actorName: String
    public let actorHandle: String
    public let avatarURL: URL?
    public let createdAt: Date
    /// Post text for mentions/reposts (empty for follows).
    public let snippet: String

    public var id: String { "\(network.rawValue):\(rawId)" }

    public init(network: Network, rawId: String, kind: Kind, actorName: String, actorHandle: String,
                avatarURL: URL?, createdAt: Date, snippet: String = "") {
        self.network = network
        self.rawId = rawId
        self.kind = kind
        self.actorName = actorName
        self.actorHandle = actorHandle
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.snippet = snippet
    }
}

/// Merges per-network notifications, newest first, de-duplicated (deterministic ties).
public func mergeNotifications(_ groups: [[NotificationItem]]) -> [NotificationItem] {
    var seen = Set<String>()
    var all: [NotificationItem] = []
    for group in groups {
        for item in group where seen.insert(item.id).inserted { all.append(item) }
    }
    return all.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
}
