import Testing
import Foundation
@testable import ConfluenceKit

/// #212: a reply carries a preview of the post it answers (author + snippet + parent id → thread).
struct ReplyContextTests {
    @Test func blueskyReplyCarriesParentContent() async throws {
        let json = """
        {"feed":[
          {"post":{"uri":"at://did:me/app.bsky.feed.post/child","cid":"c",
             "author":{"did":"did:me","handle":"me.bsky.social"},
             "record":{"text":"my reply","createdAt":"2026-07-01T10:00:00.000Z",
                       "reply":{"root":{"uri":"at://root","cid":"rc"},"parent":{"uri":"at://parent","cid":"pc"}}},
             "replyCount":0},
           "reply":{"parent":{"uri":"at://parent","cid":"pc",
                     "author":{"did":"did:ada","handle":"ada.bsky.social","displayName":"Ada"},
                     "record":{"text":"the original message"}}}}
        ]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { req in
            #expect(req.url?.path == "/xrpc/app.bsky.feed.getTimeline")
            return (req.status(200), json)
        })
        let page = try await client.timeline(auth: .bearer("t"), cursor: nil)
        let parent = try #require(page.items.first?.replyParent)
        #expect(parent.authorName == "Ada")
        #expect(parent.authorHandle == "ada.bsky.social")
        #expect(parent.snippet == "the original message")
        #expect(parent.threadID == "at://parent") // opens the parent's thread
    }

    @Test func blueskyNonReplyHasNoParent() async throws {
        let json = """
        {"feed":[{"post":{"uri":"at://did:me/app.bsky.feed.post/x","cid":"c",
          "author":{"did":"did:me","handle":"me.bsky.social"},
          "record":{"text":"top level","createdAt":"2026-07-01T10:00:00.000Z"},"replyCount":0}}]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { req in (req.status(200), json) })
        let page = try await client.timeline(auth: .bearer("t"), cursor: nil)
        #expect(page.items.first?.replyParent == nil)
    }

    @Test func mastodonReplyCarriesParentAuthorAndThreadID() async throws {
        let json = """
        [{"id":"child","created_at":"2026-07-01T10:00:00.000Z","content":"<p>my reply</p>",
          "account":{"id":"me","display_name":"Me","acct":"me","avatar":"https://m"},
          "media_attachments":[],"in_reply_to_id":"parent123","in_reply_to_account_id":"11",
          "mentions":[{"id":"11","url":"https://x/@ada","acct":"ada@x.social"}]}]
        """.data(using: .utf8)!
        let client = MastodonClient(session: MockURLProtocol.session { req in
            #expect(req.url?.path == "/api/v1/timelines/home")
            return (req.status(200), json)
        })
        let page = try await client.homeTimeline(host: "x.social", accessToken: "t", maxId: nil)
        let parent = try #require(page.items.first?.replyParent)
        #expect(parent.authorHandle == "ada@x.social")
        #expect(parent.threadID == "parent123")
        #expect(parent.snippet == "") // parent body isn't in the home timeline
    }

    @Test func mastodonStatusPreviewFillsInParentBody() async throws {
        let json = #"{"id":"parent123","created_at":"2026-07-01T09:00:00.000Z","content":"<p>the original toot</p>","account":{"id":"11","display_name":"Ada","acct":"ada","avatar":"https://a"},"media_attachments":[]}"#
        let client = MastodonClient(session: MockURLProtocol.session { req in
            #expect(req.url?.path == "/api/v1/statuses/parent123")
            return (req.status(200), json.data(using: .utf8)!)
        })
        let ref = try await client.statusPreview(host: "x.social", accessToken: "t", id: "parent123")
        #expect(ref.authorName == "Ada")
        #expect(ref.authorHandle == "ada@x.social")
        #expect(ref.snippet == "the original toot")
        #expect(ref.threadID == "parent123")
    }
}
