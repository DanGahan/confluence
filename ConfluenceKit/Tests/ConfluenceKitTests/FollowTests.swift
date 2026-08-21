import Testing
import Foundation
@testable import ConfluenceKit

struct BlueskyFollowTests {
    @Test func followCreatesGraphFollowRecord() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/com.atproto.repo.createRecord")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            #expect(body["collection"] as? String == "app.bsky.graph.follow")
            #expect(body["repo"] as? String == "did:plc:me")
            let record = body["record"] as! [String: Any]
            #expect(record["subject"] as? String == "did:plc:them")
            return (request.status(200), #"{"uri":"at://did:plc:me/app.bsky.graph.follow/abc","cid":"c"}"#.data(using: .utf8)!)
        })
        let uri = try await client.follow(auth: .bearer("tok"), repoDID: "did:plc:me", subjectDID: "did:plc:them")
        #expect(uri == "at://did:plc:me/app.bsky.graph.follow/abc")
    }

    @Test func unfollowDeletesRecordParsedFromURI() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/com.atproto.repo.deleteRecord")
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: String]
            #expect(body["repo"] == "did:plc:me")
            #expect(body["collection"] == "app.bsky.graph.follow")
            #expect(body["rkey"] == "abc")
            return (request.status(200), Data())
        })
        try await client.unfollow(auth: .bearer("tok"), followURI: "at://did:plc:me/app.bsky.graph.follow/abc")
    }
}

struct MastodonFollowTests {
    @Test func followPostsToFollowEndpoint() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/v1/accounts/42/follow")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mtok")
            return (request.status(200), #"{"following":true}"#.data(using: .utf8)!)
        })
        try await client.follow(host: "mastodon.social", accessToken: "mtok", accountID: "42")
    }

    @Test func unfollowPostsToUnfollowEndpoint() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/accounts/42/unfollow")
            return (request.status(200), #"{"following":false}"#.data(using: .utf8)!)
        })
        try await client.unfollow(host: "mastodon.social", accessToken: "mtok", accountID: "42")
    }
}

@MainActor
struct FollowStoreTests {
    nonisolated func item(following: Bool) -> FeedItem {
        FeedItem(network: .bluesky, rawId: "p1", authorID: "did:x", authorName: "A", authorHandle: "a",
                 avatarURL: nil, createdAt: .now, text: "t", isFollowing: following,
                 followURI: following ? "at://x/app.bsky.graph.follow/k" : nil)
    }

    @Test func followOptimisticallyFlipsAndPersists() async {
        let store = FollowStore()
        store.setActions([.bluesky: FollowActions(follow: { _ in "at://new" }, unfollow: { _, _ in })])
        let it = item(following: false)
        await store.toggle(it)
        #expect(store.isFollowing(it) == true)
        #expect(store.lastError == nil)
    }

    @Test func failureRevertsAndReportsError() async {
        let store = FollowStore()
        store.setActions([.bluesky: FollowActions(
            follow: { _ in throw BlueskyError.network },
            unfollow: { _, _ in }
        )])
        let it = item(following: false)
        await store.toggle(it)
        #expect(store.isFollowing(it) == false) // reverted
        #expect(store.lastError != nil)
    }

    @Test func unfollowPassesStoredURI() async {
        let store = FollowStore()
        store.setActions([.bluesky: FollowActions(
            follow: { _ in "u" },
            unfollow: { _, uri in #expect(uri == "at://x/app.bsky.graph.follow/k") }
        )])
        let it = item(following: true)
        await store.toggle(it)
        #expect(store.isFollowing(it) == false)
    }
}
