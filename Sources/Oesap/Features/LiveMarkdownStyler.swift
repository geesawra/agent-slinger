import Foundation
import UIKit
import cmark_gfm
import cmark_gfm_extensions

/// Styles Markdown in place. The attributed string contains the exact source,
/// including syntax characters, so UITextView keeps native editing, selection,
/// undo, dictation, and paste behavior.
enum LiveMarkdownStyler {
  private static let maximumStyledLength = 100_000

  struct Plan: Sendable {
    let source: String
    fileprivate let cells: [Style]
    fileprivate let syntaxRanges: [NSRange]
    fileprivate let blockRanges: [NSRange]

    func activeBlock(at caret: Int?) -> NSRange? {
      guard let caret else { return nil }
      return LiveMarkdownStyler.activeBlockRange(in: self, caret: caret)
    }

    func attributedSource(
      activeUTF16Location: Int?,
      bodyFont: UIFont = .preferredFont(forTextStyle: .body),
      traitCollection: UITraitCollection? = nil,
      textColor: UIColor = .label
    ) -> NSAttributedString {
      LiveMarkdownStyler.render(
        self, activeUTF16Location: activeUTF16Location,
        bodyFont: bodyFont, traitCollection: traitCollection,
        textColor: textColor)
    }
  }

  static func attributedSource(
    _ source: String,
    activeUTF16Location: Int?,
    bodyFont: UIFont = .preferredFont(forTextStyle: .body),
    traitCollection: UITraitCollection? = nil,
    textColor: UIColor = .label
  ) -> NSAttributedString {
    plan(for: source).attributedSource(
      activeUTF16Location: activeUTF16Location,
      bodyFont: bodyFont, traitCollection: traitCollection,
      textColor: textColor)
  }

  static func plan(for source: String) -> Plan {
    let sourceText = source as NSString
    let length = sourceText.length
    guard length > 0, length <= maximumStyledLength, !Task.isCancelled else {
      return Plan(source: source, cells: [], syntaxRanges: [], blockRanges: [])
    }
    var cells = Array(repeating: Style(), count: length)

    cmark_gfm_core_extensions_ensure_registered()
    guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else {
      return Plan(source: source, cells: [], syntaxRanges: [], blockRanges: [])
    }
    defer { cmark_parser_free(parser) }
    for name in ["autolink", "strikethrough", "tasklist", "table"] {
      guard let syntax = name.withCString({ cmark_find_syntax_extension($0) }) else { continue }
      _ = cmark_parser_attach_syntax_extension(parser, syntax)
    }
    source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
    guard let document = cmark_parser_finish(parser) else {
      return Plan(source: source, cells: [], syntaxRanges: [], blockRanges: [])
    }
    defer { cmark_node_free(document) }
    guard !Task.isCancelled else {
      return Plan(source: source, cells: [], syntaxRanges: [], blockRanges: [])
    }

    let index = SourceIndex(source)
    var syntaxRanges: [NSRange] = []
    var blockRanges: [NSRange] = []
    walk(
      document, source: sourceText, index: index, cells: &cells,
      syntaxRanges: &syntaxRanges, blockRanges: &blockRanges)
    return Plan(
      source: source, cells: cells, syntaxRanges: syntaxRanges,
      blockRanges: blockRanges)
  }

  fileprivate enum Ink: Equatable, Sendable {
    case primary
    case secondary
    case link
    case hidden
  }

  fileprivate struct Style: Equatable, Sendable {
    var headingLevel: Int?
    var bold = false
    var italic = false
    var monospaced = false
    var strike = false
    var codeBackground = false
    var ink: Ink = .primary
    var indent = 0.0
    var paragraphSpacing = 0.0
    var hidden = false
  }

  /// cmark source columns count UTF-8 bytes; UITextView selection ranges use UTF-16.
  private struct SourceIndex {
    let byteToUTF16: [Int]
    let lineStarts: [Int]
    let lineEnds: [Int]
    let utf16Length: Int

    init(_ source: String) {
      let bytes = Array(source.utf8)
      var mapping = Array(repeating: 0, count: bytes.count + 1)
      var byteOffset = 0
      var utf16Offset = 0
      for scalar in source.unicodeScalars {
        for step in 0..<scalar.utf8.count {
          mapping[byteOffset + step] = utf16Offset
        }
        byteOffset += scalar.utf8.count
        utf16Offset += scalar.value > 0xFFFF ? 2 : 1
      }
      mapping[bytes.count] = utf16Offset
      byteToUTF16 = mapping
      utf16Length = utf16Offset

      var starts = [0]
      var ends: [Int] = []
      for (offset, byte) in bytes.enumerated() where byte == 10 {
        ends.append(offset)
        starts.append(offset + 1)
      }
      ends.append(bytes.count)
      lineStarts = starts
      lineEnds = ends
    }

