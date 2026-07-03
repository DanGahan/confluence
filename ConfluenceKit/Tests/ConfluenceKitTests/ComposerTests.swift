import Testing
import Foundation
@testable import ConfluenceKit

struct PostClientTests {
    @Test func blueskyPostCreatesFeedPostRecord() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/com.atproto.repo.createRecord")
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            #expect(body["collection"] as? String == "app.bsky.feed.post")
            #expect(body["repo"] as? String == "did:me")
            #expect((body["record"] as! [String: Any])["text"] as? String == "hello world")
            return (request.status(200), #"{"uri":"at://did:me/app.bsky.feed.post/1"}"#.data(using: .utf8)!)
        })
        let uri = try await client.post(accessToken: "t", repoDID: "did:me", text: "hello world")
        #expect(uri == "at://did:me/app.bsky.feed.post/1")
    }

    @Test func mastodonPostsStatus() async throws {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/v1/statuses")
            let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            #expect(body.contains("status=hello"))
            return (request.status(200), #"{"id":"1"}"#.data(using: .utf8)!)
        })
        try await client.post(host: "mastodon.social", accessToken: "t", text: "hello there")
    }

    @Test func mastodonCharacterLimitReadsInstanceOrDefaults() async {
        let ok = MastodonClient(session: MockURLProtocol.session { request in
            (request.status(200), #"{"configuration":{"statuses":{"max_characters":1000}}}"#.data(using: .utf8)!)
        })
        #expect(await ok.characterLimit(host: "m.social") == 1000)

        let bad = MastodonClient(session: MockURLProtocol.session { ($0.status(404), Data()) })
        #expect(await bad.characterLimit(host: "m.social") == 500)
    }
}

@MainActor
struct ComposerStoreTests {
    func store() -> ComposerStore {
        ComposerStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    @Test func tightestLimitAmongSelectedNetworks() {
        let sut = store()
        sut.configure(posters: [.bluesky: { _ in }, .mastodon: { _ in }], limits: [.bluesky: 300, .mastodon: 500])
        sut.postToBluesky = true; sut.postToMastodon = true
        #expect(sut.characterLimit == 300) // tightest
        sut.postToBluesky = false
        #expect(sut.characterLimit == 500) // only Mastodon
    }

    @Test func canPostRules() {
        let sut = store()
        sut.configure(posters: [.bluesky: { _ in }], limits: [.bluesky: 10])
        sut.postToBluesky = true; sut.postToMastodon = true // mastodon not connected
        #expect(sut.canPost == false)        // empty text
        sut.text = "hi"
        #expect(sut.canPost == true)
        sut.text = String(repeating: "x", count: 11)
        #expect(sut.isOverLimit == true)
        #expect(sut.canPost == false)        // over limit
    }

    @Test func partialFailureThenRetryDoesNotDoublePost() async {
        let sut = store()
        let blueskyCalls = Counter()
        sut.configure(posters: [
            .bluesky: { _ in await blueskyCalls.increment() },      // succeeds
            .mastodon: { _ in throw MastodonError.network },        // fails
        ], limits: [.bluesky: 300, .mastodon: 500])
        sut.postToBluesky = true; sut.postToMastodon = true
        sut.text = "hi"

        await sut.post()
        #expect(sut.succeeded == [.bluesky])
        #expect(sut.failed.keys.contains(.mastodon))
        #expect(await blueskyCalls.value == 1)

        // Retry: Bluesky already succeeded, so it must NOT be posted again.
        await sut.post()
        #expect(await blueskyCalls.value == 1) // not double-posted
    }

    @Test func togglesPersistAcrossInstances() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let first = ComposerStore(defaults: defaults)
        first.postToBluesky = false
        let second = ComposerStore(defaults: defaults)
        #expect(second.postToBluesky == false)
    }
}

/// Actor counter for concurrency-safe call counting in tests.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
