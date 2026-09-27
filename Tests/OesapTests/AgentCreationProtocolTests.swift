import Foundation
import XCTest

@testable import Oesap

private actor AgentCreationFixtureTransport: PaseoFrameTransport {
  private var incoming: [String] = []
  private var incomingWaiters: [CheckedContinuation<String, Error>] = []
  private var outgoing: [String] = []
  private var outgoingWaiters: [CheckedContinuation<String, Error>] = []
  private var sentHistory: [String] = []
  private var closed = false

  func connect() async throws { closed = false }

  func send(_ text: String) async throws {
    guard !closed else { throw AgentCreationFixtureError.closed }
    sentHistory.append(text)
    if outgoingWaiters.isEmpty {
      outgoing.append(text)
    } else {
      outgoingWaiters.removeFirst().resume(returning: text)
    }
  }

  func receive() async throws -> String {
    if !incoming.isEmpty { return incoming.removeFirst() }
    guard !closed else { throw AgentCreationFixtureError.closed }
    return try await withCheckedThrowingContinuation { incomingWaiters.append($0) }
  }

  func close() async {
    closed = true
    let inbound = incomingWaiters
    let outbound = outgoingWaiters
    incomingWaiters.removeAll()
    outgoingWaiters.removeAll()
    for continuation in inbound { continuation.resume(throwing: AgentCreationFixtureError.closed) }
    for continuation in outbound { continuation.resume(throwing: AgentCreationFixtureError.closed) }
  }

  func push(_ text: String) {
    guard !closed else { return }
    if incomingWaiters.isEmpty {
      incoming.append(text)
    } else {
      incomingWaiters.removeFirst().resume(returning: text)
    }
  }

  func nextSent() async throws -> String {
    if !outgoing.isEmpty { return outgoing.removeFirst() }
    guard !closed else { throw AgentCreationFixtureError.closed }
    return try await withCheckedThrowingContinuation { outgoingWaiters.append($0) }
  }

  func sentCount() -> Int { sentHistory.count }
}

private enum AgentCreationFixtureError: Error {
  case closed
}

final class AgentCreationProtocolTests: XCTestCase {
  func testUnknownCreationReconcilesOnlyFromMatchingAgentSnapshot() async throws {
    let transport = AgentCreationFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "creation-reconcile")
    try await connect(client, transport: transport, features: ["creationLifecycle": true])

    let createTask = Task { try await client.createAgent(intent()) }
    let create = try await nextRequest(transport)
    XCTAssertEqual(create.type, "agent.create.request")
    XCTAssertEqual(create.fields["idempotencyKey"] as? String, "creation-key")

    await reply(
      transport,
      type: "agent.create.response",
      payload: [
        "requestId": create.requestID,
        "agent": NSNull(),
        "error": "prompt outcome unknown",
        "creation": creationSnapshot(
          key: "creation-key", phase: "failed", agentID: "reserved-agent",
          error: "prompt outcome unknown", failedStage: "prompt", outcomeUnknown: true),
      ])

    let lookup = try await nextRequest(transport)
    XCTAssertEqual(lookup.type, "fetch_agent_request")
    XCTAssertEqual(lookup.fields["agentId"] as? String, "reserved-agent")
    await reply(
      transport,
      type: "fetch_agent_response",
      payload: [
        "requestId": lookup.requestID,
        "agent": agentSnapshot(id: "different-agent"),
        "error": NSNull(),
      ])

