import Foundation
import Observation

/// Per-network repost / like / block operations for a post. Configured by the app so token
/// refresh stays in one place (like `FollowActions`).
public struct PostActions: Sendable {
    /// `repost`/`like` return the created record's URI (Bluesky) so it can be undone later;
    /// Mastodon returns nil (undo needs only the status id). `unrepost`/`unlike` receive that
    /// URI back.
    public let repost: @Sendable (FeedItem) async throws -> String?
    public let unrepost: @Sendable (FeedItem, _ recordURI: String?) async throws -> Void
    public let like: @Sendable (FeedItem) async throws -> String?
    public let unlike: @Sendable (FeedItem, _ recordURI: String?) async throws -> Void
    public let block: @Sendable (FeedItem) async throws -> Void
    public let delete: @Sendable (FeedItem) async throws -> Void
    /// Post a reply to `FeedItem` with the given text, using the item's network account.
    public let reply: @Sendable (FeedItem, _ text: String) async throws -> Void

    public init(repost: @escaping @Sendable (FeedItem) async throws -> String?,
                unrepost: @escaping @Sendable (FeedItem, String?) async throws -> Void,
                like: @escaping @Sendable (FeedItem) async throws -> String?,
                unlike: @escaping @Sendable (FeedItem, String?) async throws -> Void,
                block: @escaping @Sendable (FeedItem) async throws -> Void,
                delete: @escaping @Sendable (FeedItem) async throws -> Void,
                reply: @escaping @Sendable (FeedItem, String) async throws -> Void) {
        self.repost = repost
        self.unrepost = unrepost
        self.like = like
        self.unlike = unlike
        self.block = block
        self.delete = delete
        self.reply = reply
    }
}

/// Errors surfaced by post actions that need to reach the UI directly (not via the toast).
public enum PostActionError: LocalizedError {
    case notLoggedIn
    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "You're not signed in to that network."
        }
    }
}

/// Tracks which posts the user has reposted/liked this session (optimistic) and runs the
/// actions, surfacing a transient error message on failure.
@MainActor
@Observable
public final class PostActionStore {
    private var reposted: Set<String> = []
    private var liked: Set<String> = []
    // Bluesky repost/like record URIs, kept so the action can be undone this session.
    private var repostURIs: [String: String] = [:]
    private var likeURIs: [String: String] = [:]
    private var blockedAuthors: Set<String> = []
    private var deletedPosts: Set<String> = []
    private var ownAuthorKeys: Set<String> = []
    private var actions: [Network: PostActions] = [:]

    /// Human-readable message for a transient failure toast; cleared by the UI.
    public var lastError: String?

    public init() {}

    public func setActions(_ actions: [Network: PostActions]) { self.actions = actions }

    /// Identify the signed-in user per network (authorKey form) so own-post actions can show.
    public func setOwnAuthorKeys(_ keys: Set<String>) { ownAuthorKeys = keys }

    public func isReposted(_ item: FeedItem) -> Bool { reposted.contains(item.id) }
    public func isLiked(_ item: FeedItem) -> Bool { liked.contains(item.id) }
    public func isBlocked(_ item: FeedItem) -> Bool { blockedAuthors.contains(item.authorKey) }
    public func isOwn(_ item: FeedItem) -> Bool { ownAuthorKeys.contains(item.authorKey) }
    public func isDeleted(_ item: FeedItem) -> Bool { deletedPosts.contains(item.id) }

    /// Repost if not already reposted this session, otherwise un-repost. Optimistic; reverts
    /// on failure. The Bluesky undo deletes the repost record whose URI we kept.
    public func toggleRepost(_ item: FeedItem) async {
        guard let action = actions[item.network] else { return }
        if reposted.contains(item.id) {
            reposted.remove(item.id) // optimistic
            do {
                try await action.unrepost(item, repostURIs[item.id])
                repostURIs[item.id] = nil
            } catch {
                reposted.insert(item.id) // revert
                lastError = (error as? LocalizedError)?.errorDescription ?? "Couldn't undo repost. Please try again."
            }
        } else {
            reposted.insert(item.id) // optimistic
            do {
                repostURIs[item.id] = try await action.repost(item)
            } catch {
                reposted.remove(item.id) // revert
                lastError = (error as? LocalizedError)?.errorDescription ?? "Couldn't repost. Please try again."
            }
        }
    }

    /// Like if not already liked this session, otherwise un-like. Optimistic; reverts on failure.
    public func toggleLike(_ item: FeedItem) async {
        guard let action = actions[item.network] else { return }
        if liked.contains(item.id) {
            liked.remove(item.id) // optimistic
            do {
                try await action.unlike(item, likeURIs[item.id])
                likeURIs[item.id] = nil
            } catch {
                liked.insert(item.id) // revert
                lastError = (error as? LocalizedError)?.errorDescription ?? "Couldn't undo like. Please try again."
            }
        } else {
            liked.insert(item.id) // optimistic
            do {
                likeURIs[item.id] = try await action.like(item)
            } catch {
                liked.remove(item.id) // revert
                lastError = (error as? LocalizedError)?.errorDescription ?? "Couldn't like. Please try again."
            }
        }
    }

    public func block(_ item: FeedItem) async {
        await run(item, add: item.authorKey, to: \.blockedAuthors, failure: "Couldn't block. Please try again.") {
            try await $0.block(item)
        }
    }

    /// Deletes the user's own post; on success it's hidden from the feed (via `isDeleted`).
    public func delete(_ item: FeedItem) async {
        guard let action = actions[item.network] else { return }
        do {
            try await action.delete(item)
            deletedPosts.insert(item.id)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Couldn't delete. Please try again."
        }
    }

    /// Post a reply to `item`. Throws so the inline reply box shows its own error and stays
    /// open on failure (unlike the toast-based toggles above).
    public func reply(_ item: FeedItem, text: String) async throws {
        guard let action = actions[item.network] else { throw PostActionError.notLoggedIn }
        try await action.reply(item, text)
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
