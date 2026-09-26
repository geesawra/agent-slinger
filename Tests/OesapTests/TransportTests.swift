import Foundation
import XCTest

@testable import Oesap

final class TransportTests: XCTestCase {
  // Generated with Paseo's tweetnacl@1.0.3: box.keyPair.fromSecretKey,
  // box.before, then box.after using the fixed synthetic nonce below.
  private let clientSecret = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
  private let clientPublic = "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c"
  private let daemonPublic = "5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36"
  private let nonce = "c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0"
  private let ciphertext = "7e89308e4f560a28812d0318cab768a9eeb9f2a8fcd365c9cddc3ae9e6ffe1"

  func testRelayCryptoMatchesUpstreamVectorAndRejectsTampering() throws {
    let daemonKey = Data(hex: daemonPublic).base64EncodedString()
    let crypto = try PaseoRelayCrypto(
      daemonPublicKeyBase64: daemonKey,
      secretKey: Array(Data(hex: clientSecret)))
    XCTAssertEqual(Data(base64Encoded: crypto.publicKeyBase64), Data(hex: clientPublic))
    let message = Data(#"{"type":"ping"}"#.utf8)
    let bundle = try crypto.seal(message, nonce: Array(Data(hex: nonce)))
    XCTAssertEqual(bundle, Data(hex: nonce + ciphertext))
    XCTAssertEqual(try crypto.open(bundle), message)

    var tampered = bundle
    tampered[tampered.index(before: tampered.endIndex)] ^= 1
    XCTAssertThrowsError(try crypto.open(tampered)) { error in
      XCTAssertEqual(error as? PaseoConnectionError, .encryptionFailed)
    }
    XCTAssertThrowsError(try crypto.open(Data(repeating: 0, count: 39)))
  }

  func testRelayRejectsInvalidAndLowOrderDaemonKeys() throws {
    XCTAssertThrowsError(try PaseoRelayCrypto.validatePublicKey("not base64"))
    let zero = Data(repeating: 0, count: 32).base64EncodedString()
    XCTAssertThrowsError(
      try PaseoRelayCrypto(
        daemonPublicKeyBase64: zero,
        secretKey: Array(Data(hex: clientSecret)))
    ) { error in
      XCTAssertEqual(error as? PaseoConnectionError, .invalidDaemonKey)
    }
  }

  func testPairingLinkBuildsExactRelayURLAndPreservesOpaqueID() throws {
    let offer =
      #"{"v":2,"serverId":" opaque-ID ","daemonPublicKeyB64":"KEY","relay":{"endpoint":"relay.paseo.sh:443","useTls":true}}"#
      .replacingOccurrences(of: "KEY", with: Data(hex: daemonPublic).base64EncodedString())
    let payload = Data(offer.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let config = try PaseoConnectionConfig.relay(
      pairingLink: "https://app.paseo.sh/#offer=\(payload)")
    XCTAssertEqual(config.serverID, " opaque-ID ")
    XCTAssertEqual(
      try config.webSocketURL().absoluteString,
      "wss://relay.paseo.sh:443/ws?serverId=%20opaque-ID%20&role=client&v=2")
  }

  func testDirectEndpointAndIPv6() throws {
    let direct = try PaseoConnectionConfig.direct(
      endpoint: "[::1]:6767", useTLS: false, password: "test")
    XCTAssertEqual(direct.endpoint, "[::1]:6767")
    XCTAssertEqual(try direct.webSocketURL().absoluteString, "ws://[::1]:6767/ws")
    XCTAssertThrowsError(
      try PaseoConnectionConfig.direct(endpoint: "example.com:6767/path", useTLS: true))
    XCTAssertThrowsError(try PaseoConnectionConfig.direct(endpoint: "example.com:0", useTLS: true))
  }

  func testRelayHandshakeAndEncryptedApplicationFrames() async throws {
    let daemonSecret = Data(hex: "65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384")
    let daemonKey = Data(hex: daemonPublic).base64EncodedString()
    let offer =
      #"{"v":2,"serverId":"fixture","daemonPublicKeyB64":"KEY","relay":{"endpoint":"relay.paseo.sh:443","useTls":true}}"#
      .replacingOccurrences(of: "KEY", with: daemonKey)
    let payload = Data(offer.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let config = try PaseoConnectionConfig.relay(
      pairingLink: "https://app.paseo.sh/#offer=\(payload)")
    let socket = FakeSocket()
    let peer = RelayPeer(secret: Array(daemonSecret))
    socket.onSend = { frame in
      guard case .string(let text) = frame else { return }
      if text.contains("e2ee_hello") {
        guard let data = text.data(using: .utf8),
          let hello = try? JSONDecoder().decode(TestHello.self, from: data),
          let crypto = try? PaseoRelayCrypto(
            daemonPublicKeyBase64: hello.key,
            secretKey: peer.secret)
        else { return }
        peer.crypto = crypto
        socket.enqueue(.string(#"{"type":"e2ee_ready","capabilities":{"binaryCiphertext":true}}"#))
        if let reply = try? crypto.seal(
          Data(#"{"type":"server_info"}"#.utf8),
          nonce: Array(Data(hex: self.nonce)))
        {
          socket.enqueue(.string(reply.base64EncodedString()))
        }
      }
    }
    let transport = PaseoTransport(config: config, socketFactory: { _ in socket })
    try await transport.connect()
    let inbound = try await transport.receive()
    XCTAssertEqual(inbound, #"{"type":"server_info"}"#)
    try await transport.send(#"{"type":"ping"}"#)
    guard let peerCrypto = peer.crypto,
      let last = socket.sent.last,
      case .string(let ciphertext) = last,
      let encrypted = Data(base64Encoded: ciphertext)
    else {
      return XCTFail("Missing encrypted outgoing frame")
    }
    XCTAssertEqual(try peerCrypto.open(encrypted), Data(#"{"type":"ping"}"#.utf8))

    socket.enqueue(.string(#"{"type":"session","message":{}}"#))
    do {
      _ = try await transport.receive()
      XCTFail("Plaintext on encrypted channel must fail")
    } catch {
      XCTAssertEqual(error as? PaseoConnectionError, .encryptionFailed)
    }
    XCTAssertTrue(socket.cancelled)
  }

  func testAuthFailureClosesSocketAndNextConnectUsesFreshSocket() async throws {
    let config = try PaseoConnectionConfig.direct(
      endpoint: "localhost:6767", useTLS: false,
      password: "synthetic-password")
    let first = FakeSocket()
    first.fail(PaseoConnectionError.disconnected, closeCode: 4401)
    let second = FakeSocket()
    second.enqueue(.string(#"{"type":"server_info"}"#))
    let sockets = FakeSocketQueue([first, second])
    let transport = PaseoTransport(config: config, socketFactory: { _ in sockets.next() })
    try await transport.connect()
    do {
      _ = try await transport.receive()
      XCTFail("Expected authentication failure")
    } catch {
      XCTAssertEqual(error as? PaseoConnectionError, .authenticationFailed)
    }
    XCTAssertTrue(first.cancelled)
    try await transport.connect()
    let secondInbound = try await transport.receive()
    XCTAssertEqual(secondInbound, #"{"type":"server_info"}"#)
  }

  func testConnectTimeoutAndCallerCancellation() async throws {
    let config = try PaseoConnectionConfig.direct(endpoint: "localhost:6767", useTLS: false)
    let stuck = FakeSocket(holdPing: true)
    let timed = PaseoTransport(
      config: config, connectTimeout: .milliseconds(30),
      socketFactory: { _ in stuck })
    do {
      try await timed.connect()
      XCTFail("Expected timeout")
    } catch {
      XCTAssertEqual(error as? PaseoConnectionError, .timedOut)
    }
    XCTAssertTrue(stuck.cancelled)

    let cancelledSocket = FakeSocket(holdPing: true)
    let cancelledTransport = PaseoTransport(
      config: config, connectTimeout: .seconds(2),
      socketFactory: { _ in cancelledSocket })
    let connect = Task { try await cancelledTransport.connect() }
    try await Task.sleep(for: .milliseconds(20))
    connect.cancel()
    do {
      try await connect.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertEqual(error as? PaseoConnectionError, .cancelled)
    }
    XCTAssertTrue(cancelledSocket.cancelled)
  }

  func testRelayHandshakeTimeout() async throws {
    let offer =
      #"{"v":2,"serverId":"fixture","daemonPublicKeyB64":"KEY","relay":{"endpoint":"relay.paseo.sh:443","useTls":true}}"#
      .replacingOccurrences(of: "KEY", with: Data(hex: daemonPublic).base64EncodedString())
    let payload = Data(offer.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let config = try PaseoConnectionConfig.relay(
      pairingLink: "https://app.paseo.sh/#offer=\(payload)")
    let socket = FakeSocket()
    let transport = PaseoTransport(
      config: config, handshakeTimeout: .milliseconds(30),
      socketFactory: { _ in socket })
    do {
      try await transport.connect()
      XCTFail("Expected handshake timeout")
    } catch {
      XCTAssertEqual(error as? PaseoConnectionError, .timedOut)
    }
    XCTAssertTrue(socket.cancelled)
  }
}

private struct TestHello: Decodable { let key: String }

private final class RelayPeer: @unchecked Sendable {
  let secret: [UInt8]
  var crypto: PaseoRelayCrypto?
  init(secret: [UInt8]) { self.secret = secret }
}

private final class FakeSocketQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [FakeSocket]
  init(_ sockets: [FakeSocket]) { self.sockets = sockets }
  func next() -> FakeSocket {
    lock.lock()
    defer { lock.unlock() }
    return sockets.removeFirst()
  }
}

private final class FakeSocket: PaseoSocket, @unchecked Sendable {
  private let lock = NSLock()
  private var queued: [Result<URLSessionWebSocketTask.Message, Error>] = []
  private var pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
  private var sentFrames: [URLSessionWebSocketTask.Message] = []
  private var pingCompletion: ((Error?) -> Void)?
  private var wasCancelled = false
  private var code = 0
  private let holdPing: Bool
  var onSend: ((URLSessionWebSocketTask.Message) -> Void)?

  init(holdPing: Bool = false) { self.holdPing = holdPing }
  var closeCode: Int {
    lock.lock()
    defer { lock.unlock() }
    return code
  }
  var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return wasCancelled
  }
  var sent: [URLSessionWebSocketTask.Message] {
    lock.lock()
    defer { lock.unlock() }
    return sentFrames
  }
  func start() {}
  func ping(_ completion: @escaping (Error?) -> Void) {
    if holdPing {
      lock.lock()
      pingCompletion = completion
      lock.unlock()
    } else {
      completion(nil)
    }
  }
  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    let onSend = recordSend(message)
    onSend?(message)
  }
  private func recordSend(_ message: URLSessionWebSocketTask.Message) -> (
    (URLSessionWebSocketTask.Message) -> Void
  )? {
    lock.lock()
    sentFrames.append(message)
    let onSend = self.onSend
    lock.unlock()
    return onSend
  }
  func receive() async throws -> URLSessionWebSocketTask.Message {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if !queued.isEmpty {
        let item = queued.removeFirst()
        lock.unlock()
        continuation.resume(with: item)
      } else if wasCancelled {
        lock.unlock()
        continuation.resume(throwing: PaseoConnectionError.disconnected)
      } else {
        pending = continuation
        lock.unlock()
      }
    }
  }
  func enqueue(_ message: URLSessionWebSocketTask.Message) { finish(.success(message)) }
  func fail(_ error: Error, closeCode: Int) {
    lock.lock()
    code = closeCode
    lock.unlock()
    finish(.failure(error))
  }
  func cancel() {
    lock.lock()
    wasCancelled = true
    let continuation = pending
    pending = nil
    let pingCompletion = self.pingCompletion
    self.pingCompletion = nil
    lock.unlock()
    pingCompletion?(PaseoConnectionError.disconnected)
    continuation?.resume(throwing: PaseoConnectionError.disconnected)
  }
  private func finish(_ item: Result<URLSessionWebSocketTask.Message, Error>) {
    lock.lock()
    let continuation = pending
    pending = nil
    if continuation == nil { queued.append(item) }
    lock.unlock()
    continuation?.resume(with: item)
  }
}

extension Data {
  fileprivate init(hex: String) {
    self.init()
    var index = hex.startIndex
    while index < hex.endIndex {
      let end = hex.index(index, offsetBy: 2)
      append(UInt8(hex[index..<end], radix: 16) ?? 0)
      index = end
    }
  }
}
