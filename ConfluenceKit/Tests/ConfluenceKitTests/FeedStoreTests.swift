import Testing
import Foundation
@testable import ConfluenceKit

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

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
        #expect(store.hasMore())
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
        #expect(store.hasMore() == false) // nil cursor => end
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
        #expect(store.hasMore() == false)
    }

    // #214: filtered to one network, pagination must grow *that* network and stop spinning once
    // it's exhausted — not keep fetching the hidden one.
    @Test func filteredPaginationGrowsVisibleNetworkAndStops() async {
        let store = FeedStore()
        let mastoPages = Box(0)
        store.setFetchers([
            // Bluesky: endless — its cursor never nils, so combined hasMore stays true.
            .bluesky: { _ in FeedPage(items: [self.item(.bluesky, UUID().uuidString, 10)], nextCursor: "b-next") },
            // Mastodon: one page then done.
            .mastodon: { cursor in
                if cursor == nil { return FeedPage(items: [self.item(.mastodon, "m1", 5)], nextCursor: "m2") }
                mastoPages.value += 1
                return FeedPage(items: [self.item(.mastodon, "m2", 15)], nextCursor: nil) // end
            },
        ])
        await store.refresh()
        // Filtered to Mastodon: load its second (final) page, then it's exhausted.
        await store.loadMore(preferring: .mastodon)
        #expect(store.items.contains { $0.id == "mastodon:m2" }) // visible network grew
        #expect(store.hasMore(for: .mastodon) == false)          // spinner stops for this filter
        #expect(store.hasMore(for: .bluesky) == true)            // the other still has pages
        #expect(store.hasMore() == true)                         // combined still has more
        // A further filtered load is a no-op (doesn't fetch the hidden Bluesky).
        await store.loadMore(preferring: .mastodon)
        #expect(mastoPages.value == 1) // only the one end-page fetch, no runaway
    }

    @Test func refreshReplacesRatherThanAccumulates() async {
        let store = FeedStore()
        store.setFetchers([.bluesky: { _ in FeedPage(items: [self.item(.bluesky, "b1", 1)], nextCursor: nil) }])
        await store.refresh()
        await store.refresh()
        #expect(store.items.count == 1)
    }

    /// A refresh whose fetches all fail must NOT blank a feed that was showing posts — otherwise a
    /// transient failure (e.g. 429 from deep scrolling) leaves an empty feed + error and forces an
    /// app restart to recover. The previously loaded posts are kept; the failure is flagged.
    @Test func failedRefreshKeepsPreviouslyLoadedPosts() async {
        let store = FeedStore()
        store.setFetchers([
            .bluesky: { _ in FeedPage(items: [self.item(.bluesky, "b1", 10)], nextCursor: "bc") },
            .mastodon: { _ in FeedPage(items: [self.item(.mastodon, "m1", 5)], nextCursor: "mc") },
        ])
        await store.refresh()
        #expect(store.items.count == 2)

        // Both networks now fail (rate-limited Bluesky, network blip Mastodon).
        store.setFetchers([
            .bluesky: { _ in throw BlueskyError.rateLimited },
            .mastodon: { _ in throw MastodonError.network },
        ])
        await store.refresh()
        #expect(store.items.count == 2)                    // feed NOT blanked
        #expect(store.rateLimitedNetworks == [.bluesky])
        #expect(store.failedNetworks == [.mastodon])
    }

    /// A partial refresh replaces the succeeding network's posts but keeps the failing one's.
    @Test func partialRefreshReplacesWinnerKeepsLoser() async {
        let store = FeedStore()
        store.setFetchers([
            .bluesky: { _ in FeedPage(items: [self.item(.bluesky, "b1", 10)], nextCursor: nil) },
            .mastodon: { _ in FeedPage(items: [self.item(.mastodon, "m1", 5)], nextCursor: nil) },
        ])
        await store.refresh()

        store.setFetchers([
            .bluesky: { _ in FeedPage(items: [self.item(.bluesky, "b2", 1)], nextCursor: nil) }, // fresh
            .mastodon: { _ in throw MastodonError.network },                                     // fails
        ])
        await store.refresh()
        #expect(store.items.contains { $0.id == "bluesky:b2" })  // refreshed network updated
        #expect(store.items.contains { $0.id == "mastodon:m1" }) // failed network preserved
        #expect(store.items.contains { $0.id == "bluesky:b1" } == false)
        #expect(store.failedNetworks == [.mastodon])
    }
}
