import MarkdownUI
import Observation
import SwiftUI

/// Renders host-provided message text as native, selectable SwiftUI Markdown.
@MainActor
struct MessageMarkdownView: View {
  let source: String
  let cacheKey: String?
  let deferUntilRendered: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var localCacheKey = UUID().uuidString
  @State private var renderer: MessageMarkdownRenderer
  @State private var viewerItem: ImageAttachmentViewerItem?
  @State private var imageLoader: ReceivedImageLoader

  init(
    source: String,
    cacheKey: String? = nil,
    threadID: String? = nil,
    deferUntilRendered: Bool = false,
    loadRemoteImage: ReceivedImageLoader.HostFileLoader? = nil
  ) {
    self.source = source
    self.cacheKey = cacheKey
    self.deferUntilRendered = deferUntilRendered
    _renderer = State(initialValue: MessageMarkdownRenderer(source: source))
    _imageLoader = State(
      initialValue: ReceivedImageLoader(threadID: threadID, hostFileLoader: loadRemoteImage))
  }

  var body: some View {
    Group {
      if let result = renderer.result, renderer.renderedSource == source {
        Markdown(result.content)
          .markdownTheme(.basic)
          .markdownImageProvider(
            ReceivedMarkdownImageProvider(
              imagesByID: result.imagesByID,
              loader: imageLoader,
              onOpen: { image in viewerItem = .remote(image, loader: imageLoader) }
            )
          )
          .markdownInlineImageProvider(
            ReceivedMarkdownInlineImageProvider(imagesByID: result.imagesByID, loader: imageLoader)
          )
          .environment(
            \.openURL,
            OpenURLAction { url in
              if let id = MarkdownImageActionPolicy.imageID(url),
                let image = result.imagesByID[id]
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
          .transition(.move(edge: .bottom).combined(with: .opacity))
      } else if deferUntilRendered {
        if renderer.failedSource == source {
          Text(verbatim: source)
            .font(.body)
            .textSelection(.enabled)
            .foregroundStyle(.primary)
        } else {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Preparing response…")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .combine)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      } else {
        Text(verbatim: source)
          .font(.body)
          .textSelection(.enabled)
          .foregroundStyle(.primary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 0.22),
      value: renderer.renderedSource == source
    )
    .appFullScreenCover(item: $viewerItem) { item in
      ImageAttachmentViewer(item: item)
    }
    .onChange(of: source) { _, latest in renderer.update(source: latest) }
    .task {
      await renderer.run(cacheKey: cacheKey ?? localCacheKey)
    }
  }
}

/// Owns one rendering worker for the lifetime of a message view. Source
/// updates replace a single pending snapshot, never cancel an in-flight parse.
/// This guarantees visible progress even when parsing takes longer than the
/// host's token interval, while navigation still cancels work immediately.
@MainActor
@Observable
final class MessageMarkdownRenderer {
  typealias Parser = @Sendable (String, String) async throws -> MessageMarkdownContentResult

  private(set) var result: MessageMarkdownContentResult?
  private(set) var failedSource: String?
  @ObservationIgnored private(set) var renderedSource: String?
  @ObservationIgnored private var latestSource: String
  @ObservationIgnored private var continuation: AsyncStream<Void>.Continuation?
  @ObservationIgnored private var activeRunID: UUID?
  @ObservationIgnored private let parse: Parser

  init(
    source: String,
    parse: @escaping Parser = { source, key in
      try await MessageMarkdownContentParser.shared.parse(source, cacheKey: key)
    }
  ) {
    latestSource = source
    self.parse = parse
  }

  func update(source: String) {
    latestSource = source
    if failedSource != source { failedSource = nil }
    continuation?.yield(())
  }

  func run(cacheKey: String) async {
    let runID = UUID()
    activeRunID = runID
    let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.continuation?.finish()
    self.continuation = continuation
    continuation.yield(())
    defer {
      continuation.finish()
      if activeRunID == runID {
        self.continuation = nil
        activeRunID = nil
      }
    }
    var lastParseTime: ContinuousClock.Instant?
    for await _ in updates {
      var attemptedSource: String?
      do {
        if let lastParseTime {
          try await ContinuousClock().sleep(until: lastParseTime.advanced(by: .milliseconds(50)))
        }
        try Task.checkCancellation()
        guard activeRunID == runID else { return }
        // Read after the cadence delay, discarding obsolete buffered snapshots.
        let snapshot = latestSource
        attemptedSource = snapshot
        guard snapshot != renderedSource else { continue }
        let parsed = try await parse(snapshot, cacheKey)
        try Task.checkCancellation()
        guard activeRunID == runID else { return }
        result = parsed
        renderedSource = snapshot
        failedSource = nil
        lastParseTime = .now
      } catch is CancellationError {
        return
      } catch {
        failedSource = attemptedSource
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

struct MessageMarkdownContentResult: @unchecked Sendable {
  // MarkdownUI 2.4.1's content tree is an immutable value tree of arrays,
  // enums, strings, and integers. Parsing releases its temporary cmark nodes
  // before returning, so the value can safely move from the parser actor to
  // this main-actor view. Keep this wrapper local rather than adding a
  // retroactive Sendable conformance to the dependency's public type.
  let content: MarkdownContent
  let imagesByID: [String: MarkdownImageSource]
}

/// Serializes cmark work off the main actor and retains only the latest tree
/// for each visible/recent message. Both entry and source-byte limits bound the
/// cache; very large answers render normally without being retained here.
actor MessageMarkdownContentParser {
  static let shared = MessageMarkdownContentParser()

  private struct Entry {
    let source: String
    let result: MessageMarkdownContentResult
    let byteCount: Int
  }

  private let maximumEntries: Int
  private let maximumSourceBytes: Int
  private var cache: [String: Entry] = [:]
  private var recency: [String] = []
  private(set) var cachedSourceBytes = 0
  private(set) var parseCount = 0
  var cachedEntryCount: Int { cache.count }

  init(maximumEntries: Int = 64, maximumSourceBytes: Int = 512 * 1_024) {
    self.maximumEntries = maximumEntries
    self.maximumSourceBytes = maximumSourceBytes
  }

  func parse(_ source: String, cacheKey: String) throws -> MessageMarkdownContentResult {
    try Task.checkCancellation()
    if let entry = cache[cacheKey], entry.source == source {
      touch(cacheKey)
      return entry.result
    }
    let transformed = MarkdownImageTransformer.transform(source)
    try Task.checkCancellation()
    let content = MarkdownContent(transformed.markdown)
    try Task.checkCancellation()
    let result = MessageMarkdownContentResult(content: content, imagesByID: transformed.imagesByID)
    parseCount += 1
    remove(cacheKey)
    let byteCount = source.utf8.count
    if maximumEntries > 0, byteCount <= maximumSourceBytes {
      while cache.count >= maximumEntries || cachedSourceBytes > maximumSourceBytes - byteCount {
        guard let oldest = recency.first else { break }
        remove(oldest)
      }
      cache[cacheKey] = Entry(source: source, result: result, byteCount: byteCount)
      cachedSourceBytes += byteCount
      touch(cacheKey)
    }
    return result
  }

  private func touch(_ key: String) {
    recency.removeAll { $0 == key }
    recency.append(key)
  }

  private func remove(_ key: String) {
    if let old = cache.removeValue(forKey: key) { cachedSourceBytes -= old.byteCount }
    recency.removeAll { $0 == key }
  }
}
