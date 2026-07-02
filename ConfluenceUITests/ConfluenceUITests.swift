import XCTest

final class ConfluenceUITests: XCTestCase {
    // Smoke only. Real behavior is covered by ConfluenceKit unit/integration tests.
    @MainActor
    func testLaunchesToLoggedOutState() {
        let app = XCUIApplication()
        app.launch()
        // With no accounts, the onboarding/empty state must be visible.
        XCTAssertTrue(app.staticTexts["No Accounts"].waitForExistence(timeout: 5))
    }
}
