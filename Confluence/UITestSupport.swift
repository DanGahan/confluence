import Foundation
import Observation
import ConfluenceKit

/// Launch-argument switches used by the XCUITest suite. Runtime-only; a normal launch passes
/// none of these. Mirrors the existing `-uiTestLoggedOut` convention.
enum UITestLaunch {
    /// In-memory storage: clean logged-out state, no Keychain prompts.
    static let loggedOut = ProcessInfo.processInfo.arguments.contains("-uiTestLoggedOut")
    /// Show the feed populated with canned posts — no login, no network — so UI tests can
    /// exercise post rendering, link taps, and quick reply on both platforms.
    static let mockFeed = ProcessInfo.processInfo.arguments.contains("-uiTestMockFeed")
    /// Open the composer pre-seeded with an image attachment, so a UI test can exercise the
    /// remove-attachment path (which crashed — #159).
    static let composerAttachment = ProcessInfo.processInfo.arguments.contains("-uiTestComposerAttachment")
}

enum MockComposer {
    /// A 1×1 PNG so the composer can open with a renderable attachment for the removal test.
    static var attachment: Attachment {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!
        return Attachment(data: png, alt: "")
    }
}

/// Observable fetch counter so a UI test can watch live-mode polling start/stop (#169).
@MainActor @Observable final class MockFeedCounter { var fetches = 0 }

/// Canned feed for `-uiTestMockFeed`. Posts carry stable, assertable text and a mix of a
/// web link and an in-app @-mention (profile) link so tests can drive the link paths.
enum MockFeed {
    @MainActor static let counter = MockFeedCounter()

    /// A single-network page fetcher returning the canned posts; wired into FeedStore in place
    /// of the real network fetchers when `-uiTestMockFeed` is set. Each call bumps the counter
    /// so a test can observe polling cadence.
    static func fetchers() -> [Network: PageFetcher] {
        [.bluesky: { _ in
            await MainActor.run { counter.fetches += 1 }
            return FeedPage(items: items, nextCursor: nil)
        }]
    }

    static let items: [FeedItem] = [
        FeedItem(
            network: .bluesky, rawId: "mock-1", authorID: "did:plc:mockada",
            authorName: "Ada Mock", authorHandle: "ada.mock.test",
            avatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            text: "Mock post one with a link to example.com here.",
            attributedText: linked("Mock post one with a link to example.com here.",
                                    phrase: "example.com", url: URL(string: "https://example.com")!),
            cid: "bafymock1"
        ),
        FeedItem(
            network: .bluesky, rawId: "mock-2", authorID: "did:plc:mockbea",
            authorName: "Bea Mock", authorHandle: "bea.mock.test",
            avatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_769_990_000),
            text: "Mock post two mentions someone you can open in-app.",
            attributedText: linked("Mock post two mentions @someone you can open in-app.",
                                    phrase: "@someone",
                                    url: ProfileLink.url(network: .bluesky, id: "did:plc:mocksomeone", handle: "someone.mock.test")!),
            replyCount: 2, // surfaces the "N replies" thread affordance
            cid: "bafymock2"
        ),
        FeedItem(
            network: .bluesky, rawId: "mock-3", authorID: "did:plc:mockcy",
            authorName: "Cy Mock", authorHandle: "cy.mock.test",
            avatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_769_980_000),
            text: "Mock post three is plain text, good for the reply box.",
            cid: "bafymock3"
        ),
        FeedItem(
            network: .bluesky, rawId: "mock-4", authorID: "did:plc:mockdeb",
            authorName: "Deb Mock", authorHandle: "deb.mock.test",
            avatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_769_970_000),
            text: "Mock post four has an image to tap.",
            imageURLs: [URL(string: "https://picsum.photos/seed/confluence/600/400")!],
            cid: "bafymock4"
        ),
    ]

    private static func linked(_ text: String, phrase: String, url: URL) -> AttributedString {
        var s = AttributedString(text)
        if let r = s.range(of: phrase) { s[r].link = url }
        return s
    }
}