    func range(of node: UnsafeMutablePointer<cmark_node>) -> NSRange? {
      let firstLine = Int(cmark_node_get_start_line(node)) - 1
      let lastLine = Int(cmark_node_get_end_line(node)) - 1
      guard firstLine >= 0, lastLine >= firstLine,
        firstLine < lineStarts.count, lastLine < lineStarts.count
      else { return nil }
      let firstColumn = Int(cmark_node_get_start_column(node))
      let lastColumn = Int(cmark_node_get_end_column(node))
      guard firstColumn > 0, lastColumn > 0 else { return nil }
      let startByte = lineStarts[firstLine] + firstColumn - 1
      let endByte = lineStarts[lastLine] + lastColumn
      guard startByte >= lineStarts[firstLine],
        startByte <= lineEnds[firstLine],
        endByte >= lineStarts[lastLine], endByte <= lineEnds[lastLine],
        endByte <= byteToUTF16.count - 1
      else { return nil }
      let start = byteToUTF16[startByte]
      let end = byteToUTF16[endByte]
      guard end > start, end <= utf16Length else { return nil }
      return NSRange(location: start, length: end - start)
    }
  }

  private static func activeBlockRange(in plan: Plan, caret: Int) -> NSRange? {
    plan.blockRanges
      .filter { caret >= $0.location && caret <= NSMaxRange($0) }
      .min { $0.length < $1.length }
  }

  private static func walk(
    _ document: UnsafeMutablePointer<cmark_node>, source: NSString,
    index: SourceIndex, cells: inout [Style], syntaxRanges: inout [NSRange],
    blockRanges: inout [NSRange]
  ) {
    visit(document) { node in
      guard let kind = type(of: node), let range = index.range(of: node) else { return }
      if ["paragraph", "heading", "code_block", "html_block", "table_cell"].contains(kind) {
        blockRanges.append(range)
      }
      switch kind {
      case "heading":
        let level = max(1, min(6, Int(cmark_node_get_heading_level(node))))
        modify(range, cells: &cells) {
          $0.headingLevel = level
          $0.bold = true
          $0.paragraphSpacing = 5
        }
        if let prefix = leadingATXMarker(in: range, source: source) {
          syntaxRanges.append(prefix)
        }
        if let underline = setextUnderline(in: range, source: source) {
          syntaxRanges.append(underline)
        }
      case "strong":
        modify(range, cells: &cells) { $0.bold = true }
        markPairedSyntax(
          in: range, source: source, marks: ["**", "__"],
          syntaxRanges: &syntaxRanges)
      case "emph":
        modify(range, cells: &cells) { $0.italic = true }
        markPairedSyntax(
          in: range, source: source, marks: ["*", "_"],
          syntaxRanges: &syntaxRanges)
      case "strikethrough":
        modify(range, cells: &cells) { $0.strike = true }
        markPairedSyntax(
          in: range, source: source, marks: ["~~"],
          syntaxRanges: &syntaxRanges)
      case "code":
        modify(range, cells: &cells) {
          $0.monospaced = true
          $0.codeBackground = true
        }
        markCodeTicks(in: node, range: range, source: source, syntaxRanges: &syntaxRanges)
      case "code_block":
        modify(range, cells: &cells) {
          $0.monospaced = true
          $0.codeBackground = true
          $0.indent = max($0.indent, 10)
          $0.paragraphSpacing = 4
        }
        markCodeFences(in: range, source: source, syntaxRanges: &syntaxRanges)
      case "link", "image":
        modify(range, cells: &cells) { $0.ink = kind == "link" ? .link : .secondary }
        markLinkSyntax(
          in: node, range: range, source: source, index: index,
          image: kind == "image",
          syntaxRanges: &syntaxRanges)
      case "block_quote":
        modify(range, cells: &cells) {
          $0.indent = max($0.indent, 14)
          $0.ink = .secondary
        }
        markQuotePrefixes(in: range, source: source, syntaxRanges: &syntaxRanges)
      case "list":
        var depth = 1
        var ancestor = cmark_node_parent(node)
        while let current = ancestor {
          if type(of: current) == "list" { depth += 1 }
          ancestor = cmark_node_parent(current)
        }
        let indent = Double(depth * 16)
        modify(range, cells: &cells) { $0.indent = max($0.indent, indent) }
      default:
        break
      }
    }
  }

