import Foundation
import XCTest

@testable import Oesap

final class AgentOpenIntentTests: XCTestCase {
  private let base = "agentslinger://open?v=1&serverId=host&workspaceId=workspace&agentId=agent"

  func testGoQueryEncodingPreservesOpaqueIdentifiersExactlyOnce() throws {
    let url = try XCTUnwrap(
      URL(
        string:
          "agentslinger://open?agentId=a%2Bb%252Fc&serverId=host+name&v=1&workspaceId=%E6%9D%B1%E4%BA%AC&messageId=m%26%3D"
      ))
    let intent = try XCTUnwrap(AgentOpenIntent(url: url))
    XCTAssertEqual(intent.serverID, "host name")
    XCTAssertEqual(intent.workspaceID, "東京")
    XCTAssertEqual(intent.agentID, "a+b%2Fc")
    XCTAssertEqual(intent.messageID, "m&=")
    XCTAssertNil(intent.permissionID)
  }

  func testRejectsUntrustedRoutesAndAmbiguousParameters() throws {
    let invalid = [
      base + "&agentId=other", base + "&%61gentId=other", base + "&token=secret",
      base + "&messageId=m&permissionId=p", base + "&messageId=", base + "&permissionId=%00",
      base + "#fragment", base.replacingOccurrences(of: "v=1", with: "v=2"),
      base.replacingOccurrences(of: "serverId=host", with: "serverId="),
      base.replacingOccurrences(of: "serverId=host", with: "serverId=+++"),
      base.replacingOccurrences(of: "//open?", with: "//user:password@open?"),
      base.replacingOccurrences(of: "//open?", with: "//open:42?"),
      base.replacingOccurrences(of: "//open?", with: "//open/path?"),
      base.replacingOccurrences(of: "agentslinger:", with: "https:"),
      base + "&messageId=" + String(repeating: "x", count: 512),
    ]
    for raw in invalid {
      let url = try XCTUnwrap(URL(string: raw))
      XCTAssertNil(AgentOpenIntent(url: url), raw)
    }
  }

  func testAcceptsSessionAndPermissionRoutes() throws {
    XCTAssertNotNil(AgentOpenIntent(url: try XCTUnwrap(URL(string: base))))
    let intent = AgentOpenIntent(url: try XCTUnwrap(URL(string: base + "&permissionId=request")))
    XCTAssertEqual(intent?.permissionID, "request")
  }
}
