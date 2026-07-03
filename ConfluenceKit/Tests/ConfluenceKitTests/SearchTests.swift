import Testing
import Foundation
@testable import ConfluenceKit

struct SearchDecodingTests {
    @Test func blueskySearchReturnsPeopleAndPosts() async {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            switch request.url?.path {
            case "/xrpc/app.bsky.actor.searchActors":
                #expect(request.url?.query?.contains("q=swift") == true)
                let json = #"{"actors":[{"did":"did:1","handle":"a.bsky.social","displayName":"Alice","viewer":{"following":"at://f"}}]}"#
                return (request.status(200), json.data(using: .utf8)!)
            case "/xrpc/app.bsky.feed.searchPosts":
                let json = #"{"posts":[{"uri":"at://p1","author":{"did":"did:2","handle":"b.bsky.social"},"record":{"text":"swift rocks","createdAt":"2026-07-01T10:00:00.000Z"}}]}"#
                return (request.status(200), json.data(using: .utf8)!)
            default:
                return (request.status(404), Data())
            }
        })
        let results = await client.search(accessToken: "tok", query: "swift")
        #expect(results.failed == false)
        #expect(results.people.map(\.name) == ["Alice"])
        #expect(results.people[0].isFollowing == true)
        #expect(results.posts.map(\.text) == ["swift rocks"])
    }

    @Test func blueskySearchFailsOnlyWhenBothFail() async {
        let client = BlueskyClient(session: MockURLProtocol.session { ($0.status(500), Data()) })
        let results = await client.search(accessToken: "tok", query: "x")
        #expect(results.failed == true)
    }

    @Test func mastodonSearchReturnsPeopleAndPosts() async {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v2/search")
            let json = """
            {"accounts":[{"id":"1","display_name":"Carol","acct":"carol","avatar":"https://c","note":"<p>hi bio</p>"}],
             "statuses":[{"id":"9","created_at":"2026-07-01T09:00:00.000Z","content":"<p>hello</p>","account":{"id":"1","display_name":"Carol","acct":"carol","avatar":"https://c","note":""}}],
             "hashtags":[]}
            """
            return (request.status(200), json.data(using: .utf8)!)
        })
        let results = await client.search(host: "mastodon.social", accessToken: "mtok", query: "hi")
        #expect(results.people.map(\.name) == ["Carol"])
        #expect(results.people[0].bio == "hi bio")
        #expect(results.people[0].handle == "carol@mastodon.social")
        #expect(results.posts.map(\.text) == ["hello"])
    }

    @Test func mastodonSearchFailsOnError() async {
        let client = MastodonClient(session: MockURLProtocol.session { ($0.status(401), Data()) })
        let results = await client.search(host: "mastodon.social", accessToken: "t", query: "x")
        #expect(results.failed == true)
    }
}

@MainActor
struct SearchStoreTests {
    nonisolated func actor(_ n: Network, _ id: String) -> SearchActor {
        SearchActor(network: n, authorID: id, name: id, handle: id, avatarURL: nil)
    }
    nonisolated func post(_ n: Network, _ id: String, _ secondsAgo: TimeInterval) -> FeedItem {
        FeedItem(network: n, rawId: id, authorID: "a", authorName: "A", authorHandle: "a",
                 avatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo), text: id)
    }

    @Test func mergesPeopleAndPostsFromBothNetworks() async {
        let store = SearchStore()
        store.setFetchers([
            .bluesky: { _ in SearchResults(people: [self.actor(.bluesky, "b")], posts: [self.post(.bluesky, "bp", 10)]) },
            .mastodon: { _ in SearchResults(people: [self.actor(.mastodon, "m")], posts: [self.post(.mastodon, "mp", 5)]) },
        ])
        await store.runSearch("q")
        #expect(Set(store.people.map(\.id)) == ["bluesky:b", "mastodon:m"])
        #expect(store.posts.map(\.id) == ["mastodon:mp", "bluesky:bp"]) // newest first
        #expect(store.failedNetworks.isEmpty)
    }

    @Test func perNetworkFailureIsIsolated() async {
        let store = SearchStore()
        store.setFetchers([
            .bluesky: { _ in SearchResults(people: [self.actor(.bluesky, "b")]) },
            .mastodon: { _ in SearchResults(failed: true) },
        ])
        await store.runSearch("q")
        #expect(store.people.map(\.id) == ["bluesky:b"])
        #expect(store.failedNetworks == [.mastodon])
    }

    @Test func emptyQueryClears() async {
        let store = SearchStore()
        store.setFetchers([.bluesky: { _ in SearchResults(people: [self.actor(.bluesky, "b")]) }])
        await store.runSearch("q")
        #expect(!store.people.isEmpty)
        store.search("   ")
        #expect(store.people.isEmpty)
    }
}
