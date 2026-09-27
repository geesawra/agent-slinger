import XCTest

final class AccessibilityUITests: XCTestCase {
  func testNativeAccessibilityAuditOnConnectionProjectsAndChat() throws {
    let app = launchDemo()
    XCTAssertTrue(app.navigationBars["Oesap"].waitForExistence(timeout: 5))
    fillEndpoint(app)
    let connectButton = app.buttons["connect-button"]
    XCTAssertTrue(scrollUntilHittable(connectButton, in: app, whenMissing: .earlier))
    XCTAssertTrue(connectButton.isEnabled)
    XCTAssertTrue(connectButton.isHittable, "Connect should be visible during the audit.")
    attachScreenshot(named: "Accessibility audit — connection", app: app)
    try app.performAccessibilityAudit(
      for: [
        .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .trait,
      ])

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
    XCTAssertTrue(context.isHittable, "Context usage should remain in the composer accessory row.")
    attachScreenshot(named: "Accessibility audit — chat", app: app)
    try app.performAccessibilityAudit(
      for: [
        .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .trait,
      ])

  }

  func testAccessibilitySizeAndDarkModeKeepChatAndPermissionControlsReachable() {
    let app = launchDemo(accessibilitySize: true, darkMode: true)
    attachScreenshot(named: "AX5 dark connection", app: app)
    connect(app)

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

    let context = app.buttons["context-usage-button"]
    XCTAssertTrue(context.waitForExistence(timeout: 5))
    XCTAssertEqual(context.value as? String, "32% used")
    XCTAssertTrue(context.isHittable, "Context usage should remain above the composer at AX5.")
    assertMinimumTapTarget(context, named: "Context usage")

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Check the accessible send control")
    let send = app.buttons["send-message"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled)
    XCTAssertTrue(
      context.isHittable, "Context usage should remain reachable with the keyboard open.")
    assertMinimumTapTarget(send, named: "Send message")
    attachScreenshot(named: "AX5 dark chat composer", app: app)
    send.tap()
    chooseRunningSendAction(app, "Steer when supported")
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-user-0"].waitForExistence(timeout: 5))
  }

