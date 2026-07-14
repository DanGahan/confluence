import Foundation
import ConfluenceKit

/// The feed's composition root: turns the signed-in account stores into the per-network
/// closures and data the app's stores consume. Keeps FeedView free of networking wiring —
/// it just applies these to feed/follows/postActions/notifications/search/composer (G11).
///
/// Bluesky calls go through `store.withFreshSession` so an expired access token is refreshed
/// and retried once (G4). Produced closures are `@Sendable` and run off the main actor.
@MainActor
struct FeedWiring {
    let bluesky: BlueskyAccountStore
    let mastodon: MastodonAccountStore

    func pageFetchers() -> [Network: PageFetcher] {
        var fetchers: [Network: PageFetcher] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky, client = BlueskyClient()
            fetchers[.bluesky] = { cursor in
                try await store.withFreshSession { try await client.timeline(accessToken: $0.accessJwt, cursor: cursor) }
            }
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            fetchers[.mastodon] = { cursor in
                try await client.homeTimeline(host: session.host, accessToken: session.accessToken, maxId: cursor)
            }
        }
        return fetchers
    }

    func followActions() -> [Network: FollowActions] {
        var actions: [Network: FollowActions] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky, client = BlueskyClient()
            actions[.bluesky] = FollowActions(
                follow: { did in
                    guard let session = await store.session else { throw BlueskyError.invalidCredentials }
                    return try await client.follow(accessToken: session.accessJwt, repoDID: session.did, subjectDID: did)
                },
                unfollow: { _, followURI in
                    guard let session = await store.session, let followURI else { return }
                    try await client.unfollow(accessToken: session.accessJwt, followURI: followURI)
                }
            )
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            actions[.mastodon] = FollowActions(
                follow: { id in
                    try await client.follow(host: session.host, accessToken: session.accessToken, accountID: id)
                    return nil
                },
                unfollow: { id, _ in
                    try await client.unfollow(host: session.host, accessToken: session.accessToken, accountID: id)
                }
            )
        }
        return actions
    }

    func postActions() -> [Network: PostActions] {
        var actions: [Network: PostActions] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky, client = BlueskyClient()
            actions[.bluesky] = PostActions(
                repost: { item in
                    guard let cid = item.cid else { return nil }
                    return try await store.withFreshSession { try await client.repost(accessToken: $0.accessJwt, repoDID: $0.did, uri: item.rawId, cid: cid) }
                },
                unrepost: { _, recordURI in
                    guard let recordURI else { return }
                    try await store.withFreshSession { try await client.deleteRecord(accessToken: $0.accessJwt, uri: recordURI) }
                },
                like: { item in
                    guard let cid = item.cid else { return nil }
                    return try await store.withFreshSession { try await client.like(accessToken: $0.accessJwt, repoDID: $0.did, uri: item.rawId, cid: cid) }
                },
                unlike: { _, recordURI in
                    guard let recordURI else { return }
                    try await store.withFreshSession { try await client.deleteRecord(accessToken: $0.accessJwt, uri: recordURI) }
                },
                block: { item in
                    _ = try await store.withFreshSession { try await client.block(accessToken: $0.accessJwt, repoDID: $0.did, subjectDID: item.authorID) }
                },
                delete: { item in
                    try await store.withFreshSession { try await client.deletePost(accessToken: $0.accessJwt, uri: item.rawId) }
                }
            )
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            actions[.mastodon] = PostActions(
                repost: { item in try await client.reblog(host: session.host, accessToken: session.accessToken, statusID: item.threadID); return nil },
                unrepost: { item, _ in try await client.unreblog(host: session.host, accessToken: session.accessToken, statusID: item.threadID) },
                like: { item in try await client.favourite(host: session.host, accessToken: session.accessToken, statusID: item.threadID); return nil },
                unlike: { item, _ in try await client.unfavourite(host: session.host, accessToken: session.accessToken, statusID: item.threadID) },
                block: { item in try await client.block(host: session.host, accessToken: session.accessToken, accountID: item.authorID) },
                delete: { item in try await client.deletePost(host: session.host, accessToken: session.accessToken, statusID: item.threadID) }
            )
        }
        return actions
    }

    func notificationFetchers() -> [Network: NotificationFetcher] {
        var fetchers: [Network: NotificationFetcher] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky, client = BlueskyClient()
            fetchers[.bluesky] = {
                try await store.withFreshSession { try await client.notifications(accessToken: $0.accessJwt) }
            }
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            fetchers[.mastodon] = {
                try await client.notifications(host: session.host, accessToken: session.accessToken)
            }
        }
        return fetchers
    }

    func searchFetchers() -> [Network: SearchFetcher] {
        var fetchers: [Network: SearchFetcher] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky, client = BlueskyClient()
            fetchers[.bluesky] = { query, cursor in
                guard let token = await store.session?.accessJwt else { return SearchResults(failed: true) }
                return await client.search(accessToken: token, query: query, cursor: cursor)
            }
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            fetchers[.mastodon] = { query, cursor in
                await client.search(host: session.host, accessToken: session.accessToken, query: query, cursor: cursor)
            }
        }
        return fetchers
    }

    /// Signed-in user keys per network, so own-post actions (Delete) can appear.
    func ownAuthorKeys() async -> Set<String> {
        var keys: Set<String> = []
        if let did = bluesky.session?.did { keys.insert("\(Network.bluesky.rawValue):\(did)") }
        if let session = mastodon.session,
           let me = try? await MastodonClient().currentAccount(host: session.host, accessToken: session.accessToken) {
            keys.insert("\(Network.mastodon.rawValue):\(me.authorID)")
        }
        return keys
    }

    /// Mastodon relationships for the given author ids (timelines omit follow-state).
    func mastodonFollowState(authorIDs: [String]) async -> [String: Bool]? {
        guard let session = mastodon.session, !authorIDs.isEmpty else { return nil }
        return await MastodonClient().relationships(host: session.host, accessToken: session.accessToken, accountIDs: authorIDs)
    }

    /// Composer posters + per-network character limits.
    func composerConfig() async -> (posters: [Network: Poster], limits: [Network: Int]) {
        var posters: [Network: Poster] = [:]
        var limits: [Network: Int] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky, client = BlueskyClient()
            posters[.bluesky] = { text, images in
                try await store.withFreshSession { s in
                    var uploaded: [(blob: Data, alt: String)] = []
                    for attachment in images {
                        let blob = try await client.uploadImage(accessToken: s.accessJwt, data: attachment.data, mimeType: "image/jpeg")
                        uploaded.append((blob: blob, alt: attachment.alt))
                    }
                    _ = try await client.post(accessToken: s.accessJwt, repoDID: s.did, text: text, images: uploaded)
                }
            }
            limits[.bluesky] = 300
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            posters[.mastodon] = { text, images in
                var mediaIDs: [String] = []
                for (i, attachment) in images.enumerated() {
                    mediaIDs.append(try await client.uploadImage(host: session.host, accessToken: session.accessToken,
                                                                 data: attachment.data, filename: "image\(i).jpg",
                                                                 mimeType: "image/jpeg", description: attachment.alt))
                }
                try await client.post(host: session.host, accessToken: session.accessToken, text: text, mediaIDs: mediaIDs)
            }
            limits[.mastodon] = await client.characterLimit(host: session.host)
        }
        return (posters, limits)
    }
}
