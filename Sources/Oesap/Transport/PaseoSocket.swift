import Foundation
import OSLog

/// Small seam for offline transport tests. One socket represents one connection attempt.
protocol PaseoSocket: AnyObject {
  var closeCode: Int { get }
  var failureMetadata: PaseoSocketFailureMetadata { get }
  func start()
  func ping(_ completion: @escaping (Error?) -> Void)
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func cancel()
}

extension PaseoSocket {
  var failureMetadata: PaseoSocketFailureMetadata { .init(closeCode: closeCode) }
}

final class URLSessionPaseoSocket: PaseoSocket {
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private let observer: PaseoSocketObserver

  init(config: PaseoConnectionConfig) throws {
    let url = try config.webSocketURL()
    observer = PaseoSocketObserver()
    session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: nil)
    if let password = config.password, !password.isEmpty {
      // Paseo authenticates the subprotocol, not an HTTP Authorization header.
      task = session.webSocketTask(with: url, protocols: ["paseo.bearer.\(password)"])
    } else {
      task = session.webSocketTask(with: url)
    }
    // An 8 MiB image preview arrives as base64 JSON; relay ciphertext is
    // base64-encoded again. Allow that bounded frame while still rejecting
    // unexpectedly large inbound messages.
    task.maximumMessageSize = 32 * 1_024 * 1_024
  }

  var closeCode: Int { failureMetadata.closeCode ?? 0 }
  var failureMetadata: PaseoSocketFailureMetadata {
    var metadata = observer.snapshot
    if let response = task.response as? HTTPURLResponse {
      metadata.httpStatus = response.statusCode
    }
    if task.closeCode != .invalid { metadata.closeCode = task.closeCode.rawValue }
    if metadata.causes.isEmpty, let error = task.error {
      metadata.causes = ConnectionFailure.ErrorCode.capture(error)
    }
    return metadata
  }
  func start() { task.resume() }
  func ping(_ completion: @escaping (Error?) -> Void) {
    task.sendPing(pongReceiveHandler: completion)
  }
  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    try await task.send(message)
  }
  func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
  func cancel() {
    observer.markCancelled()
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
}

/// URLSession may report failed upgrades through task completion rather than a
/// WebSocket close callback. Capture both paths without retaining raw errors or
/// the server's arbitrary close reason. Lock protects delegate/transport access.
final class PaseoSocketObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  private static let logger = Logger(subsystem: "com.oesap.app", category: "connection")
  private let lock = NSLock()
  private var metadata = PaseoSocketFailureMetadata()

  var snapshot: PaseoSocketFailureMetadata {
    lock.lock()
    defer { lock.unlock() }
    return metadata
  }

  func markCancelled() {
    lock.lock()
    metadata.wasCancelled = true
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    record(
      httpStatus: (webSocketTask.response as? HTTPURLResponse)?.statusCode,
      closeCode: closeCode.rawValue, error: nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    record(
      httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
      closeCode: (task as? URLSessionWebSocketTask)?.closeCode.rawValue, error: error)
  }

  func record(httpStatus: Int?, closeCode: Int?, error: Error?) {
    let causes = error.map(ConnectionFailure.ErrorCode.capture)
    lock.lock()
    if let httpStatus, (100...599).contains(httpStatus) { metadata.httpStatus = httpStatus }
    if let closeCode, (1000...4999).contains(closeCode) { metadata.closeCode = closeCode }
    if let causes { metadata.causes = causes }
    let captured = metadata
    lock.unlock()
    guard !captured.wasCancelled, error != nil || captured.closeCode != nil else { return }
    let safeCodes = captured.causes.map { "\($0.domain):\($0.code)" }.joined(separator: ",")
    Self.logger.error(
      "Socket completion: http=\(captured.httpStatus ?? 0) close=\(captured.closeCode ?? 0) codes=\(safeCodes, privacy: .public)"
    )
  }
}
