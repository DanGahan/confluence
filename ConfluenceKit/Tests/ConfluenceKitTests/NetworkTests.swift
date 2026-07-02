import Testing
@testable import ConfluenceKit

@Test func networkCasesAreStable() {
    // Raw values are persisted (feed position, post-target checkboxes) — must not drift.
    #expect(Network.bluesky.rawValue == "bluesky")
    #expect(Network.mastodon.rawValue == "mastodon")
    #expect(Network.allCases.count == 2)
}
