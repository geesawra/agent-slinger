import Foundation
import XCTest

@testable import Oesap

private actor AgentSettingsFixtureTransport: PaseoFrameTransport {
  private var incoming: [String] = []
  private var incomingWaiters: [CheckedContinuation<String, Error>] = []
  private var outgoing: [String] = []
  private var outgoingWaiters: [CheckedContinuation<String, Error>] = []
  private var sentCount = 0

  func connect() async throws {}

  func send(_ text: String) async throws {
    sentCount += 1
    if outgoingWaiters.isEmpty {
      outgoing.append(text)
    } else {
      outgoingWaiters.removeFirst().resume(returning: text)
    }
  }

  func receive() async throws -> String {
    if !incoming.isEmpty { return incoming.removeFirst() }
    return try await withCheckedThrowingContinuation { incomingWaiters.append($0) }
  }

  func close() async {
    for waiter in incomingWaiters { waiter.resume(throwing: CancellationError()) }
    for waiter in outgoingWaiters { waiter.resume(throwing: CancellationError()) }
    incomingWaiters.removeAll()
    outgoingWaiters.removeAll()
  }

  func push(_ text: String) {
    if incomingWaiters.isEmpty {
      incoming.append(text)
    } else {
      incomingWaiters.removeFirst().resume(returning: text)
    }
  }

  func nextSent() async throws -> String {
    if !outgoing.isEmpty { return outgoing.removeFirst() }
    return try await withCheckedThrowingContinuation { outgoingWaiters.append($0) }
  }

  func numberSent() -> Int { sentCount }
}

final class AgentSettingsProtocolTests: XCTestCase {
  func testSettingsSnapshotUsesCorrelatedAgentAndNullableFields() async throws {
    let transport = AgentSettingsFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "settings-read")
    try await connect(client, transport: transport, features: [:])

