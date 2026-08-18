import Foundation

/// A participant in a DM conversation — the *other* people, never the signed-in user.
public struct DMParticipant: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let handle: String
    public let avatarURL: URL?
    public init(id: String, name: String, handle: String, avatarURL: URL?) {
        self.id = id; self.name = name; self.handle = handle; self.avatarURL = avatarURL
    }
}

/// A DM conversation, normalized across networks (F15).
public struct Conversation: Identifiable, Sendable, Equatable, Hashable {
    public let network: Network
    public let rawId: String
    public let participants: [DMParticipant]
    public let lastSnippet: String
    public let lastActivity: Date
    public let unread: Bool
    /// Mastodon threads a reply onto the conversation's most recent status id; nil for Bluesky.
    public let mastodonReplyToID: String?

    public var id: String { "\(network.rawValue):\(rawId)" }
    /// The other participants' names (both networks allow group DMs).
    public var title: String {
        participants.isEmpty ? "Conversation" : participants.map(\.name).joined(separator: ", ")
    }
    public var avatarURL: URL? { participants.first?.avatarURL }
    /// Mastodon "DMs" are `direct`-visibility posts visible to the server and everyone mentioned —
    /// not a private inbox. The UI must say so; Bluesky chat is at least not publicly visible.
    public var isPrivate: Bool { network != .mastodon }

    public init(network: Network, rawId: String, participants: [DMParticipant], lastSnippet: String,
                lastActivity: Date, unread: Bool, mastodonReplyToID: String? = nil) {
        self.network = network; self.rawId = rawId; self.participants = participants
        self.lastSnippet = lastSnippet; self.lastActivity = lastActivity; self.unread = unread
        self.mastodonReplyToID = mastodonReplyToID
    }

    /// Same conversation with unread cleared — used after mark-read so the badge updates
    /// without a full refetch.
    public func markedRead() -> Conversation {
        Conversation(network: network, rawId: rawId, participants: participants, lastSnippet: lastSnippet,
                     lastActivity: lastActivity, unread: false, mastodonReplyToID: mastodonReplyToID)
    }
}

/// A single message within a conversation.
public struct DirectMessage: Identifiable, Sendable, Equatable {
    public let network: Network
    public let rawId: String
    public let senderID: String
    public let isFromMe: Bool
    public let text: String
    public let sentAt: Date
    public var id: String { "\(network.rawValue):\(rawId)" }

    public init(network: Network, rawId: String, senderID: String, isFromMe: Bool, text: String, sentAt: Date) {
        self.network = network; self.rawId = rawId; self.senderID = senderID
        self.isFromMe = isFromMe; self.text = text; self.sentAt = sentAt
    }
}

/// Merges per-network conversations, most-recent activity first, de-duplicated (deterministic ties).
public func mergeConversations(_ groups: [[Conversation]]) -> [Conversation] {
    var seen = Set<String>()
    var all: [Conversation] = []
    for group in groups {
        for c in group where seen.insert(c.id).inserted { all.append(c) }
    }
    return all.sorted { ($0.lastActivity, $0.id) > ($1.lastActivity, $1.id) }
}
