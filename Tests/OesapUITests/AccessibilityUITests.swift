import XCTest

final class AccessibilityUITests: XCTestCase {
  func testNativeAccessibilityAuditOnConnectionProjectsAndChat() throws {
    let app = launchDemo()
    XCTAssertTrue(app.navigationBars["Oesap"].waitForExistence(timeout: 5))
    fillEndpoint(app)
    let privacyEntry = app.buttons["privacy-information-connection"]
    XCTAssertTrue(
      scrollUntilHittable(privacyEntry, in: app, whenMissing: .earlier),
      "Privacy information should be visible from connection setup."
    )
    let connectButton = app.buttons["connect-button"]
    XCTAssertTrue(connectButton.isEnabled)
    XCTAssertTrue(connectButton.isHittable, "Connect should be visible during the audit.")
    attachScreenshot(named: "Accessibility audit — connection", app: app)
    try app.performAccessibilityAudit(
      for: [
        .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .trait,
      ])

    openPrivacyInformation(
      app, entryIdentifier: "privacy-information-connection", returnScreen: "Oesap")
    connect(app, endpointIsFilled: true)
    XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
    attachScreenshot(named: "Accessibility audit — projects", app: app)
    try app.performAccessibilityAudit(
      for: [
        .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .trait,
      ])

    let project = app.buttons["project-demo-project"]
    XCTAssertTrue(scrollUntilHittable(project, in: app))
    project.tap()
    let runningThread = app.buttons["thread-demo-agent-running"]
    XCTAssertTrue(scrollUntilHittable(runningThread, in: app))
    runningThread.tap()
    let context = app.buttons["context-usage-button"]
    XCTAssertTrue(context.waitForExistence(timeout: 5))
    XCTAssertEqual(context.value as? String, "32% used")
    attachScreenshot(named: "Accessibility audit — chat", app: app)
    try app.performAccessibilityAudit(
      for: [
        .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .trait,
      ])

    app.navigationBars.buttons.firstMatch.tap()
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
    let connectionOptions = app.buttons["connection-options"]
    XCTAssertTrue(connectionOptions.waitForExistence(timeout: 5))
    connectionOptions.tap()
    openPrivacyInformation(
      app, entryIdentifier: "privacy-information-workspace", returnScreen: "Projects")
  }

