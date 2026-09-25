import XCTest

final class OesapUITests: XCTestCase {
  func testLaunchShowsHostSetupEmptyState() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.staticTexts["Connect a Paseo host"].waitForExistence(timeout: 5))
  }
}
