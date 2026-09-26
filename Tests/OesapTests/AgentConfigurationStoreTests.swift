import Foundation
import XCTest

@testable import Oesap

final class AgentConfigurationStoreTests: XCTestCase {
  func testConfigurationIsScopedToStableHostAndProject() {
    let defaults = UserDefaults(suiteName: "oesap-agent-store-\(UUID().uuidString)")!
    let store = AgentConfigurationStore(defaults: defaults)
    let configuration = RemoteAgentConfiguration(provider: "codex", model: "model-a")

    XCTAssertTrue(store.save(configuration, serverID: "host-A", projectID: "project-A"))
    XCTAssertEqual(
      store.configuration(serverID: "host-A", projectID: "project-A"), configuration)
    XCTAssertNil(store.configuration(serverID: "host-B", projectID: "project-A"))
    XCTAssertNil(store.configuration(serverID: "host-A", projectID: "project-B"))
    XCTAssertFalse(store.save(configuration, serverID: "unknown", projectID: "project-A"))
    XCTAssertFalse(store.save(configuration, serverID: "", projectID: "project-A"))
  }
}
