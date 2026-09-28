import Darwin
import Foundation
import cmark_gfm
import cmark_gfm_extensions

struct MarkdownImageSource: Identifiable, Sendable, Equatable {
  let id: String
  let source: String
  let alt: String

  var internalURL: String { "oesap-image://\(id)" }
}

struct TransformedMarkdown: Sendable {
  let markdown: String
  let imagesByID: [String: MarkdownImageSource]
}

/// Uses the same pinned cmark-gfm parser as MarkdownUI to make image nodes
/// block-level where needed. This keeps image thumbnails interactive while
/// preserving the order and formatting of surrounding inline content.
enum MarkdownImageTransformer {
  private static let maximumImagesPerMessage = 12

  static func transform(_ source: String) -> TransformedMarkdown {
    // Every CommonMark image starts with ![. Most streamed answers contain
    // none, so avoid an entire parse/render pass before MarkdownUI parses it.
    guard source.contains("![") else {
      return .init(markdown: source, imagesByID: [:])
    }
    cmark_gfm_core_extensions_ensure_registered()
    guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
      return .init(markdown: source, imagesByID: [:])
    }
    defer { cmark_parser_free(parser) }

    for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
      guard let extensionName = name.withCString({ cmark_find_syntax_extension($0) }) else {
        continue
      }
      _ = cmark_parser_attach_syntax_extension(parser, extensionName)
    }
    source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
    guard let document = cmark_parser_finish(parser) else {
      return .init(markdown: source, imagesByID: [:])
    }
    defer { cmark_node_free(document) }

    var images: [String: MarkdownImageSource] = [:]
    var allImageNodes: [UnsafeMutablePointer<cmark_node>] = []
    collectImages(in: document, into: &allImageNodes)
    guard !allImageNodes.isEmpty else {
      return .init(markdown: source, imagesByID: [:])
    }
    for (index, node) in allImageNodes.enumerated() {
      let id = "image-\(index)"
      let record = MarkdownImageSource(id: id, source: nodeURL(node) ?? "", alt: imageAlt(node))
      if index < maximumImagesPerMessage { images[id] = record }
      record.internalURL.withCString { _ = cmark_node_set_url(node, $0) }
    }

    normalizeParagraphs(in: document)
    addViewerLinksForRemainingInlineImages(in: document, images: images)

    guard let renderedCString = cmark_render_commonmark(document, CMARK_OPT_DEFAULT, 0) else {
      return .init(markdown: source, imagesByID: images)
    }
    let rendered = String(cString: renderedCString)
    free(renderedCString)
    return .init(markdown: rendered, imagesByID: images)
  }

  private enum InlineSegment {
    case content(UnsafeMutablePointer<cmark_node>)
    case image(UnsafeMutablePointer<cmark_node>)
  }

  private static func normalizeParagraphs(
    in parent: UnsafeMutablePointer<cmark_node>
  ) {
    var child = cmark_node_first_child(parent)
    while let current = child {
      let next = cmark_node_next(current)
      if nodeType(current) == "paragraph" {
        normalizeParagraph(current)
      } else {
        normalizeParagraphs(in: current)
      }
      child = next
    }
  }

  private static func normalizeParagraph(_ paragraph: UnsafeMutablePointer<cmark_node>) {
    let children = childNodes(of: paragraph)
    guard children.contains(where: { subtreeContainsImage($0) }) else { return }

    var segments: [InlineSegment] = []
    for child in children {
      cmark_node_unlink(child)
      segments.append(contentsOf: splitInline(child))
    }

    // Leave an image-only paragraph untouched: MarkdownUI renders it as an
    // image block, whose provider supplies the tappable thumbnail.
    if segments.allSatisfy({
      if case .image = $0 { return true }
      return false
    }) {
      for segment in segments {
        if case .image(let image) = segment { _ = cmark_node_append_child(paragraph, image) }
      }
      return
    }

    var outputBlocks: [UnsafeMutablePointer<cmark_node>] = []
    var pendingInline: [UnsafeMutablePointer<cmark_node>] = []

    func flushInline() {
      guard !pendingInline.isEmpty, let block = cmark_node_new(CMARK_NODE_PARAGRAPH) else { return }
      for node in pendingInline { _ = cmark_node_append_child(block, node) }
      pendingInline.removeAll(keepingCapacity: true)
      outputBlocks.append(block)
    }

    for segment in segments {
      switch segment {
      case .content(let node):
        pendingInline.append(node)
      case .image(let node):
        flushInline()
        guard let imageBlock = cmark_node_new(CMARK_NODE_PARAGRAPH) else {
          pendingInline.append(node)
          continue
        }
        _ = cmark_node_append_child(imageBlock, node)
        outputBlocks.append(imageBlock)
      }
    }
    flushInline()

    for block in outputBlocks { _ = cmark_node_insert_before(paragraph, block) }
    cmark_node_free(paragraph)
  }

  private static func splitInline(
    _ node: UnsafeMutablePointer<cmark_node>
  ) -> [InlineSegment] {
    if nodeType(node) == "image" {
      return [.image(node)]
    }

    guard isInlineContainer(node), subtreeContainsImage(node) else {
      return [.content(node)]
    }

    let originalType = cmark_node_get_type(node)
    let originalTypeName = nodeType(node)
    let url = nodeURL(node)
    let title = nodeTitle(node)
    let children = childNodes(of: node)
    // cmark may keep text literals as slices of this container's content.
    // Materialize them before freeing the container, or the new link/emphasis
    // nodes render as empty text after an image splits their original parent.
    materializeLiterals(in: node)
    for child in children { cmark_node_unlink(child) }
    cmark_node_free(node)

    var result: [InlineSegment] = []
    var pending: [UnsafeMutablePointer<cmark_node>] = []

    func flushContent() {
      guard !pending.isEmpty else { return }
      if let wrapper = cmark_node_new(originalType) {
        if originalTypeName == "link" {
          if let url { url.withCString { _ = cmark_node_set_url(wrapper, $0) } }
          if let title { title.withCString { _ = cmark_node_set_title(wrapper, $0) } }
        }
        for child in pending { _ = cmark_node_append_child(wrapper, child) }
        result.append(.content(wrapper))
      } else {
        result.append(contentsOf: pending.map(InlineSegment.content))
      }
      pending.removeAll(keepingCapacity: true)
    }

    for child in children {
      for part in splitInline(child) {
        switch part {
        case .content(let content): pending.append(content)
        case .image(let image):
          flushContent()
          result.append(.image(image))
        }
      }
    }
    flushContent()
    return result
  }

  private static func subtreeContainsImage(_ node: UnsafeMutablePointer<cmark_node>) -> Bool {
    if nodeType(node) == "image" { return true }
    return childNodes(of: node).contains(where: subtreeContainsImage)
  }

  private static func materializeLiterals(in node: UnsafeMutablePointer<cmark_node>) {
    _ = cmark_node_get_literal(node)
    for child in childNodes(of: node) { materializeLiterals(in: child) }
  }

  private static func isInlineContainer(_ node: UnsafeMutablePointer<cmark_node>) -> Bool {
    ["emph", "strong", "strikethrough", "link"].contains(nodeType(node) ?? "")
  }

  private static func nodeType(_ node: UnsafeMutablePointer<cmark_node>) -> String? {
    cmark_node_get_type_string(node).map(String.init(cString:))
  }

  private static func pointerID(_ node: UnsafeMutablePointer<cmark_node>) -> UInt {
    UInt(bitPattern: UnsafeRawPointer(node))
  }

  private static func collectImages(
    in parent: UnsafeMutablePointer<cmark_node>,
    into result: inout [UnsafeMutablePointer<cmark_node>]
  ) {
    for child in childNodes(of: parent) {
      if nodeType(child) == "image" {
        result.append(child)
      } else {
        collectImages(in: child, into: &result)
      }
    }
  }

  private static func addViewerLinksForRemainingInlineImages(
    in document: UnsafeMutablePointer<cmark_node>,
    images: [String: MarkdownImageSource]
  ) {
    var remaining: [UnsafeMutablePointer<cmark_node>] = []
    collectImages(in: document, into: &remaining)
    var lastInsertionByAnchor: [UInt: UnsafeMutablePointer<cmark_node>] = [:]

    for image in remaining {
      // An image-only paragraph is rendered by the tappable block provider.
      // Headings and table cells remain inline and need a separate action.
      if let parent = cmark_node_parent(image), nodeType(parent) == "paragraph",
        childNodes(of: parent).count == 1
      {
        continue
      }
      guard let url = nodeURL(image),
        let sourceID = URLComponents(string: url)?.host,
        let record = images[sourceID]
      else { continue }

      var anchor = image
      var ancestor = cmark_node_parent(image)
      while let current = ancestor {
        if nodeType(current) == "link" { anchor = current }
        ancestor = cmark_node_parent(current)
      }
      let anchorID = pointerID(anchor)
      let insertionPoint = lastInsertionByAnchor[anchorID] ?? anchor
      guard let separator = cmark_node_new(CMARK_NODE_TEXT),
        let link = cmark_node_new(CMARK_NODE_LINK),
        let label = cmark_node_new(CMARK_NODE_TEXT)
      else { continue }

      " ".withCString { _ = cmark_node_set_literal(separator, $0) }
      record.internalURL.withCString { _ = cmark_node_set_url(link, $0) }
      let labelText = record.alt.isEmpty ? "View image" : "View image: \(record.alt.prefix(60))"
      labelText.withCString { _ = cmark_node_set_literal(label, $0) }
      _ = cmark_node_append_child(link, label)
      _ = cmark_node_insert_after(insertionPoint, separator)
      _ = cmark_node_insert_after(separator, link)
      lastInsertionByAnchor[anchorID] = link
    }
  }

  private static func childNodes(of node: UnsafeMutablePointer<cmark_node>)
    -> [UnsafeMutablePointer<cmark_node>]
  {
    var result: [UnsafeMutablePointer<cmark_node>] = []
    var child = cmark_node_first_child(node)
    while let current = child {
      result.append(current)
      child = cmark_node_next(current)
    }
    return result
  }

  private static func nodeURL(_ node: UnsafeMutablePointer<cmark_node>) -> String? {
    cmark_node_get_url(node).map(String.init(cString:))
  }

  private static func nodeTitle(_ node: UnsafeMutablePointer<cmark_node>) -> String? {
    cmark_node_get_title(node).map(String.init(cString:))
  }

  private static func imageAlt(_ node: UnsafeMutablePointer<cmark_node>) -> String {
    var pieces: [String] = []
    collectAltText(node, into: &pieces)
    return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func collectAltText(
    _ node: UnsafeMutablePointer<cmark_node>, into pieces: inout [String]
  ) {
    if let type = nodeType(node), ["text", "code", "html_inline"].contains(type),
      let literal = cmark_node_get_literal(node)
    {
      pieces.append(String(cString: literal))
    }
    for child in childNodes(of: node) { collectAltText(child, into: &pieces) }
  }
}
