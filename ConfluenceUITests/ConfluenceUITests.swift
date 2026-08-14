import XCTest

final class ConfluenceUITests: XCTestCase {
    // Smoke only: the app launches and reaches the foreground without crashing.
    // Deeper element assertions are intentionally omitted — macOS 26's ContentUnavailableView
    // exposes no queryable accessibility text and this CI/sandbox environment snapshots the
    // window unreliably. Feature behavior is covered by ConfluenceKit unit/integration tests.
    // -uiTestLoggedOut makes the app use in-memory storage (clean state, no Keychain prompts).
    @MainActor
    func testLaunchesWithoutCrashing() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestLoggedOut"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    // -uiTestMockFeed shows the feed with canned posts (no login, no network), so we can
    // assert real post rendering. iOS-only: macOS 26's UI accessibility snapshot is unreliable
    // in this test environment (see the note above), so element queries can't be trusted there.
    @MainActor
    func testMockFeedRenders() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let post = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Ada Mock")).firstMatch
        XCTAssertTrue(post.waitForExistence(timeout: 10), app.debugDescription)
    }

    // #163: post-body links render as accessible link elements on iOS (the SwiftUI Text
    // fallback exposes .link runs), confirming the naive iOS rich-text path is viable.
    @MainActor
    func testPostLinksAreAccessible() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertTrue(app.links.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
    }

    private var isIOS: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}