  func testAccessibilitySizeAndDarkModeKeepChatAndPermissionControlsReachable() {
    let app = launchDemo(accessibilitySize: true, darkMode: true)
    XCTAssertTrue(app.buttons["privacy-information-connection"].waitForExistence(timeout: 5))
    attachScreenshot(named: "AX5 dark connection", app: app)
    openPrivacyInformation(
      app, entryIdentifier: "privacy-information-connection", returnScreen: "Oesap")
    connect(app)

    let connectionOptions = app.buttons["connection-options"]
    XCTAssertTrue(connectionOptions.waitForExistence(timeout: 5))
    connectionOptions.tap()
    openPrivacyInformation(
      app, entryIdentifier: "privacy-information-workspace", returnScreen: "Projects")

    let project = app.buttons["project-demo-project"]
    XCTAssertTrue(scrollUntilHittable(project, in: app))
    project.tap()
    let attentionThread = app.buttons["thread-demo-agent-attention"]
    XCTAssertTrue(scrollUntilHittable(attentionThread, in: app))
    attentionThread.tap()

    let timeline = app.scrollViews["chat-timeline-scroll"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    let deny = app.buttons["permission-deny-demo-permission"]
    let allow = app.buttons["permission-allow-demo-permission"]
    XCTAssertTrue(
      scrollUntilVisibleAboveComposer(
        deny, in: timeline, app: app, whenMissing: .earlier),
      "The Deny action should be reachable in the chat timeline."
    )
    assertMinimumTapTarget(deny, named: "Deny")
    attachScreenshot(named: "AX5 dark permission deny", app: app)

    XCTAssertTrue(
      scrollUntilVisibleAboveComposer(
        allow, in: timeline, app: app, whenMissing: .later),
      "The Allow action should be reachable in the chat timeline."
    )
    assertMinimumTapTarget(allow, named: "Allow")
    attachScreenshot(named: "AX5 dark permission allow", app: app)
    allow.tap()
    let cancelPermission = app.buttons["Cancel"]
    XCTAssertTrue(cancelPermission.waitForExistence(timeout: 5))
    XCTAssertTrue(cancelPermission.isHittable)
    attachScreenshot(named: "AX5 dark permission confirmation", app: app)
    cancelPermission.tap()

    app.navigationBars.buttons.firstMatch.tap()
    let runningThread = app.buttons["thread-demo-agent-running"]
    XCTAssertTrue(scrollUntilHittable(runningThread, in: app, whenMissing: .earlier))
    runningThread.tap()

    let runningTimeline = app.scrollViews["chat-timeline-scroll"]
    XCTAssertTrue(runningTimeline.waitForExistence(timeout: 5))
    let context = app.buttons["context-usage-button"]
    XCTAssertTrue(
      scrollUntilVisibleAboveComposer(
        context, in: runningTimeline, app: app, whenMissing: .earlier),
      "The context usage control should be reachable at the start of the timeline."
    )
    XCTAssertEqual(context.value as? String, "32% used")
    assertMinimumTapTarget(context, named: "Context usage")

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Check the accessible send control")
    let send = app.buttons["send-message"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled)
    assertMinimumTapTarget(send, named: "Send message")
    attachScreenshot(named: "AX5 dark chat composer", app: app)
    send.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-user-0"].waitForExistence(timeout: 5))
  }

  private func launchDemo(
    accessibilitySize: Bool = false,
    darkMode: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--demo",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
      "--demo-server-id=ui-accessibility-\(UUID().uuidString.lowercased())",
    ]
    if accessibilitySize {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    }
    if darkMode {
      app.launchArguments.append("--ui-test-dark-mode")
    }
    app.launch()
    return app
  }