    let result = try await createTask.value
    XCTAssertNil(result.agent, "a reserved ID is not an authoritative thread snapshot")
    XCTAssertFalse(result.promptAccepted)
    XCTAssertFalse(result.safeToRestart, "unknown prompt delivery must keep the original intent")
    await client.disconnect()
  }

  func testUnknownCreationAcceptsLookupOnlyWhenAgentIDMatches() async throws {
    let transport = AgentCreationFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "creation-match")
    try await connect(client, transport: transport, features: ["creationLifecycle": true])

    let createTask = Task { try await client.createAgent(intent()) }
    let create = try await nextRequest(transport)
    await reply(
      transport,
      type: "agent.create.response",
      payload: [
        "requestId": create.requestID,
        "agent": NSNull(),
        "error": "prompt outcome unknown",
        "creation": creationSnapshot(
          key: "creation-key", phase: "failed", agentID: "reserved-agent",
          error: "prompt outcome unknown", failedStage: "prompt", outcomeUnknown: true),
      ])

    let lookup = try await nextRequest(transport)
    await reply(
      transport,
      type: "fetch_agent_response",
      payload: [
        "requestId": lookup.requestID,
        "agent": agentSnapshot(id: "reserved-agent"),
        "error": NSNull(),
      ])

    let result = try await createTask.value
    XCTAssertEqual(result.agent?.id, "reserved-agent")
    XCTAssertFalse(result.promptAccepted, "the lookup proves creation, not prompt delivery")
    XCTAssertFalse(result.safeToRestart)
    await client.disconnect()
  }

  func testDefiniteAgentCreationFailureIsSafeToRestartWithoutLookup() async throws {
    let transport = AgentCreationFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "creation-definite-failure")
    try await connect(client, transport: transport, features: ["creationLifecycle": true])

    let createTask = Task { try await client.createAgent(intent()) }
    let create = try await nextRequest(transport)
    await reply(
      transport,
      type: "agent.create.response",
      payload: [
        "requestId": create.requestID,
        "agent": NSNull(),
        "error": "provider startup failed",
        "creation": creationSnapshot(
          key: "creation-key", phase: "failed", agentID: "reserved-agent",
          error: "provider startup failed", failedStage: "agent", outcomeUnknown: false),
      ])

    let result = try await createTask.value
    XCTAssertNil(result.agent, "the host only reserved this ID")
    XCTAssertFalse(result.promptAccepted)
    XCTAssertTrue(result.safeToRestart)
    let sentCount = await transport.sentCount()
    XCTAssertEqual(sentCount, 2, "only hello and create should be sent")
    await client.disconnect()
  }

  func testProviderSnapshotRequiresProjectContextCapability() async throws {
    let transport = AgentCreationFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "provider-context-gate")
    try await connect(client, transport: transport, features: ["providersSnapshot": true])

    do {
      _ = try await client.listProviders(cwd: "/fixture/project")
      XCTFail("Project provider discovery must be capability-gated")
    } catch let error as PaseoProtocolError {
      XCTAssertEqual(error, .unsupportedCapability("project-specific provider discovery"))
    }
    let sentCount = await transport.sentCount()
    XCTAssertEqual(sentCount, 1, "the unsupported operation sends no request")
    await client.disconnect()
  }

  func testImageOnlyCreationSerializesFirstPromptImages() async throws {
    let transport = AgentCreationFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "creation-image")
    try await connect(client, transport: transport, features: ["creationLifecycle": true])
    let image = PaseoImage(data: Data([1, 2, 3]), mimeType: "image/png")
    let task = Task {
      try await client.createAgent(
        PaseoAgentCreationIntent(
          idempotencyKey: "creation-image-key", clientMessageID: "image-message",
          provider: "codex", model: nil, cwd: "/fixture/project",
          initialPrompt: "", images: [image]))
    }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.type, "agent.create.request")
    XCTAssertEqual(request.fields["initialPrompt"] as? String, "")
    XCTAssertEqual(request.fields["clientMessageId"] as? String, "image-message")
    XCTAssertEqual(
      request.fields["images"] as? [[String: String]],
      [["data": "AQID", "mimeType": "image/png"]])
    await reply(
      transport, type: "agent.create.response",
      payload: [
        "requestId": request.requestID, "agent": NSNull(), "error": "provider startup failed",
        "creation": creationSnapshot(
          key: "creation-image-key", phase: "failed", agentID: "reserved-agent",
          error: "provider startup failed", failedStage: "agent", outcomeUnknown: false),
      ])
    _ = try await task.value
    await client.disconnect()
  }

  func testCreationLifecycleGatePreventsCreateMutation() async throws {
    let transport = AgentCreationFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "creation-gate")
    try await connect(client, transport: transport, features: ["projectList": true])

    do {
      _ = try await client.createAgent(intent())
      XCTFail("New thread creation must require the advertised lifecycle feature")
    } catch let error as PaseoProtocolError {
      XCTAssertEqual(error, .unsupportedCapability("new thread creation"))
    }
    let sentCount = await transport.sentCount()
    XCTAssertEqual(sentCount, 1, "only the hello handshake was sent")
    await client.disconnect()
  }

  private func intent() -> PaseoAgentCreationIntent {
    PaseoAgentCreationIntent(
      idempotencyKey: "creation-key", clientMessageID: "message-key", provider: "codex",
      model: "model-a", cwd: "/fixture/project", initialPrompt: "Inspect this project")
  }

  private func creationSnapshot(
    key: String,
    phase: String,
    agentID: String,
    error: String,
    failedStage: String,
    outcomeUnknown: Bool
  ) -> [String: Any] {
    [
      "kind": "agent", "idempotencyKey": key, "revision": 4, "phase": phase,
      "workspaceId": NSNull(), "agentId": agentID, "error": error,
      "failedStage": failedStage, "outcomeUnknown": outcomeUnknown,
    ]
  }

  private func agentSnapshot(id: String) -> [String: Any] {
    [
      "id": id, "provider": "codex", "cwd": "/fixture/project", "model": "model-a",
      "createdAt": "2026-09-25T12:00:00Z", "updatedAt": "2026-09-25T12:00:01Z",
      "lastUserMessageAt": NSNull(), "status": "error", "activeTurn": NSNull(),
      "capabilities": [String: Any](), "currentModeId": NSNull(),
      "availableModes": [Any](), "pendingPermissions": [Any](), "persistence": NSNull(),
      "title": "Inspect this project", "labels": [String: String](),
    ]
  }

  private func connect(
    _ client: PaseoProtocolClient,
    transport: AgentCreationFixtureTransport,
    features: [String: Bool]
  ) async throws {
    let task = Task { try await client.connect() }
    let hello =
      try JSONSerialization.jsonObject(with: Data((try await transport.nextSent()).utf8))
      as? [String: Any]
    XCTAssertEqual(hello?["type"] as? String, "hello")
    await reply(
      transport,
      type: "status",
      payload: [
        "status": "server_info", "serverId": "fixture-server", "version": "0.9.2",
        "features": features,
      ])
    _ = try await task.value
  }

  private func nextRequest(_ transport: AgentCreationFixtureTransport) async throws -> (
    type: String, requestID: String, fields: [String: Any]
  ) {
    let text = try await transport.nextSent()
    let envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let message = try XCTUnwrap(envelope["message"] as? [String: Any])
    return (
      try XCTUnwrap(message["type"] as? String),
      try XCTUnwrap(message["requestId"] as? String), message
    )
  }

  private func reply(
    _ transport: AgentCreationFixtureTransport, type: String, payload: [String: Any]
  ) async {
    do {
      let message: [String: Any] = ["type": type, "payload": payload]
      let envelope: [String: Any] = ["type": "session", "message": message]
      let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
      await transport.push(String(decoding: data, as: UTF8.self))
    } catch {
      XCTFail("Could not encode sanitized \(type) fixture: \(error)")
    }
  }
}
