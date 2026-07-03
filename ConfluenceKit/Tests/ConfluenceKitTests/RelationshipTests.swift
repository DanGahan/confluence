import Testing
import Foundation
@testable import ConfluenceKit

struct MastodonRelationshipTests {
    @Test func decodesFollowingMap() async {
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/accounts/relationships")
            #expect(request.url?.query?.contains("id%5B%5D=1") == true) // id[]=1 encoded
            let json = #"[{"id":"1","following":true},{"id":"2","following":false}]"#
            return (request.status(200), json.data(using: .utf8)!)
        })
        let map = await client.relationships(host: "m.social", accessToken: "t", accountIDs: ["1", "2"])
        #expect(map == ["1": true, "2": false])
    }

    @Test func emptyIdsSkipsRequest() async {
        let client = MastodonClient(session: MockURLProtocol.session { _ in (URLRequest(url: URL(string: "https://x")!).status(500), Data()) })
        #expect(await client.relationships(host: "m.social", accessToken: "t", accountIDs: []).isEmpty)
    }

    @Test func failureReturnsEmpty() async {
        let client = MastodonClient(session: MockURLProtocol.session { ($0.status(401), Data()) })
        #expect(await client.relationships(host: "m.social", accessToken: "t", accountIDs: ["1"]).isEmpty)
    }
}

@MainActor
struct FollowStoreSeedTests {
    func item(_ id: String, following: Bool) -> FeedItem {
        FeedItem(network: .mastodon, rawId: "p", authorID: id, authorName: "A", authorHandle: "a",
                 avatarURL: nil, createdAt: .now, text: "t", isFollowing: following)
    }

    @Test func seedSetsFollowStateWhenNoOverride() {
        let store = FollowStore()
        store.seed([.mastodon: ["1": true, "2": false]])
        #expect(store.isFollowing(item("1", following: false)) == true)  // seed overrides fetch-time false
        #expect(store.isFollowing(item("2", following: true)) == false)  // seed overrides fetch-time true
    }

    @Test func seedDoesNotClobberPendingUserAction() async {
        let store = FollowStore()
        store.setActions([.mastodon: FollowActions(follow: { _ in nil }, unfollow: { _, _ in })])
        let it = item("1", following: false)
        await store.toggle(it) // user follows -> override = true
        store.seed([.mastodon: ["1": false]]) // stale server state must not overwrite
        #expect(store.isFollowing(it) == true)
    }
}