    let loading = Task { try await client.agentSettings(agentID: "agent-1") }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.message["type"] as? String, "fetch_agent_request")
    XCTAssertEqual(request.message["agentId"] as? String, "agent-1")

    await reply(
      transport, type: "fetch_agent_response",
      payload: [
        "requestId": "different-request", "agent": NSNull(), "error": NSNull(),
      ])
    await reply(
      transport, type: "fetch_agent_response",
      payload: [
        "requestId": request.id,
        "agent": [
          "id": "agent-1", "provider": "codex", "cwd": "/fixture/repo",
          "status": "running", "model": NSNull(), "thinkingOptionId": "high",
          "effectiveThinkingOptionId": "medium", "currentModeId": "auto-review",
          "availableModes": [
            ["id": "auto", "label": "Default Permissions"],
            ["id": "auto-review", "label": "Auto-review", "description": "Automatic review"],
          ], "futureField": true,
        ],
        "error": NSNull(),
      ])
    let settings = try await loading.value
    XCTAssertEqual(settings.agentID, "agent-1")
    XCTAssertEqual(settings.provider, "codex")
    XCTAssertEqual(settings.cwd, "/fixture/repo")
    XCTAssertEqual(settings.status, "running")
    XCTAssertNil(settings.modelID)
    XCTAssertEqual(settings.thinkingOptionID, "high")
    XCTAssertEqual(settings.effectiveThinkingOptionID, "medium")
    XCTAssertEqual(settings.currentModeID, "auto-review")
    XCTAssertEqual(settings.availableModes.map(\.id), ["auto", "auto-review"])
    XCTAssertEqual(settings.availableModes[1].description, "Automatic review")
    await client.disconnect()
  }

  func testSettingsSnapshotRejectsMismatchedAgentIdentity() async throws {
    let transport = AgentSettingsFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "settings-identity")
    try await connect(client, transport: transport, features: [:])
    let loading = Task { try await client.agentSettings(agentID: "agent-1") }
    let request = try await nextRequest(transport)
    await reply(
      transport, type: "fetch_agent_response",
      payload: [
        "requestId": request.id,
        "agent": [
          "id": "agent-2", "provider": "codex", "cwd": "/fixture/repo",
          "status": "idle", "model": "model-a",
        ],
        "error": NSNull(),
      ])
    do {
      _ = try await loading.value
      XCTFail("A mismatched snapshot must not populate another agent's controls")
    } catch PaseoProtocolError.malformedMessage {
      // The response is correlated to this request but names the wrong agent.
    }
    await client.disconnect()
  }

  func testCompactProviderCatalogExpandsPerModelThinkingOptions() async throws {
    let transport = AgentSettingsFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "settings-catalog")
    try await connect(
      client, transport: transport,
      features: ["providersSnapshot": true, "providersSnapshotCwd": true])

    let loading = Task { try await client.listProviders(cwd: "/fixture/repo") }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.message["type"] as? String, "get_providers_snapshot_request")
    XCTAssertEqual(request.message["cwd"] as? String, "/fixture/repo")
    await reply(
      transport, type: "get_providers_snapshot_response",
      payload: [
        "requestId": request.id, "entries": [], "generatedAt": "2026-09-27T00:00:00Z",
        "compactSnapshot": [
          "entries": [
            [
              "provider": "codex", "status": "ready", "enabled": true,
              "models": [
                ["id": "model-a", "label": "Model A", "isDefault": true, "thinkingSet": 0],
                ["id": "hidden", "label": "Hidden", "isSelectable": false],
              ],
            ]
          ],
          "thinkingSets": [
            [
              "options": [
                ["id": "medium", "label": "Medium", "isDefault": true],
                ["id": "high", "label": "High", "description": "More reasoning"],
              ],
              "defaultOptionId": "medium",
            ]
          ],
        ],
      ])
    let providers = try await loading.value
    let provider = try XCTUnwrap(providers.first)
    XCTAssertEqual(provider.models.map(\.id), ["model-a"])
    XCTAssertEqual(provider.models[0].defaultThinkingOptionID, "medium")
    XCTAssertEqual(provider.models[0].thinkingOptions.map(\.id), ["medium", "high"])
    XCTAssertEqual(provider.models[0].thinkingOptions[1].description, "More reasoning")
    await client.disconnect()
  }

  func testApplyGateAndNullEncodingWithNotice() async throws {
    let oldTransport = AgentSettingsFixtureTransport()
    let oldClient = PaseoProtocolClient(transport: oldTransport, clientID: "settings-old")
    try await connect(oldClient, transport: oldTransport, features: [:])
    do {
      _ = try await oldClient.applyAgentSettings(
        agentID: "agent-1", modelID: nil, thinkingOptionID: nil)
      XCTFail("An old daemon must not receive the config RPC")
    } catch let error as PaseoProtocolError {
      XCTAssertEqual(error, .unsupportedCapability("agent settings update"))
    }
    let oldSentCount = await oldTransport.numberSent()
    XCTAssertEqual(oldSentCount, 1)
    await oldClient.disconnect()

    let transport = AgentSettingsFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "settings-apply")
    try await connect(
      client, transport: transport,
      features: ["agentConfigApply": true, "agentThinkingUpdate": true])
    let applying = Task {
      try await client.applyAgentSettings(
        agentID: "agent-1", modelID: nil, thinkingOptionID: nil)
    }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.message["type"] as? String, "agent.config.apply.request")
    XCTAssertEqual(request.message["agentId"] as? String, "agent-1")
    let config = try XCTUnwrap(request.message["config"] as? [String: Any])
    XCTAssertTrue(config["modelId"] is NSNull)
    XCTAssertTrue(config["thinkingOptionId"] is NSNull)
    await reply(
      transport, type: "agent.config.apply.response",
      payload: [
        "requestId": request.id, "agentId": "agent-1", "accepted": true,
        "error": NSNull(),
        "notice": ["type": "warning", "message": "Thinking level applies next turn"],
      ])
    let result = try await applying.value
    XCTAssertEqual(result.notice, "Thinking level applies next turn")
    await client.disconnect()
  }

  func testModelOnlyApplyOmitsThinkingAndSurfacesRejection() async throws {
    let transport = AgentSettingsFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "settings-model-only")
    try await connect(client, transport: transport, features: ["agentConfigApply": true])
    let applying = Task {
      try await client.applyAgentSettings(
        agentID: "agent-1", modelID: "model-b", thinkingOptionID: "high")
    }
    let request = try await nextRequest(transport)
    let config = try XCTUnwrap(request.message["config"] as? [String: Any])
    XCTAssertEqual(config["modelId"] as? String, "model-b")
    XCTAssertNil(config["thinkingOptionId"])
    await reply(
      transport, type: "agent.config.apply.response",
      payload: [
        "requestId": request.id, "agentId": "agent-1", "accepted": false,
        "error": "provider rejected model", "notice": NSNull(),
      ])
    do {
      _ = try await applying.value
      XCTFail("A rejected mutation must be visible to the caller")
    } catch let error as PaseoProtocolError {
      XCTAssertEqual(error, .requestRejected("provider rejected model"))
    }
    let sentCount = await transport.numberSent()
    XCTAssertEqual(sentCount, 2, "The adapter must not retry a mutation")
    await client.disconnect()
  }

  func testExplicitModelAndThinkingApplyUsesIDsAndChecksResponseAgent() async throws {
    let transport = AgentSettingsFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "settings-explicit")
    try await connect(
      client, transport: transport,
      features: ["agentConfigApply": true, "agentThinkingUpdate": true])

    let applying = Task {
      try await client.applyAgentSettings(
        agentID: "agent-1", modelID: "model-b", thinkingOptionID: "high",
        modeID: "auto-review")
    }
    let request = try await nextRequest(transport)
    let config = try XCTUnwrap(request.message["config"] as? [String: Any])
    XCTAssertEqual(config["modelId"] as? String, "model-b")
    XCTAssertEqual(config["thinkingOptionId"] as? String, "high")
    XCTAssertEqual(config["modeId"] as? String, "auto-review")
    await reply(
      transport, type: "agent.config.apply.response",
      payload: [
        "requestId": request.id, "agentId": "agent-1", "accepted": true,
        "error": NSNull(),
      ])
    let result = try await applying.value
    XCTAssertNil(result.notice)

    let wrongAgent = Task {
      try await client.applyAgentSettings(
        agentID: "agent-1", modelID: "model-a", thinkingOptionID: "medium")
    }
    let secondRequest = try await nextRequest(transport)
    await reply(
      transport, type: "agent.config.apply.response",
      payload: [
        "requestId": secondRequest.id, "agentId": "agent-2", "accepted": true,
        "error": NSNull(),
      ])
    do {
      _ = try await wrongAgent.value
      XCTFail("A mutation response for another agent must not be accepted")
    } catch PaseoProtocolError.malformedMessage {
      // Request correlation alone is insufficient when another agent ID is returned.
    }
    await client.disconnect()
  }

  func testModeOnlyApplyOmitsModelAndThinkingAndCorrelatesResponse() async throws {
    let transport = AgentSettingsFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "settings-mode-only")
    try await connect(client, transport: transport, features: ["agentConfigApply": true])
    let applying = Task {
      try await client.applyAgentMode(agentID: "agent-1", modeID: "full-access")
    }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.message["type"] as? String, "agent.config.apply.request")
    XCTAssertEqual(request.message["agentId"] as? String, "agent-1")
    let config = try XCTUnwrap(request.message["config"] as? [String: Any])
    XCTAssertEqual(Set(config.keys), ["modeId"])
    XCTAssertEqual(config["modeId"] as? String, "full-access")
    await reply(
      transport, type: "agent.config.apply.response",
      payload: [
        "requestId": "different-request", "agentId": "agent-1", "accepted": false,
        "error": "unrelated operation",
      ])
    await reply(
      transport, type: "agent.config.apply.response",
      payload: [
        "requestId": request.id, "agentId": "agent-1", "accepted": true,
        "error": NSNull(),
        "notice": ["type": "warning", "message": "Permission mode applies next turn"],
      ])
    let result = try await applying.value
    XCTAssertEqual(result.notice, "Permission mode applies next turn")
    await client.disconnect()
  }

  func testThinkingOnlyApplyOmitsModelAndEncodesDefaultAndMode() async throws {
    let transport = AgentSettingsFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "settings-thinking-only")
    try await connect(
      client, transport: transport,
      features: ["agentConfigApply": true, "agentThinkingUpdate": true])
    let applying = Task {
      try await client.applyAgentThinking(
        agentID: "agent-1", thinkingOptionID: nil, modeID: "auto-review")
    }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.message["type"] as? String, "agent.config.apply.request")
    let config = try XCTUnwrap(request.message["config"] as? [String: Any])
    XCTAssertEqual(Set(config.keys), ["thinkingOptionId", "modeId"])
    XCTAssertTrue(config["thinkingOptionId"] is NSNull)
    XCTAssertEqual(config["modeId"] as? String, "auto-review")
    await reply(
      transport, type: "agent.config.apply.response",
      payload: [
        "requestId": request.id, "agentId": "agent-1", "accepted": true,
        "error": NSNull(),
      ])
    let result = try await applying.value
    XCTAssertNil(result.notice)
    await client.disconnect()
  }

  private func connect(
    _ client: PaseoProtocolClient, transport: AgentSettingsFixtureTransport,
    features: [String: Bool]
  ) async throws {
    let connecting = Task { try await client.connect() }
    _ = try await transport.nextSent()
    await reply(
      transport, type: "status",
      payload: ["status": "server_info", "serverId": "settings-fixture", "features": features])
    _ = try await connecting.value
  }

  private func nextRequest(_ transport: AgentSettingsFixtureTransport) async throws -> (
    message: [String: Any], id: String
  ) {
    let sent = try await transport.nextSent()
    let frame = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
    let message = try XCTUnwrap(frame["message"] as? [String: Any])
    return (message, try XCTUnwrap(message["requestId"] as? String))
  }

  private func reply(
    _ transport: AgentSettingsFixtureTransport, type: String, payload: [String: Any]
  ) async {
    let frame: [String: Any] = [
      "type": "session", "message": ["type": type, "payload": payload],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: frame),
      let text = String(data: data, encoding: .utf8)
    else {
      XCTFail("Could not encode fixture frame")
      return
    }
    await transport.push(text)
  }
}
