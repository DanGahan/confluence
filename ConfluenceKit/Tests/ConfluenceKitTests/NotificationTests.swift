import Testing
import Foundation
@testable import ConfluenceKit

struct NotificationDecodingTests {
    @Test func blueskyMapsAndFiltersReasons() async throws {
        let json = """
        {"notifications":[
          {"uri":"at://1","reason":"follow","author":{"did":"did:plc:alice","handle":"a.bsky.social","displayName":"Alice","avatar":"https://a"},"indexedAt":"2026-07-01T10:00:00.000Z"},
          {"uri":"at://2","reason":"like","author":{"did":"did:plc:bob","handle":"b.bsky.social"},"indexedAt":"2026-07-01T09:00:00.000Z"},
          {"uri":"at://3","reason":"repost","author":{"did":"did:plc:carol","handle":"c.bsky.social"},"record":{"text":"boosted"},"indexedAt":"2026-07-01T08:00:00.000Z"},
          {"uri":"at://4","reason":"mention","author":{"did":"did:plc:dave","handle":"d.bsky.social"},"record":{"text":"hey @you"},"indexedAt":"2026-07-01T07:00:00.000Z"}
        ]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/app.bsky.notification.listNotifications")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return (request.status(200), json)
        })
        let notes = try await client.notifications(accessToken: "tok")
        #expect(notes.map(\.kind) == [.follow, .repost, .mention]) // like filtered out
        #expect(notes[0].actorName == "Alice")
        #expect(notes[0].actorID == "did:plc:alice")
        #expect(notes[2].snippet == "hey @you")
    }

    @Test func mastodonMapsAndFiltersTypes() async throws {
        let json = """
        [
          {"id":"1","type":"follow","created_at":"2026-07-01T10:00:00.000Z","account":{"id":"11","display_name":"Carol","acct":"carol","avatar":"https://c"}},
          {"id":"2","type":"favourite","created_at":"2026-07-01T09:30:00.000Z","account":{"id":"22","display_name":"X","acct":"x","avatar":"https://x"}},
          {"id":"3","type":"reblog","created_at":"2026-07-01T09:00:00.000Z","account":{"id":"33","display_name":"Dave","acct":"dave","avatar":"https://d"},"status":{"content":"<p>hi</p>"}}
        ]
        """.data(using: .utf8)!
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/notifications")
            return (request.status(200), json)
        })
        let notes = try await client.notifications(host: "mastodon.social", accessToken: "mtok")
        #expect(notes.map(\.kind) == [.follow, .repost]) // favourite filtered out
        #expect(notes[1].snippet == "hi")
        #expect(notes[0].actorHandle == "carol@mastodon.social")
        #expect(notes[0].actorID == "11")
        #expect(notes[1].actorID == "33")
    }
}

@MainActor
struct NotificationStoreTests {
    nonisolated func note(_ n: Network, _ id: String, _ secondsAgo: TimeInterval) -> NotificationItem {
        NotificationItem(network: n, rawId: id, kind: .follow, actorID: "actor-\(id)",
                         actorName: "A", actorHandle: "a",
                         avatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo))
    }
    func store() -> NotificationStore {
        NotificationStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    @Test func mentionsFilterByKindAndNetwork() {
        func note(_ n: Network, _ id: String, _ k: NotificationItem.Kind) -> NotificationItem {
            NotificationItem(network: n, rawId: id, kind: k, actorID: id, actorName: "A",
                             actorHandle: "a", avatarURL: nil, createdAt: Date())
        }
        let items = [note(.bluesky, "1", .follow), note(.bluesky, "2", .mention),
                     note(.mastodon, "3", .mention), note(.mastodon, "4", .repost)]
        #expect(items.mentions().map(\.rawId) == ["2", "3"])
        #expect(items.mentions(network: .bluesky).map(\.rawId) == ["2"])
        #expect(items.mentions(network: .mastodon).map(\.rawId) == ["3"])
    }

    @Test func refreshMergesAndCountsAllUnreadInitially() async {
        let sut = store()
        sut.setFetchers([
            .bluesky: { [self.note(.bluesky, "b1", 10)] },
            .mastodon: { [self.note(.mastodon, "m1", 5)] },
        ])
        await sut.refresh()
        #expect(sut.items.map(\.id) == ["mastodon:m1", "bluesky:b1"])
        #expect(sut.unreadCount == 2) // nothing seen yet
    }

    @Test func markSeenZeroesUnread() async {
        let sut = store()
        sut.setFetchers([.bluesky: { [self.note(.bluesky, "b1", 10)] }])
        await sut.refresh()
        #expect(sut.unreadCount == 1)
        sut.markSeen()
        #expect(sut.unreadCount == 0)
        await sut.refresh() // same items, now seen
        #expect(sut.unreadCount == 0)
    }

    @Test func newNotificationAfterSeenCountsAsUnread() async {
        let sut = store()
        sut.setFetchers([.bluesky: { [self.note(.bluesky, "old", 100)] }])
        await sut.refresh()
        sut.markSeen()
        // A newer notification arrives.
        sut.setFetchers([.bluesky: { [self.note(.bluesky, "new", 1), self.note(.bluesky, "old", 100)] }])
        await sut.refresh()
        #expect(sut.unreadCount == 1)
    }

    @Test func oneNetworkFailingStillCountsTheOther() async {
        let sut = store()
        sut.setFetchers([
            .bluesky: { [self.note(.bluesky, "b1", 10)] },
            .mastodon: { throw MastodonError.network },
        ])
        await sut.refresh()
        #expect(sut.failedNetworks == [.mastodon])
        #expect(sut.unreadCount == 1)
    }
}
