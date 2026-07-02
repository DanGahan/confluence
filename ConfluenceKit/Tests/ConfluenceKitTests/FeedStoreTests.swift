import Testing
import Foundation
@testable import ConfluenceKit

@MainActor
struct FeedStoreTests {
    nonisolated func item(_ network: Network, _ id: String, _ secondsAgo: TimeInterval) -> FeedItem {
        FeedItem(network: network, rawId: id, authorName: "A", authorHandle: "a",
                 avatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo), text: "t")
    }

    @Test func refreshMergesBothNetworks() async {
        let store = FeedStore()
        store.setFetchers([
            .bluesky: { _ in FeedPage(items: [self.item(.bluesky, "b1", 10)], nextCursor: "bc") },
            .mastodon: { _ in FeedPage(items: [self.item(.mastodon, "m1", 5)], nextCursor: "mc") },
        ])
        await store.refresh()
        #expect(store.items.map(\.id) == ["mastodon:m1", "bluesky:b1"])
        #expect(store.failedNetworks.isEmpty)
        #expect(store.hasMore)
    }

    @Test func oneNetworkFailingStillShowsTheOther() async {
        let store = FeedStore()
        store.setFetchers([
            .bluesky: { _ in FeedPage(items: [self.item(.bluesky, "b1", 10)], nextCursor: nil) },
            .mastodon: { _ in throw MastodonError.network },
        ])
        await store.refresh()
        #expect(store.items.map(\.id) == ["bluesky:b1"])
        #expect(store.failedNetworks == [.mastodon])
    }

    @Test func worksWithASingleNetwork() async {
        let store = FeedStore()
        store.setFetchers([.bluesky: { _ in FeedPage(items: [self.item(.bluesky, "b1", 1)], nextCursor: nil) }])
        await store.refresh()
        #expect(store.items.count == 1)
        #expect(store.hasMore == false) // nil cursor => end
    }

    @Test func loadMoreAppendsNextPageUsingCursor() async {
        let store = FeedStore()
        store.setFetchers([.bluesky: { cursor in
            if cursor == nil { return FeedPage(items: [self.item(.bluesky, "b1", 10)], nextCursor: "page2") }
            #expect(cursor == "page2") // second call must use the cursor from page one
            return FeedPage(items: [self.item(.bluesky, "b2", 20)], nextCursor: nil)
        }])
        await store.refresh()
        await store.loadMore()
        #expect(store.items.map(\.id) == ["bluesky:b1", "bluesky:b2"])
        #expect(store.hasMore == false)
    }

    @Test func refreshReplacesRatherThanAccumulates() async {
        let store = FeedStore()
        store.setFetchers([.bluesky: { _ in FeedPage(items: [self.item(.bluesky, "b1", 1)], nextCursor: nil) }])
        await store.refresh()
        await store.refresh()
        #expect(store.items.count == 1)
    }
}
