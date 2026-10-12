import Foundation
import Security

/// The item kept in the Keychain for each host. Connection material stays in
/// this record and is never included in the user-facing instance summary.
struct StoredPaseoConnection: Codable, Equatable, Sendable {
  var id: String
  var name: String
  var config: PaseoConnectionConfig
  var serverID: String? = nil

  var summary: SavedPaseoInstance {
    let subtitle: String
    switch config.mode {
    case .direct:
      subtitle = "Direct · \(config.useTLS ? "TLS" : "No TLS") · \(config.endpoint)"
    case .relay:
      subtitle = "Relay · \(config.useTLS ? "TLS" : "No TLS") · \(config.endpoint)"
    }
    return SavedPaseoInstance(
      id: id,
      name: name,
      subtitle: subtitle,
      serverID: serverID ?? config.serverID)
  }
}

/// Small storage boundary so migration and collection behavior can be tested
/// without reading or writing a real Keychain.
protocol ConnectionStoreStorage: Sendable {
  func data(forAccount account: String) throws -> Data?
  func write(_ data: Data, forAccount account: String) throws
  func delete(account: String) throws
}

struct ConnectionStore: Sendable {
  private let storage: any ConnectionStoreStorage
  private let collectionAccount = "saved-instances-v1"
  private let legacyAccount = "current-host"

  init(storage: (any ConnectionStoreStorage)? = nil) {
    self.storage = storage ?? KeychainConnectionStoreStorage()
  }

  func list() throws -> [StoredPaseoConnection] {
    try readState().instances
  }

  func activeID() throws -> String? {
    try readState().activeInstanceID
  }

  func activeConnection() throws -> StoredPaseoConnection? {
    let state = try readState()
    guard let activeID = state.activeInstanceID else { return nil }
    return state.instances.first(where: { $0.id == activeID })
  }

  /// Adds or updates a host by its non-secret connection identity and makes it
  /// the selected host. A direct host's password is deliberately excluded from
  /// identity matching; relay identity uses its advertised server ID and key.
  @discardableResult
  func saveAndSelect(_ config: PaseoConnectionConfig, name: String) throws
    -> StoredPaseoConnection
  {
    let validated = try config.validated()
    var state = try readState()
    let record: StoredPaseoConnection
    if let index = state.instances.firstIndex(where: {
      Self.identity($0.config) == Self.identity(validated)
    }) {
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      record = StoredPaseoConnection(
        id: state.instances[index].id,
        name: trimmedName.isEmpty
          ? state.instances[index].name
          : trimmedName,
        config: validated, serverID: state.instances[index].serverID)
      state.instances[index] = record
    } else {
      record = StoredPaseoConnection(
        id: UUID().uuidString, name: Self.resolvedName(name, config: validated), config: validated)
      state.instances.append(record)
    }
    state.activeInstanceID = record.id
    try writeState(state)
    return record
  }

  func select(id: String) throws {
    var state = try readState()
    guard state.instances.contains(where: { $0.id == id }) else {
      throw RemoteServiceError.unavailable("That saved Paseo instance is no longer available.")
    }
    state.activeInstanceID = id
    try writeState(state)
  }

  /// Remember only identities observed after a successful authenticated handshake.
  func recordServerID(_ serverID: String?, for id: String) throws {
    guard let serverID, !serverID.isEmpty else { return }
    var state = try readState()
    guard let index = state.instances.firstIndex(where: { $0.id == id }) else { return }
    state.instances[index].serverID = serverID
    try writeState(state)
  }

  /// Removes exactly the requested saved record. Removing the active record
  /// leaves no selection; another host is never selected implicitly.
  func remove(id: String) throws {
    var state = try readState()
    guard let index = state.instances.firstIndex(where: { $0.id == id }) else { return }
    state.instances.remove(at: index)
    if state.activeInstanceID == id { state.activeInstanceID = nil }
    try writeState(state)
  }

  private struct State: Codable, Equatable, Sendable {
    var version = 1
    var instances: [StoredPaseoConnection] = []
    var activeInstanceID: String?
  }

  /// The new collection is committed before the legacy item is removed. If
  /// writing the collection fails, the old credential remains untouched.
  private func readState() throws -> State {
    if let data = try storage.data(forAccount: collectionAccount) {
      let state = try JSONDecoder().decode(State.self, from: data)
      // A prior migration may have committed the collection and then failed
      // while deleting the legacy item. It is safe to retry that cleanup.
      try? storage.delete(account: legacyAccount)
      return state
    }

    guard let legacyData = try storage.data(forAccount: legacyAccount) else {
      return State()
    }
    let legacy = try JSONDecoder().decode(PaseoConnectionConfig.self, from: legacyData)
      .validated()
    let record = StoredPaseoConnection(
      id: UUID().uuidString, name: Self.resolvedName("", config: legacy), config: legacy)
    let migrated = State(instances: [record], activeInstanceID: record.id)
    try writeCollection(migrated)
    // The collection is already committed; a failed cleanup is safe and will
    // be retried on a later read without hiding the migrated connection.
    try? storage.delete(account: legacyAccount)
    return migrated
  }

  private func writeState(_ state: State) throws {
    try writeCollection(state)
  }

  private func writeCollection(_ state: State) throws {
    try storage.write(JSONEncoder().encode(state), forAccount: collectionAccount)
  }

  private static func identity(_ config: PaseoConnectionConfig) -> String {
    switch config.mode {
    case .direct:
      return "direct:\(config.endpoint.utf8.count):\(config.endpoint):\(config.useTLS)"
    case .relay:
      let serverID = config.serverID ?? ""
      let publicKey = config.daemonPublicKeyBase64 ?? ""
      return "relay:\(serverID.utf8.count):\(serverID):\(publicKey.utf8.count):\(publicKey)"
    }
  }

  private static func resolvedName(_ proposed: String, config: PaseoConnectionConfig) -> String {
    let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty else { return trimmed }
    switch config.mode {
    case .direct:
      return config.endpoint
    case .relay:
      if let serverID = config.serverID, !serverID.isEmpty {
        return "Paseo relay \(serverID.prefix(8))"
      }
      return "Paseo relay"
    }
  }
}

private struct KeychainConnectionStoreStorage: ConnectionStoreStorage {
  private let service = "com.oesap.app.connection"

  func data(forAccount account: String) throws -> Data? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw PaseoConnectionError.keychainFailure(status)
    }
    return data
  }

  func write(_ data: Data, forAccount account: String) throws {
    let query = baseQuery(account: account)
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else {
      throw PaseoConnectionError.keychainFailure(status)
    }
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    if addStatus == errSecSuccess { return }
    if addStatus == errSecDuplicateItem {
      let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
      guard retryStatus == errSecSuccess else {
        throw PaseoConnectionError.keychainFailure(retryStatus)
      }
      return
    }
    throw PaseoConnectionError.keychainFailure(addStatus)
  }

  func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PaseoConnectionError.keychainFailure(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      // macOS uses the same protected keychain and device-only accessibility
      // semantics as iOS instead of the legacy file-based login keychain.
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
