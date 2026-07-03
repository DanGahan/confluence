import Testing
import Foundation
@testable import ConfluenceKit

struct ThreadTests {
    // MARK: Bluesky getPostThread

    @Test func blueskyThreadFlattensAncestorsAndRepliesChronologically() async throws {
        // parent (10:00) <- focus (10:05) with two replies (10:07, 10:06).
        let json = """
        {
          "thread": {
            "post": {
              "uri": "at://did/post/focus",
              "author": {"did": "did:b", "handle": "b.social"},
              "record": {"text": "focus", "createdAt": "2026-07-01T10:05:00.000Z", "reply": {}},
              "replyCount": 2
            },
            "parent": {
              "post": {
                "uri": "at://did/post/root",
                "author": {"did": "did:a", "handle": "a.social"},
                "record": {"text": "root", "createdAt": "2026-07-01T10:00:00.000Z"},
                "replyCount": 1
              }
            },
            "replies": [
              {"post": {"uri": "at://did/post/r2", "author": {"did": "did:c", "handle": "c.social"},
                        "record": {"text": "second reply", "createdAt": "2026-07-01T10:07:00.000Z", "reply": {}}}},
              {"post": {"uri": "at://did/post/r1", "author": {"did": "did:d", "handle": "d.social"},
                        "record": {"text": "first reply", "createdAt": "2026-07-01T10:06:00.000Z", "reply": {}}}}
            ]
          }
        }
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/app.bsky.feed.getPostThread")
            #expect(request.url?.query?.contains("uri=at://did/post/focus") == true)
            return (request.status(200), json)
        })
        let thread = try await client.postThread(accessToken: "tok", uri: "at://did/post/focus")
        #expect(thread.items.map(\.text) == ["root", "focus", "first reply", "second reply"])
        #expect(thread.focusID == "bluesky:at://did/post/focus")
        let focus = try #require(thread.items.first { $0.id == thread.focusID })
        #expect(focus.isReply == true)
        #expect(focus.replyCount == 2)
    }

    // MARK: Mastodon status context

    @Test func mastodonContextAssemblesFocusAncestorsDescendants() async throws {
        let focus = """
        {"id": "20", "created_at": "2026-07-01T10:05:00.000Z", "content": "<p>focus</p>",
         "account": {"id": "1", "display_name": "B", "acct": "b", "avatar": "https://cdn/b.png"},
         "media_attachments": [], "replies_count": 1, "in_reply_to_id": "10"}
        """
        let context = """
        {"ancestors": [
           {"id": "10", "created_at": "2026-07-01T10:00:00.000Z", "content": "<p>root</p>",
            "account": {"id": "2", "display_name": "A", "acct": "a", "avatar": "https://cdn/a.png"},
            "media_attachments": []}],
         "descendants": [
           {"id": "30", "created_at": "2026-07-01T10:09:00.000Z", "content": "<p>reply</p>",
            "account": {"id": "3", "display_name": "C", "acct": "c", "avatar": "https://cdn/c.png"},
            "media_attachments": [], "in_reply_to_id": "20"}]}
        """
        let client = MastodonClient(session: MockURLProtocol.session { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/statuses/20" { return (request.status(200), focus.data(using: .utf8)!) }
            if path == "/api/v1/statuses/20/context" { return (request.status(200), context.data(using: .utf8)!) }
            throw URLError(.badURL)
        })
        let thread = try await client.statusContext(host: "m.social", accessToken: "tok", statusID: "20")
        #expect(thread.items.map(\.text) == ["root", "focus", "reply"])
        #expect(thread.focusID == "mastodon:20")
        let focusItem = try #require(thread.items.first { $0.id == thread.focusID })
        #expect(focusItem.isReply == true)
        #expect(focusItem.replyCount == 1)
    }

    @Test func chronologicalDedupesAndSortsOldestFirst() {
        let base = Date(timeIntervalSince1970: 1_000)
        func item(_ id: String, _ t: TimeInterval) -> FeedItem {
            FeedItem(network: .bluesky, rawId: id, authorName: "x", authorHandle: "x",
                     avatarURL: nil, createdAt: base.addingTimeInterval(t), text: id)
        }
        let out = chronological([item("c", 20), item("a", 0), item("a", 0), item("b", 10)])
        #expect(out.map(\.text) == ["a", "b", "c"])
    }
}
