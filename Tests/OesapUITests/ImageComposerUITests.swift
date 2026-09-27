import UIKit
import UniformTypeIdentifiers
import XCTest

final class ImageComposerUITests: XCTestCase {
  func testPastedImageCanBeRemovedFromDraft() {
    let app = launchDemo(arguments: ["--demo-images"])
    openRunningThread(in: app)

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    pasteSanitizedImage(into: composer, app: app)

    let strip = app.descendants(matching: .any)["composer-attachment-strip"]
    XCTAssertTrue(strip.waitForExistence(timeout: 10))
    let surface = composerSurface("chat-composer-surface", in: app)
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    let thumbnail = surface.descendants(matching: .any)["composer-image-0"].firstMatch
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Remove image"].isHittable)
    let send = surface.descendants(matching: .button)["send-message"].firstMatch
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    assertContained(thumbnail, in: surface, named: "Image thumbnail")
    assertContained(send, in: surface, named: "Send button")
    assertMinimumSendTarget(send)
    attachScreenshot(named: "Pasted image in chat composer", app: app)

    surface.buttons["Preview selected image"].tap()
    let closeViewer = app.buttons["Close image"]
    XCTAssertTrue(closeViewer.waitForExistence(timeout: 5))
    closeViewer.tap()
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
    app.buttons["Remove image"].tap()
    XCTAssertFalse(strip.waitForExistence(timeout: 2))
    XCTAssertFalse(app.buttons["send-message"].isEnabled)
  }

  func testPastedImageAndTextStayInDraftAfterUncertainSend() {
    let app = launchDemo(arguments: ["--demo-send-failure"])
    openRunningThread(in: app)

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    pasteSanitizedImage(into: composer, app: app)
    XCTAssertTrue(app.descendants(matching: .any)["composer-image-0"].waitForExistence(timeout: 10))

    typeMessageAfterPasting(
      remainingText: "eep this image with the uncertain message", into: composer, app: app)
    let surface = composerSurface("chat-composer-surface", in: app)
    let thumbnail = surface.descendants(matching: .any)["composer-image-0"].firstMatch
    let send = surface.descendants(matching: .button)["send-message"].firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    XCTAssertTrue(thumbnail.exists)
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isHittable)
    assertContained(thumbnail, in: surface, named: "Image thumbnail")
    assertContained(send, in: surface, named: "Send button")
    assertMinimumSendTarget(send)
    XCTAssertFalse(composer.frame.intersects(send.frame), "The editor must not overlap Send.")
    attachScreenshot(named: "Compact composer with image and text", app: app)

