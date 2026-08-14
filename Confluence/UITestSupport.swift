import Foundation
import ConfluenceKit

/// Launch-argument switches used by the XCUITest suite. Runtime-only; a normal launch passes
/// none of these. Mirrors the existing `-uiTestLoggedOut` convention.
enum UITestLaunch {
    /// In-memory storage: clean logged-out state, no Keychain prompts.
    static let loggedOut = ProcessInfo.processInfo.arguments.contains("-uiTestLoggedOut")
    /// Show the feed populated with canned posts — no login, no network — so UI tests can
    /// exercise post rendering, link taps, and quick reply on both platforms.
    static let mockFeed = ProcessInfo.processInfo.arguments.contains("-uiTestMockFeed")
}

/// Canned feed for `-uiTestMockFeed`. Posts carry stable, assertable text and a mix of a
/// web link and an in-app @-mention (profile) link so tests can drive the link paths.
enum MockFeed {
    /// A single-network page fetcher returning the canned posts; wired into FeedStore in place
    /// of the real network fetchers when `-uiTestMockFeed` is set.
    static func fetchers() -> [Network: PageFetcher] {
        [.bluesky: { _ in FeedPage(items: items, nextCursor: nil) }]
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
            cid: "bafymock2"
        ),
        FeedItem(
            network: .bluesky, rawId: "mock-3", authorID: "did:plc:mockcy",
            authorName: "Cy Mock", authorHandle: "cy.mock.test",
            avatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_769_980_000),
            text: "Mock post three is plain text, good for the reply box.",
            cid: "bafymock3"
        ),
    ]

    private static func linked(_ text: String, phrase: String, url: URL) -> AttributedString {
        var s = AttributedString(text)
        if let r = s.range(of: phrase) { s[r].link = url }
        return s
    }
}
