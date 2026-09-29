import UIKit
import XCTest

final class WorkspacePlatformUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    #if !targetEnvironment(macCatalyst)
      try XCTSkipIf(
        UIDevice.current.userInterfaceIdiom != .pad, "Split workspace is for iPad and Mac.")
      XCUIDevice.shared.orientation = .landscapeLeft
    #endif
  }

  func testColdLaunchWithoutSavedHostShowsConnectionSetup() {
    let app = launchDemo()
    XCTAssertTrue(app.textFields["direct-endpoint"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["connect-button"].exists)
    app.terminate()
  }

  func testRelaunchWithSavedDemoHostAutoConnects() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--demo", "--demo-saved-connection",
      "--demo-server-id=platform-ui-saved-\(UUID().uuidString.lowercased())",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()

    XCTAssertTrue(element("project-demo-project", in: app).waitForExistence(timeout: 10))
    app.terminate()
  }

  func testSplitWorkspaceSwitchesThreadsAndPreservesDraft() {
    let app = connectDemo()
    let project = element("project-demo-project", in: app)
    XCTAssertTrue(project.waitForExistence(timeout: 10))
    project.tap()

    let running = element("thread-demo-agent-running", in: app)
    XCTAssertTrue(running.waitForExistence(timeout: 10))
    running.tap()
    let composer = element("chat-composer", in: app)
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    composer.typeText("Keep this draft across selection")
    dismissKeyboard(in: app)

    let idle = element("thread-demo-agent-idle", in: app)
    XCTAssertTrue(idle.waitForExistence(timeout: 5))
    idle.tap()
    XCTAssertTrue(element("chat-composer", in: app).waitForExistence(timeout: 5))
    XCTAssertNotEqual(
      element("chat-composer", in: app).value as? String, "Keep this draft across selection")
    running.tap()
    let restored = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Keep this draft across selection"),
      object: element("chat-composer", in: app)
    )
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
    XCTAssertTrue(
      project.exists, "Project sidebar should remain available alongside the conversation.")
    attachScreenshot("Split workspace with selected conversation")

    // Changing projects must remove the previous chat before another thread opens.
    let toolsProject = element("project-demo-tools-project", in: app)
    XCTAssertTrue(toolsProject.waitForExistence(timeout: 5))
    toolsProject.tap()
    let toolsThread = element("thread-demo-tools-running", in: app)
    XCTAssertTrue(toolsThread.waitForExistence(timeout: 5))
    XCTAssertFalse(element("chat-composer", in: app).exists)
    toolsThread.tap()
    XCTAssertTrue(element("chat-composer", in: app).waitForExistence(timeout: 5))
    XCTAssertNotEqual(
      element("chat-composer", in: app).value as? String, "Keep this draft across selection")
    project.tap()
    XCTAssertTrue(running.waitForExistence(timeout: 5))
    running.tap()
    let restoredAfterProjectChange = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Keep this draft across selection"),
      object: element("chat-composer", in: app)
    )
    XCTAssertEqual(XCTWaiter.wait(for: [restoredAfterProjectChange], timeout: 5), .completed)
  }

  func testNewThreadOpensInDetail() {
    let app = connectDemo()
    let project = element("project-demo-project", in: app)
    XCTAssertTrue(project.waitForExistence(timeout: 10))
    project.tap()
    let newThread = app.buttons["new-thread-button"]
    XCTAssertTrue(newThread.waitForExistence(timeout: 10))
    newThread.tap()
    XCTAssertTrue(element("chat-composer", in: app).waitForExistence(timeout: 10))
    attachScreenshot("New thread in split workspace")
  }

  private func connectDemo() -> XCUIApplication {
    let app = launchDemo()
    let endpoint = app.textFields["direct-endpoint"]
    XCTAssertTrue(endpoint.waitForExistence(timeout: 10))
    endpoint.tap()
    endpoint.typeText("demo.paseo.local:6767")
    dismissKeyboard(in: app)
    let connect = app.buttons["connect-button"]
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    connect.tap()
    return app
  }

  private func launchDemo() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--demo", "--demo-server-id=platform-ui-\(UUID().uuidString.lowercased())",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()
    return app
  }

  private func dismissKeyboard(in app: XCUIApplication) {
    #if !targetEnvironment(macCatalyst)
      let done = app.buttons["connection-keyboard-done"]
      if done.exists && done.isHittable { done.tap() }
      // Chat's keyboard can be dismissed without mutating the draft.
      if app.keyboards.firstMatch.exists {
        let hideKeyboard = app.buttons.matching(
          NSPredicate(format: "label CONTAINS[c] 'Hide keyboard'")
        )
        .firstMatch
        if hideKeyboard.exists { hideKeyboard.tap() }
      }
    #endif
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
