import Foundation
import Observation

/// Per-network repost / like / block operations for a post. Configured by the app so token
/// refresh stays in one place (like `FollowActions`).
public struct PostActions: Sendable {
    public let repost: @Sendable (FeedItem) async throws -> Void
    public let like: @Sendable (FeedItem) async throws -> Void
    public let block: @Sendable (FeedItem) async throws -> Void

    public init(repost: @escaping @Sendable (FeedItem) async throws -> Void,
                like: @escaping @Sendable (FeedItem) async throws -> Void,
                block: @escaping @Sendable (FeedItem) async throws -> Void) {
        self.repost = repost
        self.like = like
        self.block = block
    }
}

/// Tracks which posts the user has reposted/liked this session (optimistic) and runs the
/// actions, surfacing a transient error message on failure.
@MainActor
@Observable
public final class PostActionStore {
    private var reposted: Set<String> = []
    private var liked: Set<String> = []
    private var blockedAuthors: Set<String> = []
    private var actions: [Network: PostActions] = [:]

    /// Human-readable message for a transient failure toast; cleared by the UI.
    public var lastError: String?

    public init() {}

    public func setActions(_ actions: [Network: PostActions]) { self.actions = actions }

    public func isReposted(_ item: FeedItem) -> Bool { reposted.contains(item.id) }
    public func isLiked(_ item: FeedItem) -> Bool { liked.contains(item.id) }
    public func isBlocked(_ item: FeedItem) -> Bool { blockedAuthors.contains(item.authorKey) }

    public func repost(_ item: FeedItem) async {
        await run(item, add: item.id, to: \.reposted, failure: "Couldn't repost. Please try again.") {
            try await $0.repost(item)
        }
    }

    public func like(_ item: FeedItem) async {
        await run(item, add: item.id, to: \.liked, failure: "Couldn't like. Please try again.") {
            try await $0.like(item)
        }
    }

    public func block(_ item: FeedItem) async {
        await run(item, add: item.authorKey, to: \.blockedAuthors, failure: "Couldn't block. Please try again.") {
            try await $0.block(item)
        }
    }

    private func run(_ item: FeedItem, add key: String, to set: ReferenceWritableKeyPath<PostActionStore, Set<String>>,
                     failure: String, _ body: (PostActions) async throws -> Void) async {
        guard let action = actions[item.network] else { return }
        self[keyPath: set].insert(key) // optimistic
        do {
            try await body(action)
        } catch {
            self[keyPath: set].remove(key) // revert
            lastError = (error as? LocalizedError)?.errorDescription ?? failure
        }
    }
}