  private static func visit(
    _ node: UnsafeMutablePointer<cmark_node>, _ body: (UnsafeMutablePointer<cmark_node>) -> Void
  ) {
    body(node)
    var child = cmark_node_first_child(node)
    while let current = child {
      let next = cmark_node_next(current)
      visit(current, body)
      child = next
    }
  }

  private static func type(of node: UnsafeMutablePointer<cmark_node>) -> String? {
    cmark_node_get_type_string(node).map(String.init(cString:))
  }

  private static func modify(
    _ range: NSRange, cells: inout [Style], _ change: (inout Style) -> Void
  ) {
    guard range.location >= 0, NSMaxRange(range) <= cells.count else { return }
    for offset in range.location..<NSMaxRange(range) { change(&cells[offset]) }
  }

  private static func markPairedSyntax(
    in range: NSRange, source: NSString, marks: [String],
    syntaxRanges: inout [NSRange]
  ) {
    let content = source.substring(with: range) as NSString
    for mark in marks {
      let width = (mark as NSString).length
      guard range.length >= width * 2,
        content.substring(to: width) == mark,
        content.substring(from: content.length - width) == mark
      else { continue }
      syntaxRanges.append(NSRange(location: range.location, length: width))
      syntaxRanges.append(NSRange(location: NSMaxRange(range) - width, length: width))
      return
    }
  }

  private static func markCodeTicks(
    in node: UnsafeMutablePointer<cmark_node>, range: NSRange, source: NSString,
    syntaxRanges: inout [NSRange]
  ) {
    // cmark's code node span deliberately excludes the opening and closing
    // backtick runs. Only collapse runs proven adjacent to that parsed span.
    let width = Int(cmark_node_get_backtick_count(node))
    guard width > 0, range.location >= width,
      NSMaxRange(range) + width <= source.length
    else { return }
    let opening = NSRange(location: range.location - width, length: width)
    let closing = NSRange(location: NSMaxRange(range), length: width)
    let ticks = String(repeating: "`", count: width)
    guard source.substring(with: opening) == ticks,
      source.substring(with: closing) == ticks
    else { return }
    syntaxRanges.append(opening)
    syntaxRanges.append(closing)
  }

  private static func markLinkSyntax(
    in node: UnsafeMutablePointer<cmark_node>, range: NSRange, source: NSString,
    index: SourceIndex, image: Bool, syntaxRanges: inout [NSRange]
  ) {
    // The visible label may contain nested brackets or escaped delimiters.
    // Use parsed child positions so no portion of that label is collapsed.
    guard let firstChild = cmark_node_first_child(node),
      let lastChild = cmark_node_last_child(node),
      let first = index.range(of: firstChild), let last = index.range(of: lastChild),
      first.location >= range.location, NSMaxRange(last) <= NSMaxRange(range),
      NSMaxRange(last) >= first.location
    else { return }
    let prefix = image ? "![" : "["
    let prefixRange = NSRange(
      location: range.location,
      length: first.location - range.location)
    let suffixRange = NSRange(
      location: NSMaxRange(last),
      length: NSMaxRange(range) - NSMaxRange(last))
    guard source.substring(with: prefixRange) == prefix,
      source.substring(with: suffixRange).hasPrefix("]")
    else { return }
    syntaxRanges.append(prefixRange)
    syntaxRanges.append(suffixRange)
  }

