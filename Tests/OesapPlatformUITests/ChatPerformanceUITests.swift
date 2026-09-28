import XCTest

/// A functional load regression, not a device frame-rate benchmark. The same
/// native controls and gestures are exercised on iPhone, iPad, and Mac.
final class ChatPerformanceUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    executionTimeAllowance = 90
  }

  func testLargeStreamingTimelinePreservesReadingPositionAndDraft() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--demo-performance", "--demo-server-id=performance-ui",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()
    defer { app.terminate() }
    let endpoint = app.textFields["direct-endpoint"]
    XCTAssertTrue(endpoint.waitForExistence(timeout: 10))
    endpoint.tap()
    endpoint.typeText("demo.paseo.local:6767")
    #if os(iOS)
      let done = app.buttons["connection-keyboard-done"]
      if done.exists { done.tap() }
    #endif
    let connect = app.buttons["connect-button"]
    for _ in 0..<3 where !connect.isHittable { app.swipeUp() }
    connect.tap()
    let project = element("project-demo-project", in: app)
    XCTAssertTrue(project.waitForExistence(timeout: 5))
    project.tap()
    let thread = element("thread-demo-agent-running", in: app)
    XCTAssertTrue(thread.waitForExistence(timeout: 5))
    thread.tap()

    let timeline = app.scrollViews["chat-timeline-scroll"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntil(timeout: 5) { self.progress(in: timeline) > 20 })
    let initialProgress = progress(in: timeline)
    let stream = element("message-demo-performance-stream", in: app)
    XCTAssertTrue(stream.exists, "The long timeline should initially show its latest output.")

    // Move far enough above the rapidly growing final message to inspect history.
    timeline.swipeDown(velocity: .fast)
    timeline.swipeDown(velocity: .fast)
    let latest = app.buttons["chat-jump-to-latest"]
    attachScreenshot("Scrolled away from the streaming answer")
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    let readingProgress = progress(in: timeline)
    XCTAssertGreaterThan(readingProgress, initialProgress)

    let composer = element("chat-composer", in: app)
    XCTAssertTrue(composer.isHittable)
    composer.tap()
    let draft = "Keep this draft while the reply streams."
    composer.typeText(draft)
    XCTAssertEqual(composer.value as? String, draft)
    XCTAssertTrue(waitUntil(timeout: 5) { self.progress(in: timeline) > readingProgress })
    XCTAssertTrue(latest.exists, "Live output and typing must preserve the scroll-away state.")
    attachScreenshot("Reading history with live output and an unsent draft")

    latest.tap()
    XCTAssertTrue(waitUntil(timeout: 5) { !latest.exists })
    XCTAssertTrue(stream.exists, "Latest should return to the streamed message.")
    XCTAssertEqual(composer.value as? String, draft)
    attachScreenshot("Returned to latest without losing the draft")
  }

  private func progress(in timeline: XCUIElement) -> Int {
    Int(timeline.value as? String ?? "") ?? 0
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
