import UIKit
import XCTest

@testable import Oesap

final class LiveMarkdownStylerTests: XCTestCase {
  func testHeadingAndInlineFormattingAppearInTheEditableSource() throws {
    let source = "## Plan\n\nA **bold** and `code` note."
    let styled = LiveMarkdownStyler.attributedSource(source, activeUTF16Location: nil)
    XCTAssertEqual(styled.string, source)

    let bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize
    let headingFont = try font(at: "Plan", in: styled)
    XCTAssertGreaterThan(headingFont.pointSize, bodySize)
    XCTAssertTrue(headingFont.fontDescriptor.symbolicTraits.contains(.traitBold))

    let boldFont = try font(at: "bold", in: styled)
    XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    let codeFont = try font(at: "code", in: styled)
    XCTAssertTrue(codeFont.fontName.lowercased().contains("mono"), codeFont.fontName)

    XCTAssertLessThan(try font(at: "##", in: styled).pointSize, 2)
    XCTAssertLessThan(try font(at: "**", in: styled).pointSize, 2)
    XCTAssertLessThan(try font(at: "`", in: styled).pointSize, 2)
  }

  func testCaretBlockRevealsItsSyntaxWithoutLosingFormatting() throws {
    let source = "# Heading\n\nUse **bold** here."
    let caret = try XCTUnwrap(source.utf16Range(of: "bold"))
    let styled = LiveMarkdownStyler.attributedSource(
      source,
      activeUTF16Location: caret.location + 2)

    XCTAssertEqual(styled.string, source)
    XCTAssertLessThan(try font(at: "#", in: styled).pointSize, 2)
    XCTAssertGreaterThan(try font(at: "**", in: styled).pointSize, 2)
    XCTAssertEqual(try color(at: "**", in: styled), .secondaryLabel)
    XCTAssertTrue(
      try font(at: "bold", in: styled)
        .fontDescriptor.symbolicTraits.contains(.traitBold))
  }

  func testUTF8SourcePositionsMapToUTF16AfterEmoji() throws {
    let source = "👩🏽‍💻 **bold** and _italic_"
    let styled = LiveMarkdownStyler.attributedSource(source, activeUTF16Location: nil)

    XCTAssertEqual(styled.string, source)
    XCTAssertTrue(
      try font(at: "bold", in: styled)
        .fontDescriptor.symbolicTraits.contains(.traitBold))
    XCTAssertTrue(
      try font(at: "italic", in: styled)
        .fontDescriptor.symbolicTraits.contains(.traitItalic))
    XCTAssertLessThan(try font(at: "**", in: styled).pointSize, 2)
    XCTAssertLessThan(try font(at: "_", in: styled).pointSize, 2)
  }

  func testNestedFormattingKeepsBothTraitsAndListMarkersVisible() throws {
    let source = "- **bold _italic_**\n  - nested\n- second"
    let styled = LiveMarkdownStyler.attributedSource(source, activeUTF16Location: nil)

    XCTAssertEqual(styled.string, source)
    let italicFont = try font(at: "italic", in: styled)
    XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
    XCTAssertGreaterThan(try font(at: "-", in: styled).pointSize, 2)
    let outer = try paragraph(at: "bold", in: styled)
    let nested = try paragraph(at: "nested", in: styled)
    XCTAssertGreaterThan(nested.headIndent, outer.headIndent)
  }

  func testCodeFenceAndIncompleteMarkdownKeepSourceEditable() throws {
    let source = "```swift\nlet x = 1\n```\n\n**unfinished"
    let styled = LiveMarkdownStyler.attributedSource(source, activeUTF16Location: nil)

    XCTAssertEqual(styled.string, source)
    XCTAssertLessThan(try font(at: "```", in: styled).pointSize, 2)
    XCTAssertTrue(
      try font(at: "let x", in: styled)
        .fontName.lowercased().contains("mono"))
    XCTAssertGreaterThan(try font(at: "**unfinished", in: styled).pointSize, 2)
  }

  func testCRLFAndTabCharactersArePreserved() {
    let source = "Intro\r\n\t**bold**\r\nplain"
    let styled = LiveMarkdownStyler.attributedSource(source, activeUTF16Location: nil)
    XCTAssertEqual(styled.string, source)
    XCTAssertEqual(styled.length, (source as NSString).length)
  }

  func testNestedAndEscapedLinkLabelsStayVisible() throws {
    let source = #"[a [b] c](https://example.com/a) and [a\]b](https://example.com/b)"#
    let styled = LiveMarkdownStyler.attributedSource(source, activeUTF16Location: nil)

    XCTAssertEqual(styled.string, source)
    XCTAssertGreaterThan(try font(at: "[b] c", in: styled).pointSize, 2)
    XCTAssertGreaterThan(try font(at: #"a\]b"#, in: styled).pointSize, 2)
  }

  func testVeryLargeDraftRemainsEditableWithoutParsingDelay() throws {
    let source = String(repeating: "x", count: 100_001)
    let styled = LiveMarkdownStyler.attributedSource(source, activeUTF16Location: 50_000)
    XCTAssertEqual(styled.string, source)
    XCTAssertGreaterThan(try font(at: "x", in: styled).pointSize, 2)
  }

  func testAccessibilityHeadingUsesSemanticDynamicTypeSize() throws {
    let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
    let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
    let expectedTitle = UIFont.preferredFont(forTextStyle: .title1, compatibleWith: traits)
    let styled = LiveMarkdownStyler.attributedSource(
      "# Live heading", activeUTF16Location: nil,
      bodyFont: body, traitCollection: traits)

    XCTAssertEqual(try font(at: "Live", in: styled).pointSize, expectedTitle.pointSize)
    XCTAssertGreaterThan(expectedTitle.pointSize, body.pointSize)
  }

  private func font(at needle: String, in styled: NSAttributedString) throws -> UIFont {
    let range = try XCTUnwrap(styled.string.utf16Range(of: needle))
    return try XCTUnwrap(
      styled.attribute(
        .font, at: range.location,
        effectiveRange: nil) as? UIFont)
  }

  private func color(at needle: String, in styled: NSAttributedString) throws -> UIColor {
    let range = try XCTUnwrap(styled.string.utf16Range(of: needle))
    return try XCTUnwrap(
      styled.attribute(
        .foregroundColor, at: range.location,
        effectiveRange: nil) as? UIColor)
  }

  private func paragraph(
    at needle: String, in styled: NSAttributedString
  ) throws -> NSParagraphStyle {
    let range = try XCTUnwrap(styled.string.utf16Range(of: needle))
    return try XCTUnwrap(
      styled.attribute(
        .paragraphStyle, at: range.location,
        effectiveRange: nil) as? NSParagraphStyle)
  }
}

extension String {
  fileprivate func utf16Range(of needle: String) -> NSRange? {
    let range = (self as NSString).range(of: needle)
    return range.location == NSNotFound ? nil : range
  }
}
