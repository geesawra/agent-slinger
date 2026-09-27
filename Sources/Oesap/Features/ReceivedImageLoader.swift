import Foundation

/// Loads only image bytes declared in Markdown. HTTP transfers are ephemeral,
/// credential-free and capped while receiving, and daemon files are delegated
/// to the model's workspace-scoped RPC.
actor ReceivedImageLoader {
  typealias HostFileLoader = (String, String) async throws -> Data

  private let threadID: String?
  private let hostFileLoader: HostFileLoader?
  private var cache: [String: Data] = [:]
  private var cachedBytes = 0
  private let maximumCacheBytes = 16 * 1_024 * 1_024
  private let maximumCacheEntries = 8

  init(threadID: String?, hostFileLoader: HostFileLoader?) {
    self.threadID = threadID
    self.hostFileLoader = hostFileLoader
  }

  func load(source: String) async throws -> Data {
    if let cached = cache[source] { return cached }

    let data: Data
    switch try ImageSourcePolicy.classify(source) {
    case .data(let bytes):
      data = bytes
    case .http(let url):
      data = try await BoundedImageHTTPClient.fetch(url: url)
    case .hostFile(let originalSource):
      guard let threadID, let hostFileLoader else { throw ImageLoadError.hostImageUnavailable }
      data = try await hostFileLoader(originalSource, threadID)
    }

    try Task.checkCancellation()
    guard data.count <= RemoteImageLimits.maximumDisplayBytes else {
      throw ImageLoadError.tooLarge
    }
    let normalized = try await ImageByteProcessor.normalizeForDisplay(data)
    try Task.checkCancellation()
    if cache.count < maximumCacheEntries, cachedBytes <= maximumCacheBytes - normalized.count {
      cache[source] = normalized
      cachedBytes += normalized.count
    }
    return normalized
  }
}

enum ImageLoadError: Error, Equatable {
  case invalidSource
  case invalidImageData
  case tooLarge
  case unsupportedImage
  case hostImageUnavailable
  case httpStatus
  case unsafeRedirect
  case tooManyRedirects
  case network
}

enum ImageSourcePolicy {
  enum Source {
    case data(Data)
    case http(URL)
    case hostFile(String)
  }

  static func classify(_ source: String) throws -> Source {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ImageLoadError.invalidSource }

    if trimmed.lowercased().hasPrefix("data:") {
      return .data(try decodeDataURL(trimmed))
    }
    guard trimmed.utf8.count <= 4_096 else { throw ImageLoadError.invalidSource }

    if let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased()
    {
      if scheme == "http" || scheme == "https" {
        guard let safe = safeHTTPURL(components) else { throw ImageLoadError.invalidSource }
        return .http(safe)
      }
      if scheme == "file" {
        guard components.user == nil, components.password == nil,
          components.host == nil || components.host?.isEmpty == true
            || components.host?.lowercased() == "localhost"
        else { throw ImageLoadError.invalidSource }
        // The model resolves this through the selected host's workspace-scoped
        // file RPC. The app never opens a file URL on the phone.
        return .hostFile(trimmed)
      }
      throw ImageLoadError.invalidSource
    }

