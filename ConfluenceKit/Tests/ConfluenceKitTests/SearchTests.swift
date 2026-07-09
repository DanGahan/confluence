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
                // Includes a link facet + an image embed — search must decode these like the feed.
                let json = #"{"posts":[{"uri":"at://p1","cid":"cid1","author":{"did":"did:2","handle":"b.bsky.social"},"record":{"text":"see https://ex.com","createdAt":"2026-07-01T10:00:00.000Z","facets":[{"index":{"byteStart":4,"byteEnd":18},"features":[{"$type":"app.bsky.richtext.facet#link","uri":"https://ex.com"}]}]},"embed":{"images":[{"fullsize":"https://cdn/i.jpg"}]}}]}"#
                return (request.status(200), json.data(using: .utf8)!)
            default:
                return (request.status(404), Data())
            }
        })
        let results = await client.search(accessToken: "tok", query: "swift")
        #expect(results.failed == false)
        #expect(results.people.map(\.name) == ["Alice"])
        #expect(results.people[0].isFollowing == true)
        // Rich decoding: the post carries a link run, images, and a cid (#78).
        let post = results.posts[0]
        #expect(post.text == "see https://ex.com")
        #expect(post.attributedText.runs.contains { $0.link?.absoluteString == "https://ex.com" })
        #expect(post.imageURLs.map(\.absoluteString) == ["https://cdn/i.jpg"])
        #expect(post.cid == "cid1")
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
             "statuses":[{"id":"9","created_at":"2026-07-01T09:00:00.000Z","content":"<p>hello <a href=\\"https://ex.com\\">link</a></p>","account":{"id":"1","display_name":"Carol","acct":"carol","avatar":"https://c","note":""},"media_attachments":[{"type":"image","url":"https://m/pic.jpg"}]}],
             "hashtags":[]}
            """
            return (request.status(200), json.data(using: .utf8)!)
        })
        let results = await client.search(host: "mastodon.social", accessToken: "mtok", query: "hi")
        #expect(results.people.map(\.name) == ["Carol"])
        #expect(results.people[0].bio == "hi bio")
        #expect(results.people[0].handle == "carol@mastodon.social")
        // Rich decoding: HTML link becomes a link run, media becomes imageURLs (#78).
        let post = results.posts[0]
        #expect(post.text == "hello link")
        #expect(post.attributedText.runs.contains { $0.link?.absoluteString == "https://ex.com" })
        #expect(post.imageURLs.map(\.absoluteString) == ["https://m/pic.jpg"])
    }

    @Test func mastodonSearchFailsOnError() async {
        let client = MastodonClient(session: MockURLProtocol.session { ($0.status(401), Data()) })
        let results = await client.search(host: "mastodon.social", accessToken: "t", query: "x")
        #expect(results.failed == true)
    }

    // Resolving a tapped Mastodon status permalink (#100): searching the URL with resolve=true
    // returns the status as the first post, whose threadID is the LOCAL id on the user's
    // instance (42) — not the origin instance's id in the URL — which ThreadView loads from.
    @Test func mastodonResolvesStatusURLToLocalThreadID() async throws {
        let statusURL = "https://mastodon.macstories.net/@appstories/116872581526086363"
        let client = MastodonClient(session: MockURLProtocol.session { request in
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(q.contains { $0.name == "q" && $0.value == statusURL })
            #expect(q.contains { $0.name == "resolve" && $0.value == "true" })
            let json = """
            {"accounts":[],"statuses":[{"id":"42","created_at":"2026-07-01T09:00:00.000Z",
             "content":"<p>remote toot</p>",
             "account":{"id":"7","display_name":"App Stories","acct":"appstories@mastodon.macstories.net","avatar":"https://a","note":""},
             "media_attachments":[]}],"hashtags":[]}
            """
            return (request.status(200), json.data(using: .utf8)!)
        })
        let results = await client.search(host: "mastodon.social", accessToken: "t", query: statusURL)
        let post = try #require(results.posts.first)
        #expect(post.threadID == "42")
        #expect(post.network == .mastodon)
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
            .bluesky: { _, _ in SearchResults(people: [self.actor(.bluesky, "b")], posts: [self.post(.bluesky, "bp", 10)]) },
            .mastodon: { _, _ in SearchResults(people: [self.actor(.mastodon, "m")], posts: [self.post(.mastodon, "mp", 5)]) },
        ])
        await store.runSearch("q")
        #expect(Set(store.people.map(\.id)) == ["bluesky:b", "mastodon:m"])
        #expect(store.posts.map(\.id) == ["mastodon:mp", "bluesky:bp"]) // newest first
        #expect(store.failedNetworks.isEmpty)
    }

    @Test func perNetworkFailureIsIsolated() async {
        let store = SearchStore()
        store.setFetchers([
            .bluesky: { _, _ in SearchResults(people: [self.actor(.bluesky, "b")]) },
            .mastodon: { _, _ in SearchResults(failed: true) },
        ])
        await store.runSearch("q")
        #expect(store.people.map(\.id) == ["bluesky:b"])
        #expect(store.failedNetworks == [.mastodon])
    }

    @Test func emptyQueryClears() async {
        let store = SearchStore()
        store.setFetchers([.bluesky: { _, _ in SearchResults(people: [self.actor(.bluesky, "b")]) }])
        await store.runSearch("q")
        #expect(!store.people.isEmpty)
        store.search("   ")
        #expect(store.people.isEmpty)
    }

    @Test func loadMoreAppendsNextPageUntilCursorEnds() async {
        let store = SearchStore()
        store.setFetchers([
            .bluesky: { _, cursor in
                switch cursor {
                case nil: SearchResults(posts: [self.post(.bluesky, "b1", 10)], postsCursor: "c1")
                case "c1": SearchResults(posts: [self.post(.bluesky, "b2", 20)], postsCursor: nil) // last page
                default: SearchResults(failed: true)
                }
            },
        ])
        await store.runSearch("q")
        #expect(store.posts.map(\.id) == ["bluesky:b1"])
        #expect(store.hasMore == true)

        await store.loadMore()
        #expect(store.posts.map(\.id) == ["bluesky:b1", "bluesky:b2"]) // appended, newest-first order
        #expect(store.hasMore == false)

        await store.loadMore() // no-op at the end
        #expect(store.posts.count == 2)
    }

    @Test func recentSearchesDedupeCapAndPersist() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = SearchStore(defaults: defaults)
        for q in ["swift", "cats", "swift", "  dogs ", "birds", "fish", "moss"] { store.recordSearch(q) }
        // Most-recent first, de-duplicated (case/space-insensitive), capped at 5.
        #expect(store.recentSearches == ["moss", "fish", "birds", "dogs", "swift"])
        store.recordSearch("")
        #expect(store.recentSearches.count == 5) // blank ignored

        // Persists across instances.
        let reopened = SearchStore(defaults: defaults)
        #expect(reopened.recentSearches == ["moss", "fish", "birds", "dogs", "swift"])
        reopened.clearRecents()
        #expect(SearchStore(defaults: defaults).recentSearches.isEmpty)
    }
}
