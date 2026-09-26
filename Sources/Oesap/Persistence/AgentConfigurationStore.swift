import Foundation

/// Oesap-only project settings. Paseo's project descriptor has no agent binding.
struct AgentConfigurationStore {
  private let defaults: UserDefaults
  private let key = "oesap.agentConfigurations.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func configuration(serverID: String, projectID: String) -> RemoteAgentConfiguration? {
    guard Self.valid(serverID), !projectID.isEmpty else { return nil }
    return read()[Self.scope(serverID: serverID, projectID: projectID)]
  }

  func save(
    _ configuration: RemoteAgentConfiguration, serverID: String, projectID: String
  ) -> Bool {
    guard Self.valid(serverID), !projectID.isEmpty,
      !configuration.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    var configurations = read()
    configurations[Self.scope(serverID: serverID, projectID: projectID)] = configuration
    guard let data = try? JSONEncoder().encode(configurations) else { return false }
    defaults.set(data, forKey: key)
    return true
  }

  private func read() -> [String: RemoteAgentConfiguration] {
    guard let data = defaults.data(forKey: key),
      let result = try? JSONDecoder().decode([String: RemoteAgentConfiguration].self, from: data)
    else { return [:] }
    return result
  }

  private static func valid(_ serverID: String) -> Bool {
    !serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && serverID != "unknown"
  }

  private static func scope(serverID: String, projectID: String) -> String {
    "\(serverID.utf8.count):\(serverID):\(projectID)"
  }
}
