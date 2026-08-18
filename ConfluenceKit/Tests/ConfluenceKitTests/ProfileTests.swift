import Testing
import Foundation
@testable import ConfluenceKit

struct ProfileDecodingTests {
    @Test func blueskyProfileDecodes() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/app.bsky.actor.getProfile")
            let json = #"{"did":"did:1","handle":"a.bsky.social","displayName":"Alice","description":"hi","avatar":"https://a","followersCount":10,"followsCount":5,"postsCount":42,"viewer":{"following":"at://f"}}"#
            return (request.status(200), json.data(using: .utf8)!)
        })
        let p = try await client.profile(auth: .bearer("t"), actor: "a.bsky.social")
        #expect(p.name == "Alice")
        #expect(p.followersCount == 10)
        #expect(p.followingCount == 5)
        #expect(p.postsCount == 42)
        #expect(p.isFollowing == true)
    }

    @Test func blueskyFollowsListDecodes() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/app.bsky.graph.getFollows")
            let json = #"{"follows":[{"did":"did:2","handle":"b.bsky.social","displayName":"Bob","viewer":{"following":"at://x"}}]}"#
            return (request.status(200), json.data(using: .utf8)!)
        })
        let list = try await client.followList(auth: .bearer("t"), actor: "a", kind: .following)
        #expect(list.map(\.name) == ["Bob"])
        #expect(list[0].isFollowing == true)
    }

    @Test func blueskyFollowersListDecodes() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/app.bsky.graph.getFollowers")
            return (request.status(200), #"{"followers":[{"did":"did:3","handle":"c.bsky.social"}]}"#.data(using: .utf8)!)
        })
        let list = try await client.followList(auth: .bearer("t"), actor: "a", kind: .followers)
        #expect(list.map(\.handle) == ["c.bsky.social"])
    }

    @Test func blueskyAuthorFeedDecodes() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/app.bsky.feed.getAuthorFeed")
            let json = #"{"cursor":"n","feed":[{"post":{"uri":"at://p","author":{"did":"did:1","handle":"a.bsky.social"},"record":{"text":"my post","createdAt":"2026-07-01T10:00:00.000Z"}}}]}"#
            return (request.status(200), json.data(using: .utf8)!)
        })
        let page = try await client.authorFeed(auth: .bearer("t"), actor: "a", cursor: nil)
        #expect(page.items.map(\.text) == ["my post"])
        #expect(page.nextCursor == "n")
    }

    @Test func mastodonProfileDecodes() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            switch request.url?.path {
            case "/api/v1/accounts/9":
                let json = #"{"id":"9","display_name":"Carol","acct":"carol","avatar":"https://c","note":"<p>bio</p>","followers_count":3,"following_count":7,"statuses_count":100}"#
                return (request.status(200), json.data(using: .utf8)!)
            case "/api/v1/accounts/relationships":
                return (request.status(200), #"[{"id":"9","following":true}]"#.data(using: .utf8)!)
            default: return (request.status(404), Data())
            }
        })
        let p = try await client.profile(host: "m.social", accessToken: "t", accountID: "9")
        #expect(p.name == "Carol")
        #expect(p.bio == "bio")
        #expect(p.followersCount == 3)
        #expect(p.postsCount == 100)
        #expect(p.isFollowing == true)
        #expect(p.handle == "carol@m.social")
    }

    @Test func mastodonCurrentAccountUsesVerifyCredentials() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/accounts/verify_credentials")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            let json = #"{"id":"1","display_name":"Me","acct":"me","avatar":"https://a/me.png","note":"","followers_count":0,"following_count":0,"statuses_count":0}"#
            return (request.status(200), json.data(using: .utf8)!)
        })
        let p = try await client.currentAccount(host: "m.social", accessToken: "tok")
        #expect(p.name == "Me")
        #expect(p.handle == "me@m.social")
        #expect(p.avatarURL?.absoluteString == "https://a/me.png")
    }

    @Test func mastodonFollowingListDecodes() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/accounts/9/following")
            return (request.status(200), #"[{"id":"1","display_name":"D","acct":"d","avatar":"https://d","note":""}]"#.data(using: .utf8)!)
        })
        let list = try await client.followList(host: "m.social", accessToken: "t", accountID: "9", kind: .following)
        #expect(list.map(\.name) == ["D"])
    }

    @Test func mastodonAccountStatusesDecode() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/accounts/9/statuses")
            return (request.status(200), #"[{"id":"1","created_at":"2026-07-01T10:00:00.000Z","content":"<p>post</p>","account":{"id":"9","display_name":"Carol","acct":"carol","avatar":"https://c"},"media_attachments":[]}]"#.data(using: .utf8)!)
        })
        let page = try await client.accountStatuses(host: "m.social", accessToken: "t", accountID: "9", maxId: nil)
        #expect(page.items.map(\.text) == ["post"])
    }
}
