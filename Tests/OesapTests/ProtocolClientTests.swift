import Foundation
import XCTest

@testable import Oesap

private actor FixturePaseoTransport: PaseoFrameTransport {
  private var inbound: [String] = []
  private var inboundWaiters: [CheckedContinuation<String, Error>] = []
  private var outbound: [String] = []
  private var outboundWaiters: [CheckedContinuation<String, Error>] = []
  private var closed = false

  func connect() async throws { closed = false }

  func send(_ text: String) async throws {
    if closed { throw FixtureTransportError.closed }
    if outboundWaiters.isEmpty {
      outbound.append(text)
    } else {
      outboundWaiters.removeFirst().resume(returning: text)
    }
  }

  func receive() async throws -> String {
    if !inbound.isEmpty { return inbound.removeFirst() }
    if closed { throw FixtureTransportError.closed }
    return try await withCheckedThrowingContinuation { inboundWaiters.append($0) }
  }

  func close() async {
    closed = true
    let incoming = inboundWaiters
    let outgoing = outboundWaiters
    inboundWaiters.removeAll()
    outboundWaiters.removeAll()
    for continuation in incoming {
      continuation.resume(throwing: FixtureTransportError.closed)
    }
    for continuation in outgoing {
      continuation.resume(throwing: FixtureTransportError.closed)
    }
  }

  func push(_ text: String) {
    guard !closed else { return }
    if inboundWaiters.isEmpty {
      inbound.append(text)
    } else {
      inboundWaiters.removeFirst().resume(returning: text)
    }
  }

  func nextSent() async throws -> String {
    if !outbound.isEmpty { return outbound.removeFirst() }
    if closed { throw FixtureTransportError.closed }
    return try await withCheckedThrowingContinuation { outboundWaiters.append($0) }
  }
}

private enum FixtureTransportError: Error {
  case closed
}

final class ProtocolClientTests: XCTestCase {
  func testProviderSnapshotAndIdempotentCreateWithInitialPrompt() async throws {
    let transport = FixturePaseoTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "oesap-create-fixture")
    try await connect(
      client, transport: transport,
      features:
        #"{"projectList":true,"stableProjectIdentity":true,"ownedSubscriptions":true,"selectiveAgentTimeline":true,"providersSnapshot":true,"providersSnapshotCwd":true,"creationLifecycle":true}"#
    )

    let providersTask = Task { try await client.listProviders(cwd: "/fixture/project") }
    let providersRequest = try await nextRequest(transport)
    XCTAssertEqual(
      providersRequest.message["type"] as? String, "get_providers_snapshot_request")
    XCTAssertEqual(providersRequest.message["cwd"] as? String, "/fixture/project")
    await transport.push(
      sessionFrame(
        type: "get_providers_snapshot_response",
        payload:
          #"{"requestId":"\#(providersRequest.requestID)","cwd":"/fixture/project","entries":[{"provider":"codex","status":"ready","enabled":true,"label":"Codex","models":[{"provider":"codex","id":"default-model","label":"Default model","isDefault":true},{"provider":"codex","id":"hidden","label":"Hidden","isSelectable":false}]},{"provider":"other","status":"unavailable","enabled":true,"error":"not installed"}],"generatedAt":"2026-09-25T00:00:00Z"}"#
      ))
    let providers = try await providersTask.value
    XCTAssertEqual(providers.map(\.id), ["codex", "other"])
    XCTAssertEqual(providers[0].models.map(\.id), ["default-model"])
    XCTAssertTrue(providers[0].models[0].isDefault)
    XCTAssertFalse(providers[1].available)