  private static func leadingATXMarker(in range: NSRange, source: NSString) -> NSRange? {
    let line = source.lineRange(for: NSRange(location: range.location, length: 0))
    let extent = NSIntersectionRange(line, range)
    guard extent.length > 0 else { return nil }
    let content = source.substring(with: extent)
    guard let expression = try? NSRegularExpression(pattern: #"^ {0,3}#{1,6}[ \t]+"#),
      let match = expression.firstMatch(
        in: content,
        range: NSRange(
          location: 0,
          length: (content as NSString).length))
    else { return nil }
    return NSRange(location: extent.location + match.range.location, length: match.range.length)
  }

  private static func setextUnderline(in range: NSRange, source: NSString) -> NSRange? {
    let line = source.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
    let extent = NSIntersectionRange(line, range)
    guard extent.length > 0 else { return nil }
    let content = source.substring(with: extent)
    guard
      content.range(
        of: #"^ {0,3}(=+|-+)[ \t]*$"#,
        options: .regularExpression) != nil
    else { return nil }
    return extent
  }

  private static func markCodeFences(
    in range: NSRange, source: NSString, syntaxRanges: inout [NSRange]
  ) {
    let first = NSIntersectionRange(
      source.lineRange(for: NSRange(location: range.location, length: 0)), range)
    guard first.length > 0 else { return }
    let firstText = source.substring(with: first)
    guard
      firstText.range(
        of: #"^ {0,3}(`{3,}|~{3,})"#,
        options: .regularExpression) != nil
    else { return }
    syntaxRanges.append(first)
    let last = NSIntersectionRange(
      source.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0)), range)
    guard last.location != first.location, last.length > 0 else { return }
    let lastText = source.substring(with: last)
    if lastText.range(
      of: #"^ {0,3}(`{3,}|~{3,})[ \t]*$"#,
      options: .regularExpression) != nil
    {
      syntaxRanges.append(last)
    }
  }

  private static func markQuotePrefixes(
    in range: NSRange, source: NSString, syntaxRanges: inout [NSRange]
  ) {
    var location = range.location
    while location < NSMaxRange(range) {
      let line = source.lineRange(for: NSRange(location: location, length: 0))
      let extent = NSIntersectionRange(line, range)
      guard extent.length > 0 else { break }
      let content = source.substring(with: extent)
      if let expression = try? NSRegularExpression(pattern: #"^ {0,3}>[ \t]?"#),
        let match = expression.firstMatch(
          in: content,
          range: NSRange(location: 0, length: (content as NSString).length))
      {
        syntaxRanges.append(NSRange(location: extent.location, length: match.range.length))
      }
      location = NSMaxRange(line)
      if location <= extent.location { break }
    }
  }

  private static func render(
    _ plan: Plan, activeUTF16Location: Int?, bodyFont: UIFont,
    traitCollection: UITraitCollection?, textColor: UIColor
  ) -> NSAttributedString {
    let result = NSMutableAttributedString(
      string: plan.source,
      attributes: [.font: bodyFont, .foregroundColor: textColor])
    guard !plan.cells.isEmpty else { return result }
    var cells = plan.cells
    let activeBlock = activeUTF16Location.flatMap {
      activeBlockRange(in: plan, caret: min(max($0, 0), cells.count))
    }
    for range in plan.syntaxRanges {
      guard range.location >= 0, NSMaxRange(range) <= cells.count else { continue }
      let isActive = activeBlock.map { NSIntersectionRange($0, range).length > 0 } ?? false
      modify(range, cells: &cells) {
        $0.hidden = !isActive
        $0.ink = isActive ? .secondary : .hidden
        $0.headingLevel = nil
        $0.codeBackground = false
      }
    }
    var start = 0
    while start < cells.count {
      let style = cells[start]
      var end = start + 1
      while end < cells.count, cells[end] == style { end += 1 }

      let size: CGFloat
      if style.hidden {
        size = 1
      } else if let headingLevel = style.headingLevel {
        size =
          UIFont.preferredFont(
            forTextStyle: headingTextStyle(headingLevel),
            compatibleWith: traitCollection
          ).pointSize
      } else {
        size = bodyFont.pointSize
      }
      var font: UIFont
      if style.monospaced {
        font = .monospacedSystemFont(ofSize: size, weight: style.bold ? .bold : .regular)
      } else {
        font = .systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
      }
      if style.italic,
        let descriptor = font.fontDescriptor.withSymbolicTraits(
          font.fontDescriptor.symbolicTraits.union(.traitItalic))
      {
        font = UIFont(descriptor: descriptor, size: size)
      }

      let color: UIColor
      switch style.ink {
      case .primary: color = textColor
      case .secondary: color = .secondaryLabel
      case .link:
        color = UIColor(named: "AccentColor", in: .main, compatibleWith: traitCollection) ?? .link
      case .hidden: color = .clear
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = 2
      paragraph.paragraphSpacing = style.paragraphSpacing
      paragraph.headIndent = style.indent
      paragraph.firstLineHeadIndent = style.indent
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ]
      if style.codeBackground { attributes[.backgroundColor] = UIColor.tertiarySystemFill }
      if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      if style.ink == .link { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      result.setAttributes(attributes, range: NSRange(location: start, length: end - start))
      start = end
    }
    return result
  }

  private static func headingTextStyle(_ level: Int) -> UIFont.TextStyle {
    switch level {
    case 1: return .title1
    case 2: return .title2
    case 3: return .title3
    case 4, 5: return .headline
    default: return .body
    }
  }
}

/// Parsing is isolated from UIKit's main actor. Repeated selection changes
/// reuse the resulting plan; only edits to the source require a new parse.
actor LiveMarkdownParser {
  func parse(_ source: String) -> LiveMarkdownStyler.Plan {
    LiveMarkdownStyler.plan(for: source)
  }
}
