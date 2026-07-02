import Testing
import Foundation
@testable import ConfluenceKit

struct FeedMergeTests {
    func item(_ network: Network, _ id: String, _ secondsAgo: TimeInterval) -> FeedItem {
        FeedItem(network: network, rawId: id, authorName: "A", authorHandle: "a",
                 avatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo), text: "t")
    }

    @Test func mergesNewestFirstAcrossNetworks() {
        let bsky = [item(.bluesky, "b1", 10), item(.bluesky, "b2", 30)]
        let masto = [item(.mastodon, "m1", 20), item(.mastodon, "m2", 40)]
        let merged = mergeFeeds([bsky, masto])
        #expect(merged.map(\.id) == ["bluesky:b1", "mastodon:m1", "bluesky:b2", "mastodon:m2"])
    }

    @Test func dedupesByNetworkAndId() {
        let a = [item(.bluesky, "x", 10)]
        let b = [item(.bluesky, "x", 10), item(.mastodon, "x", 5)]
        let merged = mergeFeeds([a, b])
        #expect(merged.count == 2) // bluesky:x once, mastodon:x once
    }

    @Test func handlesSingleNetworkAndEmpty() {
        #expect(mergeFeeds([]).isEmpty)
        #expect(mergeFeeds([[], []]).isEmpty)
        #expect(mergeFeeds([[item(.bluesky, "b1", 1)]]).count == 1)
    }

    @Test func tieBreaksDeterministicallyById() {
        let a = item(.bluesky, "aaa", 0)
        let b = item(.mastodon, "bbb", 0) // same timestamp
        #expect(mergeFeeds([[a], [b]]).map(\.id) == mergeFeeds([[b], [a]]).map(\.id))
    }
}
