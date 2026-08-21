import Testing
import Foundation
@testable import ConfluenceKit

/// #196: images carry their aspect ratio so the row reserves space before they load (no scroll jump).
struct ImageAspectTests {
    @Test func blueskyImageAspectFromEmbed() async throws {
        let json = """
        {"feed":[{"post":{"uri":"at://p","cid":"c","author":{"did":"did:me","handle":"me.bsky.social"},
          "record":{"text":"pic","createdAt":"2026-07-01T10:00:00.000Z"},
          "embed":{"$type":"app.bsky.embed.images#view",
                   "images":[{"fullsize":"https://img/1.jpg","aspectRatio":{"width":1600,"height":900}}]}}}]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { req in (req.status(200), json) })
        let page = try await client.timeline(auth: .bearer("t"), cursor: nil)
        let item = try #require(page.items.first)
        #expect(item.imageURLs.map(\.absoluteString) == ["https://img/1.jpg"])
        #expect(item.imageAspects.count == 1)
        #expect(abs(item.imageAspects[0] - 1600.0 / 900.0) < 0.001)
    }

    @Test func mastodonImageAspectFromMeta() async throws {
        let json = """
        [{"id":"1","created_at":"2026-07-01T10:00:00.000Z","content":"<p>pic</p>",
          "account":{"id":"a","display_name":"A","acct":"a","avatar":"https://av"},
          "media_attachments":[{"type":"image","url":"https://img/2.jpg",
                                "meta":{"original":{"width":1080,"height":720,"aspect":1.5}}}]}]
        """.data(using: .utf8)!
        let client = MastodonClient(session: MockURLProtocol.session { req in (req.status(200), json) })
        let page = try await client.homeTimeline(host: "x.social", accessToken: "t", maxId: nil)
        let item = try #require(page.items.first)
        #expect(item.imageURLs.map(\.absoluteString) == ["https://img/2.jpg"])
        #expect(item.imageAspects == [1.5])
    }

    @Test func missingDimensionsGiveZeroAspect() async throws {
        // Bluesky embed without aspectRatio → 0 (PostImages falls back).
        let json = """
        {"feed":[{"post":{"uri":"at://p","cid":"c","author":{"did":"did:me","handle":"h"},
          "record":{"text":"x","createdAt":"2026-07-01T10:00:00.000Z"},
          "embed":{"images":[{"fullsize":"https://img/3.jpg"}]}}}]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { req in (req.status(200), json) })
        let item = try #require(try await client.timeline(auth: .bearer("t"), cursor: nil).items.first)
        #expect(item.imageAspects == [0])
    }
}
