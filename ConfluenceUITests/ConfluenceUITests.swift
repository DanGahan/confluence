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
}
