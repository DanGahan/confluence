import Testing
import Foundation
@testable import ConfluenceKit

struct EngagementTests {
    // MARK: Bluesky

    @Test func blueskyRepostBuildsCreateRecord() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/xrpc/com.atproto.repo.createRecord")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            #expect(body["collection"] as? String == "app.bsky.feed.repost")
            let record = body["record"] as! [String: Any]
            let subject = record["subject"] as! [String: Any]
            #expect(subject["uri"] as? String == "at://did/app.bsky.feed.post/1")
            #expect(subject["cid"] as? String == "bafycid")
            return (request.status(200), #"{"uri":"at://did/app.bsky.feed.repost/xyz"}"#.data(using: .utf8)!)
        })
        let uri = try await client.repost(accessToken: "tok", repoDID: "did", uri: "at://did/app.bsky.feed.post/1", cid: "bafycid")
        #expect(uri == "at://did/app.bsky.feed.repost/xyz")
    }

    @Test func blueskyLikeUsesLikeCollection() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            #expect(body["collection"] as? String == "app.bsky.feed.like")
            return (request.status(200), #"{"uri":"at://x"}"#.data(using: .utf8)!)
        })
        _ = try await client.like(accessToken: "t", repoDID: "did", uri: "at://p", cid: "c")
    }

    @Test func blueskyBlockUsesGraphBlockWithDIDSubject() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            #expect(body["collection"] as? String == "app.bsky.graph.block")
            let record = body["record"] as! [String: Any]
            #expect(record["subject"] as? String == "did:plc:target")
            return (request.status(200), #"{"uri":"at://b"}"#.data(using: .utf8)!)
        })
        _ = try await client.block(accessToken: "t", repoDID: "did", subjectDID: "did:plc:target")
    }

    @Test func blueskyDeletePostSendsDeleteRecord() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/com.atproto.repo.deleteRecord")
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            #expect(body["repo"] as? String == "did:me")
            #expect(body["collection"] as? String == "app.bsky.feed.post")
            #expect(body["rkey"] as? String == "abc")
            return (request.status(200), Data())
        })
        try await client.deletePost(accessToken: "t", uri: "at://did:me/app.bsky.feed.post/abc")
    }

    @Test func blueskyDeleteRecordParsesRepostURI() async throws {
        // Un-repost/un-like delete the repost/like record by its AT URI.
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/com.atproto.repo.deleteRecord")
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            #expect(body["repo"] as? String == "did:me")
            #expect(body["collection"] as? String == "app.bsky.feed.repost")
            #expect(body["rkey"] as? String == "xyz")
            return (request.status(200), Data())
        })
        try await client.deleteRecord(accessToken: "t", uri: "at://did:me/app.bsky.feed.repost/xyz")
    }

    @Test func mastodonUnreblogAndUnfavouritePaths() async throws {
        let un = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/v1/statuses/42/unreblog")
            return (request.status(200), Data())
        })
        try await un.unreblog(host: "m.social", accessToken: "t", statusID: "42")

        let unf = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/statuses/7/unfavourite")
            return (request.status(200), Data())
        })
        try await unf.unfavourite(host: "m.social", accessToken: "t", statusID: "7")
    }

    @Test func mastodonDeletePostSendsDELETE() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/api/v1/statuses/55")
            return (request.status(200), #"{"id":"55"}"#.data(using: .utf8)!)
        })
        try await client.deletePost(host: "m.social", accessToken: "t", statusID: "55")
    }

    @Test func blueskyEngagement401MapsToInvalidCredentials() async {
        let client = BlueskyClient(session: MockURLProtocol.session { ($0.status(401), Data()) })
        await #expect(throws: BlueskyError.invalidCredentials) {
            _ = try await client.like(accessToken: "stale", repoDID: "did", uri: "at://p", cid: "c")
        }
    }

    // MARK: Mastodon

    @Test func mastodonReblogPostsToStatusPath() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/v1/statuses/42/reblog")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return (request.status(200), Data())
        })
        try await client.reblog(host: "m.social", accessToken: "tok", statusID: "42")
    }

    @Test func mastodonFavouriteAndBlockPaths() async throws {
        let fav = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/statuses/7/favourite")
            return (request.status(200), Data())
        })
        try await fav.favourite(host: "m.social", accessToken: "t", statusID: "7")

        let blk = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/accounts/9/block")
            return (request.status(200), Data())
        })
        try await blk.block(host: "m.social", accessToken: "t", accountID: "9")
    }

    // MARK: FeedItem post URL / cid decoding

    @Test func blueskyPostDecodesCidAndWebURL() async throws {
        let json = """
        {"feed":[{"post":{
          "uri":"at://did:plc:a/app.bsky.feed.post/abc123",
          "cid":"bafyxyz",
          "author":{"did":"did:plc:a","handle":"alice.bsky.social"},
          "record":{"text":"hi","createdAt":"2026-07-01T10:00:00.000Z"}
        }}]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { ($0.status(200), json) })
        let item = try #require(try await client.timeline(accessToken: "t", cursor: nil).items.first)
        #expect(item.cid == "bafyxyz")
        #expect(item.postURL?.absoluteString == "https://bsky.app/profile/alice.bsky.social/post/abc123")
    }

    @Test func mastodonStatusDecodesPostURL() async throws {
        let json = """
        [{"id":"1","created_at":"2026-07-01T10:00:00.000Z","content":"<p>hi</p>",
          "url":"https://m.social/@bob/1",
          "account":{"id":"2","display_name":"Bob","acct":"bob","avatar":"https://a"},
          "media_attachments":[]}]
        """.data(using: .utf8)!
        let client = MastodonClient(session: MockURLProtocol.session { ($0.status(200), json) })
        let item = try #require(try await client.homeTimeline(host: "m.social", accessToken: "t", maxId: nil).items.first)
        #expect(item.postURL?.absoluteString == "https://m.social/@bob/1")
    }
}
