import Foundation

/// Small seam for offline transport tests. One socket represents one connection attempt.
protocol PaseoSocket: AnyObject {
  var closeCode: Int { get }
  func start()
  func ping(_ completion: @escaping (Error?) -> Void)
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func cancel()
}

final class URLSessionPaseoSocket: PaseoSocket {
  private let session: URLSession
  private let task: URLSessionWebSocketTask

  init(config: PaseoConnectionConfig) throws {
    let url = try config.webSocketURL()
    session = URLSession(configuration: .ephemeral)
    if let password = config.password, !password.isEmpty {
      // Paseo authenticates the subprotocol, not an HTTP Authorization header.
      task = session.webSocketTask(with: url, protocols: ["paseo.bearer.\(password)"])
    } else {
      task = session.webSocketTask(with: url)
    }
  }

  var closeCode: Int { task.closeCode.rawValue }
  func start() { task.resume() }
  func ping(_ completion: @escaping (Error?) -> Void) {
    task.sendPing(pongReceiveHandler: completion)
  }
  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    try await task.send(message)
  }
  func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
  func cancel() {
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
}
