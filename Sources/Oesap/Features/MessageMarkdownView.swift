import MarkdownUI
import SwiftUI

/// Renders host-provided message text as native, selectable SwiftUI Markdown.
@MainActor
struct MessageMarkdownView: View {
  let source: String

  @State private var parsedSource: String?
  @State private var parsedContent: MarkdownContent?
  @State private var imageSources: [String: MarkdownImageSource] = [:]
  @State private var viewerItem: ImageAttachmentViewerItem?
  @State private var imageLoader: ReceivedImageLoader

  init(
    source: String,
    threadID: String? = nil,
    loadRemoteImage: ReceivedImageLoader.HostFileLoader? = nil
  ) {
    self.source = source
    _imageLoader = State(
      initialValue: ReceivedImageLoader(threadID: threadID, hostFileLoader: loadRemoteImage))
  }

  var body: some View {
    Group {
      if parsedSource == source, let parsedContent {
        Markdown(parsedContent)
          .markdownTheme(.basic)
          .markdownImageProvider(
            ReceivedMarkdownImageProvider(
              imagesByID: imageSources,
              loader: imageLoader,
              onOpen: { image in viewerItem = .remote(image, loader: imageLoader) }
            )
          )
          .markdownInlineImageProvider(
            ReceivedMarkdownInlineImageProvider(imagesByID: imageSources, loader: imageLoader)
          )
          .environment(
            \.openURL,
            OpenURLAction { url in
              if let id = MarkdownImageActionPolicy.imageID(url),
                let image = imageSources[id]
              {
                viewerItem = .remote(image, loader: imageLoader)
                return .handled
              }
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
    .fullScreenCover(item: $viewerItem) { item in
      ImageAttachmentViewer(item: item)
    }
    .task(id: source) {
      parsedSource = nil
      parsedContent = nil
      imageSources = [:]

      do {
        let result = try await MessageMarkdownContentParser.shared.parse(source)
        try Task.checkCancellation()
        parsedContent = result.content
        imageSources = result.imagesByID
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
  let imagesByID: [String: MarkdownImageSource]
}

private actor MessageMarkdownContentParser {
  static let shared = MessageMarkdownContentParser()

  func parse(_ source: String) throws -> MessageMarkdownContentResult {
    try Task.checkCancellation()
    let transformed = MarkdownImageTransformer.transform(source)
    try Task.checkCancellation()
    let content = MarkdownContent(transformed.markdown)
    try Task.checkCancellation()
    return MessageMarkdownContentResult(content: content, imagesByID: transformed.imagesByID)
  }
}
