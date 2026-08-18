import Testing
import Foundation
@testable import ConfluenceKit

/// Guards the optimistic quick-reply splice (G15): a just-posted reply is inserted directly
/// after the post it answers, so it appears instantly without a full thread reload.
struct ThreadInsertTests {
    func fi(_ id: String) -> FeedItem {
        FeedItem(network: .bluesky, rawId: id, authorName: "x", authorHandle: "x",
                 avatarURL: nil, createdAt: Date(), text: id)
    }

    @Test func insertsReplyRightAfterItsParent() {
        let thread = PostThread(items: [fi("a"), fi("b"), fi("c")], focusID: "bluesky:b")
        let out = thread.inserting(fi("reply"), after: "bluesky:b")
        #expect(out.items.map(\.id) == ["bluesky:a", "bluesky:b", "bluesky:reply", "bluesky:c"])
        #expect(out.focusID == "bluesky:b") // highlight unchanged
    }

    @Test func appendsWhenParentMissing() {
        let thread = PostThread(items: [fi("a"), fi("b")], focusID: "bluesky:a")
        let out = thread.inserting(fi("reply"), after: "bluesky:zzz")
        #expect(out.items.map(\.id) == ["bluesky:a", "bluesky:b", "bluesky:reply"])
    }
}