    send.tap()
    chooseRunningSendAction(app, "Steer when supported")

    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Delivery couldn’t be confirmed")
      ).firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(composer.value as? String, "Keep this image with the uncertain message")
    XCTAssertTrue(app.descendants(matching: .any)["composer-image-0"].exists)
    attachScreenshot(named: "Uncertain send keeps image draft", app: app)
  }

  func testExpandedComposerSharesPastedImageDraft() {
    let app = launchDemo(arguments: ["--demo-images"])
    openRunningThread(in: app)

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    pasteSanitizedImage(into: composer, app: app)
    XCTAssertTrue(app.descendants(matching: .any)["composer-image-0"].waitForExistence(timeout: 10))
    typeMessageAfterPasting(
      remainingText: "eep this source in the expanded editor", into: composer, app: app)
    app.buttons["chat-composer-expand"].tap()

    let editor = app.textViews["expanded-chat-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Preview selected image"].waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "Keep this source in the expanded editor")
    pasteSanitizedImage(into: editor, app: app)
    let expandedSurface = composerSurface("expanded-composer-surface", in: app)
    XCTAssertTrue(expandedSurface.waitForExistence(timeout: 5))
    let thumbnail = expandedSurface.descendants(matching: .any)["composer-image-1"].firstMatch
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
    let send = expandedSurface.descendants(matching: .button)["expanded-send-message"].firstMatch
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isHittable)
    assertContained(thumbnail, in: expandedSurface, named: "Expanded image thumbnail")
    assertContained(send, in: expandedSurface, named: "Expanded Send button")
    assertMinimumSendTarget(send)
    XCTAssertFalse(editor.frame.intersects(send.frame), "The editor must not overlap Send.")
    attachScreenshot(named: "Expanded composer with shared image draft", app: app)

    app.buttons["expanded-composer-done"].tap()
    XCTAssertEqual(composer.value as? String, "Keep this source in the expanded editor")
    XCTAssertTrue(app.descendants(matching: .any)["composer-image-0"].exists)
  }

  func testNewThreadCanStartWithAnImageOnlyDraft() {
    let app = launchDemo(arguments: ["--demo-images"])
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["new-thread-button"].tap()

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    pasteSanitizedImage(into: composer, app: app)
    XCTAssertTrue(app.descendants(matching: .any)["composer-image-0"].waitForExistence(timeout: 10))
    app.buttons["new-thread-setup-agent"].tap()
    XCTAssertTrue(app.navigationBars["Project Agent"].waitForExistence(timeout: 5))
    let saveAgent = app.buttons["save-agent-configuration"]
    XCTAssertTrue(saveAgent.waitForExistence(timeout: 5))
    XCTAssertTrue(saveAgent.isEnabled)
    saveAgent.tap()
    XCTAssertTrue(app.navigationBars["New thread"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["composer-image-0"].exists)
    let send = app.buttons["send-message"]
    XCTAssertTrue(send.isEnabled, "An image-only first message should be sendable.")
    attachScreenshot(named: "Image-only new thread draft", app: app)
    send.tap()

    XCTAssertTrue(app.navigationBars["Image request"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.descendants(matching: .any)["message-demo-created-1-prompt"].waitForExistence(timeout: 10)
    )
    XCTAssertTrue(app.descendants(matching: .any)["message-image-demo-created-1-prompt-0"].exists)
  }

  func testPhotosPickerAddsSeededImageToDraft() {
    let app = launchDemo(arguments: ["--demo-images"])
    openRunningThread(in: app)

    app.buttons["attach-image"].tap()
    app.buttons["Choose from Photos"].tap()
    attachScreenshot(named: "Photos picker after opening", app: app)
    let pickerHierarchy = XCTAttachment(string: app.debugDescription)
    pickerHierarchy.name = "Photos picker accessibility tree"
    pickerHierarchy.lifetime = .keepAlways
    add(pickerHierarchy)
    let photo = app.scrollViews["photosView_content_scroll_view"]
      .images["PXGGridLayout-Info"].firstMatch
    guard photo.waitForExistence(timeout: 30) else {
      XCTFail("Photos picker did not expose a photo asset.\n\(app.debugDescription)")
      return
    }
    XCTAssertTrue(photo.label.hasPrefix("Photo,"), app.debugDescription)
    photo.tap()
    let done = app.navigationBars["Photos"].buttons["Done"]
    let doneEnabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: done)
    guard done.waitForExistence(timeout: 5),
      XCTWaiter.wait(for: [doneEnabled], timeout: 5) == .completed
    else {
      XCTFail("Photos picker did not select the seeded asset.\n\(app.debugDescription)")
      return
    }
    done.tap()

    let thumbnail = app.descendants(matching: .any)["composer-image-0"]
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
    attachScreenshot(named: "PhotosPicker image draft", app: app)
  }

  func testReceivedAgentImageOpensAndClosesViewer() {
    let app = launchDemo(arguments: ["--demo-images"])
    openRunningThread(in: app)

    let preview = app.buttons["Synthetic image"]
    guard scrollTimelineUntilHittable(preview, in: app) else {
      XCTFail("Received image did not become hittable after scrolling.\n\(app.debugDescription)")
      return
    }
    attachScreenshot(named: "Received agent image thumbnail", app: app)
    preview.tap()
    XCTAssertTrue(app.buttons["Close image"].waitForExistence(timeout: 5))
    attachScreenshot(named: "Received agent image viewer", app: app)
    app.buttons["Close image"].tap()
    XCTAssertTrue(preview.waitForExistence(timeout: 5))
  }

  func testAX5ComposerKeepsPastedImageAndSendVisible() {
    let app = launchDemo(accessibilitySize: true, arguments: ["--demo-images"])
    openRunningThread(in: app)

    let composer = app.descendants(matching: .any)["chat-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    pasteSanitizedImage(into: composer, app: app)
    let compactSurface = composerSurface("chat-composer-surface", in: app)
    XCTAssertTrue(compactSurface.waitForExistence(timeout: 5))
    let thumbnail = compactSurface.descendants(matching: .any)["composer-image-0"].firstMatch
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
    let context = app.buttons["context-usage-button"]
    let accessory = app.descendants(matching: .any)["chat-composer-accessory"]
    let send = compactSurface.descendants(matching: .button)["send-message"].firstMatch
    typeMessageAfterPasting(
      remainingText: "eep this image visible at AX5", into: composer, app: app)
    XCTAssertEqual(composer.value as? String, "Keep this image visible at AX5")
    XCTAssertTrue(context.isHittable)
    XCTAssertTrue(accessory.exists)
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isHittable)
    XCTAssertTrue(thumbnail.isHittable)
    assertInsideAppBounds(context, app: app)
    assertInsideAppBounds(send, app: app)
    assertInsideAppBounds(thumbnail, app: app)
    assertContained(thumbnail, in: compactSurface, named: "AX5 image thumbnail")
    assertContained(send, in: compactSurface, named: "AX5 Send button")
    assertMinimumSendTarget(send)
    XCTAssertLessThanOrEqual(context.frame.maxY, compactSurface.frame.minY)
    XCTAssertLessThanOrEqual(accessory.frame.maxY, compactSurface.frame.minY)
    XCTAssertFalse(composer.frame.intersects(send.frame), "The editor must not overlap Send.")
    attachScreenshot(named: "AX5 compact composer with image and text", app: app)

    app.buttons["chat-composer-expand"].tap()
    let expandedSurface = composerSurface("expanded-composer-surface", in: app)
    XCTAssertTrue(expandedSurface.waitForExistence(timeout: 5))
    let expandedThumbnail = expandedSurface.descendants(matching: .any)["composer-image-0"]
      .firstMatch
    let expandedSend = expandedSurface.descendants(matching: .button)["expanded-send-message"]
      .firstMatch
    let expandedEditor = app.textViews["expanded-chat-composer"]
    XCTAssertTrue(expandedEditor.waitForExistence(timeout: 5))
    XCTAssertTrue(expandedThumbnail.waitForExistence(timeout: 5))
    XCTAssertTrue(expandedSend.waitForExistence(timeout: 5))
    XCTAssertTrue(expandedThumbnail.isHittable)
    XCTAssertTrue(expandedSend.isHittable)
    assertInsideAppBounds(expandedThumbnail, app: app)
    assertInsideAppBounds(expandedSend, app: app)
    assertContained(expandedThumbnail, in: expandedSurface, named: "AX5 expanded image thumbnail")
    assertContained(expandedSend, in: expandedSurface, named: "AX5 expanded Send button")
    assertMinimumSendTarget(expandedSend)
    XCTAssertFalse(
      expandedEditor.frame.intersects(expandedSend.frame),
      "The expanded editor must not overlap Send."
    )
    attachScreenshot(named: "AX5 expanded composer with image and text", app: app)
  }

  private func launchDemo(accessibilitySize: Bool = false, arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      arguments + [
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US",
        "--demo-server-id=ui-image-composer-\(UUID().uuidString.lowercased())",
      ]
    if accessibilitySize {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
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

  private func openRunningThread(in app: XCUIApplication) {
    connect(app)
    app.buttons["project-demo-project"].tap()
    app.buttons["thread-demo-agent-running"].tap()
    XCTAssertTrue(app.buttons["context-usage-button"].waitForExistence(timeout: 5))
  }

  private func pasteSanitizedImage(into composer: XCUIElement, app: XCUIApplication) {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let png = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48), format: format)
      .pngData { context in
        UIColor.systemIndigo.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
      }
    UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
    addTeardownBlock { UIPasteboard.general.items = [] }

    composer.tap()
    composer.press(forDuration: 1.0)
    let menuPaste = app.menuItems["Paste"]
    let buttonPaste = app.buttons["Paste"]
    let recentPaste = app.buttons["RecentPaste"]
    let paste: XCUIElement
    if menuPaste.waitForExistence(timeout: 2) {
      paste = menuPaste
    } else if buttonPaste.waitForExistence(timeout: 2) {
      paste = buttonPaste
    } else {
      paste = recentPaste
    }
    guard paste.waitForExistence(timeout: 5) else {
      XCTFail("UIKit should offer the standard Paste action.\n\(app.debugDescription)")
      return
    }
    if paste.identifier == "RecentPaste", paste.frame.minY <= 0 {
      // iOS exposes the native paste suggestion at a zero-origin AX frame.
      // Tap its visible strip immediately above the keyboard instead.
      let keyboard = app.keyboards.firstMatch
      guard keyboard.exists else {
        XCTFail("Native paste suggestion had no keyboard.\n\(app.debugDescription)")
        return
      }
      let stripCenterY = keyboard.frame.minY - 22
      app.coordinate(
        withNormalizedOffset: CGVector(
          dx: 0.5, dy: stripCenterY / app.frame.height)
      ).tap()
    } else {
      paste.tap()
    }
  }

  private func typeMessageAfterPasting(
    remainingText: String, into composer: XCUIElement, app: XCUIApplication
  ) {
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    let firstKey = keyboard.keys["K"]
    guard firstKey.waitForExistence(timeout: 5) else {
      XCTFail("The native keyboard did not expose its K key.\n\(app.debugDescription)")
      return
    }
    firstKey.tap()
    XCTAssertEqual(composer.value as? String, "K", "The first key must reach the editor.")
    composer.typeText(remainingText)
  }

  private func scrollTimelineUntilHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool
  {
    let timeline = app.scrollViews["chat-timeline-scroll"]
    guard timeline.waitForExistence(timeout: 5) else { return false }
    let accessory = app.descendants(matching: .any)["chat-composer-accessory"]
    let navigationBar = app.navigationBars.firstMatch

    for _ in 0..<12 {
      let frame = timeline.frame
      let top = max(frame.minY + 8, navigationBar.frame.maxY + 8)
      let bottom = min(frame.maxY - 8, accessory.frame.minY - 8)
      let height = bottom - top
      guard frame.height > 0, height > 40 else { return false }
      if element.exists && element.isHittable,
        element.frame.minY >= top, element.frame.maxY <= bottom
      {
        return true
      }
      let start = timeline.coordinate(
        withNormalizedOffset: CGVector(
          dx: 0.5, dy: (top + height * 0.72 - frame.minY) / frame.height))
      let end = timeline.coordinate(
        withNormalizedOffset: CGVector(
          dx: 0.5, dy: (top + height * 0.57 - frame.minY) / frame.height))
      start.press(forDuration: 0.04, thenDragTo: end)
    }
    let top = max(timeline.frame.minY + 8, navigationBar.frame.maxY + 8)
    let bottom = min(timeline.frame.maxY - 8, accessory.frame.minY - 8)
    return element.exists && element.isHittable
      && element.frame.minY >= top && element.frame.maxY <= bottom
  }

  private func chooseRunningSendAction(_ app: XCUIApplication, _ title: String) {
    XCTAssertTrue(app.navigationBars["Send to running agent?"].waitForExistence(timeout: 5))
    let action = app.buttons[
      title == "Steer when supported" ? "agent-send-steer" : "agent-send-interrupt"]
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    action.tap()
  }

  private func scrollUntilHittable(
    _ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 10
  ) -> Bool {
    for _ in 0..<maxSwipes {
      if element.exists && element.isHittable { return true }
      app.swipeUp()
    }
    return element.exists && element.isHittable
  }

  private func assertInsideAppBounds(_ element: XCUIElement, app: XCUIApplication) {
    let bounds = app.frame
    XCTAssertGreaterThanOrEqual(element.frame.minX, bounds.minX)
    XCTAssertGreaterThanOrEqual(element.frame.minY, bounds.minY)
    XCTAssertLessThanOrEqual(element.frame.maxX, bounds.maxX)
    XCTAssertLessThanOrEqual(element.frame.maxY, bounds.maxY)
  }

  private func attachScreenshot(named name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func composerSurface(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func assertContained(
    _ element: XCUIElement, in surface: XCUIElement, named name: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      element.exists, "\(name) should be exposed inside its composer surface.",
      file: file, line: line
    )
    let matchingDescendant = surface.descendants(matching: .any)
      .matching(identifier: element.identifier).firstMatch
    XCTAssertTrue(
      matchingDescendant.exists,
      "\(name) should be an accessibility descendant of its composer surface.",
      file: file, line: line
    )
    let elementFrameDescription = "\(name) AX frame \(element.frame)"
    let surfaceFrameDescription = "composer surface AX frame \(surface.frame)"
    XCTAssertTrue(
      surface.frame.insetBy(dx: -1, dy: -1).contains(element.frame),
      "\(elementFrameDescription) should be inside \(surfaceFrameDescription).",
      file: file, line: line
    )
  }

  private func assertMinimumSendTarget(
    _ send: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertGreaterThanOrEqual(
      send.frame.width, 44, "Send should be at least 44 points wide.", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      send.frame.height, 44, "Send should be at least 44 points tall.", file: file, line: line)
  }
}
