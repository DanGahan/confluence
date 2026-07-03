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
        store.save(itemID: "bluesky:abc")
        #expect(store.savedItemID() == "bluesky:abc")
    }

    @Test func returnsNilWhenNothingSaved() {
        #expect(makeStore().savedItemID() == nil)
    }

    @Test func discardsPositionOlderThanSevenDays() {
        let store = makeStore()
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        store.save(itemID: "mastodon:1", now: eightDaysAgo)
        #expect(store.savedItemID() == nil)          // expired
        #expect(store.savedItemID() == nil)          // and cleared
    }

    @Test func keepsPositionWithinSevenDays() {
        let store = makeStore()
        let sixDaysAgo = Date().addingTimeInterval(-6 * 24 * 60 * 60)
        store.save(itemID: "mastodon:1", now: sixDaysAgo)
        #expect(store.savedItemID() == "mastodon:1")
    }

    @Test func clearRemovesPosition() {
        let store = makeStore()
        store.save(itemID: "x")
        store.clear()
        #expect(store.savedItemID() == nil)
    }
}
