import Foundation

/// Versioned, untrusted notification route. IDs are opaque and never credentials.
struct AgentOpenIntent: Equatable, Sendable {
  let serverID: String
  let workspaceID: String
  let agentID: String
  let messageID: String?
  let permissionID: String?

  init?(url: URL) {
    let raw = url.absoluteString
    guard raw.utf8.count <= 512,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "agentslinger", components.host == "open",
      components.path.isEmpty, components.user == nil, components.password == nil,
      components.port == nil, components.fragment == nil,
      let query = components.percentEncodedQuery
    else { return nil }
    // Go net/url uses form query encoding: raw '+' means space; '%2B' means '+'.
    components.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%20")
    guard let items = components.queryItems else { return nil }
    let allowed: Set<String> = [
      "v", "serverId", "workspaceId", "agentId", "messageId", "permissionId",
    ]
    var values: [String: String] = [:]
    for item in items {
      guard allowed.contains(item.name), values[item.name] == nil,
        let value = item.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { return nil }
      values[item.name] = value
    }
    guard values["v"] == "1", let serverID = values["serverId"],
      let workspaceID = values["workspaceId"], let agentID = values["agentId"],
      values["messageId"] == nil || values["permissionId"] == nil
    else { return nil }
    self.serverID = serverID
    self.workspaceID = workspaceID
    self.agentID = agentID
    self.messageID = values["messageId"]
    self.permissionID = values["permissionId"]
  }
}

struct AgentOpenNavigation: Equatable {
  let id = UUID()
  let route: OesapRoute
}

struct AgentOpenHighlight: Equatable {
  enum Target: Equatable {
    case message(String)
    case permission(String)
  }
  let id = UUID()
  let agentID: String
  let target: Target
}
