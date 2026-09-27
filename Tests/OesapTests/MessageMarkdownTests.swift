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
}
