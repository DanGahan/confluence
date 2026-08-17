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
        var replyTexts: [String] = []
        var failReply = false
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
            delete: { _ in },
            reply: { _, text in
                rec.replyTexts.append(text)
                if rec.failReply { throw BlueskyError.network }
            }
        )])
        return store
    }

    @Test func replyForwardsTextToNetworkAction() async throws {
        let rec = Recorder()
        let sut = makeStore(rec)
        try await sut.reply(item(), text: "great post")
        #expect(rec.replyTexts == ["great post"])
    }

    @Test func replyRethrowsOnFailure() async {
        let rec = Recorder()
        rec.failReply = true
        let sut = makeStore(rec)
        await #expect(throws: BlueskyError.self) { try await sut.reply(item(), text: "x") }
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
