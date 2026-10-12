import Foundation
import MarkdownUI
import XCTest

@testable import Oesap

final class MessageMarkdownTests: XCTestCase {
  func testLegacyTimelinePreservesFollowIntentAcrossRenderedGrowth() {
    let pinned = CGRect(x: 0, y: -1_000, width: 400, height: 2_000)
    let grown = CGRect(x: 0, y: -1_000, width: 400, height: 2_200)
    let following = TimelineScrollFollowPolicy.evaluate(
      previousFrame: pinned, frame: grown, viewportHeight: 1_000, wasFollowing: true)
    XCTAssertTrue(following.isNearBottom)

    let readingEarlier = TimelineScrollFollowPolicy.evaluate(
      previousFrame: CGRect(x: 0, y: -700, width: 400, height: 2_000),
      frame: CGRect(x: 0, y: -700, width: 400, height: 2_200),
      viewportHeight: 1_000, wasFollowing: false)
    XCTAssertFalse(readingEarlier.isNearBottom)
  }

  func testLegacyTimelineRespectsScrollAwayEvenWhenContentAlsoGrows() {
    let pinned = CGRect(x: 0, y: -1_000, width: 400, height: 2_000)
    let scrolledAndGrown = CGRect(x: 0, y: -700, width: 400, height: 2_200)
    let decision = TimelineScrollFollowPolicy.evaluate(
      previousFrame: pinned, frame: scrolledAndGrown, viewportHeight: 1_000, wasFollowing: true)
    XCTAssertFalse(decision.isNearBottom)

    let initial = TimelineScrollFollowPolicy.evaluate(
      previousFrame: nil, frame: pinned, viewportHeight: 1_000, wasFollowing: true)
    XCTAssertTrue(initial.isNearBottom)
  }

  func testTimelineFollowsUpdatesOnlyWhileIdleAndPinned() {
    XCTAssertTrue(
      TimelineScrollFollowPolicy.shouldFollowUpdates(
        TimelineReaderIntent(followLatest: true), hasExpandedToolCall: false),
      "The native bottom anchor should follow async Markdown, new rows, and status growth")
    XCTAssertFalse(
      TimelineScrollFollowPolicy.shouldFollowUpdates(
        TimelineReaderIntent(followLatest: false), hasExpandedToolCall: false),
      "New output and status must preserve the reader's earlier position")
    XCTAssertFalse(
      TimelineScrollFollowPolicy.shouldFollowUpdates(
        TimelineReaderIntent(followLatest: true, gestureInFlight: true),
        hasExpandedToolCall: false),
      "Incoming text must not compete with an active drag or deceleration")
    XCTAssertFalse(
      TimelineScrollFollowPolicy.shouldFollowUpdates(
        TimelineReaderIntent(followLatest: true), hasExpandedToolCall: true),
      "Expanding a tool call must not move the timeline")
  }

  func testNativeScrollGeometryPreservesGrowthButRecognizesJumpsAndDrags() {
    XCTAssertTrue(
      TimelineScrollFollowPolicy.updatedFollowIntent(
        TimelineReaderIntent(followLatest: true), contentSizeChanged: true,
        isNearBottom: false),
      "Layout may report the old offset before the bottom anchor applies")
    XCTAssertFalse(
      TimelineScrollFollowPolicy.updatedFollowIntent(
        TimelineReaderIntent(followLatest: true, gestureInFlight: true),
        contentSizeChanged: true, isNearBottom: false),
      "A drag away must win even when content grows")
    XCTAssertFalse(
      TimelineScrollFollowPolicy.updatedFollowIntent(
        TimelineReaderIntent(followLatest: true), contentSizeChanged: false,
        isNearBottom: false),
      "A scroll away without a size change must end follow mode")
    XCTAssertTrue(
      TimelineScrollFollowPolicy.updatedFollowIntent(
        TimelineReaderIntent(followLatest: false), contentSizeChanged: false,
        isNearBottom: true),
      "A programmatic jump to Latest must restore follow mode")
  }

  func testOrdinaryMarkdownSkipsImageRewriteWithoutChangingSource() {
    let source = "# Heading\n\n- **bold**\n- `code`\n\n[link](https://example.com)"
    let transformed = MarkdownImageTransformer.transform(source)
    XCTAssertEqual(transformed.markdown, source)
    XCTAssertTrue(transformed.imagesByID.isEmpty)

    let codeOnly = "`![literal](https://example.com/image.png)`"
    XCTAssertEqual(MarkdownImageTransformer.transform(codeOnly).markdown, codeOnly)
  }

