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
                "author": {"did": "did:plc:alice", "handle": "alice.bsky.social", "displayName": "Alice", "avatar": "https://cdn/a.jpg", "viewer": {"following": "at://did:plc:me/app.bsky.graph.follow/xyz"}},
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
        #expect(item.authorID == "did:plc:alice")
        #expect(item.isFollowing == true)
        #expect(item.followURI == "at://did:plc:me/app.bsky.graph.follow/xyz")
    }

    @Test func decodesBlueskyExternalEmbedAsLinkCard() async throws {
        // A link-only post: empty text, an external embed carries the content (bridged accounts).
        let json = """
        {
          "feed": [{
            "post": {
              "uri": "at://did/app.bsky.feed.post/ext",
              "author": {"did": "did:plc:x", "handle": "x.brid.gy"},
              "record": {"text": "", "createdAt": "2026-07-01T10:00:00.000Z"},
              "embed": {
                "$type": "app.bsky.embed.external#view",
                "external": {"uri": "https://example.com/story", "title": "Big Story",
                             "description": "What happened", "thumb": "https://cdn/thumb.jpg"}
              }
            }
          }]
        }
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            (request.status(200), json)
        })
        let item = try #require(try await client.timeline(accessToken: "tok", cursor: nil).items.first)
        let card = try #require(item.linkCard)
        #expect(card.url.absoluteString == "https://example.com/story")
        #expect(card.title == "Big Story")
        #expect(card.description == "What happened")
        #expect(card.thumbURL?.absoluteString == "https://cdn/thumb.jpg")
        #expect(item.imageURLs.isEmpty)
    }

    @Test func decodesBlueskyVideoEmbed() async throws {
        let json = """
        {
          "feed": [{
            "post": {
              "uri": "at://did/app.bsky.feed.post/vid",
              "author": {"did": "did:plc:v", "handle": "v.bsky.social"},
              "record": {"text": "watch this", "createdAt": "2026-07-01T10:00:00.000Z"},
              "embed": {
                "$type": "app.bsky.embed.video#view",
                "playlist": "https://video.cdn/playlist.m3u8",
                "thumbnail": "https://video.cdn/thumb.jpg",
                "aspectRatio": {"width": 1920, "height": 1080}
              }
            }
          }]
        }
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { ($0.status(200), json) })
        let item = try #require(try await client.timeline(accessToken: "tok", cursor: nil).items.first)
        let video = try #require(item.videos.first)
        #expect(video.url.absoluteString == "https://video.cdn/playlist.m3u8")
        #expect(video.thumbnailURL?.absoluteString == "https://video.cdn/thumb.jpg")
        #expect(item.imageURLs.isEmpty)
        #expect(item.linkCard == nil)
    }

    @Test func decodesBlueskyRecordWithMediaVideo() async throws {
        // A quote post that also embeds a video: the video lives under `media`.
        let json = """
        {
          "feed": [{
            "post": {
              "uri": "at://did/app.bsky.feed.post/rwm",
              "author": {"did": "did:plc:r", "handle": "r.bsky.social"},
              "record": {"text": "quote + clip", "createdAt": "2026-07-01T10:00:00.000Z"},
              "embed": {
                "$type": "app.bsky.embed.recordWithMedia#view",
                "media": {
                  "$type": "app.bsky.embed.video#view",
                  "playlist": "https://video.cdn/nested.m3u8",
                  "thumbnail": "https://video.cdn/nested-thumb.jpg"
                }
              }
            }
          }]
        }
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { ($0.status(200), json) })
        let item = try #require(try await client.timeline(accessToken: "tok", cursor: nil).items.first)
        let video = try #require(item.videos.first)
        #expect(video.url.absoluteString == "https://video.cdn/nested.m3u8")
        #expect(video.thumbnailURL?.absoluteString == "https://video.cdn/nested-thumb.jpg")
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

    @Test func blueskyRepostOrdersByRepostTimeNotOriginal() async throws {
        // A repost of an old post must sort by when it was reposted, not authored.
        let json = """
        {"feed":[{
          "post": {
            "uri": "at://old",
            "author": {"did": "did:x", "handle": "x.bsky.social"},
            "record": {"text": "ancient", "createdAt": "2023-01-01T00:00:00.000Z"},
            "indexedAt": "2023-01-01T00:00:00.000Z"
          },
          "reason": {"by": {"displayName": "Reposter"}, "indexedAt": "2026-07-01T12:00:00.000Z"}
        }]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { ($0.status(200), json) })
        let item = try #require(try await client.timeline(accessToken: "t", cursor: nil).items.first)
        #expect(item.createdAt == ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z"))
        #expect(item.repostedBy == "Reposter")
    }

    @Test func mastodonBoostOrdersByBoostTime() async throws {
        let json = """
        [{"id":"1","created_at":"2026-07-01T12:00:00.000Z","content":"<p>wrap</p>",
          "account":{"id":"9","display_name":"Booster","acct":"booster","avatar":"https://a","note":""},
          "reblog":{"id":"orig","created_at":"2020-01-01T00:00:00.000Z","content":"<p>old</p>",
            "account":{"id":"7","display_name":"Author","acct":"author","avatar":"https://b","note":""},"media_attachments":[]},
          "media_attachments":[]}]
        """.data(using: .utf8)!
        let client = MastodonClient(session: MockURLProtocol.session { ($0.status(200), json) })
        let item = try #require(try await client.homeTimeline(host: "m.social", accessToken: "t", maxId: nil).items.first)
        #expect(item.createdAt == ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z"))
        #expect(item.repostedBy == "Booster")
        #expect(item.authorName == "Author")
    }

    @Test func blueskyExpiredTokenMapsToInvalidCredentials() async {
        // AT Proto returns 400 ExpiredToken (not 401) for a stale access token.
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            (request.status(400), #"{"error":"ExpiredToken","message":"Token has expired"}"#.data(using: .utf8)!)
        })
        await #expect(throws: BlueskyError.invalidCredentials) {
            try await client.timeline(accessToken: "stale", cursor: nil)
        }
    }

    // MARK: Mastodon

    @Test func decodesMastodonHomeTimelineHTMLAndCursor() async throws {
        let json = """
        [
          {
            "id": "111",
            "created_at": "2026-07-01T09:00:00.000Z",
            "content": "<p>Hello &amp; <a href=\\"x\\">welcome</a></p>",
            "account": {"id": "1", "display_name": "Carol", "acct": "carol", "avatar": "https://m/c.png"},
            "media_attachments": [{"type": "image", "url": "https://m/pic.jpg"}]
          },
          {
            "id": "110",
            "created_at": "2026-07-01T08:00:00.000Z",
            "content": "<p>boosted body</p>",
            "account": {"id": "2", "display_name": "Dave", "acct": "dave", "avatar": "https://m/d.png"},
            "media_attachments": [],
            "reblog": {
              "id": "999",
              "created_at": "2026-06-30T08:00:00.000Z",
              "content": "<p>original</p>",
              "account": {"id": "3", "display_name": "Erin", "acct": "erin@other.social", "avatar": "https://m/e.png"},
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

    @Test func decodesMastodonVideoAndGifvAttachments() async throws {
        let json = """
        [
          {
            "id": "201", "created_at": "2026-07-01T09:00:00.000Z", "content": "<p>clip</p>",
            "account": {"id": "1", "display_name": "Vic", "acct": "vic", "avatar": "https://m/v.png"},
            "media_attachments": [
              {"type": "video", "url": "https://m/clip.mp4", "preview_url": "https://m/clip-thumb.jpg"}
            ]
          },
          {
            "id": "200", "created_at": "2026-07-01T08:00:00.000Z", "content": "<p>loop</p>",
            "account": {"id": "2", "display_name": "Gina", "acct": "gina", "avatar": "https://m/g.png"},
            "media_attachments": [
              {"type": "gifv", "url": "https://m/loop.mp4", "preview_url": "https://m/loop-thumb.jpg"}
            ]
          }
        ]
        """.data(using: .utf8)!
        let client = MastodonClient(session: MockURLProtocol.session { ($0.status(200), json) })
        let page = try await client.homeTimeline(host: "mastodon.social", accessToken: "t", maxId: nil)

        let clip = try #require(page.items.first { $0.authorName == "Vic" })
        #expect(clip.imageURLs.isEmpty)
        #expect(clip.videos.map(\.url.absoluteString) == ["https://m/clip.mp4"])
        #expect(clip.videos.first?.thumbnailURL?.absoluteString == "https://m/clip-thumb.jpg")

        let gif = try #require(page.items.first { $0.authorName == "Gina" })
        #expect(gif.videos.map(\.url.absoluteString) == ["https://m/loop.mp4"])
    }
}
