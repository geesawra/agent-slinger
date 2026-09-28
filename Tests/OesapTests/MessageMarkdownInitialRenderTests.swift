import Foundation
import MarkdownUI
import XCTest

@testable import Oesap

final class MessageMarkdownInitialRenderTests: XCTestCase {
  @MainActor
  func testInitialTreeIsReusedBeforeStreamingUpdates() async throws {
    let parser = MessageMarkdownContentParser()
    let initial = MessageMarkdownContentResult(source: "# Heading\n\n**Formatted** text")
    let renderer = MessageMarkdownRenderer(source: "# Heading\n\n**Formatted** text") {
      source, key in
      try await parser.parse(source, cacheKey: key)
    }
    let worker = Task {
      await renderer.run(
        cacheKey: "message", initialResult: initial,
        initialSource: "# Heading\n\n**Formatted** text")
    }
    defer { worker.cancel() }

    for _ in 0..<20 where renderer.result == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNotNil(renderer.result)
    XCTAssertEqual(renderer.result?.content.renderHTML(), initial.content.renderHTML())
    let initialParseCount = await parser.parseCount
    XCTAssertEqual(initialParseCount, 0, "The first visible tree is already parsed")

    renderer.update(source: "# Heading\n\n**Formatted** update")
    for _ in 0..<100 where renderer.renderedSource != "# Heading\n\n**Formatted** update" {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(renderer.renderedSource, "# Heading\n\n**Formatted** update")
    let updatedParseCount = await parser.parseCount
    XCTAssertEqual(updatedParseCount, 1)
  }
}
