import XCTest

final class OesapUITests: XCTestCase {
  func testGitChangesStayVisibleBesideContextAndOpenFileDiff() {
    let app = launchDemo()
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["thread-demo-agent-idle"].tap()

    let git = app.buttons["git-diff-summary"]
    let context = app.buttons["context-usage-button"]
    XCTAssertTrue(git.waitForExistence(timeout: 5))
    XCTAssertTrue(context.waitForExistence(timeout: 5))
    XCTAssertTrue(git.isHittable, "Git changes should stay visible above the composer.")
    XCTAssertLessThan(git.frame.maxX, context.frame.minX)
    XCTAssertEqual(git.frame.height, context.frame.height, accuracy: 1)
    XCTAssertTrue((git.value as? String)?.contains("2 additions, 1 deletions") == true)

    git.tap()
    XCTAssertTrue(app.navigationBars["Git changes"].waitForExistence(timeout: 5))
    let file = app.buttons["git-diff-file-Sources/Oesap/Features/ChatView.swift"]
    XCTAssertTrue(file.waitForExistence(timeout: 5))
    file.tap()
    XCTAssertTrue(app.scrollViews["git-diff-content"].waitForExistence(timeout: 5))
    let wrap = app.buttons["git-diff-toggle-line-wrapping"]
    XCTAssertTrue(wrap.waitForExistence(timeout: 5))
    XCTAssertTrue(wrap.label.contains("Disable line wrapping"))
    wrap.tap()
    XCTAssertTrue(wrap.label.contains("Enable line wrapping"))
  }

  func testSettingsAreAvailableAfterFirstConfiguredInstance() {
    let app = launchDemo()

    XCTAssertFalse(app.buttons["setup-settings-button"].exists)

    connect(app)
    app.buttons["connection-options"].tap()
    app.buttons["settings-button"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    app.buttons["add-instance-button"].tap()
    XCTAssertTrue(app.navigationBars["Add Paseo instance"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["connection-name"].exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

    let removeInstance = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Remove ")
    ).firstMatch
    XCTAssertTrue(removeInstance.waitForExistence(timeout: 5))
    removeInstance.tap()
    let confirmRemoval = app.buttons.matching(identifier: "confirm-remove-instance").firstMatch
    XCTAssertTrue(confirmRemoval.waitForExistence(timeout: 5))
    confirmRemoval.tap()
    XCTAssertTrue(app.staticTexts["No saved instances"].waitForExistence(timeout: 5))

    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.navigationBars["Oesap"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["setup-settings-button"].exists)
  }

  func testCanSwitchBetweenNamedInstancesAndRemoveAnInactiveOne() {
    let app = launchDemo()
    connect(app, name: "Studio", endpoint: "studio.paseo.local:6767")

    app.buttons["connection-options"].tap()
    app.buttons["settings-button"].tap()
    app.buttons["add-instance-button"].tap()
    XCTAssertTrue(app.navigationBars["Add Paseo instance"].waitForExistence(timeout: 5))
    connect(app, name: "Travel", endpoint: "travel.paseo.local:6767")

    app.buttons["connection-options"].tap()
    app.buttons["settings-button"].tap()
    let studio = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Studio"))
      .firstMatch
    XCTAssertTrue(studio.waitForExistence(timeout: 5))
    studio.tap()
    XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))

    app.buttons["connection-options"].tap()
    app.buttons["settings-button"].tap()
    let selectedStudio = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Studio, Selected")
    ).firstMatch
    XCTAssertTrue(selectedStudio.waitForExistence(timeout: 5))

