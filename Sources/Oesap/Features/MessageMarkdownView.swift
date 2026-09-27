import MarkdownUI
import SwiftUI

/// Renders host-provided message text as native, selectable SwiftUI Markdown.
@MainActor
struct MessageMarkdownView: View {
  let source: String

  @State private var parsedSource: String?
  @State private var parsedContent: MarkdownContent?

  var body: some View {
    Group {
      if parsedSource == source, let parsedContent {
        Markdown(parsedContent)
          .markdownTheme(.basic)
          .markdownImageProvider(DisabledMarkdownImageProvider())
          .markdownInlineImageProvider(DisabledInlineMarkdownImageProvider())
          .environment(
            \.openURL,
            OpenURLAction { url in
              guard let safeURL = MarkdownLinkPolicy.validatedURL(url) else {
                return .discarded
              }
              return .systemAction(safeURL)
            }
          )
          .textSelection(.enabled)
          .foregroundStyle(.primary)
      } else {
        Text(verbatim: source)
          .font(.body)
          .textSelection(.enabled)
          .foregroundStyle(.primary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: source) {
      parsedSource = nil
      parsedContent = nil

      do {
        let result = try await MessageMarkdownContentParser.shared.parse(source)
        try Task.checkCancellation()
        parsedContent = result.content
        parsedSource = source
      } catch is CancellationError {
        // A newer streamed message source owns the view now.
      } catch {
        // Preserve the original text if the parser ever reports a failure.
      }
    }
  }
}

enum MarkdownLinkPolicy {
  static func validatedURL(_ url: URL) -> URL? {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host,
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.port.map({ (1...65_535).contains($0) }) ?? true
    else {
      return nil
    }

    return components.url
  }
}

private struct MessageMarkdownContentResult: @unchecked Sendable {
  // MarkdownUI 2.4.1's content tree is an immutable value tree of arrays,
  // enums, strings, and integers. Parsing releases its temporary cmark nodes
  // before returning, so the value can safely move from the parser actor to
  // this main-actor view. Keep this wrapper local rather than adding a
  // retroactive Sendable conformance to the dependency's public type.
  let content: MarkdownContent
}

private actor MessageMarkdownContentParser {
  static let shared = MessageMarkdownContentParser()

  func parse(_ source: String) throws -> MessageMarkdownContentResult {
    try Task.checkCancellation()
    let content = MarkdownContent(source)
    try Task.checkCancellation()
    return MessageMarkdownContentResult(content: content)
  }
}

private struct DisabledMarkdownImageProvider: ImageProvider {
  func makeImage(url: URL?) -> some View {
    Label("Image unavailable", systemImage: "photo")
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

private struct DisabledInlineMarkdownImageProvider: InlineImageProvider {
  func image(with url: URL, label: String) async throws -> Image {
    Image(systemName: "photo")
  }
}
