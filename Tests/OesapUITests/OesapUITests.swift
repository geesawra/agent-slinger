import XCTest

final class OesapUITests: XCTestCase {
  func testConnectBrowseAndSendMessage() {
    let app = launchDemo()
    attachScreenshot(named: "Connection setup")
    connect(app)

    let project = app.buttons["project-demo-project"]
    XCTAssertTrue(project.waitForExistence(timeout: 5))
    attachScreenshot(named: "Projects")
    project.tap()

    let thread = app.buttons["thread-demo-agent-running"]
    XCTAssertTrue(thread.waitForExistence(timeout: 5))
    thread.tap()

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-welcome-user"].waitForExistence(timeout: 5))
    attachScreenshot(named: "Agent chat")
    composer.tap()
    composer.typeText("Show the app status")
    let sendButton = app.buttons["send-message"]
    XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
    XCTAssertTrue(sendButton.isEnabled)
    sendButton.tap()
    chooseRunningSendAction(app, "Steer when supported")

    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-user-0"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-reply-0"].waitForExistence(timeout: 5))
    XCTAssertNotEqual(composer.value as? String, "Show the app status")
  }

  func testCancellingStopKeepsAgentRunningAndPreservesDraft() {
    let (app, stop) = openAgentControlChat()
    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Keep this draft if I cancel Stop")

    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    let context = app.buttons["context-usage-button"]
    let send = app.buttons["send-message"]
    XCTAssertTrue(context.waitForExistence(timeout: 5))
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(context.isHittable, "Context should remain reachable while typing.")
    XCTAssertTrue(stop.isHittable, "Stop should remain reachable while typing.")
    XCTAssertTrue(send.isHittable, "Send should remain reachable while typing.")
    XCTAssertLessThanOrEqual(context.frame.maxY, composer.frame.minY)
    XCTAssertLessThanOrEqual(stop.frame.maxY, composer.frame.minY)
    assertMinimumTapTarget(context, named: "Context usage")
    assertMinimumTapTarget(stop, named: "Stop agent")
    attachScreenshot(named: "Light context and Stop accessory with keyboard")

    stop.tap()
    let alert = app.alerts["Stop this agent?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilHittable(alert.buttons["Stop agent"]))
    let cancel = alert.buttons["Cancel"]
    XCTAssertTrue(waitUntilHittable(cancel))
    cancel.tap()

    XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 5))
    XCTAssertEqual(composer.value as? String, "Keep this draft if I cancel Stop")
  }

  func testConfirmingStopUpdatesAuthoritativeAgentState() {
    let (app, stop) = openAgentControlChat()
    XCTAssertTrue(stop.isHittable)
    stop.tap()

    let alert = app.alerts["Stop this agent?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    let confirm = alert.buttons["Stop agent"]
    XCTAssertTrue(waitUntilHittable(confirm))
    confirm.tap()

    XCTAssertTrue(app.staticTexts["Idle"].waitForExistence(timeout: 5))
    let receipt = app.descendants(matching: .any)[
      "agent-action-status-demo-agent-running"
    ]
    XCTAssertTrue(waitForLabel(receipt, containing: "Agent stopped.", timeout: 5))
  }

  func testSteerChoiceSendsAndShowsHostReceipt() {
    let (app, _) = openAgentControlChat()
    let prompt = "Continue this active turn without restarting"
    sendRunningPrompt(prompt, using: "Steer when supported", in: app)
    assertAcceptedRunningPrompt(prompt, in: app)
  }

  func testInterruptChoiceSendsAndShowsHostReceipt() {
    let (app, _) = openAgentControlChat()
    let prompt = "Replace the active turn with this task"
    sendRunningPrompt(prompt, using: "Interrupt and send", in: app)
    assertAcceptedRunningPrompt(prompt, in: app)
  }

  func testConnectionFailureIsVisible() {
    let app = launchDemo(arguments: ["--demo-failure"])
    enterEndpoint(app)
    app.buttons["connect-button"].tap()

    XCTAssertTrue(app.descendants(matching: .any)["connection-error"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "rejected this connection")
      )
      .firstMatch.waitForExistence(timeout: 5))
  }

  func testEmptyProjectsHaveAnExplicitEmptyState() {
    let app = launchDemo(arguments: ["--demo-empty"])
    enterEndpoint(app)
    app.buttons["connect-button"].tap()

    XCTAssertTrue(app.staticTexts["No projects yet"].waitForExistence(timeout: 5))
  }

  func testAgentOverviewFiltersGroupsAndOpensTheSelectedProjectThread() {
    let app = launchDemo()
    connect(app)
    app.buttons["agents-overview-button"].tap()

    XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5))
    let running = app.buttons["overview-agent-demo-agent-running"]
    let attention = app.buttons["overview-agent-demo-agent-attention"]
    let toolsRunning = app.buttons["overview-agent-demo-tools-running"]
    let failed = app.buttons["overview-agent-demo-tools-failed"]
    let idle = app.buttons["overview-agent-demo-agent-idle"]
    XCTAssertTrue(running.waitForExistence(timeout: 5))
    XCTAssertTrue(attention.exists)
    XCTAssertTrue(toolsRunning.exists)
    XCTAssertTrue(failed.exists)
    XCTAssertFalse(idle.exists)
    XCTAssertTrue(
      app.staticTexts["agent-overview-summary"].label.contains(
        "2 running · 2 need attention · 1 error")
    )
    attachScreenshot(named: "Active agents grouped by project")

    app.buttons["All"].tap()
    XCTAssertTrue(idle.waitForExistence(timeout: 5))
    attachScreenshot(named: "All agents including idle")

    XCTAssertTrue(scrollUntilHittable(failed, in: app))
    failed.tap()
    XCTAssertTrue(app.navigationBars["Fix release build"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Failed"].waitForExistence(timeout: 5))
    attachScreenshot(named: "Agent opened from overview")
  }

  func testAgentOverviewShowsEmptyAndPartialFailureStates() {
    let emptyApp = launchDemo(arguments: ["--demo-overview-empty"])
    connect(emptyApp)
    emptyApp.buttons["agents-overview-button"].tap()
    XCTAssertTrue(emptyApp.navigationBars["Agents"].waitForExistence(timeout: 5))
    XCTAssertTrue(emptyApp.staticTexts["No active agents"].waitForExistence(timeout: 5))
    emptyApp.buttons["All"].tap()
    XCTAssertTrue(
      emptyApp.staticTexts["No agents in these projects"].waitForExistence(timeout: 5))

    let failureApp = launchDemo(arguments: ["--demo-overview-failure"])
    connect(failureApp)
    failureApp.buttons["agents-overview-button"].tap()
    XCTAssertTrue(failureApp.navigationBars["Agents"].waitForExistence(timeout: 5))
    let healthyAgent = failureApp.buttons["overview-agent-demo-agent-running"]
    XCTAssertTrue(healthyAgent.waitForExistence(timeout: 5))
    XCTAssertTrue(failureApp.staticTexts["Some project states are unavailable"].exists)
    XCTAssertTrue(failureApp.buttons["retry-agent-overview"].exists)
    XCTAssertFalse(
      failureApp.staticTexts["No active agents"].exists,
      "A partial project failure must stay visible instead of looking like an empty overview."
    )
    attachScreenshot(named: "Partial agent overview with healthy project rows")

    let projectError = failureApp.staticTexts["overview-project-error-demo-tools-project"]
    XCTAssertTrue(projectError.waitForExistence(timeout: 5))
    for _ in 0..<5 where !projectError.isHittable {
      failureApp.swipeUp()
    }
    XCTAssertTrue(projectError.isHittable)
    XCTAssertEqual(projectError.label, "The demo tools project could not be loaded.")
    attachScreenshot(named: "Partial agent overview project error")
  }

  func testContextDisclosureShowsLastReportAndHostUsageShowsProviderQuotas() {
    continueAfterFailure = false
    let app = launchDemo()
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["thread-demo-agent-running"].tap()

    let contextButton = app.buttons["context-usage-button"]
    XCTAssertTrue(contextButton.waitForExistence(timeout: 5))
    XCTAssertTrue(contextButton.isHittable, "Context belongs to the persistent composer accessory.")
    XCTAssertTrue(contextButton.label.contains("Last reported context usage"))
    let contextValue = (contextButton.value as? String) ?? ""
    let contextAccessibility = "\(contextButton.label) \(contextValue)"
    XCTAssertTrue(contextAccessibility.contains("32%"))
    attachScreenshot(named: "Chat context usage")
    contextButton.tap()

    XCTAssertTrue(app.navigationBars["Usage details"].waitForExistence(timeout: 5))
    XCTAssertTrue(staticText(containing: "Last reported context", in: app).exists)
    let usageList = app.collectionViews.firstMatch
    XCTAssertTrue(usageList.waitForExistence(timeout: 5))
    let expanded = expandUsageDetailsSheet(app)
    if !expanded {
      attachScreenshot(named: "Usage details sheet expansion failure")
      attachAccessibilitySnapshot(named: "Usage details sheet accessibility", app: app)
    }
    XCTAssertTrue(expanded, "Usage details should expand before scrolling.")

    let usedTokens = staticText(containing: "64,000 tokens", in: app)
    XCTAssertTrue(scrollElementIntoView(usedTokens, in: usageList))
    let contextWindow = staticText(containing: "200,000 tokens", in: app)
    XCTAssertTrue(scrollElementIntoView(contextWindow, in: usageList))
    attachScreenshot(named: "Context token details")
    let fiveHourWindow = staticText(containing: "Five-hour window", in: app)
    XCTAssertTrue(
      scrollElementIntoView(fiveHourWindow, in: usageList),
      "The five-hour quota should be reachable in the usage list.\n\(app.debugDescription)"
    )
    let remaining = staticText(containing: "62%", in: app)
    XCTAssertTrue(scrollElementIntoView(remaining, in: usageList))
    attachScreenshot(named: "Selected provider quota window")
    let credits = staticText(containing: "Credits", in: app)
    XCTAssertTrue(scrollElementIntoView(credits, in: usageList))
    let creditBalance = staticText(containing: "12.50", in: app)
    XCTAssertTrue(scrollElementIntoView(creditBalance, in: usageList))
    attachScreenshot(named: "Selected provider credit balance")
    app.buttons["usage-details-done"].tap()

    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Oesap demo"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
    openHostUsage(app)

    XCTAssertTrue(app.navigationBars["Usage"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["provider-usage-0"].waitForExistence(timeout: 5))
    let hostUsageList = app.collectionViews.firstMatch
    XCTAssertTrue(hostUsageList.waitForExistence(timeout: 5))
    let hostFiveHourWindow = staticText(containing: "Five-hour window", in: app)
    XCTAssertTrue(scrollElementIntoView(hostFiveHourWindow, in: hostUsageList))
    attachScreenshot(named: "Host provider usage windows")
    let hostCredits = staticText(containing: "Credits", in: app)
    XCTAssertTrue(scrollElementIntoView(hostCredits, in: hostUsageList))
    attachScreenshot(named: "Host provider balance")
    let claude = staticText(containing: "Claude Code", in: app)
    XCTAssertTrue(scrollElementIntoView(claude, in: hostUsageList))
    XCTAssertTrue(staticText(containing: "Unavailable", in: app).exists)
    let cursor = staticText(containing: "Cursor", in: app)
    XCTAssertTrue(scrollElementIntoView(cursor, in: hostUsageList))
    XCTAssertTrue(staticText(containing: "Usage provider temporarily unavailable.", in: app).exists)
    attachScreenshot(named: "Host provider unavailable and error statuses")
  }

  func testProviderUsageUnsupportedUnavailableAndErrorStates() {
    let unsupportedApp = launchDemo(arguments: ["--demo", "--demo-usage-unsupported"])
    connect(unsupportedApp)
    openHostUsage(unsupportedApp)
    XCTAssertTrue(
      unsupportedApp.staticTexts["Quotas unavailable"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      staticText(containing: "Update the Paseo host", in: unsupportedApp).exists)
    attachScreenshot(named: "Provider usage unsupported")

    let unavailableApp = launchDemo(arguments: ["--demo", "--demo-usage-unavailable"])
    connect(unavailableApp)
    openHostUsage(unavailableApp)
    XCTAssertTrue(unavailableApp.navigationBars["Usage"].waitForExistence(timeout: 5))
    XCTAssertTrue(staticText(containing: "Codex", in: unavailableApp).exists)
    XCTAssertTrue(staticText(containing: "Claude Code", in: unavailableApp).exists)
    XCTAssertTrue(staticText(containing: "Unavailable", in: unavailableApp).exists)
    XCTAssertFalse(staticText(containing: "0%", in: unavailableApp).exists)
    attachScreenshot(named: "Provider usage unavailable")

    let failureApp = launchDemo(arguments: ["--demo", "--demo-usage-failure"])
    connect(failureApp)
    openHostUsage(failureApp)
    XCTAssertTrue(
      failureApp.staticTexts["Provider usage unavailable"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      staticText(containing: "The demo host could not load provider usage.", in: failureApp).exists)
    XCTAssertTrue(failureApp.buttons["retry-provider-usage"].exists)
    attachScreenshot(named: "Provider usage refresh failure")
  }

  func testUsageViewsRemainReadableAtAccessibilityTextSize() {
    continueAfterFailure = false
    let app = launchDemo(
      arguments: [
        "--demo", "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityXXXL",
      ])
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["thread-demo-agent-running"].tap()

    let contextButton = app.buttons["context-usage-button"]
    XCTAssertTrue(contextButton.waitForExistence(timeout: 5))
    XCTAssertTrue(contextButton.isHittable, "Context should remain in the accessory row at AX5.")
    assertMinimumTapTarget(contextButton, named: "Context usage")
    let timeline = app.scrollViews["chat-timeline-scroll"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    let running = app.staticTexts["Running"]
    for _ in 0..<8 where !running.isHittable { timeline.swipeDown() }
    XCTAssertTrue(running.waitForExistence(timeout: 5))
    XCTAssertTrue(running.isHittable)
    attachScreenshot(named: "Chat at accessibility text size")
    contextButton.tap()
    XCTAssertTrue(app.navigationBars["Usage details"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["usage-details-done"].isHittable)
    attachScreenshot(named: "Usage details at accessibility text size")
    let accessibilityUsageList = app.collectionViews.firstMatch
    XCTAssertTrue(accessibilityUsageList.waitForExistence(timeout: 5))
    let accessibilityUsed = staticText(containing: "64,000 tokens", in: app)
    XCTAssertTrue(scrollElementIntoView(accessibilityUsed, in: accessibilityUsageList))
    attachScreenshot(named: "Usage token details at accessibility text size")
  }

  func testFailedSendKeepsTheDraftForRetry() {
    let app = launchDemo(arguments: ["--demo-send-failure"])
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["thread-demo-agent-running"].tap()

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-welcome-user"].waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Keep this draft")
    let sendButton = app.buttons["send-message"]
    XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
    XCTAssertTrue(sendButton.isEnabled)
    sendButton.tap()
    chooseRunningSendAction(app, "Steer when supported")

    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Delivery couldn’t be confirmed")
      )
      .firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(composer.value as? String, "Keep this draft")
  }

  func testToolCallCardsExpandShowTypedDetailsAndUpdateInPlace() {
    let app = launchDemo(arguments: ["--demo-tools"])
    connect(app)
    app.buttons["project-demo-tools-project"].tap()
    app.buttons["thread-demo-tools-agent"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-tools-agent-welcome"].waitForExistence(
        timeout: 5))

    let timeline = app.scrollViews["chat-timeline-scroll"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))

    let readRowID = "tool:turn:1:1:demo-read-call"
    let readCard = toolCallCard(app, rowID: readRowID)
    XCTAssertTrue(scrollCardIntoSafePosition(readCard, in: timeline, whenMissing: .earlier))
    readCard.tap()
    XCTAssertTrue(
      app.staticTexts["Sources/Oesap/Features/WorkspaceViews.swift"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Offset 1 · Limit 7"].waitForExistence(timeout: 5))
    attachScreenshot(named: "Read tool preview")
    readCard.tap()

    let editRowID = "tool:turn:1:1:demo-edit-call"
    let editCard = toolCallCard(app, rowID: editRowID)
    XCTAssertTrue(scrollCardIntoSafePosition(editCard, in: timeline, whenMissing: .later))
    editCard.tap()
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "+  @State private var selectedProject")
      ).firstMatch.waitForExistence(timeout: 5))
    attachScreenshot(named: "Edit tool diff")
    editCard.tap()

    let failedRowID = "tool:turn:1:1:demo-failed-call"
    let failedCard = toolCallCard(app, rowID: failedRowID)
    XCTAssertTrue(scrollCardIntoSafePosition(failedCard, in: timeline, whenMissing: .later))
    failedCard.tap()
    XCTAssertTrue(app.staticTexts["swiftformat: command not found"].waitForExistence(timeout: 5))
    failedCard.tap()

    let shellRowID = "tool:turn:1:1:demo-shell-call"
    let shellCard = toolCallCard(app, rowID: shellRowID)
    XCTAssertTrue(scrollCardIntoSafePosition(shellCard, in: timeline, whenMissing: .earlier))
    XCTAssertTrue(shellCard.label.contains("Running"))
    attachScreenshot(named: "Tool-call activity")
    shellCard.tap()

    let fullOutput = app.buttons["tool-call-full-\(shellRowID)-shell-output"]
    XCTAssertTrue(fullOutput.waitForExistence(timeout: 5))
    attachScreenshot(named: "Expanded shell call")
    fullOutput.tap()

    let loadMore = app.buttons["tool-call-load-more-output"]
    let sheetScrollView = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
    XCTAssertTrue(scrollUntilHittable(loadMore, in: sheetScrollView, maxSwipes: 20))
    loadMore.tap()
    let case150 = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", "Test case 150:")
    ).firstMatch
    XCTAssertTrue(scrollUntilHittable(case150, in: sheetScrollView, maxSwipes: 20))
    attachScreenshot(named: "Full shell output")
    app.buttons["tool-call-full-output-done"].tap()

    let composer = app.textFields["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Please finish checking the output")
    let sendButton = app.buttons["send-message"]
    XCTAssertTrue(sendButton.isEnabled)
    sendButton.tap()
    chooseRunningSendAction(app, "Interrupt and send")

    let completedCard = app.buttons.matching(
      NSPredicate(
        format: "identifier == %@ AND label CONTAINS %@",
        "tool-call-disclosure-\(shellRowID)", "Completed")
    ).firstMatch
    XCTAssertTrue(completedCard.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["tool-call-full-\(shellRowID)-shell-output"].exists)
  }

  func testNewThreadStartsBlankKeepsDraftThroughAgentSetupAndCreatesOnSend() {
    let app = launchDemo()
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["new-thread-button"].tap()

    XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
    let composer = app.textFields["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    attachScreenshot(named: "Blank focused new thread")
    let sendButton = app.buttons["send-message"]
    XCTAssertFalse(sendButton.isEnabled)
    composer.typeText("Inspect the project structure")
    XCTAssertEqual(composer.value as? String, "Inspect the project structure")
    XCTAssertTrue(app.buttons["new-thread-setup-agent"].waitForExistence(timeout: 5))

    app.buttons["new-thread-setup-agent"].tap()
    XCTAssertTrue(app.navigationBars["Project Agent"].waitForExistence(timeout: 5))
    let providerPicker = app.descendants(matching: .any)["agent-provider-picker"]
    XCTAssertTrue(providerPicker.waitForExistence(timeout: 5))
    let saveButton = app.buttons["save-agent-configuration"]
    XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
    XCTAssertTrue(saveButton.isEnabled)
    let modelPicker = app.descendants(matching: .any)["agent-model-picker"]
    XCTAssertTrue(modelPicker.waitForExistence(timeout: 5))
    attachScreenshot(named: "Project Agent configuration")
    modelPicker.tap()
    let nonDefaultModel = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "GPT-6 Astra")
    ).firstMatch
    XCTAssertTrue(nonDefaultModel.waitForExistence(timeout: 5))
    nonDefaultModel.tap()
    saveButton.tap()

    XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
    XCTAssertEqual(composer.value as? String, "Inspect the project structure")
    XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Codex · GPT-6 Astra"].waitForExistence(timeout: 5))

    app.buttons["new-thread-edit-agent"].tap()
    XCTAssertTrue(app.navigationBars["Project Agent"].waitForExistence(timeout: 5))
    let restoredModelPicker = app.descendants(matching: .any)["agent-model-picker"]
    XCTAssertTrue(restoredModelPicker.waitForExistence(timeout: 5))
    attachScreenshot(named: "Reopened Project Agent selection")
    attachAccessibilitySnapshot(named: "Reopened Project Agent accessibility", app: app)
    XCTAssertTrue(
      restoredModelPicker.label.contains("GPT-6 Astra"),
      "The Agent picker should expose the saved GPT-6 Astra selection.\n\(app.debugDescription)"
    )
    app.buttons["save-agent-configuration"].tap()

    XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
    let resumedComposer = app.textFields["chat-composer"]
    XCTAssertTrue(resumedComposer.waitForExistence(timeout: 5))
    XCTAssertEqual(resumedComposer.value as? String, "Inspect the project structure")
    resumedComposer.tap()
    let resumedSendButton = app.buttons["send-message"]
    XCTAssertTrue(resumedSendButton.waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    attachScreenshot(named: "Focused composer after Agent settings")
    XCTAssertTrue(resumedSendButton.isEnabled)
    XCTAssertTrue(resumedSendButton.isHittable)
    resumedSendButton.tap()
    XCTAssertTrue(app.navigationBars["Inspect the project structure"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-created-1-prompt"].waitForExistence(timeout: 5))
    XCTAssertNotEqual(composer.value as? String, "Inspect the project structure")
  }

  func testUnsupportedHostExplainsNewThreadAndPreservesDraft() {
    let app = launchDemo(arguments: ["--demo-creation-unsupported"])
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["new-thread-button"].tap()

    XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts[
        "This host can’t start threads from Oesap yet."
      ].waitForExistence(timeout: 5))
    let composer = app.textFields["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.typeText("Keep this draft for the host update")
    XCTAssertFalse(app.buttons["send-message"].isEnabled)
    XCTAssertEqual(composer.value as? String, "Keep this draft for the host update")
  }

  private func launchDemo(arguments: [String] = ["--demo"]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      arguments + [
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "--demo-server-id=ui-test-\(UUID().uuidString.lowercased())",
      ]
    app.launch()
    XCTAssertTrue(app.navigationBars["Oesap"].waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUntilHittable(app.textFields["direct-endpoint"], in: app))
    return app
  }

  private func connect(_ app: XCUIApplication) {
    enterEndpoint(app)
    let connectButton = app.buttons["connect-button"]
    XCTAssertTrue(scrollUntilHittable(connectButton, in: app))
    connectButton.tap()
    XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
  }

  private func chooseRunningSendAction(_ app: XCUIApplication, _ action: String) {
    let sendSheet = app.navigationBars["Send to running agent?"]
    XCTAssertTrue(sendSheet.waitForExistence(timeout: 5), "A running-send choice should be shown.")
    let choice = app.buttons[runningSendActionIdentifier(action)]
    XCTAssertTrue(choice.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUntilHittable(choice, in: app))
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

  private func openAgentControlChat() -> (XCUIApplication, XCUIElement) {
    let app = launchDemo(arguments: ["--demo-agent-control"])
    connect(app)
    let project = app.buttons["project-demo-project"]
    XCTAssertTrue(scrollUntilHittable(project, in: app))
    project.tap()
    let thread = app.buttons["thread-demo-agent-running"]
    XCTAssertTrue(scrollUntilHittable(thread, in: app))
    thread.tap()
    let stop = app.buttons["agent-stop-demo-agent-running"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    XCTAssertTrue(stop.isHittable, "Stop should stay in the composer accessory row.")
    return (app, stop)
  }

  private func assertMinimumTapTarget(_ element: XCUIElement, named name: String) {
    XCTAssertGreaterThanOrEqual(
      element.frame.width, 44, "\(name) should be at least 44 points wide.")
    XCTAssertGreaterThanOrEqual(
      element.frame.height, 44, "\(name) should be at least 44 points tall.")
  }

  private func sendRunningPrompt(_ prompt: String, using action: String, in app: XCUIApplication) {
    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText(prompt)
    let send = app.buttons["send-message"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled)
    send.tap()

    let sendSheet = app.navigationBars["Send to running agent?"]
    XCTAssertTrue(sendSheet.waitForExistence(timeout: 5))
    let choice = app.buttons[runningSendActionIdentifier(action)]
    XCTAssertTrue(choice.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUntilHittable(choice, in: app))
    XCTAssertTrue(waitUntilHittable(choice))
    choice.tap()
  }

  private func assertAcceptedRunningPrompt(_ prompt: String, in app: XCUIApplication) {
    let sentPrompt = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", prompt)
    ).firstMatch
    XCTAssertTrue(sentPrompt.waitForExistence(timeout: 5))

    let receipt = app.descendants(matching: .any)[
      "agent-message-status-demo-agent-running"
    ]
    XCTAssertTrue(waitForLabel(receipt, containing: "Message accepted by host.", timeout: 5))
  }

  private func waitForLabel(
    _ element: XCUIElement,
    containing text: String,
    timeout: TimeInterval
  ) -> Bool {
    let label = element.staticTexts.containing(
      NSPredicate(format: "label CONTAINS[cd] %@", text)
    ).firstMatch
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true"), object: label)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "isHittable == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func openHostUsage(_ app: XCUIApplication) {
    let options = app.buttons["connection-options"]
    XCTAssertTrue(options.waitForExistence(timeout: 5))
    options.tap()
    let usage = app.buttons["host-usage-button"]
    XCTAssertTrue(usage.waitForExistence(timeout: 5))
    usage.tap()
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

  private func expandUsageDetailsSheet(_ app: XCUIApplication) -> Bool {
    let grabber = app.buttons["Sheet Grabber"]
    guard grabber.waitForExistence(timeout: 5) else { return false }
    if grabber.frame.minY < 200 { return true }

    let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
    start.press(forDuration: 0.1, thenDragTo: end)

    let expanded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@ OR value == %@", "Expanded", "Full screen"),
      object: grabber
    )
    return XCTWaiter.wait(for: [expanded], timeout: 5) == .completed
      && app.collectionViews.firstMatch.frame.minY < 200
  }

  private func scrollElementIntoView(
    _ element: XCUIElement,
    in scrollView: XCUIElement,
    maxMoves: Int = 14
  ) -> Bool {
    for _ in 0..<maxMoves {
      guard scrollView.exists else { return false }
      let viewport = scrollView.frame
      let elementFrame = element.exists ? element.frame : .zero
      let isSafelyVisible =
        element.exists && element.isHittable
        && elementFrame.minY >= viewport.minY + 12
        && elementFrame.maxY <= viewport.maxY - 12
      if isSafelyVisible { return true }

      let moveFingerDown =
        element.exists && elementFrame.height > 0
        && elementFrame.minY < viewport.minY + 12
      let startY: CGFloat = moveFingerDown ? 0.28 : 0.78
      let endY: CGFloat = moveFingerDown ? 0.39 : 0.67
      let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
      let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
      start.press(forDuration: 0.04, thenDragTo: end)
    }
    let viewport = scrollView.frame
    return element.exists && element.isHittable
      && element.frame.minY >= viewport.minY + 12
      && element.frame.maxY <= viewport.maxY - 12
  }

  private func staticText(containing value: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
  }

  private func enterEndpoint(_ app: XCUIApplication) {
    let endpoint = app.textFields["direct-endpoint"]
    XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
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
      "Dismiss the keyboard before connecting.")
  }

  private func attachScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func attachAccessibilitySnapshot(named name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func toolCallCard(_ app: XCUIApplication, rowID: String) -> XCUIElement {
    app.buttons["tool-call-disclosure-\(rowID)"]
  }

  private func scrollUntilHittable(
    _ element: XCUIElement,
    in scrollView: XCUIElement,
    maxSwipes: Int = 8
  ) -> Bool {
    for _ in 0..<maxSwipes {
      if element.exists && element.isHittable { return true }
      scrollView.swipeUp()
    }
    return element.exists && element.isHittable
  }

  private func scrollCardIntoSafePosition(
    _ element: XCUIElement,
    in scrollView: XCUIElement,
    whenMissing direction: TimelineDirection,
    maxSwipes: Int = 16
  ) -> Bool {
    let safeTop = scrollView.frame.minY + 64
    let safeBottom = scrollView.frame.maxY - 130

    for _ in 0..<maxSwipes {
      if !element.exists {
        scroll(direction, in: scrollView)
        continue
      }

      let midpoint = element.frame.midY
      if element.isHittable && midpoint >= safeTop && midpoint <= safeBottom { return true }
      if midpoint < safeTop {
        scrollView.swipeDown()
      } else if midpoint > safeBottom {
        scrollView.swipeUp()
      } else {
        scroll(direction, in: scrollView)
      }
    }
    let midpoint = element.frame.midY
    return element.exists && element.isHittable && midpoint >= safeTop && midpoint <= safeBottom
  }

  private func scroll(_ direction: TimelineDirection, in scrollView: XCUIElement) {
    switch direction {
    case .earlier: scrollView.swipeDown()
    case .later: scrollView.swipeUp()
    }
  }

  private enum TimelineDirection { case earlier, later }
}
