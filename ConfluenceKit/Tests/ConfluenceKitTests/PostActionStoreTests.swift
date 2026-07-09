import Testing
import Foundation
@testable import ConfluenceKit

@MainActor
struct PostActionStoreTests {
    /// Captures what the injected PostActions closures were called with. Sequential in these
    /// tests, so a plain box is fine.
    final class Recorder: @unchecked Sendable {
        var repostCalls = 0
        var unrepostURIs: [String?] = []
        var failRepost = false
    }

    func item(_ id: String = "p1") -> FeedItem {
        FeedItem(network: .bluesky, rawId: id, authorName: "A", authorHandle: "a",
                 avatarURL: nil, createdAt: Date(), text: "hi")
    }

    func makeStore(_ rec: Recorder) -> PostActionStore {
        let store = PostActionStore()
        store.setActions([.bluesky: PostActions(
            repost: { _ in
                rec.repostCalls += 1
                if rec.failRepost { throw BlueskyError.network }
                return "at://did/app.bsky.feed.repost/xyz"
            },
            unrepost: { _, uri in rec.unrepostURIs.append(uri) },
            like: { _ in "at://like" },
            unlike: { _, _ in },
            block: { _ in },
            delete: { _ in }
        )])
        return store
    }

    @Test func toggleRepostThenUndoPassesBackStoredURI() async {
        let rec = Recorder()
        let sut = makeStore(rec)
        let post = item()

        await sut.toggleRepost(post)
        #expect(sut.isReposted(post))
        #expect(rec.repostCalls == 1)

        await sut.toggleRepost(post)          // undo
        #expect(!sut.isReposted(post))
        #expect(rec.unrepostURIs == ["at://did/app.bsky.feed.repost/xyz"]) // undo received the record URI
    }

    @Test func failedRepostRevertsOptimisticState() async {
        let rec = Recorder(); rec.failRepost = true
        let sut = makeStore(rec)
        let post = item()

        await sut.toggleRepost(post)
        #expect(!sut.isReposted(post))   // reverted
        #expect(sut.lastError != nil)
    }
}
