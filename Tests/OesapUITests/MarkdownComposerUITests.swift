import XCTest

final class MarkdownComposerUITests: XCTestCase {
  func testExpandedComposerKeepsMarkdownSourceWhenDismissed() {
    let app = launchDemo(accessibilitySize: true)
    openNewThread(in: app)

    let compactEditor = app.textViews["chat-composer"]
    XCTAssertTrue(compactEditor.waitForExistence(timeout: 5))
    assertNoComposerModeControls(in: app)
    assertOnlyVisibleComposerEditor("chat-composer", in: app)

    let expand = app.buttons["chat-composer-expand"]
    XCTAssertTrue(expand.waitForExistence(timeout: 5))
    expand.tap()

    let editor = app.textViews["expanded-chat-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    assertNoComposerModeControls(in: app)
    assertOnlyVisibleComposerEditor("expanded-chat-composer", in: app)
    let source = "# Live heading\n\n**Bold text**\n\n"
    editor.tap()
    editor.typeText(source)
    XCTAssertEqual(editor.value as? String, source)
    attachScreenshot(named: "AX5 expanded composer with live Markdown", app: app)

    app.buttons["expanded-composer-done"].tap()
    XCTAssertTrue(compactEditor.waitForExistence(timeout: 5))
    XCTAssertEqual(compactEditor.value as? String, source)
    assertNoComposerModeControls(in: app)
    assertOnlyVisibleComposerEditor("chat-composer", in: app)
  }

  func testExpandedComposerStylesMarkdownWhileKeepingTheEditableSource() {
    let app = launchDemo()
    openNewThread(in: app)
    app.buttons["chat-composer-expand"].tap()

    let editor = app.textViews["expanded-chat-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    assertNoComposerModeControls(in: app)
    assertOnlyVisibleComposerEditor("expanded-chat-composer", in: app)
    let source = "## Live heading\n\n**Bold** and *italic* with `code`.\n\n- First item\n\n"
    editor.tap()
    editor.typeText(source)
    XCTAssertEqual(editor.value as? String, source)
    attachScreenshot(named: "Expanded live Markdown editing", app: app)

    app.buttons["expanded-composer-done"].tap()
    let compactEditor = app.textViews["chat-composer"]
    XCTAssertTrue(compactEditor.waitForExistence(timeout: 5))
    XCTAssertEqual(compactEditor.value as? String, source)
    assertNoComposerModeControls(in: app)
    assertOnlyVisibleComposerEditor("chat-composer", in: app)
    attachScreenshot(named: "Compact live Markdown editing", app: app)
  }

  func testAgentReplyRendersMarkdownInChat() {
    let app = launchDemo()
    openRunningThread(in: app)

    let welcome = app.descendants(matching: .any)["message-demo-welcome-agent"]
    XCTAssertTrue(welcome.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Project check-in")
      ).firstMatch.waitForExistence(timeout: 5))
    let timeline = app.scrollViews["chat-timeline-scroll"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    let code = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", "xcodebuild")
    ).firstMatch
    XCTAssertTrue(scrollUntilVisible(code, in: timeline))
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Status:")
      ).firstMatch.exists)
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Plan:")
      ).firstMatch.exists)
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "xcodebuild")
      ).firstMatch.exists)
    XCTAssertFalse(app.staticTexts["## Project check-in"].exists)
    attachScreenshot(named: "Markdown-formatted agent reply", app: app)
  }

  func testAX5ComposerControlsStayInsideScreenBounds() {
    let app = launchDemo(accessibilitySize: true, agentControl: true)
    openRunningThread(in: app)

    let context = app.buttons["context-usage-button"]
    let stop = app.buttons["agent-stop-demo-agent-running"]
    let send = app.buttons["send-message"]
    let accessory = app.descendants(matching: .any)["chat-composer-accessory"]
    XCTAssertTrue(context.waitForExistence(timeout: 5))
    XCTAssertEqual(context.value as? String, "32% used")
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(accessory.exists)
    assertInsideAppBounds(context, named: "Context", app: app)
    assertInsideAppBounds(stop, named: "Stop", app: app)
    assertInsideAppBounds(send, named: "Send", app: app)
    XCTAssertLessThanOrEqual(context.frame.maxY, accessory.frame.maxY)
    XCTAssertLessThanOrEqual(stop.frame.maxY, accessory.frame.maxY)
    attachScreenshot(named: "AX5 Context Stop and Send controls", app: app)
  }

  func testExpandedSendDismissesBeforeShowingRunningAgentChoice() {
    let app = launchDemo(agentControl: true)
    openRunningThread(in: app)
    app.buttons["chat-composer-expand"].tap()

    let editor = app.textViews["expanded-chat-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    let prompt = "## Continue this active turn\n\n**Use the existing plan**\n\n"
    editor.tap()
    editor.typeText(prompt)
    XCTAssertEqual(editor.value as? String, prompt)
    assertNoComposerModeControls(in: app)
    let surface = app.descendants(matching: .any)["expanded-composer-surface"].firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    let send = surface.descendants(matching: .button)["expanded-send-message"].firstMatch
    XCTAssertTrue(send.isHittable)
    XCTAssertTrue(
      surface.descendants(matching: .any)["expanded-send-message"].exists,
      "Expanded Send should be contained by the composer surface."
    )
    XCTAssertTrue(
      surface.frame.insetBy(dx: -1, dy: -1).contains(send.frame),
      "Expanded Send should be geometrically inside the composer surface."
    )
    XCTAssertGreaterThanOrEqual(send.frame.width, 44)
    XCTAssertGreaterThanOrEqual(send.frame.height, 44)
    XCTAssertFalse(editor.frame.intersects(send.frame), "The editor must not overlap Send.")
    XCTAssertFalse(
      app.navigationBars["Compose message"].descendants(matching: .any)["expanded-send-message"]
        .exists,
      "Expanded Send should not be in the navigation toolbar."
    )
    attachScreenshot(named: "Expanded live Markdown before send", app: app)
    send.tap()

    let sendChoice = app.navigationBars["Send to running agent?"]
    XCTAssertTrue(sendChoice.waitForExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars["Compose message"].exists)
    let steer = app.buttons["agent-send-steer"]
    XCTAssertTrue(steer.waitForExistence(timeout: 5))
    XCTAssertTrue(steer.isHittable)
    steer.tap()

    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Continue this active turn")
      )
      .firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Use the existing plan"].exists)
    let receipt = app.descendants(matching: .any)["agent-message-status-demo-agent-running"]
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Message accepted by host.")
      ).firstMatch.waitForExistence(timeout: 5),
      "The existing running-agent send choice should still reach the host receipt."
    )
    XCTAssertTrue(receipt.exists)
    attachScreenshot(named: "Expanded composer running-send receipt", app: app)
  }

  private func launchDemo(accessibilitySize: Bool = false, agentControl: Bool = false)
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments = [
      "--demo",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
      "--demo-server-id=ui-markdown-\(UUID().uuidString.lowercased())",
    ]
    if accessibilitySize {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    }
    if agentControl {
      app.launchArguments.append("--demo-agent-control")
    }
    app.launch()
    XCTAssertTrue(app.navigationBars["Oesap"].waitForExistence(timeout: 5))
    return app
  }

  private func connect(_ app: XCUIApplication) {
    let endpoint = app.textFields["direct-endpoint"]
    XCTAssertTrue(scrollUntilHittable(endpoint, in: app))
    endpoint.tap()
    endpoint.typeText("demo.paseo.local:6767")
    let done = app.buttons["connection-keyboard-done"]
    XCTAssertTrue(done.waitForExistence(timeout: 5))
    done.tap()
    let connect = app.buttons["connect-button"]
    XCTAssertTrue(scrollUntilHittable(connect, in: app))
    connect.tap()
    XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
  }

  private func openNewThread(in app: XCUIApplication) {
    connect(app)
    let project = app.buttons["project-demo-project"]
    XCTAssertTrue(project.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUntilHittable(project, in: app))
    project.tap()
    let newThread = app.buttons["new-thread-button"]
    XCTAssertTrue(newThread.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUntilHittable(newThread, in: app))
    newThread.tap()
    XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
  }

  private func openRunningThread(in app: XCUIApplication) {
    connect(app)
    let project = app.buttons["project-demo-project"]
    XCTAssertTrue(project.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUntilHittable(project, in: app))
    project.tap()
    let thread = app.buttons["thread-demo-agent-running"]
    XCTAssertTrue(thread.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUntilHittable(thread, in: app))
    thread.tap()
    XCTAssertTrue(app.buttons["chat-composer-expand"].waitForExistence(timeout: 5))
  }

  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func assertNoComposerModeControls(
    in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(app.buttons["chat-composer-mode"].exists, file: file, line: line)
    XCTAssertFalse(app.segmentedControls["expanded-composer-mode"].exists, file: file, line: line)
    XCTAssertFalse(
      app.descendants(matching: .any)["expanded-composer-preview"].exists, file: file, line: line)
  }

  private func assertOnlyVisibleComposerEditor(
    _ identifier: String, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let identifiers = ["chat-composer", "expanded-chat-composer"]
    let visibleEditors =
      identifiers
      .map { app.textViews[$0] }
      .filter { $0.exists && $0.isHittable }
    XCTAssertEqual(visibleEditors.count, 1, file: file, line: line)
    XCTAssertEqual(visibleEditors.first?.identifier, identifier, file: file, line: line)
  }

  private func scrollUntilHittable(
    _ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8
  ) -> Bool {
    for _ in 0..<maxSwipes {
      if element.exists && element.isHittable { return true }
      guard element.exists else {
        app.swipeUp()
        continue
      }
      if element.frame.midY < app.frame.minY {
        app.swipeDown()
      } else {
        app.swipeUp()
      }
    }
    return element.exists && element.isHittable
  }

  private func scrollUntilVisible(
    _ element: XCUIElement, in scrollView: XCUIElement, maxSwipes: Int = 10
  ) -> Bool {
    for _ in 0..<maxSwipes {
      if element.exists && element.isHittable { return true }
      scrollView.swipeUp()
    }
    return element.exists && element.isHittable
  }

  private func attachScreenshot(named name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func assertInsideAppBounds(
    _ element: XCUIElement, named name: String, app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertGreaterThan(
      element.frame.width, 0, "\(name) should have a visible width.", file: file, line: line)
    XCTAssertGreaterThan(
      element.frame.height, 0, "\(name) should have a visible height.", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      element.frame.minX, app.frame.minX, "\(name) is clipped on the left.", file: file, line: line)
    XCTAssertLessThanOrEqual(
      element.frame.maxX, app.frame.maxX, "\(name) is clipped on the right.", file: file, line: line
    )
    XCTAssertGreaterThanOrEqual(
      element.frame.minY, app.frame.minY, "\(name) is clipped at the top.", file: file, line: line)
    XCTAssertLessThanOrEqual(
      element.frame.maxY, app.frame.maxY, "\(name) is clipped at the bottom.", file: file,
      line: line)
  }
}
