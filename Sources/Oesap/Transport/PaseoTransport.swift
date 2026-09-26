import Foundation

/// One physical Paseo socket. The protocol client owns reconnection and subscriptions.
actor PaseoTransport {
  private let config: PaseoConnectionConfig
  private let socketFactory: @Sendable (PaseoConnectionConfig) throws -> any PaseoSocket
  private let connectTimeout: Duration
  private let handshakeTimeout: Duration
  private var socket: (any PaseoSocket)?
  private var crypto: PaseoRelayCrypto?
  private var binaryCiphertext = false
  private var connecting: Task<Void, Error>?
  private var generation = UUID()

  init(
    config: PaseoConnectionConfig,
    connectTimeout: Duration = .seconds(15),
    handshakeTimeout: Duration = .seconds(15),
    socketFactory: @escaping @Sendable (PaseoConnectionConfig) throws -> any PaseoSocket = {
      try URLSessionPaseoSocket(config: $0)
    }
  ) {
    self.config = config
    self.connectTimeout = connectTimeout
    self.handshakeTimeout = handshakeTimeout
    self.socketFactory = socketFactory
  }

  func connect() async throws {
    if let connecting {
      return try await withTaskCancellationHandler {
        try await connecting.value
      } onCancel: {
        connecting.cancel()
      }
    }
    if socket != nil { return }
    let attemptID = UUID()
    generation = attemptID
    let attempt = Task { try await establish() }
    connecting = attempt
    do {
      try await withTaskCancellationHandler {
        try await attempt.value
      } onCancel: {
        attempt.cancel()
      }
      if generation == attemptID { connecting = nil }
    } catch {
      let mapped = Self.map(error, socket: socket)
      if generation == attemptID {
        connecting = nil
        close()
      }
      throw mapped
    }
  }

  func send(_ text: String) async throws {
    guard let socket else { throw PaseoConnectionError.disconnected }
    do {
      if config.mode == .relay {
        guard let crypto else { throw PaseoConnectionError.encryptionFailed }
        let bundle = try crypto.seal(Data(text.utf8))
        try await socket.send(.string(bundle.base64EncodedString()))
      } else {
        try await socket.send(.string(text))
      }
    } catch {
      let mapped = Self.map(error, socket: socket)
      if self.socket === socket { close() }
      throw mapped
    }
  }

  /// Calls must be serialized by one protocol receive pump.
  func receive() async throws -> String {
    guard let socket else { throw PaseoConnectionError.disconnected }
    do {
      while true {
        let frame = try await socket.receive()
        if config.mode == .direct {
          guard case .string(let text) = frame else {
            throw PaseoConnectionError.malformedFrame
          }
          return text
        }
        guard let crypto else { throw PaseoConnectionError.encryptionFailed }
        let bundle: Data
        switch frame {
        case .string(let text):
          if Self.isReadyFrame(text) { continue }
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            throw PaseoConnectionError.encryptionFailed
          }
          guard let decoded = Self.decodeCiphertext(text) else {
            throw PaseoConnectionError.malformedFrame
          }
          bundle = decoded
        case .data(let data):
          if binaryCiphertext {
            bundle = data
          } else if let encoded = String(data: data, encoding: .utf8),
            let decoded = Self.decodeCiphertext(encoded)
          {
            // COMPAT(binaryCiphertext): older adapters sometimes lost the opcode.
            bundle = decoded
          } else {
            bundle = data
          }
        @unknown default:
          throw PaseoConnectionError.malformedFrame
        }
        let plain = try crypto.open(bundle)
        guard let text = String(data: plain, encoding: .utf8) else {
          throw PaseoConnectionError.malformedFrame
        }
        return text
      }
    } catch {
      let mapped = Self.map(error, socket: socket)
      if self.socket === socket { close() }
      throw mapped
    }
  }

  func close() {
    generation = UUID()
    connecting?.cancel()
    connecting = nil
    socket?.cancel()
    socket = nil
    crypto = nil
    binaryCiphertext = false
  }

  private func establish() async throws {
    try Task.checkCancellation()
    let socket = try socketFactory(config)
    self.socket = socket
    socket.start()
    try await waitForOpen(socket)
    try Task.checkCancellation()

    if config.mode == .relay {
      guard let daemonKey = config.daemonPublicKeyBase64 else {
        throw PaseoConnectionError.invalidDaemonKey
      }
      let crypto = try PaseoRelayCrypto(daemonPublicKeyBase64: daemonKey)
      try await withTaskCancellationHandler {
        try await handshake(socket, crypto: crypto)
      } onCancel: {
        socket.cancel()
      }
      try Task.checkCancellation()
      self.crypto = crypto
    }
  }

  private func waitForOpen(_ socket: any PaseoSocket) async throws {
    let gate = OneShotContinuation()
    let timeout = Task {
      try? await Task.sleep(for: connectTimeout)
      if !Task.isCancelled {
        gate.finish(.failure(PaseoConnectionError.timedOut))
        socket.cancel()
      }
    }
    defer { timeout.cancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        gate.install(continuation)
        socket.ping { error in
          if let error { gate.finish(.failure(error)) } else { gate.finish(.success(())) }
        }
      }
    } onCancel: {
      gate.finish(.failure(PaseoConnectionError.cancelled))
      socket.cancel()
    }
  }

  private func handshake(_ socket: any PaseoSocket, crypto: PaseoRelayCrypto) async throws {
    let hello =
      "{\"type\":\"e2ee_hello\",\"key\":\"\(crypto.publicKeyBase64)\",\"capabilities\":{\"binaryCiphertext\":true}}"
    try await socket.send(.string(hello))
    let deadline = HandshakeDeadline()
    let timeout = Task {
      try? await Task.sleep(for: handshakeTimeout)
      if !Task.isCancelled {
        deadline.expire()
        socket.cancel()
      }
    }
    let retry = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        try? await socket.send(.string(hello))
      }
    }
    defer {
      timeout.cancel()
      retry.cancel()
    }
    do {
      while true {
        try Task.checkCancellation()
        let frame = try await socket.receive()
        guard case .string(let text) = frame else { continue }
        guard let data = text.data(using: .utf8),
          let ready = try? JSONDecoder().decode(RelayReady.self, from: data),
          ready.type == "e2ee_ready"
        else { continue }
        binaryCiphertext = ready.capabilities?.binaryCiphertext == true
        return
      }
    } catch {
      if deadline.expired { throw PaseoConnectionError.timedOut }
      if Task.isCancelled { throw PaseoConnectionError.cancelled }
      throw error
    }
  }

  private static func isReadyFrame(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8),
      let ready = try? JSONDecoder().decode(RelayReady.self, from: data)
    else { return false }
    return ready.type == "e2ee_ready"
  }

  private static func decodeCiphertext(_ encoded: String) -> Data? {
    var standard = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
    return Data(base64Encoded: standard)
  }

  private static func map(_ error: Error, socket: (any PaseoSocket)? = nil) -> PaseoConnectionError
  {
    if let typed = error as? PaseoConnectionError, typed == .cancelled { return typed }
    if error is CancellationError { return .cancelled }
    if socket?.closeCode == 4401 { return .authenticationFailed }
    if let typed = error as? PaseoConnectionError { return typed }
    if (error as NSError).code == NSURLErrorTimedOut { return .timedOut }
    return .disconnected
  }
}

private struct RelayReady: Decodable {
  let type: String
  let capabilities: Capabilities?
  struct Capabilities: Decodable { let binaryCiphertext: Bool? }
}

private final class OneShotContinuation: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var completed: Result<Void, Error>?

  func install(_ continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    if let completed {
      lock.unlock()
      continuation.resume(with: completed)
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  func finish(_ result: Result<Void, Error>) {
    lock.lock()
    guard completed == nil else {
      lock.unlock()
      return
    }
    completed = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

private final class HandshakeDeadline: @unchecked Sendable {
  private let lock = NSLock()
  private var didExpire = false
  var expired: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didExpire
  }
  func expire() {
    lock.lock()
    didExpire = true
    lock.unlock()
  }
}
