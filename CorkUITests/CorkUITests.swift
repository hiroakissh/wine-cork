import XCTest

final class CorkUITests: XCTestCase {
    func testAppLaunchesWithCellarTab() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Cellar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Scan"].exists)
    }
}
