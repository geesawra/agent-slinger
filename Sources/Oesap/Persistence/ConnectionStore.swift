import Foundation
import Security

/// Stores the entire connection record in the Keychain, including direct passwords.
struct ConnectionStore: Sendable {
  private let service = "com.oesap.app.connection"
  private let account = "current-host"

  func save(_ config: PaseoConnectionConfig) throws {
    let data = try JSONEncoder().encode(config.validated())
    let query = baseQuery()
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
    guard addStatus == errSecSuccess else {
      throw PaseoConnectionError.keychainFailure(addStatus)
    }
  }

  func load() throws -> PaseoConnectionConfig? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw PaseoConnectionError.keychainFailure(status)
    }
    return try JSONDecoder().decode(PaseoConnectionConfig.self, from: data).validated()
  }

  func clear() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PaseoConnectionError.keychainFailure(status)
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