  func testAX5DarkAgentStopAndRunningSendChoicesAreReachable() {
    let app = launchDemo(accessibilitySize: true, darkMode: true, agentControl: true)
    connect(app)
    let project = app.buttons["project-demo-project"]
    XCTAssertTrue(scrollUntilHittable(project, in: app))
    project.tap()
    let thread = app.buttons["thread-demo-agent-running"]
    XCTAssertTrue(scrollUntilHittable(thread, in: app))
    thread.tap()

    let stop = app.buttons["agent-stop-demo-agent-running"]
    let context = app.buttons["context-usage-button"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    XCTAssertTrue(context.waitForExistence(timeout: 5))
    XCTAssertTrue(stop.isHittable, "Stop should stay in the composer accessory row at AX5.")
    XCTAssertTrue(context.isHittable, "Context should stay in the composer accessory row at AX5.")
    assertMinimumTapTarget(stop, named: "Stop agent")
    assertMinimumTapTarget(context, named: "Context usage")
    attachScreenshot(named: "AX5 dark Stop control", app: app)
    stop.tap()

    let stopAlert = app.alerts["Stop this agent?"]
    XCTAssertTrue(stopAlert.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilHittable(stopAlert.buttons["Stop agent"]))
    let stopCancel = stopAlert.buttons["Cancel"]
    XCTAssertTrue(waitUntilHittable(stopCancel))
    attachScreenshot(named: "AX5 dark Stop confirmation", app: app)
    stopCancel.tap()

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    assertMinimumTapTarget(composer, named: "Message composer")
    let prompt = "Check active-turn choices at large text size"
    composer.tap()
    composer.typeText(prompt)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(stop.isHittable, "Stop should remain reachable while the keyboard is open.")
    XCTAssertTrue(context.isHittable, "Context should remain reachable while the keyboard is open.")
    let send = app.buttons["send-message"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled)
    XCTAssertTrue(send.isHittable)
    assertMinimumTapTarget(send, named: "Send message")
    attachScreenshot(named: "AX5 dark accessory and composer with keyboard", app: app)
    send.tap()

    let sendSheet = app.navigationBars["Send to running agent?"]
    XCTAssertTrue(sendSheet.waitForExistence(timeout: 5))
    let steer = app.buttons["agent-send-steer"]
    let interrupt = app.buttons["agent-send-interrupt"]
    XCTAssertTrue(scrollSheetActionFullyIntoView(steer, in: app))
    XCTAssertTrue(waitUntilHittable(steer))
    attachScreenshot(named: "AX5 dark steer choice", app: app)
    XCTAssertTrue(scrollSheetActionFullyIntoView(interrupt, in: app))
    XCTAssertTrue(waitUntilHittable(interrupt))
    attachScreenshot(named: "AX5 dark interrupt choice", app: app)
    let sendCancel = app.buttons["agent-action-cancel"]
    XCTAssertTrue(waitUntilHittable(sendCancel))
    sendCancel.tap()
    XCTAssertEqual(composer.value as? String, prompt)
  }

  func testAX5DarkFailedRunningSendCanBeReviewedAndClearedWithoutLosingDraft() {
    let app = launchDemo(
      accessibilitySize: true, darkMode: true,
      additionalArguments: ["--demo-send-failure"])
    connect(app)
    let project = app.buttons["project-demo-project"]
    XCTAssertTrue(scrollUntilHittable(project, in: app))
    project.tap()
    let thread = app.buttons["thread-demo-agent-running"]
    XCTAssertTrue(scrollUntilHittable(thread, in: app))
    thread.tap()

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    let prompt = "Keep this message available after an uncertain send"
    composer.tap()
    composer.typeText(prompt)
    let send = app.buttons["send-message"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled)
    send.tap()

    let sendSheet = app.navigationBars["Send to running agent?"]
    XCTAssertTrue(sendSheet.waitForExistence(timeout: 5))
    let steer = app.buttons["agent-send-steer"]
    XCTAssertTrue(scrollSheetActionFullyIntoView(steer, in: app))
    XCTAssertTrue(waitUntilHittable(steer))
    steer.tap()

    let timeline = app.scrollViews["chat-timeline-scroll"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    let warning = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", "Delivery couldn’t be confirmed")
    ).firstMatch
    XCTAssertTrue(warning.waitForExistence(timeout: 5))
    let review = app.buttons["agent-action-review"]
    XCTAssertTrue(review.waitForExistence(timeout: 5))
    XCTAssertTrue(
      scrollUntilVisibleAboveComposer(
        review, in: timeline, app: app, whenMissing: .later),
      "The failed-send warning and Review action should be reachable above the keyboard.")
    XCTAssertTrue(waitUntilHittable(warning))
    XCTAssertTrue(isFullyVisibleAboveComposer(warning, in: app))
    attachScreenshot(named: "AX5 dark failed-send warning", app: app)
    review.tap()

    let reviewSheet = app.navigationBars["Check the previous send"]
    XCTAssertTrue(reviewSheet.waitForExistence(timeout: 5))
    let explanation = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", "host may still deliver it")
    ).firstMatch
    XCTAssertTrue(explanation.waitForExistence(timeout: 5))
    let clearWarning = app.buttons["agent-action-clear-warning"]
    XCTAssertTrue(scrollSheetActionFullyIntoView(clearWarning, in: app))
    XCTAssertTrue(waitUntilHittable(clearWarning))
    let cancel = app.buttons["agent-action-cancel"]
    XCTAssertTrue(waitUntilHittable(cancel))
    attachScreenshot(named: "AX5 dark uncertain-send review sheet", app: app)
    cancel.tap()

    XCTAssertEqual(composer.value as? String, prompt)
    XCTAssertTrue(warning.waitForExistence(timeout: 5))
    XCTAssertTrue(
      scrollUntilVisibleAboveComposer(review, in: timeline, app: app, whenMissing: .later))
    review.tap()
    let clearSheet = app.navigationBars["Check the previous send"]
    XCTAssertTrue(clearSheet.waitForExistence(timeout: 5))
    let clearWarningAfterCancel = app.buttons["agent-action-clear-warning"]
    XCTAssertTrue(scrollSheetActionFullyIntoView(clearWarningAfterCancel, in: app))
    XCTAssertTrue(waitUntilHittable(clearWarningAfterCancel))
    clearWarningAfterCancel.tap()

    let warningDismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: warning)
    XCTAssertEqual(XCTWaiter.wait(for: [warningDismissed], timeout: 5), .completed)
    XCTAssertEqual(composer.value as? String, prompt)
  }

  private func launchDemo(
    accessibilitySize: Bool = false,
    darkMode: Bool = false,
    agentControl: Bool = false,
    additionalArguments: [String] = []
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
    if agentControl {
      app.launchArguments.append("--demo-agent-control")
    }
    app.launchArguments += additionalArguments
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
    let accessory = app.descendants(matching: .any)["chat-composer-accessory"]
    let navigationBar = app.navigationBars.firstMatch

    for _ in 0..<maxSwipes {
      let top = navigationBar.frame.maxY + 8
      let bottom: CGFloat
      if accessory.exists {
        bottom = accessory.frame.minY - 8
      } else if composer.exists {
        bottom = composer.frame.minY - 24
      } else {
        bottom = timeline.frame.maxY - 24
      }
      if element.exists && element.isHittable
        && element.frame.minY >= top && element.frame.maxY <= bottom
      {
        return true
      }

      guard element.exists else {
        nudgeTimeline(toward: direction, in: timeline, top: top, bottom: bottom)
        continue
      }
      if element.frame.minY < top {
        nudgeTimeline(toward: .earlier, in: timeline, top: top, bottom: bottom)
      } else {
        nudgeTimeline(toward: .later, in: timeline, top: top, bottom: bottom)
      }
    }

    let top = navigationBar.frame.maxY + 8
    let bottom: CGFloat
    if accessory.exists {
      bottom = accessory.frame.minY - 8
    } else if composer.exists {
      bottom = composer.frame.minY - 24
    } else {
      bottom = timeline.frame.maxY - 24
    }
    return element.exists && element.isHittable
      && element.frame.minY >= top && element.frame.maxY <= bottom
  }

  private func isFullyVisibleAboveComposer(_ element: XCUIElement, in app: XCUIApplication) -> Bool
  {
    let top = app.navigationBars.firstMatch.frame.maxY + 8
    let composer = app.descendants(matching: .any)["chat-composer"]
    let accessory = app.descendants(matching: .any)["chat-composer-accessory"]
    guard accessory.exists || composer.exists else { return false }
    let bottom = accessory.exists ? accessory.frame.minY - 8 : composer.frame.minY - 24
    return element.exists && element.isHittable
      && element.frame.minY >= top && element.frame.maxY <= bottom
  }

  private func scrollSheetActionFullyIntoView(
    _ element: XCUIElement,
    in app: XCUIApplication,
    maxSwipes: Int = 16
  ) -> Bool {
    let options = app.descendants(matching: .any)["agent-action-options"]
    let navigationBar = app.navigationBars.firstMatch
    guard options.waitForExistence(timeout: 5), navigationBar.exists else { return false }

    for _ in 0..<maxSwipes {
      let top = navigationBar.frame.maxY + 8
      let bottom = min(options.frame.maxY - 12, app.frame.maxY - 40)
      if element.exists && element.isHittable
        && element.frame.minY >= top && element.frame.maxY <= bottom
      {
        return true
      }

      guard element.exists else {
        options.swipeUp()
        continue
      }
      if element.frame.minY < top {
        options.swipeDown()
      } else {
        options.swipeUp()
      }
    }

    let top = navigationBar.frame.maxY + 8
    let bottom = min(options.frame.maxY - 12, app.frame.maxY - 40)
    return element.exists && element.isHittable
      && element.frame.minY >= top && element.frame.maxY <= bottom
  }

  private func scroll(_ direction: TimelineDirection, in scrollView: XCUIElement) {
    switch direction {
    case .earlier: scrollView.swipeDown()
    case .later: scrollView.swipeUp()
    }
  }

  private func nudgeTimeline(
    toward direction: TimelineDirection,
    in timeline: XCUIElement,
    top: CGFloat,
    bottom: CGFloat
  ) {
    let frame = timeline.frame
    let usableTop = max(top, frame.minY + 8)
    let usableBottom = min(bottom, frame.maxY - 8)
    let usableHeight = usableBottom - usableTop
    guard frame.height > 0, usableHeight > 40 else { return }

    let startY: CGFloat
    let endY: CGFloat
    switch direction {
    case .earlier:
      startY = usableTop + usableHeight * 0.34
      endY = usableTop + usableHeight * 0.49
    case .later:
      startY = usableTop + usableHeight * 0.72
      endY = usableTop + usableHeight * 0.57
    }
    let start = timeline.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: (startY - frame.minY) / frame.height))
    let end = timeline.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: (endY - frame.minY) / frame.height))
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

  private func chooseRunningSendAction(_ app: XCUIApplication, _ action: String) {
    let sendSheet = app.navigationBars["Send to running agent?"]
    XCTAssertTrue(sendSheet.waitForExistence(timeout: 5), "A running-send choice should be shown.")
    let choice = app.buttons[runningSendActionIdentifier(action)]
    XCTAssertTrue(choice.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollSheetActionFullyIntoView(choice, in: app))
    XCTAssertTrue(waitUntilHittable(choice))
    choice.tap()
  }

  private func runningSendActionIdentifier(_ action: String) -> String {
    switch action {
    case "Steer when supported": return "agent-send-steer"
    case "Interrupt and send": return "agent-send-interrupt"
    default:
      XCTFail("Unexpected running-send action: \(action)")
      return ""
    }
  }

  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "isHittable == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
