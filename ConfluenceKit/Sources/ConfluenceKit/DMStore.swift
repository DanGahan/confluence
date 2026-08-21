import Foundation
import Observation

public enum DMError: Error, Equatable { case notAvailable }

/// Per-network DM operations, injected so the store is testable — mirrors FollowActions/PostActions.
public struct DMActions: Sendable {
    public let listConversations: @Sendable () async throws -> [Conversation]
    public let messages: @Sendable (Conversation) async throws -> [DirectMessage]
    public let send: @Sendable (Conversation, String) async throws -> DirectMessage
    public let markRead: @Sendable (Conversation) async throws -> Void
    public init(
        listConversations: @escaping @Sendable () async throws -> [Conversation],
        messages: @escaping @Sendable (Conversation) async throws -> [DirectMessage],
        send: @escaping @Sendable (Conversation, String) async throws -> DirectMessage,
        markRead: @escaping @Sendable (Conversation) async throws -> Void
    ) {
        self.listConversations = listConversations
        self.messages = messages
        self.send = send
        self.markRead = markRead
    }
}

/// Owns the unified DM inbox (F15): fetch + merge conversations across networks, load a
/// conversation's messages, send, and mark read. Networks are injected as `DMActions`, so no
/// networking lives here and it's fully unit-testable.
@MainActor
@Observable
public final class DMStore {
    public private(set) var conversations: [Conversation] = []
    public private(set) var failedNetworks: Set<Network> = []
    public private(set) var isLoading = false

    private var actions: [Network: DMActions] = [:]

    public init() {}

    public var unreadCount: Int { conversations.reduce(0) { $0 + ($1.unread ? 1 : 0) } }

    public func setActions(_ actions: [Network: DMActions]) { self.actions = actions }

    public func refresh() async {
        isLoading = true
        let active = Array(actions)
        let results = await withTaskGroup(of: (Network, [Conversation]?).self) { group in
            for (network, ops) in active {
                group.addTask {
                    do { return (network, try await ops.listConversations()) }
                    catch { return (network, nil) }
                }
            }
            var acc: [(Network, [Conversation]?)] = []
            for await r in group { acc.append(r) }
            return acc
        }
        var groups: [[Conversation]] = []
        var failures: Set<Network> = []
        for (network, convos) in results {
            if let convos { groups.append(convos) } else { failures.insert(network) }
        }
        failedNetworks = failures
        conversations = mergeConversations(groups)
        isLoading = false
    }

    /// A conversation's messages, oldest-first. The view owns the array; the store just fetches.
    public func messages(for conversation: Conversation) async throws -> [DirectMessage] {
        guard let ops = actions[conversation.network] else { return [] }
        return try await ops.messages(conversation)
    }

    /// Sends to the conversation's network only — DMs are never cross-posted.
    public func send(_ text: String, to conversation: Conversation) async throws -> DirectMessage {
        guard let ops = actions[conversation.network] else { throw DMError.notAvailable }
        return try await ops.send(conversation, text)
    }

    public func markRead(_ conversation: Conversation) async {
        guard conversation.unread, let ops = actions[conversation.network] else { return }
        try? await ops.markRead(conversation)
        conversations = conversations.map { $0.id == conversation.id ? $0.markedRead() : $0 }
    }
}
