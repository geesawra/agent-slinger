import Foundation
import MarkdownUI
import XCTest

@testable import Oesap

final class MessageMarkdownTests: XCTestCase {
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