    let intent = PaseoAgentCreationIntent(
      idempotencyKey: "stable-intent-key", clientMessageID: "stable-message-id",
      provider: "codex", model: nil, cwd: "/fixture/project", initialPrompt: "Start work")
    let creating = Task { try await client.createAgent(intent) }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.message["type"] as? String, "agent.create.request")
    XCTAssertEqual(request.message["idempotencyKey"] as? String, "stable-intent-key")
    XCTAssertEqual(request.message["clientMessageId"] as? String, "stable-message-id")
    XCTAssertEqual(request.message["initialPrompt"] as? String, "Start work")
    XCTAssertNil(request.message["workspaceId"])
    let config = try XCTUnwrap(request.message["config"] as? [String: Any])
    XCTAssertEqual(config["provider"] as? String, "codex")
    XCTAssertEqual(config["cwd"] as? String, "/fixture/project")
    XCTAssertNil(config["model"])
    await transport.push(
      sessionFrame(
        type: "agent.create.response",
        payload:
          #"{"requestId":"\#(request.requestID)","agent":{"id":"created-agent","provider":"codex","cwd":"/fixture/project","model":null,"createdAt":"2026-09-25T00:00:00Z","updatedAt":"2026-09-25T00:00:00Z","lastUserMessageAt":"2026-09-25T00:00:00Z","status":"running","activeTurn":null,"capabilities":{},"currentModeId":null,"availableModes":[],"pendingPermissions":[],"persistence":null,"title":"Start work","labels":{}},"error":null,"creation":{"kind":"agent","idempotencyKey":"stable-intent-key","revision":2,"phase":"completed","workspaceId":"workspace-1","agentId":"created-agent","error":null}}"#
      ))
    let created = try await creating.value
    XCTAssertEqual(created.agent?.id, "created-agent")
    XCTAssertTrue(created.promptAccepted)
    XCTAssertFalse(created.safeToRestart)
    await client.disconnect()
  }

  func testCreatedAgentIsReturnedWhenPromptFails() async throws {
    let transport = FixturePaseoTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "oesap-failed-prompt")
    try await connect(
      client, transport: transport,
      features: #"{"creationLifecycle":true}"#)
    let intent = PaseoAgentCreationIntent(
      idempotencyKey: "same-key", clientMessageID: "same-message",
      provider: "codex", model: "model-a", cwd: "/fixture/project",
      initialPrompt: "Start work")
    let creating = Task { try await client.createAgent(intent) }
    let request = try await nextRequest(transport)
    await transport.push(
      sessionFrame(
        type: "agent.create.response",
        payload:
          #"{"requestId":"\#(request.requestID)","agent":{"id":"created-agent","provider":"codex","cwd":"/fixture/project","model":"model-a","createdAt":"2026-09-25T00:00:00Z","updatedAt":"2026-09-25T00:00:00Z","lastUserMessageAt":null,"status":"error","activeTurn":null,"capabilities":{},"currentModeId":null,"availableModes":[],"pendingPermissions":[],"persistence":null,"title":"Start work","labels":{}},"error":"prompt outcome unknown","creation":{"kind":"agent","idempotencyKey":"same-key","revision":4,"phase":"failed","workspaceId":"workspace-1","agentId":"created-agent","error":"prompt outcome unknown","failedStage":"prompt","outcomeUnknown":true}}"#
      ))
    let result = try await creating.value
    XCTAssertEqual(result.agent?.id, "created-agent")
    XCTAssertFalse(result.promptAccepted)
    XCTAssertFalse(result.safeToRestart)
    await client.disconnect()
  }
  func testHelloNegotiatesProviderVisibilityAndCorrelatedProjectThreadRequests() async throws {
    let transport = FixturePaseoTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "oesap-fixture")
    try await connect(client, transport: transport)

    let projectsTask = Task { try await client.listProjects() }
    let projectRequest = try await nextRequest(transport)
    XCTAssertEqual(projectRequest.message["type"] as? String, "project.list.request")
    await transport.push(
      sessionFrame(
        type: "project.list.response",
        payload: #"{"requestId":"wrong-request","projects":[]}"#
      ))
    await transport.push(
      sessionFrame(
        type: "project.list.response",
        payload:
          #"{"requestId":"\#(projectRequest.requestID)","projects":[{"projectId":"stable-project-id","projectKey":"separate-descriptor-key","projectDisplayName":"Fixture Project","projectCustomName":null,"projectRootPath":"/synthetic/project","projectKind":"git","futureProjectField":true}]}"#
      ))
    let projects = try await projectsTask.value
    XCTAssertEqual(projects.map(\.id), ["stable-project-id"])
    XCTAssertEqual(projects.first?.key, "separate-descriptor-key")

    let threadsTask = Task {
      try await client.listThreads(
        projectID: "stable-project-id",
        page: PaseoPageRequest(cursor: "opaque-page-cursor", limit: 25))
    }
    let threadsRequest = try await nextRequest(transport)
    XCTAssertEqual(threadsRequest.message["type"] as? String, "fetch_agents_request")
    let filter = try XCTUnwrap(threadsRequest.message["filter"] as? [String: Any])
    XCTAssertEqual(filter["projectKeys"] as? [String], ["stable-project-id"])
    XCTAssertEqual(filter["includeArchived"] as? Bool, false)
    let page = try XCTUnwrap(threadsRequest.message["page"] as? [String: Any])
    XCTAssertEqual(page["cursor"] as? String, "opaque-page-cursor")
    XCTAssertEqual(page["limit"] as? Int, 25)
    await transport.push(
      sessionFrame(
        type: "fetch_agents_response",
        payload:
          #"{"requestId":"\#(threadsRequest.requestID)","entries":[{"agent":{"id":"agent-1","provider":"future-provider","title":"Fixture thread","model":null,"status":"running","cwd":"/synthetic/project","createdAt":"2026-09-25T12:00:00.000Z","updatedAt":"2026-09-25T12:01:00.000Z","lastUserMessageAt":null,"pendingPermissions":[],"requiresAttention":false,"futureAgentField":true},"project":{"projectKey":"stable-project-id","projectName":"Fixture Project","checkout":{"kind":"directory","isGit":false,"cwd":"/synthetic/project","remoteUrl":null}}}],"pageInfo":{"nextCursor":"next-page","prevCursor":null,"hasMore":true}}"#
      ))
    let threads = try await threadsTask.value
    XCTAssertEqual(threads.items.first?.id, "agent-1")
    XCTAssertEqual(threads.items.first?.provider, "future-provider")
    XCTAssertEqual(threads.nextCursor, "next-page")
    XCTAssertTrue(threads.hasMore)

    let sendTask = Task { try await client.send(agentID: "agent-1", text: "Hello from fixture") }
    let sendRequest = try await nextRequest(transport)
    XCTAssertEqual(sendRequest.message["type"] as? String, "send_agent_message_request")
    XCTAssertEqual(sendRequest.message["agentId"] as? String, "agent-1")
    XCTAssertEqual(sendRequest.message["text"] as? String, "Hello from fixture")
    await transport.push(
      sessionFrame(
        type: "send_agent_message_response",
        payload:
          #"{"requestId":"\#(sendRequest.requestID)","agentId":"agent-1","accepted":true,"error":null}"#
      ))
    try await sendTask.value
    await client.disconnect()
  }

  func testTimelineHistoryPreservesOpaqueItemsAndGapMetadata() async throws {
    let transport = FixturePaseoTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "oesap-history-fixture")
    try await connect(client, transport: transport)

    let historyTask = Task {
      try await client.history(
        agentID: "agent-1", direction: .before,
        cursor: PaseoTimelineCursor(epoch: "epoch-a", sequence: 9), limit: 50)
    }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.message["type"] as? String, "fetch_agent_timeline_request")
    XCTAssertEqual(request.message["direction"] as? String, "before")
    XCTAssertEqual(request.message["limit"] as? Int, 50)
    let cursor = try XCTUnwrap(request.message["cursor"] as? [String: Any])
    XCTAssertEqual(cursor["epoch"] as? String, "epoch-a")
    XCTAssertEqual(cursor["seq"] as? Int, 9)

    await transport.push(
      sessionFrame(
        type: "fetch_agent_timeline_response",
        payload:
          #"{"requestId":"\#(request.requestID)","agentId":"agent-1","agent":null,"direction":"before","projection":"projected","epoch":"epoch-b","reset":true,"staleCursor":true,"gap":true,"window":{"minSeq":5,"maxSeq":7,"nextSeq":8},"startCursor":{"epoch":"epoch-b","seq":5},"endCursor":{"epoch":"epoch-b","seq":7},"hasOlder":true,"hasNewer":false,"entries":[{"provider":"codex","item":{"type":"future_timeline_item","text":"sanitized fixture","future":{"keep":true}},"timestamp":"2026-09-25T12:00:00.000Z","seqStart":7,"seqEnd":7,"sourceSeqRanges":[],"collapsed":[],"futureEntryField":"preserved"}],"error":null,"futureResponseField":true}"#
      ))
    let page = try await historyTask.value
    XCTAssertTrue(page.reset)
    XCTAssertTrue(page.staleCursor)
    XCTAssertTrue(page.gap)
    XCTAssertTrue(page.hasOlder)
    XCTAssertEqual(page.endCursor, PaseoTimelineCursor(epoch: "epoch-b", sequence: 7))
    XCTAssertEqual(page.entries.first?.id, "epoch-b:7-7")
    XCTAssertEqual(page.entries.first?.item["future"]?["keep"], .bool(true))
    await client.disconnect()
  }

  func testTimelineSubscriptionBuffersEarlyUpdatesAndReleasesOwnedStream() async throws {
    let transport = FixturePaseoTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "oesap-stream-fixture")
    try await connect(client, transport: transport)

    let eventsTask = Task {
      try await client.events(
        agentID: "agent-1", after: PaseoTimelineCursor(epoch: "epoch-a", sequence: 4))
    }
    let subscribeRequest = try await nextRequest(transport)
    XCTAssertEqual(
      subscribeRequest.message["type"] as? String, "agent.timeline.set_subscription.request")
    XCTAssertEqual(subscribeRequest.message["agentIds"] as? [String], ["agent-1"])
    await transport.push(
      sessionFrame(
        type: "agent.timeline.set_subscription.response",
        payload:
          #"{"requestId":"\#(subscribeRequest.requestID)","agentIds":["agent-1"],"subscriptionId":"owned-subscription-1"}"#
      ))
    await transport.push(
      sessionFrame(
        type: "agent_stream",
        payload:
          #"{"subscriptionId":"owned-subscription-1","agentId":"agent-1","event":{"type":"timeline","provider":"codex","item":{"type":"assistant_message","text":"sanitized"}},"timestamp":"2026-09-25T12:01:00.000Z","seq":6,"epoch":"epoch-a"}"#
      ))
    let stream = try await eventsTask.value
    var iterator = stream.makeAsyncIterator()
    let nextEvent = try await iterator.next()
    let first = try XCTUnwrap(nextEvent)
    guard
      case .reloadRequired(agentID: "agent-1", reason: .sequenceGap(expected: 5, received: 6)) =
        first
    else {
      return XCTFail("Expected a history reload event for the missing sequence")
    }

    let consumer = Task {
      do {
        for try await _ in stream {}
      } catch {}
    }
    consumer.cancel()
    _ = await consumer.result
    let release = try await nextRequest(transport)
    XCTAssertEqual(release.message["type"] as? String, "subscription.release.request")
    XCTAssertEqual(release.message["subscriptionId"] as? String, "owned-subscription-1")
    await client.disconnect()
  }

  func testPermissionAnswerWaitsForMatchingResolution() async throws {
    let transport = FixturePaseoTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "oesap-permission-fixture")
    try await connect(client, transport: transport)

    let answerTask = Task {
      try await client.answerPermission(
        agentID: "agent-1", requestID: "permission-1", decision: .allow(actionID: "allow-once"))
    }
    let answer = try await nextRequest(transport)
    XCTAssertEqual(answer.message["type"] as? String, "agent_permission_response")
    XCTAssertEqual(answer.requestID, "permission-1")
    let response = try XCTUnwrap(answer.message["response"] as? [String: Any])
    XCTAssertEqual(response["behavior"] as? String, "allow")
    XCTAssertEqual(response["selectedActionId"] as? String, "allow-once")
    await transport.push(
      sessionFrame(
        type: "agent_permission_resolved",
        payload:
          #"{"subscriptionId":"permissions-1","agentId":"agent-1","requestId":"permission-1","resolution":{"behavior":"allow","selectedActionId":"allow-once"}}"#
      ))
    try await answerTask.value
    await client.disconnect()
  }

  func testMissingProjectArrayAndUnavailableCapabilityAreErrors() async throws {
    let transport = FixturePaseoTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "oesap-error-fixture")
    try await connect(
      client, transport: transport,
      features:
        #"{"projectList":true,"stableProjectIdentity":true,"ownedSubscriptions":true,"selectiveAgentTimeline":true}"#
    )

    let projectsTask = Task { try await client.listProjects() }
    let projectRequest = try await nextRequest(transport)
    await transport.push(
      sessionFrame(
        type: "project.list.response",
        payload: #"{"requestId":"\#(projectRequest.requestID)"}"#
      ))
    do {
      _ = try await projectsTask.value
      XCTFail("A missing projects array must not be treated as an empty directory")
    } catch let error as PaseoProtocolError {
      XCTAssertEqual(error, .malformedMessage("project list omitted its projects array"))
    }

    let unsupportedTransport = FixturePaseoTransport()
    let unsupportedClient = PaseoProtocolClient(
      transport: unsupportedTransport, clientID: "oesap-old-daemon-fixture")
    try await connect(
      unsupportedClient, transport: unsupportedTransport,
      features:
        #"{"projectList":false,"stableProjectIdentity":false,"ownedSubscriptions":false,"selectiveAgentTimeline":false}"#
    )
    do {
      _ = try await unsupportedClient.listProjects()
      XCTFail("Project listing requires the advertised projectList feature")
    } catch let error as PaseoProtocolError {
      XCTAssertEqual(error, .unsupportedCapability("project listing"))
    }
    await client.disconnect()
    await unsupportedClient.disconnect()
  }

  func testJSONIntegerConversionRejectsFractionsAndOverflow() throws {
    let fraction = try JSONDecoder().decode(PaseoJSONValue.self, from: Data("1.5".utf8))
    let oversized = try JSONDecoder().decode(PaseoJSONValue.self, from: Data("1e100".utf8))
    let sequence = try JSONDecoder().decode(PaseoJSONValue.self, from: Data("12".utf8))
    XCTAssertNil(fraction.intValue)
    XCTAssertNil(oversized.intValue)
    XCTAssertEqual(sequence.intValue, 12)
  }

  private func connect(
    _ client: PaseoProtocolClient,
    transport: FixturePaseoTransport,
    features: String =
      #"{"projectList":true,"stableProjectIdentity":true,"ownedSubscriptions":true,"selectiveAgentTimeline":true,"futureFeature":{"version":2}}"#
  ) async throws {
    let connectionTask = Task { try await client.connect() }
    let hello =
      try JSONSerialization.jsonObject(with: Data((try await transport.nextSent()).utf8))
      as? [String: Any]
    XCTAssertEqual(hello?["type"] as? String, "hello")
    XCTAssertEqual(hello?["clientType"] as? String, "mobile")
    let capabilities = try XCTUnwrap(hello?["capabilities"] as? [String: Any])
    XCTAssertEqual(capabilities["all_providers"] as? Bool, true)
    XCTAssertEqual(capabilities["explicit_event_subscriptions"] as? Bool, true)
    XCTAssertEqual(capabilities["owned_subscriptions"] as? Bool, true)
    XCTAssertEqual(capabilities["selective_agent_timeline"] as? Bool, true)
    XCTAssertEqual(capabilities["timeline_notifications"] as? Bool, true)
    let serverInfoFrame =
      #"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"fixture-server","version":"0.9.2","hostname":"fixture-host","features":\#(features)}}}"#
    _ = try JSONSerialization.jsonObject(with: Data(serverInfoFrame.utf8))
    await transport.push(serverInfoFrame)
    let info = try await connectionTask.value
    XCTAssertEqual(info.serverID, "fixture-server")
    XCTAssertEqual(info.version, "0.9.2")
    XCTAssertNil(info.features["futureFeature"])
  }

  private func nextRequest(_ transport: FixturePaseoTransport) async throws -> (
    message: [String: Any], requestID: String
  ) {
    let frame =
      try JSONSerialization.jsonObject(with: Data((try await transport.nextSent()).utf8))
      as? [String: Any]
    let message = try XCTUnwrap(frame?["message"] as? [String: Any])
    let requestID = try XCTUnwrap(message["requestId"] as? String)
    return (message, requestID)
  }

  private func sessionFrame(type: String, payload: String) -> String {
    let frame = #"{"type":"session","message":{"type":"\#(type)","payload":\#(payload)}}"#
    guard (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) != nil else {
      XCTFail("Invalid JSON in the \(type) protocol fixture")
      return "{}"
    }
    return frame
  }
}