  func testParsedMessagesAreReusedAndStreamingReplacesOneCacheEntry() async throws {
    let parser = MessageMarkdownContentParser(maximumEntries: 4, maximumSourceBytes: 4_096)
    let first = try await parser.parse("**first**", cacheKey: "row")
    let reused = try await parser.parse("**first**", cacheKey: "row")
    XCTAssertEqual(first.content.renderHTML(), reused.content.renderHTML())
    var parseCount = await parser.parseCount
    XCTAssertEqual(parseCount, 1, "Reappearing rows should reuse their parsed tree")

    for index in 0..<100 {
      _ = try await parser.parse("**stream snapshot \(index)**", cacheKey: "row")
    }
    let entryCount = await parser.cachedEntryCount
    let byteCount = await parser.cachedSourceBytes
    parseCount = await parser.parseCount
    XCTAssertEqual(entryCount, 1, "Old token snapshots must not accumulate in the cache")
    XCTAssertEqual(byteCount, "**stream snapshot 99**".utf8.count)
    XCTAssertEqual(parseCount, 101)
  }

  func testMarkdownCacheEvictsLeastRecentAndHonorsByteBudget() async throws {
    let parser = MessageMarkdownContentParser(maximumEntries: 2, maximumSourceBytes: 10)
    _ = try await parser.parse("first", cacheKey: "A")
    _ = try await parser.parse("next", cacheKey: "B")
    _ = try await parser.parse("first", cacheKey: "A")
    _ = try await parser.parse("third", cacheKey: "C")
    _ = try await parser.parse("first", cacheKey: "A")
    var count = await parser.parseCount
    XCTAssertEqual(count, 3, "Reading A should keep it ahead of B for eviction")
    _ = try await parser.parse("next", cacheKey: "B")
    count = await parser.parseCount
    XCTAssertEqual(count, 4, "The least recently read row should have been evicted")
    let bytes = await parser.cachedSourceBytes
    let entries = await parser.cachedEntryCount
    XCTAssertLessThanOrEqual(bytes, 10)
    XCTAssertLessThanOrEqual(entries, 2)

    _ = try await parser.parse(String(repeating: "large ", count: 100), cacheKey: "large")
    let afterLargeBytes = await parser.cachedSourceBytes
    XCTAssertEqual(afterLargeBytes, bytes, "Oversized content renders without entering the cache")
  }