  private func fillEndpoint(_ app: XCUIApplication) {
    let endpoint = app.textFields["direct-endpoint"]
    XCTAssertTrue(scrollUntilHittable(endpoint, in: app))
    endpoint.tap()
    endpoint.typeText("demo.paseo.local:6767")
    let keyboard = app.keyboards.firstMatch
    let keyboardDone = app.buttons["connection-keyboard-done"]
    XCTAssertTrue(keyboardDone.waitForExistence(timeout: 5))
    let keyboardDoneHittable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"), object: keyboardDone)
    XCTAssertEqual(
      XCTWaiter.wait(for: [keyboardDoneHittable], timeout: 5), .completed,
      "The keyboard Done button should become hittable.")
    keyboardDone.tap()
    let keyboardDismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: keyboard)
    XCTAssertEqual(
      XCTWaiter.wait(for: [keyboardDismissed], timeout: 3), .completed,
      "Dismiss the keyboard before the audit.")
  }

  private func connect(_ app: XCUIApplication, endpointIsFilled: Bool = false) {
    if !endpointIsFilled { fillEndpoint(app) }
    let connectButton = app.buttons["connect-button"]
    XCTAssertTrue(scrollUntilHittable(connectButton, in: app))
    connectButton.tap()
    XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
  }

  private func openPrivacyInformation(
    _ app: XCUIApplication,
    entryIdentifier: String,
    returnScreen: String
  ) {
    let entry = app.buttons[entryIdentifier]
    XCTAssertTrue(scrollUntilHittable(entry, in: app, whenMissing: .earlier))
    entry.tap()

    XCTAssertTrue(app.navigationBars["Privacy & Host Data"].waitForExistence(timeout: 5))
    let done = app.buttons["privacy-information-done"]
    XCTAssertTrue(done.waitForExistence(timeout: 5))
    XCTAssertTrue(done.isHittable)
    attachScreenshot(named: "Privacy information — \(returnScreen)", app: app)
    done.tap()
    XCTAssertTrue(app.navigationBars[returnScreen].waitForExistence(timeout: 5))
  }

  private func scrollUntilHittable(
    _ element: XCUIElement,
    in app: XCUIApplication,
    maxSwipes: Int = 10
  ) -> Bool {
    for _ in 0..<maxSwipes {
      if element.exists && element.isHittable { return true }
      app.swipeUp()
    }
    return element.exists && element.isHittable
  }

  private func scrollUntilHittable(
    _ element: XCUIElement,
    in app: XCUIApplication,
    whenMissing direction: TimelineDirection,
    maxSwipes: Int = 10
  ) -> Bool {
    for _ in 0..<maxSwipes {
      if element.exists && element.isHittable { return true }
      if !element.exists {
        scroll(direction, in: app)
        continue
      }

      if element.frame.midY < app.frame.midY {
        app.swipeDown()
      } else {
        app.swipeUp()
      }
    }
    return element.exists && element.isHittable
  }

  private func scrollUntilVisibleAboveComposer(
    _ element: XCUIElement,
    in timeline: XCUIElement,
    app: XCUIApplication,
    whenMissing direction: TimelineDirection,
    maxSwipes: Int = 16
  ) -> Bool {
    let composer = app.descendants(matching: .any)["chat-composer"]
    let navigationBar = app.navigationBars.firstMatch

    for _ in 0..<maxSwipes {
      let top = navigationBar.frame.maxY + 8
      let bottom = composer.exists ? composer.frame.minY - 24 : timeline.frame.maxY - 24
      if element.exists && element.isHittable
        && element.frame.minY >= top && element.frame.maxY <= bottom
      {
        return true
      }

      guard element.exists else {
        scroll(direction, in: timeline)
        continue
      }
      if element.frame.minY < top {
        nudgeTimeline(toward: .earlier, in: timeline)
      } else {
        nudgeTimeline(toward: .later, in: timeline)
      }
    }

    let top = navigationBar.frame.maxY + 8
    let bottom = composer.exists ? composer.frame.minY - 24 : timeline.frame.maxY - 24
    return element.exists && element.isHittable
      && element.frame.minY >= top && element.frame.maxY <= bottom
  }

  private func scroll(_ direction: TimelineDirection, in scrollView: XCUIElement) {
    switch direction {
    case .earlier: scrollView.swipeDown()
    case .later: scrollView.swipeUp()
    }
  }

  private func nudgeTimeline(toward direction: TimelineDirection, in timeline: XCUIElement) {
    let startY: CGFloat
    let endY: CGFloat
    switch direction {
    case .earlier:
      startY = 0.30
      endY = 0.41
    case .later:
      startY = 0.70
      endY = 0.59
    }
    let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
    let end = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
    start.press(forDuration: 0.04, thenDragTo: end)
  }

  private func scroll(_ direction: TimelineDirection, in app: XCUIApplication) {
    switch direction {
    case .earlier: app.swipeDown()
    case .later: app.swipeUp()
    }
  }

  private func assertMinimumTapTarget(
    _ element: XCUIElement,
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(element.exists, "\(name) should exist.", file: file, line: line)
    XCTAssertTrue(element.isHittable, "\(name) should be reachable.", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      element.frame.width, 44, "\(name) should be at least 44 pt wide.", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      element.frame.height, 44, "\(name) should be at least 44 pt high.", file: file, line: line)
  }

  private func attachScreenshot(named name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let accessibilityTree = XCTAttachment(string: app.debugDescription)
    accessibilityTree.name = "\(name) — accessibility tree"
    accessibilityTree.lifetime = .keepAlways
    add(accessibilityTree)
  }

  private enum TimelineDirection { case earlier, later }
}
