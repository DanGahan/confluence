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

    // #165: tapping a post body expands the inline quick-reply field.
    @MainActor
    func testTappingPostBodyExpandsReply() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        // Tap the body text itself (clear of the avatar/username row) so the tap exercises the
        // post-body expand gesture, not the "Opens profile" author button.
        let body = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "plain text, good for the reply")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        body.tap()
        XCTAssertTrue(app.textFields["Reply text"].waitForExistence(timeout: 5), app.debugDescription)
    }

    // #163/#164: an in-app @-mention link opens the profile (link taps still win over the
    // body-expand catcher, and route in-app rather than to Safari).
    @MainActor
    func testTappingMentionLinkOpensProfile() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        let mention = app.links["@someone"]
        XCTAssertTrue(mention.waitForExistence(timeout: 15))
        mention.tap()
        let profile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "someone.mock.test")).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10), app.debugDescription)
    }

    // #164: tapping the username (not the body) opens the author's profile.
    @MainActor
    func testTappingUsernameOpensProfile() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        let author = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Opens profile"))
            .matching(NSPredicate(format: "label CONTAINS %@", "cy.mock.test")).firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 15))
        author.tap()
        let profile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "cy.mock.test")).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10), app.debugDescription)
    }

    // #168: tapping the avatar opens the author's profile. Regression guard for the
    // two-.sheet-on-one-view iOS bug (only one sheet presents; the avatar's was shadowed).
    @MainActor
    func testTappingAvatarOpensProfile() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        let avatar = app.buttons.matching(NSPredicate(format: "identifier == %@", "person.fill")).firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 15))
        avatar.tap()
        let profile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "ada.mock.test")).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10), app.debugDescription)
    }

    // #168: the "N replies" affordance opens the thread sheet (the other sheet on the avatar
    // button — guards the two-sheet-on-one-view path and the thread sheet's iOS sizing).
    @MainActor
    func testOpeningThreadSheet() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        let replies = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "replies")).firstMatch
        XCTAssertTrue(replies.waitForExistence(timeout: 15), app.debugDescription)
        replies.tap()
        XCTAssertTrue(app.staticTexts["Thread"].waitForExistence(timeout: 10), app.debugDescription)
    }

    // #168: the composer sheet presents on iOS and its content fits (macOS fixed width gated).
    @MainActor
    func testComposerSheetPresents() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        let compose = app.buttons["New Post"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15))
        compose.tap()
        // "New Post" title appears inside the composer sheet (distinct from the FAB button).
        XCTAssertTrue(app.staticTexts["New Post"].waitForExistence(timeout: 5), app.debugDescription)
    }

    // #167: the feed toolbar renders on iOS (regression — without a NavigationStack the
    // toolbar was absent entirely, leaving search/notifications/settings unreachable).
    @MainActor
    func testFeedToolbarPresentOnIOS() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["Search"].exists)
        XCTAssertTrue(app.buttons["More"].exists)
    }

    // #164: the post context menu opens on long-press and offers the post actions.
    @MainActor
    func testPostContextMenuOnIOS() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        let body = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "plain text, good for the reply")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        body.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Repost"].exists)
        XCTAssertTrue(app.buttons["Like"].exists)
    }

    // #164: tapping a post image opens the lightbox.
    @MainActor
    func testTappingImageOpensLightbox() throws {
        try XCTSkipUnless(isIOS, "Element queries are unreliable on macOS UI tests.")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMockFeed"]
        app.launch()
        // The image post's row (Deb Mock) — its tappable image Button lives inside it.
        let image = app.buttons["Image"]
        XCTAssertTrue(image.waitForExistence(timeout: 15))
        image.tap()
        XCTAssertTrue(app.buttons["Zoom in"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private var isIOS: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}
