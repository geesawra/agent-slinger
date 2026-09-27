import Foundation
import XCTest

@testable import Oesap

final class ConnectionStoreTests: XCTestCase {
  func testLegacyCurrentHostMigratesToActiveSavedInstanceWithoutExposingCredentials() throws {
    let storage = MemoryConnectionStoreStorage()
    let legacy = try PaseoConnectionConfig.direct(
      endpoint: "legacy.example:6767", useTLS: true, password: "private-password")
    storage.seed(try JSONEncoder().encode(legacy), account: "current-host")
    let store = ConnectionStore(storage: storage)

    let records = try store.list()

    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].config, legacy)
    XCTAssertEqual(try store.activeID(), records[0].id)
    XCTAssertNil(storage.value(account: "current-host"))
    XCTAssertNotNil(storage.value(account: "saved-instances-v1"))
    XCTAssertFalse(records[0].summary.name.contains("private-password"))
    XCTAssertFalse(records[0].summary.subtitle.contains("private-password"))
  }

  func testMigrationLeavesLegacyCredentialWhenCollectionWriteFails() throws {
    let storage = MemoryConnectionStoreStorage()
    let legacy = try PaseoConnectionConfig.direct(
      endpoint: "legacy.example:6767", useTLS: false, password: "private-password")
    let legacyData = try JSONEncoder().encode(legacy)
    storage.seed(legacyData, account: "current-host")
    storage.setFailWrites(true)
    let store = ConnectionStore(storage: storage)

    XCTAssertThrowsError(try store.list())
    XCTAssertEqual(storage.value(account: "current-host"), legacyData)
    XCTAssertNil(storage.value(account: "saved-instances-v1"))
  }

  func testMigrationReturnsCommittedCollectionAndRetriesLegacyCleanup() throws {
    let storage = MemoryConnectionStoreStorage()
    let legacy = try PaseoConnectionConfig.direct(
      endpoint: "legacy.example:6767", useTLS: true, password: "private-password")
    storage.seed(try JSONEncoder().encode(legacy), account: "current-host")
    storage.setFailDeletes(true)
    let store = ConnectionStore(storage: storage)

    let migrated = try store.list()

    XCTAssertEqual(migrated.count, 1)
    XCTAssertNotNil(storage.value(account: "current-host"))
    XCTAssertNotNil(storage.value(account: "saved-instances-v1"))

    storage.setFailDeletes(false)
    XCTAssertEqual(try store.list().map(\.id), [migrated[0].id])
    XCTAssertNil(storage.value(account: "current-host"))
  }

  func testSavingDeduplicatesWithoutPasswordAndSelectionRemovalAreScoped() throws {
    let store = ConnectionStore(storage: MemoryConnectionStoreStorage())
    let firstConfig = try PaseoConnectionConfig.direct(
      endpoint: "first.example:6767", useTLS: true, password: "old-password")
    let changedCredential = try PaseoConnectionConfig.direct(
      endpoint: "first.example:6767", useTLS: true, password: "new-password")
    let secondConfig = try PaseoConnectionConfig.direct(
      endpoint: "second.example:6767", useTLS: false, password: "other-password")

    let first = try store.saveAndSelect(firstConfig, name: "  Work laptop  ")
    let updatedFirst = try store.saveAndSelect(changedCredential, name: "  ")
    let second = try store.saveAndSelect(secondConfig, name: "Home")

    XCTAssertEqual(updatedFirst.id, first.id)
    XCTAssertEqual(updatedFirst.name, "Work laptop")
    XCTAssertEqual(try store.list().count, 2)
    XCTAssertEqual(try store.activeID(), second.id)

    try store.select(id: first.id)
    try store.remove(id: second.id)
    XCTAssertEqual(try store.activeID(), first.id)
    XCTAssertEqual(try store.list().map(\.id), [first.id])

    try store.remove(id: first.id)
    XCTAssertNil(try store.activeID())
    XCTAssertTrue(try store.list().isEmpty)
  }
}

private final class MemoryConnectionStoreStorage: ConnectionStoreStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var failWrites = false
  private var failDeletes = false

  func data(forAccount account: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[account]
  }

  func write(_ data: Data, forAccount account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    if failWrites { throw TestStorageError.writeFailed }
    values[account] = data
  }

  func delete(account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    if failDeletes { throw TestStorageError.deleteFailed }
    values[account] = nil
  }

  func seed(_ data: Data, account: String) {
    lock.lock()
    defer { lock.unlock() }
    values[account] = data
  }

  func setFailWrites(_ fail: Bool) {
    lock.lock()
    defer { lock.unlock() }
    failWrites = fail
  }

  func setFailDeletes(_ fail: Bool) {
    lock.lock()
    defer { lock.unlock() }
    failDeletes = fail
  }

  func value(account: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[account]
  }
}

private enum TestStorageError: Error {
  case writeFailed
  case deleteFailed
}
