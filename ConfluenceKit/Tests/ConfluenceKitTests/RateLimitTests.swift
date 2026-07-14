import Testing
import Foundation
@testable import ConfluenceKit

/// Integration tests for the shared 429 policy. Real sleeping is replaced with a
/// TaskLocal noop so tests never block wall-clock time; the recorded delays are
/// checked separately.
struct RateLimitTests {

    // MARK: helpers

    /// Captures each sleep duration the retry loop asks for, in ns.
    final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _delays: [UInt64] = []
        var delays: [UInt64] { lock.withLock { _delays } }
        func record(_ ns: UInt64) { lock.withLock { _delays.append(ns) } }
    }

    /// Runs `body` with sleep replaced by a recorder (no real delay) and jitter pinned.
    func withNoRealSleep<T: Sendable>(_ body: (SleepRecorder) async throws -> T) async rethrows -> T {
        let recorder = SleepRecorder()
        return try await RateLimit.$sleep.withValue({ ns in recorder.record(ns) }) {
            try await body(recorder)
        }
    }

    func blueskyClient(handler: @escaping MockURLProtocol.Handler) -> BlueskyClient {
        BlueskyClient(pdsURL: URL(string: "https://bsky.social")!, session: MockURLProtocol.session(handler: handler))
    }

    func mastodonClient(handler: @escaping MockURLProtocol.Handler) -> MastodonClient {
        MastodonClient(session: MockURLProtocol.session(handler: handler))
    }

    func timelineJSON() -> Data {
        Data("""
        {"cursor":"c1","feed":[]}
        """.utf8)
    }

    func mastodonTimelineJSON() -> Data { Data("[]".utf8) }

    // MARK: Bluesky

    @Test func bluesky429WithRetryAfterDelaysThenSucceeds() async throws {
        let attempts = Attempts()
        let sut = blueskyClient { request in
            let n = attempts.increment()
            if n == 1 {
                return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                        headerFields: ["Retry-After": "2"])!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"cursor":"c1","feed":[]}"#.utf8))
        }
        let page = try await withNoRealSleep { recorder in
            let p = try await sut.timeline(accessToken: "tok", cursor: nil)
            #expect(recorder.delays == [2_000_000_000]) // Retry-After was honoured
            return p
        }
        #expect(page.nextCursor == "c1")
        #expect(attempts.value == 2)
    }

    @Test func bluesky429WithoutRetryAfterUsesExponentialBackoff() async throws {
        let attempts = Attempts()
        let sut = blueskyClient { request in
            _ = attempts.increment()
            if attempts.value < 3 { // fail first two attempts
                return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"cursor":"c1","feed":[]}"#.utf8))
        }
        _ = try await withNoRealSleep { recorder in
            let p = try await sut.timeline(accessToken: "tok", cursor: nil)
            // Two retries required. Delays should grow (attempt 0 < attempt 1) even with jitter,
            // since jitter is bounded ±20% and the base doubles.
            #expect(recorder.delays.count == 2)
            #expect(recorder.delays[0] < recorder.delays[1])
            return p
        }
    }

    @Test func bluesky429AfterRetriesExhaustedThrowsRateLimited() async {
        let attempts = Attempts()
        let sut = blueskyClient { request in
            _ = attempts.increment()
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }
        let _: Void = await withNoRealSleep { _ in
            await #expect(throws: BlueskyError.rateLimited) {
                _ = try await sut.timeline(accessToken: "tok", cursor: nil)
            }
        }
        #expect(attempts.value == 4) // initial + 3 retries
    }

    // MARK: Mastodon

    @Test func mastodon429AfterRetriesExhaustedThrowsRateLimited() async {
        let attempts = Attempts()
        let sut = mastodonClient { request in
            _ = attempts.increment()
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }
        let _: Void = await withNoRealSleep { _ in
            await #expect(throws: MastodonError.rateLimited) {
                _ = try await sut.homeTimeline(host: "mastodon.social", accessToken: "tok", maxId: nil)
            }
        }
        #expect(attempts.value == 4)
    }

    @Test func mastodon429WithRetryAfterHonoured() async throws {
        let attempts = Attempts()
        let sut = mastodonClient { request in
            let n = attempts.increment()
            if n == 1 {
                return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                        headerFields: ["Retry-After": "3"])!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("[]".utf8))
        }
        _ = try await withNoRealSleep { recorder in
            let p = try await sut.homeTimeline(host: "mastodon.social", accessToken: "tok", maxId: nil)
            #expect(recorder.delays == [3_000_000_000])
            return p
        }
    }

    // MARK: FeedStore surfacing (isolation between networks)

    @MainActor
    @Test func feedStoreSurfacesRateLimitDistinctFromFailure() async {
        let store = FeedStore()
        store.setFetchers([
            .bluesky: { _ in throw BlueskyError.rateLimited },
            .mastodon: { _ in
                FeedPage(items: [FeedItem(network: .mastodon, rawId: "m1", authorName: "A", authorHandle: "a",
                                          avatarURL: nil, createdAt: Date(), text: "hi")], nextCursor: nil)
            },
        ])
        await store.refresh()
        // Rate-limit is separate from generic failure; Mastodon still renders.
        #expect(store.rateLimitedNetworks == [.bluesky])
        #expect(store.failedNetworks.isEmpty)
        #expect(store.items.map(\.id) == ["mastodon:m1"])
    }

    @MainActor
    @Test func feedStoreClearsRateLimitStateOnSuccessfulRefresh() async {
        let attempts = Attempts()
        let store = FeedStore()
        store.setFetchers([
            .bluesky: { _ in
                if attempts.increment() == 1 { throw BlueskyError.rateLimited }
                return FeedPage(items: [], nextCursor: nil)
            },
        ])
        await store.refresh()
        #expect(store.rateLimitedNetworks == [.bluesky])
        await store.refresh()
        #expect(store.rateLimitedNetworks.isEmpty)
    }

    // MARK: Backoff shape (deterministic — no random dependency)

    @Test func retryAfterCapAt30Seconds() {
        let ns = rateLimitBackoffNanos(attempt: 0, retryAfter: "3600")
        #expect(ns == 30_000_000_000)
    }

    @Test func retryAfterZeroReturnsZero() {
        #expect(rateLimitBackoffNanos(attempt: 0, retryAfter: "0") == 0)
    }

    @Test func retryAfterNegativeClampedToZero() {
        #expect(rateLimitBackoffNanos(attempt: 0, retryAfter: "-5") == 0)
    }
}

/// Thread-safe attempt counter for handlers.
final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    @discardableResult func increment() -> Int { lock.withLock { _value += 1; return _value } }
}
