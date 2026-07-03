import Foundation
import Observation

/// Per-network follow/unfollow operations. `follow` returns an optional handle (Bluesky
/// follow-record URI) needed later to unfollow; `unfollow` receives it back.
public struct FollowActions: Sendable {
    public let follow: @Sendable (_ authorID: String) async throws -> String?
    public let unfollow: @Sendable (_ authorID: String, _ followURI: String?) async throws -> Void

    public init(follow: @escaping @Sendable (_ authorID: String) async throws -> String?,
                unfollow: @escaping @Sendable (_ authorID: String, _ followURI: String?) async throws -> Void) {
        self.follow = follow
        self.unfollow = unfollow
    }
}

/// Tracks follow state per author and toggles it optimistically, reverting on failure.
@MainActor
@Observable
public final class FollowStore {
    /// Non-nil overrides the item's fetch-time `isFollowing` after a user action.
    private var overrides: [String: Bool] = [:]
    private var followURIs: [String: String?] = [:]
    private var actions: [Network: FollowActions] = [:]

    /// Human-readable message for a transient failure toast; cleared by the UI.
    public var lastError: String?

    public init() {}

    public func setActions(_ actions: [Network: FollowActions]) {
        self.actions = actions
    }

    public func isFollowing(_ item: FeedItem) -> Bool {
        overrides[item.authorKey] ?? item.isFollowing
    }

    public func toggle(_ item: FeedItem) async {
        guard let action = actions[item.network] else { return }
        let key = item.authorKey
        let wasFollowing = isFollowing(item)
        overrides[key] = !wasFollowing // optimistic
        do {
            if wasFollowing {
                try await action.unfollow(item.authorID, followURIs[key] ?? item.followURI)
                followURIs[key] = .some(nil)
            } else {
                followURIs[key] = .some(try await action.follow(item.authorID))
            }
        } catch {
            overrides[key] = wasFollowing // revert
            lastError = (error as? LocalizedError)?.errorDescription ?? "Couldn't update follow. Please try again."
        }
    }
}