  @MainActor
  func testContinuousSourceUpdatesPublishBeforeStreamFinishes() async throws {
    let parser = MessageMarkdownContentParser()
    let renderer = MessageMarkdownRenderer(source: "# Initial") { source, key in
      // Deliberately slower than the 1ms incoming update interval.
      try await Task.sleep(for: .milliseconds(40))
      return try await parser.parse(source, cacheKey: key)
    }
    let worker = Task { await renderer.run(cacheKey: "stream") }
    defer { worker.cancel() }
    var producerFinished = false
    let producer = Task {
      for index in 0..<300 {
        renderer.update(source: "# Snapshot \(index)\n\n**Streaming** content")
        try await Task.sleep(for: .milliseconds(1))
      }
      producerFinished = true
    }
    for _ in 0..<100 where renderer.result == nil && !producerFinished {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNotNil(renderer.result)
    XCTAssertFalse(producerFinished, "A sustained stream must render before its final token")
    try await producer.value
    for _ in 0..<100 where renderer.renderedSource != "# Snapshot 299\n\n**Streaming** content" {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(renderer.renderedSource, "# Snapshot 299\n\n**Streaming** content")
    let count = await parser.parseCount
    XCTAssertLessThan(count, 20, "Superseded source snapshots must be coalesced")
    worker.cancel()
    await worker.value
  }

  @MainActor
  func testDisappearingMessageCancelsPendingParseWithoutPublishing() async throws {
    let parser = MessageMarkdownContentParser()
    let started = expectation(description: "Parser started")
    let renderer = MessageMarkdownRenderer(source: "cancelled") { source, key in
      started.fulfill()
      try await Task.sleep(for: .seconds(10))
      return try await parser.parse(source, cacheKey: key)
    }
    let worker = Task { await renderer.run(cacheKey: "row") }
    await fulfillment(of: [started], timeout: 1)
    worker.cancel()
    await worker.value
    XCTAssertNil(renderer.result)
    let count = await parser.parseCount
    XCTAssertEqual(count, 0)
  }

  func testMarkdownUIParsesHeadingsListsCodeEmphasisAndLinks() {
    let source = """
      # Build the chat

      Keep the timeline **readable** and review the [project notes](https://example.com/notes).

      - Show live status
      - Keep the draft

      Run `xcodebuild -scheme Oesap build` to compile the app.
      """

    let content = MarkdownContent(source)
    let html = content.renderHTML()

    XCTAssertTrue(html.contains("<h1>Build the chat</h1>"))
    XCTAssertTrue(html.contains("<strong>readable</strong>"))
    XCTAssertTrue(html.contains("<ul>"))
    XCTAssertTrue(html.contains("<code>xcodebuild -scheme Oesap build</code>"))
    XCTAssertTrue(html.contains("href=\"https://example.com/notes\""))
  }

  func testImageTransformerTurnsMixedInlineImagesIntoTappableImageBlocks() throws {
    let source = "Before **bold** ![chart](https://images.example/chart.png) after."

    let transformed = MarkdownImageTransformer.transform(source)
    let rendered = MarkdownContent(transformed.markdown).renderHTML()

    XCTAssertEqual(transformed.imagesByID.count, 1)
    XCTAssertEqual(transformed.imagesByID["image-0"]?.source, "https://images.example/chart.png")
    XCTAssertTrue(rendered.contains("<strong>bold</strong>"))
    XCTAssertTrue(rendered.contains("<img src=\"oesap-image://image-0\" alt=\"chart\""))
    let before = try XCTUnwrap(rendered.range(of: "Before")).lowerBound
    let image = try XCTUnwrap(rendered.range(of: "<img")).lowerBound
    let after = try XCTUnwrap(rendered.range(of: "after.")).lowerBound
    XCTAssertLessThan(before, image)
    XCTAssertLessThan(image, after)
  }

  func testImageTransformerPreservesSurroundingLinkSegmentsAndIgnoresCodeImages() throws {
    let source = """
      [Read ![diagram](https://images.example/diagram.png) carefully](https://docs.example/guide)

      `![not an image](javascript:alert(1))`
      """

    let transformed = MarkdownImageTransformer.transform(source)
    let rendered = MarkdownContent(transformed.markdown).renderHTML()

    XCTAssertEqual(transformed.imagesByID.count, 1)
    XCTAssertFalse(transformed.markdown.contains("[]("), transformed.markdown)
    let preservedLinkCount =
      rendered.components(separatedBy: "href=\"https://docs.example/guide\"").count - 1
    XCTAssertEqual(preservedLinkCount, 2, rendered)
    let read = try XCTUnwrap(rendered.range(of: "Read"), transformed.markdown).lowerBound
    let image = try XCTUnwrap(rendered.range(of: "<img"), transformed.markdown).lowerBound
    let carefully = try XCTUnwrap(rendered.range(of: "carefully"), transformed.markdown).lowerBound
    XCTAssertLessThan(read, image)
    XCTAssertLessThan(image, carefully)
    XCTAssertTrue(rendered.contains("<code>![not an image](javascript:alert(1))</code>"))
    XCTAssertTrue(rendered.contains("oesap-image://image-0"))
  }

  func testHeadingAndTableImagesKeepGFMBlocksAndViewerActions() {
    let source = """
      # Plan ![diagram](https://images.example/heading.png) today

      | Step |
      | --- |
      | Read ![chart](https://images.example/table.png) carefully |
      """

    let transformed = MarkdownImageTransformer.transform(source)
    let rendered = MarkdownContent(transformed.markdown).renderHTML()

    XCTAssertEqual(transformed.imagesByID.count, 2)
    XCTAssertTrue(rendered.contains("<h1>"), rendered)
    XCTAssertTrue(rendered.contains("<table>"), rendered)
    XCTAssertTrue(rendered.contains("Plan"), rendered)
    XCTAssertTrue(rendered.contains("today"), rendered)
    XCTAssertTrue(rendered.contains("Read"), rendered)
    XCTAssertTrue(rendered.contains("carefully"), rendered)
    XCTAssertTrue(rendered.contains("oesap-image://image-0"), rendered)
    XCTAssertTrue(rendered.contains("oesap-image://image-1"), rendered)
    XCTAssertEqual(transformed.markdown.components(separatedBy: "View image:").count - 1, 2)
  }

  func testMarkdownLinksAllowOnlyAbsoluteHTTPAndHTTPSURLsWithoutCredentials() throws {
    let secure = try XCTUnwrap(URL(string: "https://example.com/path?q=one#top"))
    let web = try XCTUnwrap(URL(string: "http://example.com/path"))

    XCTAssertEqual(MarkdownLinkPolicy.validatedURL(secure), secure)
    XCTAssertEqual(MarkdownLinkPolicy.validatedURL(web), web)
  }

  func testMarkdownLinksRejectExecutableLocalAndAmbiguousDestinations() throws {
    let rejectedURLs = [
      "javascript:alert(1)",
      "data:text/html,<script>alert(1)</script>",
      "file:///etc/passwd",
      "mailto:agent@example.com",
      "custom://run/action",
      "relative/path",
      "https://user:password@example.com/path",
      "https://example.com:70000/path",
    ]

    for rawURL in rejectedURLs {
      let url = try XCTUnwrap(URL(string: rawURL), "Expected URL fixture to parse: \(rawURL)")
      XCTAssertNil(MarkdownLinkPolicy.validatedURL(url), "Unexpectedly accepted \(rawURL)")
    }
  }

  func testReceivedImageSourcePolicyAcceptsOnlyBoundedImageDataAndCredentialFreeHTTP() throws {
    guard case .data(let bytes) = try ImageSourcePolicy.classify("data:image/png;base64,aGVsbG8=")
    else {
      return XCTFail("Expected the data URL to be accepted")
    }
    XCTAssertEqual(bytes, Data("hello".utf8))

    guard case .http(let url) = try ImageSourcePolicy.classify("https://images.example/picture.png")
    else {
      return XCTFail("Expected HTTPS image source")
    }
    XCTAssertEqual(url.host, "images.example")

    for source in [
      "javascript:alert(1)",
      "blob:https://example.com/id",
      "data:text/html;base64,PHNjcmlwdD4=",
      "https://user:password@images.example/a.png",
      "https://images.example:70000/a.png",
      "file://other-host/workspace/image.png",
    ] {
      XCTAssertThrowsError(
        try ImageSourcePolicy.classify(source), "Unexpectedly accepted \(source)")
    }

    guard case .hostFile = try ImageSourcePolicy.classify("file:///workspace/image.png") else {
      return XCTFail("A local file URL should be delegated to the scoped host reader")
    }
  }

  func testReceivedImageRedirectsRejectDowngradesCredentialsAndCustomSchemes() throws {
    let secure = try XCTUnwrap(URL(string: "https://images.example/start.png"))
    let secureTarget = try XCTUnwrap(URL(string: "https://cdn.example/image.png"))
    let downgraded = try XCTUnwrap(URL(string: "http://cdn.example/image.png"))
    let credentialTarget = try XCTUnwrap(URL(string: "https://user:secret@cdn.example/image.png"))
    let localFile = try XCTUnwrap(URL(string: "file:///tmp/image.png"))

    XCTAssertTrue(ImageSourcePolicy.allowsRedirect(from: secure, to: secureTarget))
    XCTAssertFalse(ImageSourcePolicy.allowsRedirect(from: secure, to: downgraded))
    XCTAssertFalse(ImageSourcePolicy.allowsRedirect(from: secure, to: credentialTarget))
    XCTAssertFalse(ImageSourcePolicy.allowsRedirect(from: secure, to: localFile))
  }

  func testImageActionURLsAreOpaqueAndCannotOpenExecutableSchemes() throws {
    let valid = try XCTUnwrap(URL(string: "oesap-image://image-3"))
    XCTAssertEqual(MarkdownImageActionPolicy.imageID(valid), "image-3")

    for value in [
      "javascript://image-3",
      "oesap-image://image-3/path",
      "oesap-image://user@image-3",
      "oesap-image://image-nope",
    ] {
      XCTAssertNil(MarkdownImageActionPolicy.imageID(try XCTUnwrap(URL(string: value))))
    }
  }
}
