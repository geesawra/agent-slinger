import Foundation
import Security

enum PaseoConnectionError: Error, LocalizedError, Equatable {
  case invalidEndpoint
  case invalidPairingLink
  case invalidDaemonKey
  case unsupportedPairingVersion
  case authenticationFailed
  case timedOut
  case disconnected
  case malformedFrame
  case encryptionFailed
  case cancelled
  case keychainFailure(OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint: "Enter a valid host and port."
    case .invalidPairingLink: "The pairing link is invalid."
    case .invalidDaemonKey: "The pairing link contains an invalid daemon key."
    case .unsupportedPairingVersion: "This pairing link version is not supported."
    case .authenticationFailed: "The host rejected the password."
    case .timedOut: "The connection timed out."
    case .disconnected: "The connection closed."
    case .malformedFrame: "The host sent an invalid message."
    case .encryptionFailed: "The encrypted connection failed."
    case .cancelled: "The connection was cancelled."
    case .keychainFailure: "Secure storage is unavailable."
    }
  }
}

struct PaseoConnectionConfig: Codable, Equatable, Sendable {
  enum Mode: String, Codable, Sendable { case direct, relay }

  let mode: Mode
  let endpoint: String
  let useTLS: Bool
  let password: String?
  let serverID: String?
  let daemonPublicKeyBase64: String?

  var displayName: String { endpoint }

  func validated() throws -> Self {
    switch mode {
    case .direct:
      return try .direct(endpoint: endpoint, useTLS: useTLS, password: password)
    case .relay:
      _ = try validateHostPort(endpoint)
      guard let serverID, !serverID.isEmpty,
        let daemonPublicKeyBase64
      else { throw PaseoConnectionError.invalidPairingLink }
      _ = try PaseoRelayCrypto.validatePublicKey(daemonPublicKeyBase64)
      return self
    }
  }

  static func direct(endpoint: String, useTLS: Bool, password: String? = nil) throws -> Self {
    let normalized = try validateHostPort(endpoint)
    let credential = password
    if let credential, credential.contains("\r") || credential.contains("\n") {
      throw PaseoConnectionError.invalidEndpoint
    }
    return .init(
      mode: .direct, endpoint: normalized, useTLS: useTLS,
      password: credential?.isEmpty == true ? nil : credential,
      serverID: nil, daemonPublicKeyBase64: nil)
  }

  static func relay(pairingLink: String) throws -> Self {
    let trimmed = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URLComponents(string: trimmed),
      url.scheme == "https" || url.scheme == "http",
      let fragment = url.fragment, fragment.hasPrefix("offer=")
    else {
      throw PaseoConnectionError.invalidPairingLink
    }
    let encoded = String(fragment.dropFirst("offer=".count))
    guard !encoded.isEmpty,
      encoded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else {
      throw PaseoConnectionError.invalidPairingLink
    }
    var base64 = encoded.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let bytes = Data(base64Encoded: base64),
      let offer = try? JSONDecoder().decode(PairingOffer.self, from: bytes)
    else {
      throw PaseoConnectionError.invalidPairingLink
    }
    guard offer.v == 2 else { throw PaseoConnectionError.unsupportedPairingVersion }
    let endpoint = try validateHostPort(offer.relay.endpoint)
    let serverID = offer.serverId
    guard !serverID.isEmpty, !offer.daemonPublicKeyB64.isEmpty else {
      throw PaseoConnectionError.invalidPairingLink
    }
    _ = try PaseoRelayCrypto.validatePublicKey(offer.daemonPublicKeyB64)
    let port = URLComponents(string: "ws://\(endpoint)")?.port
    // COMPAT(relayTLS): old pairing offers omitted useTls; upstream uses TLS on port 443.
    let useTLS = offer.relay.useTls ?? (port == 443)
    return .init(
      mode: .relay, endpoint: endpoint, useTLS: useTLS,
      password: nil, serverID: serverID,
      daemonPublicKeyBase64: offer.daemonPublicKeyB64)
  }

  func webSocketURL() throws -> URL {
    let endpoint = try validateHostPort(endpoint)
    var components = URLComponents()
    components.scheme = useTLS ? "wss" : "ws"
    guard let validated = URLComponents(string: "ws://\(endpoint)") else {
      throw PaseoConnectionError.invalidEndpoint
    }
    components.host = validated.host
    components.port = validated.port
    components.path = "/ws"
    if mode == .relay {
      components.queryItems = [
        URLQueryItem(name: "serverId", value: serverID),
        URLQueryItem(name: "role", value: "client"),
        URLQueryItem(name: "v", value: "2"),
      ]
    }
    guard let url = components.url else { throw PaseoConnectionError.invalidEndpoint }
    return url
  }
}

private struct PairingOffer: Decodable {
  let v: Int
  let serverId: String
  let daemonPublicKeyB64: String
  let relay: Relay

  struct Relay: Decodable {
    let endpoint: String
    let useTls: Bool?
  }
}

private func validateHostPort(_ input: String) throws -> String {
  let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty,
    let components = URLComponents(string: "ws://\(trimmed)"),
    let host = components.host, !host.isEmpty,
    let port = components.port, (1...65535).contains(port),
    components.user == nil, components.password == nil,
    components.path.isEmpty, components.query == nil, components.fragment == nil
  else {
    throw PaseoConnectionError.invalidEndpoint
  }
  let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
  return "\(hostPart):\(port)"
}
