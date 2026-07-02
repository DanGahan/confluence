import Testing
import Foundation
@testable import ConfluenceKit

struct FeedDecodingTests {
    // MARK: Bluesky

    @Test func decodesBlueskyTimelineWithRepostAndImages() async throws {
        let json = """
        {
          "cursor": "next-page",
          "feed": [
            {
              "post": {
                "uri": "at://did:plc:1/app.bsky.feed.post/aaa",
                "author": {"handle": "alice.bsky.social", "displayName": "Alice", "avatar": "https://cdn/a.jpg"},
                "record": {"text": "hello world", "createdAt": "2026-07-01T10:00:00.000Z"},
                "embed": {"images": [{"fullsize": "https://cdn/img1.jpg"}]}
              },
              "reason": {"by": {"displayName": "Bob"}}
            }
          ]
        }
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            #expect(request.url?.path == "/xrpc/app.bsky.feed.getTimeline")
            return (request.status(200), json)
        })
        let page = try await client.timeline(accessToken: "tok", cursor: nil)
        #expect(page.nextCursor == "next-page")
        let item = try #require(page.items.first)
        #expect(item.network == .bluesky)
        #expect(item.authorName == "Alice")
        #expect(item.text == "hello world")
        #expect(item.imageURLs.map(\.absoluteString) == ["https://cdn/img1.jpg"])
        #expect(item.repostedBy == "Bob")
    }

    @Test func blueskyPassesCursorAsQuery() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.query?.contains("cursor=abc") == true)
            return (request.status(200), #"{"feed":[]}"#.data(using: .utf8)!)
        })
        let page = try await client.timeline(accessToken: "tok", cursor: "abc")
        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
    }

    // MARK: Mastodon

    @Test func decodesMastodonHomeTimelineHTMLAndCursor() async throws {
        let json = """
        [
          {
            "id": "111",
            "created_at": "2026-07-01T09:00:00.000Z",
            "content": "<p>Hello &amp; <a href=\\"x\\">welcome</a></p>",
            "account": {"display_name": "Carol", "acct": "carol", "avatar": "https://m/c.png"},
            "media_attachments": [{"type": "image", "url": "https://m/pic.jpg"}]
          },
          {
            "id": "110",
            "created_at": "2026-07-01T08:00:00.000Z",
            "content": "<p>boosted body</p>",
            "account": {"display_name": "Dave", "acct": "dave", "avatar": "https://m/d.png"},
            "media_attachments": [],
            "reblog": {
              "id": "999",
              "created_at": "2026-06-30T08:00:00.000Z",
              "content": "<p>original</p>",
              "account": {"display_name": "Erin", "acct": "erin@other.social", "avatar": "https://m/e.png"},
              "media_attachments": []
            }
          }
        ]
        """.data(using: .utf8)!
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mtok")
            #expect(request.url?.path == "/api/v1/timelines/home")
            return (request.status(200), json)
        })
        let page = try await client.homeTimeline(host: "mastodon.social", accessToken: "mtok", maxId: nil)
        #expect(page.nextCursor == "110") // oldest id -> max_id for next page

        let first = page.items[0]
        #expect(first.authorName == "Carol")
        #expect(first.text == "Hello & welcome") // tags stripped, entity decoded
        #expect(first.authorHandle == "carol@mastodon.social")
        #expect(first.imageURLs.count == 1)

        let boost = page.items[1]
        #expect(boost.authorName == "Erin")          // shows the original author
        #expect(boost.text == "original")
        #expect(boost.repostedBy == "Dave")          // attributed to the booster
        #expect(boost.authorHandle == "erin@other.social")
    }
}