    // Bare workspace paths are also resolved by the selected host's scoped RPC.
    guard !trimmed.hasPrefix("//"), !trimmed.contains("\0")
    else {
      throw ImageLoadError.invalidSource
    }
    return .hostFile(trimmed)
  }

  static func safeHTTPURL(_ components: URLComponents) -> URL? {
    guard
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.port.map({ (1...65_535).contains($0) }) ?? true,
      let url = components.url
    else { return nil }
    return url
  }

  static func allowsRedirect(from currentURL: URL, to targetURL: URL) -> Bool {
    guard
      let components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false),
      safeHTTPURL(components) != nil
    else { return false }
    return !(currentURL.scheme?.lowercased() == "https" && targetURL.scheme?.lowercased() == "http")
  }

  private static func decodeDataURL(_ value: String) throws -> Data {
    // A 8 MiB base64 payload is at most 4/3 of its decoded size, plus the
    // short data-URL header. Reject before allocating the decoded buffer.
    guard value.utf8.count <= (RemoteImageLimits.maximumDisplayBytes * 4 / 3) + 1_024,
      let comma = value.firstIndex(of: ",")
    else { throw ImageLoadError.tooLarge }

    let metadata = value[..<comma].lowercased()
    guard metadata.hasPrefix("data:image/"), metadata.hasSuffix(";base64") else {
      throw ImageLoadError.invalidSource
    }
    let payload = value[value.index(after: comma)...]
    guard let data = Data(base64Encoded: String(payload)),
      !data.isEmpty,
      data.count <= RemoteImageLimits.maximumDisplayBytes
    else { throw ImageLoadError.invalidImageData }
    return data
  }
}

private final class BoundedImageHTTPClient: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate
{
  private let lock = NSLock()
  private let maxBytes: Int
  private var received = Data()
  private var responseError: Error?
  private var continuation: CheckedContinuation<Data, Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var redirectCount = 0
  private var isCancelled = false
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "Oesap.BoundedImageHTTPClient"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()

  private init(maxBytes: Int) { self.maxBytes = maxBytes }

  static func fetch(url: URL) async throws -> Data {
    let client = BoundedImageHTTPClient(maxBytes: RemoteImageLimits.maximumDisplayBytes)
    return try await client.start(url: url)
  }

  private func start(url: URL) async throws -> Data {
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue("Oesap", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)

        lock.lock()
        self.continuation = continuation
        self.session = session
        self.task = task
        let wasCancelled = isCancelled
        lock.unlock()

        if wasCancelled {
          task.resume()
          task.cancel()
        } else {
          task.resume()
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse,
      (200...299).contains(response.statusCode)
    else {
      responseError = ImageLoadError.httpStatus
      completionHandler(.cancel)
      finish()
      return
    }
    if response.expectedContentLength > Int64(maxBytes) {
      responseError = ImageLoadError.tooLarge
      completionHandler(.cancel)
      finish()
      return
    }
    if let mimeType = response.mimeType?.lowercased(), !mimeType.hasPrefix("image/") {
      responseError = ImageLoadError.invalidImageData
      completionHandler(.cancel)
      finish()
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard responseError == nil else { return }
    guard received.count <= maxBytes - data.count else {
      responseError = ImageLoadError.tooLarge
      dataTask.cancel()
      finish()
      return
    }
    received.append(data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard redirectCount < 5 else {
      responseError = ImageLoadError.tooManyRedirects
      completionHandler(nil)
      finish()
      return
    }
    guard let url = request.url,
      let currentURL = response.url,
      ImageSourcePolicy.allowsRedirect(from: currentURL, to: url)
    else {
      responseError = ImageLoadError.unsafeRedirect
      completionHandler(nil)
      finish()
      return
    }

    redirectCount += 1
    var safeRequest = request
    for header in ["Authorization", "Proxy-Authorization", "Cookie", "Referer"] {
      safeRequest.setValue(nil, forHTTPHeaderField: header)
    }
    completionHandler(safeRequest)
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error, responseError == nil {
      if (error as? URLError)?.code == .cancelled {
        responseError = CancellationError()
      } else {
        responseError = ImageLoadError.network
      }
    }
    finish()
  }

  private func finish() {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    let error = responseError
    let data = received
    lock.unlock()

    guard let continuation else { return }
    if let error {
      continuation.resume(throwing: error)
    } else if data.isEmpty {
      continuation.resume(throwing: ImageLoadError.invalidImageData)
    } else {
      continuation.resume(returning: data)
    }
    session?.invalidateAndCancel()
    session = nil
  }

  private func cancel() {
    lock.lock()
    isCancelled = true
    let task = self.task
    lock.unlock()
    task?.cancel()
  }
}