    let removeTravel = app.buttons.matching(
      NSPredicate(format: "label == %@", "Remove Travel")
    ).firstMatch
    XCTAssertTrue(removeTravel.waitForExistence(timeout: 5))
    removeTravel.tap()
    let confirmRemoval = app.buttons.matching(identifier: "confirm-remove-instance").firstMatch
    XCTAssertTrue(confirmRemoval.waitForExistence(timeout: 5))
    confirmRemoval.tap()
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Travel")).firstMatch
        .waitForExistence(timeout: 1))
    XCTAssertTrue(selectedStudio.exists)
  }

  func testConnectBrowseAndSendMessage() {
    let app = launchDemo()
    attachScreenshot(named: "Connection setup")
    connect(app)

    let project = app.buttons["project-demo-project"]
    XCTAssertTrue(project.waitForExistence(timeout: 5))
    attachScreenshot(named: "Projects")
    project.tap()

    let thread = app.buttons["thread-demo-agent-idle"]
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
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-user-0"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-reply-0"].waitForExistence(timeout: 5))
    XCTAssertNotEqual(composer.value as? String, "Show the app status")
  }

  func testOpeningKeyboardKeepsLatestMessageAndComposerAboveIt() {
    let app = launchDemo()
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["thread-demo-agent-idle"].tap()

    let timeline = app.scrollViews["chat-timeline-scroll"]
    let latest = app.descendants(matching: .any)["message-demo-welcome-agent"]
    let composer = app.descendants(matching: .any)["chat-composer"]
    let composerSurface = app.descendants(matching: .any)["chat-composer-surface"]
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    let latestYBeforeKeyboard = latest.frame.minY

    composer.tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    XCTAssertLessThanOrEqual(composerSurface.frame.maxY, keyboard.frame.minY + 4)
    XCTAssertLessThanOrEqual(timeline.frame.maxY, composerSurface.frame.minY + 4)
    XCTAssertLessThan(latest.frame.minY, latestYBeforeKeyboard - 20)
  }

  func testReadingEarlierMessagesStaysPutWhileMarkdownStreams() {
    let app = launchDemo(arguments: ["--demo-performance"])
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["thread-demo-agent-running"].tap()

    let timeline = app.scrollViews["chat-timeline-scroll"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    let earlierMessage = app.descendants(matching: .any)["message-demo-performance-996"]
    for _ in 0..<8 where !earlierMessage.isHittable {
      timeline.swipeDown()
    }
    XCTAssertTrue(earlierMessage.isHittable)
    XCTAssertTrue(app.buttons["chat-jump-to-latest"].waitForExistence(timeout: 5))

    // Let swipe deceleration finish before measuring the reading position.
    Thread.sleep(forTimeInterval: 0.8)
    attachScreenshot(named: "Earlier message above composer")
    let initialY = earlierMessage.frame.minY
    let initialProgress = Int(timeline.value as? String ?? "0") ?? 0
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        (Int(timeline.value as? String ?? "0") ?? 0) > initialProgress + 100
      },
      object: timeline)
    XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
    XCTAssertTrue(earlierMessage.isHittable)
    XCTAssertLessThan(
      abs(earlierMessage.frame.minY - initialY), 12,
      "Streaming Markdown should not move the message being read")

    app.buttons["chat-jump-to-latest"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-performance-stream"]
        .waitForExistence(timeout: 5))
  }

  func testStopActionReturnsAfterCancelAndBecomesSendWhenTyping() {
    let (app, stop) = openAgentControlChat()
    stop.tap()
    let alert = app.alerts["Stop this agent?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilHittable(alert.buttons["Cancel"]))
    alert.buttons["Cancel"].tap()
    XCTAssertTrue(stop.waitForExistence(timeout: 5))

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Continue the active turn")

    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    let context = app.buttons["context-usage-button"]
    let send = app.buttons["send-message"]
    XCTAssertTrue(context.waitForExistence(timeout: 5))
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(context.isHittable, "Context should remain reachable while typing.")
    XCTAssertFalse(stop.exists, "The Stop action should switch to Send while typing.")
    XCTAssertTrue(send.isHittable, "Send should remain reachable while typing.")
    XCTAssertLessThanOrEqual(context.frame.maxY, composer.frame.minY)
    assertMinimumTapTarget(context, named: "Context usage")
    assertMinimumTapTarget(send, named: "Send message")
    attachScreenshot(named: "Light context and Send action with keyboard")
    XCTAssertEqual(composer.value as? String, "Continue the active turn")

    let info = app.buttons["session-info-button"]
    XCTAssertTrue(info.isHittable)
    info.tap()
    XCTAssertTrue(app.navigationBars["Session info"].waitForExistence(timeout: 5))
    let status = app.descendants(matching: .any)
      .matching(identifier: "session-info-status").firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    XCTAssertTrue(status.label.contains("Running"))
    app.buttons["session-info-done"].tap()
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

  func testRunningSendUsesPaseoSteerByDefault() {
    let (app, _) = openAgentControlChat()
    let prompt = "Continue this active turn without restarting"
    sendRunningPrompt(prompt, in: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-user-0"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.descendants(matching: .any)["chat-composer"].value as? String, "")
  }

  func testStopActionBecomesSendWhenComposingFollowUp() {
    let (app, _) = openAgentControlChat()
    let stop = app.buttons["agent-stop-demo-agent-running"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["send-message"].exists)

    let composer = app.descendants(matching: .any)["chat-composer"]
    composer.tap()
    composer.typeText("Continue the active turn")
    XCTAssertFalse(stop.exists)
    let send = app.buttons["send-message"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled)
    send.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-user-0"].waitForExistence(timeout: 5))
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

  func testLocalConnectionFailureShowsSafeTechnicalDetails() {
    // No demo factory: exercise URLSession, transport, protocol, adapter and UI.
    // The reserved local port cannot reach a remote host or save credentials.
    let app = launchDemo(arguments: [])
    enterEndpoint(app, endpoint: "127.0.0.1:1")
    let tls = app.switches["Use TLS"]
    XCTAssertTrue(scrollUntilHittable(tls, in: app))
    if tls.value as? String == "1" { tls.tap() }
    let connect = app.buttons["connect-button"]
    XCTAssertTrue(scrollUntilHittable(connect, in: app))
    connect.tap()

    XCTAssertTrue(app.descendants(matching: .any)["connection-error"].waitForExistence(timeout: 15))
    let diagnostics = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Phase:", "Cause:")
    ).firstMatch
    XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
    XCTAssertFalse(diagnostics.label.contains("127.0.0.1"))
    XCTAssertTrue(app.buttons["connection-error-copy"].exists)
    attachScreenshot(named: "Local connection failure diagnostics")
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
    let timeline = app.scrollViews["chat-timeline-scroll"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    for _ in 0..<5 { timeline.swipeDown() }
    attachScreenshot(named: "Agent chat without status header")
    let infoButton = app.buttons["session-info-button"]
    XCTAssertTrue(infoButton.waitForExistence(timeout: 5))
    infoButton.tap()
    XCTAssertTrue(app.navigationBars["Session info"].waitForExistence(timeout: 5))
    let sessionStatus = app.descendants(matching: .any)
      .matching(identifier: "session-info-status").firstMatch
    XCTAssertTrue(sessionStatus.waitForExistence(timeout: 5))
    XCTAssertTrue(sessionStatus.label.contains("Running"))
    XCTAssertTrue(staticText(containing: "codex", in: app).exists)
    XCTAssertTrue(staticText(containing: "gpt-6-sol", in: app).exists)
    XCTAssertTrue(staticText(containing: "Last reported context", in: app).exists)
    let usageList = app.collectionViews.firstMatch
    XCTAssertTrue(usageList.waitForExistence(timeout: 5))
    attachScreenshot(named: "Session info and usage")
    XCTAssertFalse(app.buttons["Sheet Grabber"].exists, "Session info opens fully expanded.")

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
    app.buttons["session-info-done"].tap()

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

  func testAgentSettingsApplyModelEffortAndPermissionsThroughContextButton() {
    continueAfterFailure = false
    let app = launchDemo()
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["thread-demo-agent-running"].tap()

    let context = app.buttons["context-usage-button"]
    XCTAssertTrue(context.waitForExistence(timeout: 5))
    assertMinimumTapTarget(context, named: "Context and settings")
    context.tap()
    XCTAssertTrue(app.navigationBars["Agent settings"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.descendants(matching: .any)["session-context-gauge"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["session-usage-details-link"].exists)

    let modelPicker = app.descendants(matching: .any)["session-model-picker"]
    let effortPicker = app.descendants(matching: .any)["session-effort-picker"]
    let permissionsPicker = app.descendants(matching: .any)["session-permissions-picker"]
    let apply = app.buttons["apply-session-settings"]
    XCTAssertTrue(modelPicker.waitForExistence(timeout: 5))
    XCTAssertTrue(effortPicker.waitForExistence(timeout: 5))
    XCTAssertFalse(apply.isEnabled)

    modelPicker.tap()
    let astra = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "GPT-6 Astra")
    ).firstMatch
    XCTAssertTrue(astra.waitForExistence(timeout: 5))
    astra.tap()
    XCTAssertTrue(apply.isEnabled)
    XCTAssertTrue(scrollUntilHittable(effortPicker, in: app))
    effortPicker.tap()
    let maximum = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Max")
    ).firstMatch
    XCTAssertTrue(maximum.waitForExistence(timeout: 5))
    maximum.tap()
    XCTAssertTrue(scrollUntilHittable(permissionsPicker, in: app))
    permissionsPicker.tap()
    let fullAccess = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Full Access")
    ).firstMatch
    XCTAssertTrue(fullAccess.waitForExistence(timeout: 5))
    fullAccess.tap()
    XCTAssertTrue(scrollUntilHittable(apply, in: app))
    apply.tap()
    XCTAssertTrue(waitUntilHittable(context), "Successful Apply should close Agent settings.")
    attachScreenshot(named: "Agent model and effort applied")

    context.tap()
    XCTAssertTrue(app.navigationBars["Agent settings"].waitForExistence(timeout: 5))
    let reopenedModel = app.descendants(matching: .any)["session-model-picker"]
    let reopenedEffort = app.descendants(matching: .any)["session-effort-picker"]
    let reopenedPermissions = app.descendants(matching: .any)["session-permissions-picker"]
    XCTAssertTrue(reopenedModel.waitForExistence(timeout: 5))
    XCTAssertTrue(reopenedModel.label.contains("GPT-6 Astra"))
    XCTAssertTrue(reopenedEffort.label.contains("Max"))
    XCTAssertTrue(reopenedPermissions.label.contains("Full Access"))
    XCTAssertFalse(app.buttons["apply-session-settings"].isEnabled)

    XCTAssertTrue(scrollUntilHittable(reopenedEffort, in: app))
    reopenedEffort.tap()
    let high = app.buttons["High"]
    XCTAssertTrue(high.waitForExistence(timeout: 5))
    high.tap()
    app.buttons["apply-session-settings"].tap()
    XCTAssertTrue(waitUntilHittable(context), "Successful Apply should close Agent settings.")
    context.tap()
    XCTAssertTrue(app.navigationBars["Agent settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["session-model-picker"].label.contains("GPT-6 Astra"))
    XCTAssertTrue(app.descendants(matching: .any)["session-effort-picker"].label.contains("High"))
    XCTAssertTrue(
      app.descendants(matching: .any)["session-permissions-picker"].label.contains("Full Access"))
  }

  func testSessionInfoOpensPermissionSettings() {
    continueAfterFailure = false
    let app = launchDemo()
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["thread-demo-agent-running"].tap()

    app.buttons["session-info-button"].tap()
    XCTAssertTrue(app.navigationBars["Session info"].waitForExistence(timeout: 5))
    let settingsButton = app.buttons["session-info-settings-button"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
    settingsButton.tap()

    XCTAssertTrue(app.navigationBars["Agent settings"].waitForExistence(timeout: 5))
    let permissionsPicker = app.descendants(matching: .any)["session-permissions-picker"]
    XCTAssertTrue(permissionsPicker.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollUntilHittable(permissionsPicker, in: app))
    permissionsPicker.tap()
    let fullAccess = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Full Access")
    ).firstMatch
    XCTAssertTrue(fullAccess.waitForExistence(timeout: 5))
    fullAccess.tap()
    app.buttons["apply-session-settings"].tap()

    XCTAssertTrue(app.navigationBars["Session info"].waitForExistence(timeout: 5))
    settingsButton.tap()
    XCTAssertTrue(app.navigationBars["Agent settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["session-permissions-picker"].label.contains("Full Access"))
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
    attachScreenshot(named: "Chat at accessibility text size")
    let infoButton = app.buttons["session-info-button"]
    XCTAssertTrue(infoButton.waitForExistence(timeout: 5))
    infoButton.tap()
    XCTAssertTrue(app.navigationBars["Session info"].waitForExistence(timeout: 5))
    let sessionStatus = app.descendants(matching: .any)
      .matching(identifier: "session-info-status").firstMatch
    XCTAssertTrue(sessionStatus.waitForExistence(timeout: 5))
    XCTAssertTrue(sessionStatus.label.contains("Running"))
    let accessibilityUsageList = app.collectionViews.firstMatch
    XCTAssertTrue(accessibilityUsageList.waitForExistence(timeout: 5))
    let accessibilityUsed = staticText(containing: "64,000 tokens", in: app)
    XCTAssertTrue(scrollElementIntoView(accessibilityUsed, in: accessibilityUsageList))
    attachScreenshot(named: "Session info and usage at accessibility text size")
    app.buttons["session-info-done"].tap()
    contextButton.tap()
    XCTAssertTrue(app.navigationBars["Agent settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["agent-settings-done"].isHittable)
    XCTAssertFalse(app.descendants(matching: .any)["session-context-gauge"].exists)
    attachScreenshot(named: "Agent settings at accessibility text size")
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

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Please finish checking the output")
    let sendButton = app.buttons["send-message"]
    XCTAssertTrue(sendButton.isEnabled)
    sendButton.tap()
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
    let composer = app.descendants(matching: .any)["chat-composer"]
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
    let resumedComposer = app.descendants(matching: .any)["chat-composer"]
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
    let composer = app.descendants(matching: .any)["chat-composer"]
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

  private func connect(_ app: XCUIApplication, name: String? = nil, endpoint: String? = nil) {
    enterEndpoint(app, name: name, endpoint: endpoint)
    let connectButton = app.buttons["connect-button"]
    XCTAssertTrue(scrollUntilHittable(connectButton, in: app))
    connectButton.tap()
    XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
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
    XCTAssertTrue(stop.isHittable, "Stop should occupy the composer action button.")
    return (app, stop)
  }

  private func assertMinimumTapTarget(_ element: XCUIElement, named name: String) {
    XCTAssertGreaterThanOrEqual(
      element.frame.width, 44, "\(name) should be at least 44 points wide.")
    XCTAssertGreaterThanOrEqual(
      element.frame.height, 44, "\(name) should be at least 44 points tall.")
  }

  private func sendRunningPrompt(_ prompt: String, in app: XCUIApplication) {
    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText(prompt)
    let send = app.buttons["send-message"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled)
    send.tap()
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

  private func enterEndpoint(
    _ app: XCUIApplication, name: String? = nil, endpoint value: String? = nil
  ) {
    if let name {
      let nameField = app.textFields["connection-name"]
      XCTAssertTrue(nameField.waitForExistence(timeout: 5))
      nameField.tap()
      nameField.typeText(name)
      let done = app.buttons["connection-keyboard-done"]
      XCTAssertTrue(done.waitForExistence(timeout: 5))
      done.tap()
    }
    let endpoint = app.textFields["direct-endpoint"]
    XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
    endpoint.tap()
    endpoint.typeText(value ?? "demo.paseo.local:6767")
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
