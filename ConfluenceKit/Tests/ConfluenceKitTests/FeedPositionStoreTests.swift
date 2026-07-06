import Testing
import Foundation
@testable import ConfluenceKit

struct FeedPositionStoreTests {
    /// Isolated UserDefaults per test so nothing leaks into the real domain.
    func makeStore() -> FeedPositionStore {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return FeedPositionStore(defaults: defaults)
    }

    @Test func savesAndReturnsItemID() {
        let store = makeStore()
        store.save(itemID: "bluesky:abc", for: "both")
        #expect(store.savedItemID(for: "both") == "bluesky:abc")
    }

    @Test func returnsNilWhenNothingSaved() {
        #expect(makeStore().savedItemID(for: "both") == nil)
    }

    @Test func positionsAreScopedPerFilter() {
        let store = makeStore()
        store.save(itemID: "bluesky:1", for: "bluesky")
        store.save(itemID: "mastodon:2", for: "mastodon")
        #expect(store.savedItemID(for: "bluesky") == "bluesky:1")
        #expect(store.savedItemID(for: "mastodon") == "mastodon:2")
        #expect(store.savedItemID(for: "both") == nil) // independent scopes
    }

    @Test func discardsPositionOlderThanSevenDays() {
        let store = makeStore()
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        store.save(itemID: "mastodon:1", for: "both", now: eightDaysAgo)
        #expect(store.savedItemID(for: "both") == nil)   // expired
        #expect(store.savedItemID(for: "both") == nil)   // and cleared
    }

    @Test func keepsPositionWithinSevenDays() {
        let store = makeStore()
        let sixDaysAgo = Date().addingTimeInterval(-6 * 24 * 60 * 60)
        store.save(itemID: "mastodon:1", for: "both", now: sixDaysAgo)
        #expect(store.savedItemID(for: "both") == "mastodon:1")
    }

    @Test func clearRemovesPosition() {
        let store = makeStore()
        store.save(itemID: "x", for: "both")
        store.clear(for: "both")
        #expect(store.savedItemID(for: "both") == nil)
    }
}
