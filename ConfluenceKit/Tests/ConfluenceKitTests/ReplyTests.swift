import Testing
import Foundation
@testable import ConfluenceKit

struct ReplyTests {
    @Test func blueskyReplyRootsAtConversationNotParent() async throws {
        // Replying to a mid-thread post: parent is that post, root is the distinct thread root.
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/com.atproto.repo.createRecord")
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            let record = body["record"] as! [String: Any]
            #expect(record["text"] as? String == "nice one")
            let reply = record["reply"] as! [String: Any]
            let parent = reply["parent"] as! [String: Any]
            let root = reply["root"] as! [String: Any]
            #expect(parent["uri"] as? String == "at://did:them/app.bsky.feed.post/mid")
            #expect(parent["cid"] as? String == "bafymid")
            #expect(root["uri"] as? String == "at://did:them/app.bsky.feed.post/root")
            #expect(root["cid"] as? String == "bafyroot")
            return (request.status(200), #"{"uri":"at://did:me/app.bsky.feed.post/xyz"}"#.data(using: .utf8)!)
        })
        _ = try await client.post(accessToken: "t", repoDID: "did:me", text: "nice one",
                                  reply: (parent: PostRef(uri: "at://did:them/app.bsky.feed.post/mid", cid: "bafymid"),
                                          root: PostRef(uri: "at://did:them/app.bsky.feed.post/root", cid: "bafyroot")))
    }

    @Test func blueskyNoReplyOmitsReplyField() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            let record = body["record"] as! [String: Any]
            #expect(record["reply"] == nil)
            return (request.status(200), #"{"uri":"at://did:me/app.bsky.feed.post/xyz"}"#.data(using: .utf8)!)
        })
        _ = try await client.post(accessToken: "t", repoDID: "did:me", text: "top level")
    }

    @Test func mastodonReplySendsInReplyToID() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/statuses")
            let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            #expect(body.contains("in_reply_to_id=112233"))
            #expect(body.contains("status=hello"))
            return (request.status(200), "{}".data(using: .utf8)!)
        })
        try await client.post(host: "mastodon.social", accessToken: "t", text: "hello", inReplyToID: "112233")
    }

    @Test func mastodonNoReplyOmitsInReplyToID() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            #expect(!body.contains("in_reply_to_id"))
            return (request.status(200), "{}".data(using: .utf8)!)
        })
        try await client.post(host: "mastodon.social", accessToken: "t", text: "top level")
    }
}

struct BlueskyResolveHandleTests {
    @Test func resolveHandleReturnsDID() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/com.atproto.identity.resolveHandle")
            #expect(request.url?.query?.contains("handle=lisaocarroll.bsky.social") == true)
            return (request.status(200), #"{"did":"did:plc:lisa"}"#.data(using: .utf8)!)
        })
        let did = try await client.resolveHandle(accessToken: "t", handle: "lisaocarroll.bsky.social")
        #expect(did == "did:plc:lisa")
    }
}
