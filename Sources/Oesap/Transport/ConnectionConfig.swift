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
  case transportFailure(ConnectionFailure)
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
    case .timedOut:
      "The connection timed out. Check that the host is reachable and Paseo is running, then retry."
    case .disconnected:
      "The connection closed without a reported cause. Reconnect and check the host if this repeats."
    case .transportFailure(let failure):
      "\(failure.summary) \(failure.recoverySuggestion)\n\(failure.diagnosticDescription)"
    case .malformedFrame: "The host sent an invalid message."
    case .encryptionFailed: "The encrypted connection failed."
    case .cancelled: "The connection was cancelled."
    case .keychainFailure(let status):
      switch status {
      case errSecMissingEntitlement:
        "This build is missing Keychain access entitlements (OSStatus \(status)). Rebuild with a development team and a matching provisioning profile."
      case errSecInteractionNotAllowed:
        "Secure storage is locked or interaction is unavailable (OSStatus \(status)). Unlock the device and try again."
      case errSecAuthFailed:
        "Secure storage access was denied (OSStatus \(status)). Unlock the device; if this continues, check the app’s signing and provisioning."
      default:
        "Secure storage is unavailable (OSStatus \(status)). Check the app’s signing and device security settings, then retry."
      }
    }
  }
}

/// A bounded, safe diagnostic value. Never retains NSError userInfo, endpoint,
/// password, pairing material, server close text, or message content.
struct ConnectionFailure: Equatable, Sendable {
  enum Phase: String, Sendable { case connect, relayHandshake, send, receive }
  enum Reason: String, Sendable {
    case dns, refused, cannotConnect, offline, tls, appTransportSecurity, timeout, authentication
    case httpUpgrade, connectionLost, closed, unknown
  }

  struct ErrorCode: Equatable, Sendable {
    let domain: String
    let code: Int

    init(domain: String, code: Int) {
      let knownDomains = [
        NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
        NSCocoaErrorDomain, "kCFErrorDomainCFNetwork",
      ]
      self.domain = knownDomains.contains(domain) ? domain : "OtherErrorDomain"
      self.code = code
    }

    static func capture(_ error: Error) -> [Self] {
      var result: [Self] = []
      var current: NSError? = error as NSError
      while let error = current, result.count < 3 {
        result.append(Self(domain: error.domain, code: error.code))
        current = error.userInfo[NSUnderlyingErrorKey] as? NSError
      }
      return result
    }
  }

  let phase: Phase
  let reason: Reason
  let causes: [ErrorCode]
  let httpStatus: Int?
  let webSocketCloseCode: Int?

  init(error: Error, phase: Phase, metadata: PaseoSocketFailureMetadata = .init()) {
    self.phase = phase
    let captured = (error as? PaseoConnectionError) == nil ? ErrorCode.capture(error) : []
    var codes = captured
    for code in metadata.causes where !codes.contains(code) && codes.count < 3 {
      codes.append(code)
    }
    causes = Array(codes.prefix(3))
    httpStatus = metadata.httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
    webSocketCloseCode = metadata.closeCode.flatMap { (1000...4999).contains($0) ? $0 : nil }
    reason = Self.classify(
      error: error, causes: causes, httpStatus: httpStatus,
      closeCode: webSocketCloseCode)
  }

  var summary: String {
    switch reason {
    case .dns: "The host name could not be resolved."
    case .refused: "The host refused the connection."
    case .cannotConnect: "Couldn’t connect to the host."
    case .offline: "No network path to the host is available."
    case .tls: "The secure connection could not be established."
    case .appTransportSecurity: "App Transport Security blocked this unencrypted connection."
    case .timeout: "The connection timed out."
    case .authentication: "The host rejected authentication."
    case .httpUpgrade: "The server did not accept the WebSocket connection."
    case .connectionLost: "The network connection was interrupted."
    case .closed: "The WebSocket connection closed."
    case .unknown: "The connection failed, but the system did not provide a recognized cause."
    }
  }

  var recoverySuggestion: String {
    switch reason {
    case .dns: "Check the host name and your Wi-Fi or VPN connection."
    case .refused, .cannotConnect:
      "Check the host and port, confirm Paseo is running, and check its firewall or VPN access."
    case .offline:
      "Check Wi-Fi or VPN connectivity and Local Network access in system settings."
    case .tls:
      "Check the TLS setting, the host’s certificate and secure port, and the device’s date."
    case .appTransportSecurity:
      "Use the host’s TLS endpoint, or a build with an explicit exception for this trusted private network."
    case .timeout:
      phase == .relayHandshake
        ? "Check that the paired daemon is online and the pairing link is current, then retry."
        : "Check that the host is reachable and Paseo is running, then retry."
    case .authentication: "Check the password or pairing link before reconnecting."
    case .httpUpgrade:
      "Check the host and port and any proxy’s WebSocket configuration."
    case .connectionLost, .closed:
      "Reconnect. If it happens again, check the network and the Paseo host’s logs."
    case .unknown:
      "Retry and use these diagnostic codes to check the connection logs."
    }
  }

  /// Only enum labels, allowlisted domains and numeric codes are included.
  var diagnosticDescription: String {
    var parts = ["Phase: \(phase.rawValue)", "Cause: \(reason.rawValue)"]
    parts += causes.map { "\($0.domain) \($0.code)" }
    if let httpStatus { parts.append("HTTP \(httpStatus)") }
    if let webSocketCloseCode { parts.append("WebSocket close \(webSocketCloseCode)") }
    return parts.joined(separator: " · ")
  }

  private static func classify(error: Error, causes: [ErrorCode], httpStatus: Int?, closeCode: Int?)
    -> Reason
  {
    if closeCode == 4401 || httpStatus == 401 || httpStatus == 403 { return .authentication }
    if (error as? PaseoConnectionError) == .timedOut { return .timeout }
    if (error as? PaseoConnectionError) == .authenticationFailed { return .authentication }
    if let httpStatus, httpStatus != 101 { return .httpUpgrade }
    if causes.contains(where: { $0.domain == NSPOSIXErrorDomain && $0.code == Int(ECONNREFUSED) }) {
      return .refused
    }
    for cause in causes
    where cause.domain == NSURLErrorDomain || cause.domain == "kCFErrorDomainCFNetwork" {
      switch cause.code {
      case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dns
      case NSURLErrorCannotConnectToHost: return .cannotConnect
      case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff:
        return .offline
      case NSURLErrorTimedOut: return .timeout
      case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired:
        return .tls
      case NSURLErrorAppTransportSecurityRequiresSecureConnection: return .appTransportSecurity
      case NSURLErrorUserAuthenticationRequired: return .authentication
      case NSURLErrorNetworkConnectionLost: return .connectionLost
      default: continue
      }
    }
    // HTTP 101 means the WebSocket upgrade succeeded. If a later socket error
    // has no more specific cause or close code, report a closed WebSocket,
    // rather than claiming the server rejected its upgrade.
    if httpStatus == 101 || closeCode != nil || (error as? PaseoConnectionError) == .disconnected {
      return .closed
    }
    return .unknown
  }
}

struct PaseoSocketFailureMetadata: Equatable, Sendable {
  var httpStatus: Int?
  var closeCode: Int?
  var causes: [ConnectionFailure.ErrorCode] = []
  var wasCancelled = false
}

extension PaseoConnectionError {
  var connectionFailure: ConnectionFailure? {
    if case .transportFailure(let failure) = self { return failure }
    return nil
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
