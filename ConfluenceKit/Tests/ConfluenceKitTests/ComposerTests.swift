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

    @Test func blueskyUploadImageReturnsBlobAndPostEmbedsIt() async throws {
        let upload = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/com.atproto.repo.uploadBlob")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
            return (request.status(200), #"{"blob":{"$type":"blob","ref":{"$link":"bafycid"},"mimeType":"image/jpeg","size":10}}"#.data(using: .utf8)!)
        })
        let blob = try await upload.uploadImage(accessToken: "t", data: Data([1, 2, 3]), mimeType: "image/jpeg")
        let blobObj = try JSONSerialization.jsonObject(with: blob) as! [String: Any]
        #expect(blobObj["$type"] as? String == "blob")

        let post = BlueskyClient(session: MockURLProtocol.session { request in
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            let record = body["record"] as! [String: Any]
            let embed = record["embed"] as! [String: Any]
            #expect(embed["$type"] as? String == "app.bsky.embed.images")
            let images = embed["images"] as! [[String: Any]]
            #expect(images.count == 1)
            #expect(((images[0]["image"] as! [String: Any])["$type"] as? String) == "blob")
            return (request.status(200), #"{"uri":"at://x"}"#.data(using: .utf8)!)
        })
        _ = try await post.post(accessToken: "t", repoDID: "did:me", text: "pic", imageBlobs: [blob])
    }

    @Test func mastodonUploadImageAndPostWithMediaIDs() async throws {
        let upload = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v2/media")
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            return (request.status(200), #"{"id":"77"}"#.data(using: .utf8)!)
        })
        let id = try await upload.uploadImage(host: "m.social", accessToken: "t", data: Data([1]), filename: "a.jpg", mimeType: "image/jpeg")
        #expect(id == "77")

        let post = MastodonClient(session: MockURLProtocol.session { request in
            let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            #expect(body.contains("media_ids%5B%5D=77")) // media_ids[]=77
            return (request.status(200), #"{"id":"1"}"#.data(using: .utf8)!)
        })
        try await post.post(host: "m.social", accessToken: "t", text: "pic", mediaIDs: [id])
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
        sut.configure(posters: [.bluesky: { _, _ in }, .mastodon: { _, _ in }], limits: [.bluesky: 300, .mastodon: 500])
        sut.postToBluesky = true; sut.postToMastodon = true
        #expect(sut.characterLimit == 300) // tightest
        sut.postToBluesky = false
        #expect(sut.characterLimit == 500) // only Mastodon
    }

    @Test func canPostRules() {
        let sut = store()
        sut.configure(posters: [.bluesky: { _, _ in }], limits: [.bluesky: 10])
        sut.postToBluesky = true; sut.postToMastodon = true // mastodon not connected
        #expect(sut.canPost == false)        // empty text
        sut.text = "hi"
        #expect(sut.canPost == true)
        sut.text = String(repeating: "x", count: 11)
        #expect(sut.isOverLimit == true)
        #expect(sut.canPost == false)        // over limit
        // An image with no text is postable.
        sut.text = ""
        sut.attachments = [Data([1, 2, 3])]
        #expect(sut.canPost == true)
    }

    @Test func partialFailureThenRetryDoesNotDoublePost() async {
        let sut = store()
        let blueskyCalls = Counter()
        sut.configure(posters: [
            .bluesky: { _, _ in await blueskyCalls.increment() },      // succeeds
            .mastodon: { _, _ in throw MastodonError.network },        // fails
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
