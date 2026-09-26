import Foundation
import XCTest

@testable import Oesap

private actor UsageFixtureTransport: PaseoFrameTransport {
  private var incoming: [String] = []
  private var incomingWaiters: [CheckedContinuation<String, Error>] = []
  private var outgoing: [String] = []
  private var outgoingWaiters: [CheckedContinuation<String, Error>] = []

  func connect() async throws {}

  func send(_ text: String) async throws {
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
}

final class UsageProtocolTests: XCTestCase {
  func testProviderUsageGateAndCompleteResponseWithPartialNumericFields() async throws {
    let unsupportedTransport = UsageFixtureTransport()
    let unsupported = PaseoProtocolClient(transport: unsupportedTransport, clientID: "usage-old")
    try await connect(unsupported, transport: unsupportedTransport, features: "{}")
    let unsupportedCapability = await unsupported.supportsProviderUsage()
    XCTAssertFalse(unsupportedCapability)
    do {
      _ = try await unsupported.listProviderUsage()
      XCTFail("An old host must not receive the new RPC")
    } catch PaseoProtocolError.unsupportedCapability {
      // The capability gate rejects before sending a request.
    }
    await unsupported.disconnect()

    let transport = UsageFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "usage-supported")
    try await connect(
      client, transport: transport, features: #"{"providerUsageList":true}"#)
    let supportedCapability = await client.supportsProviderUsage()
    XCTAssertTrue(supportedCapability)
    let loading = Task { try await client.listProviderUsage() }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.message["type"] as? String, "provider.usage.list.request")
    XCTAssertEqual(Set(request.message.keys), ["type", "requestId"])
    await transport.push(
      frame(
        type: "provider.usage.list.response",
        payload:
          #"{"requestId":"\#(request.id)","fetchedAt":"2026-09-25T00:00:00Z","providers":[{"providerId":"codex","displayName":"Codex","status":"available","planLabel":"Pro","sourceLabel":"Host","windows":[{"id":"five_hour","label":"Five hours","usedPct":23,"remainingPct":77,"resetsAt":"2026-09-25T05:00:00Z","tone":"ok"},{"id":"weekly","label":"Weekly","usedPct":"invalid","remainingPct":null,"shortfallPct":-1,"tone":"future"}],"balances":[{"id":"credits","label":"Credits","used":12,"remaining":-3.5,"limit":50,"unit":"usd"}],"details":[{"id":"plan","label":"Plan","value":"Pro","tone":"default"}],"futureField":true},{"providerId":"claude","displayName":"Claude","status":"unavailable","planLabel":null,"windows":[]},{"providerId":"future","displayName":"Future","status":"new-status","planLabel":null,"windows":[]}] }"#
      ))
    let snapshot = try await loading.value
    XCTAssertEqual(snapshot.providers.count, 3)
    XCTAssertEqual(snapshot.providers[0].windows.count, 2)
    XCTAssertEqual(snapshot.providers[0].windows[0].usedPct, 23)
    XCTAssertNil(snapshot.providers[0].windows[1].usedPct)
    XCTAssertEqual(snapshot.providers[0].windows[1].shortfallPct, -1)
    XCTAssertEqual(snapshot.providers[0].balances[0].remaining, -3.5)
    XCTAssertEqual(snapshot.providers[2].status, "new-status")
    await client.disconnect()
  }

  func testAgentContextUsesOnlyReportedContextFields() async throws {
    let transport = UsageFixtureTransport()
    let client = PaseoProtocolClient(transport: transport, clientID: "context-fixture")
    try await connect(client, transport: transport, features: "{}")

    let loading = Task { try await client.agentContextUsage(agentID: "agent-1") }
    let request = try await nextRequest(transport)
    XCTAssertEqual(request.message["type"] as? String, "fetch_agent_request")
    XCTAssertEqual(request.message["agentId"] as? String, "agent-1")
    await transport.push(
      frame(
        type: "fetch_agent_response",
        payload:
          #"{"requestId":"\#(request.id)","agent":{"id":"agent-1","lastUsage":{"inputTokens":999999,"outputTokens":222,"contextWindowUsedTokens":64000,"contextWindowMaxTokens":200000}},"project":null,"error":null}"#
      ))
    let context = try await loading.value
    XCTAssertEqual(context.usedTokens, 64_000)
    XCTAssertEqual(context.maxTokens, 200_000)

    let partial = Task { try await client.agentContextUsage(agentID: "agent-1") }
    let next = try await nextRequest(transport)
    await transport.push(
      frame(
        type: "fetch_agent_response",
        payload:
          #"{"requestId":"\#(next.id)","agent":{"id":"agent-1","lastUsage":{"inputTokens":999999,"contextWindowUsedTokens":-1,"contextWindowMaxTokens":0}},"error":null}"#
      ))
    let partialUsage = try await partial.value
    XCTAssertNil(partialUsage.usedTokens)
    XCTAssertEqual(partialUsage.maxTokens, 0)
    await client.disconnect()
  }

  private func connect(
    _ client: PaseoProtocolClient, transport: UsageFixtureTransport, features: String
  ) async throws {
    let connecting = Task { try await client.connect() }
    _ = try await transport.nextSent()
    await transport.push(
      #"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"usage-fixture","features":\#(features)}}}"#
    )
    _ = try await connecting.value
  }

  private func nextRequest(_ transport: UsageFixtureTransport) async throws -> (
    message: [String: Any], id: String
  ) {
    let sent = try await transport.nextSent()
    let frame = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
    let message = try XCTUnwrap(frame["message"] as? [String: Any])
    return (message, try XCTUnwrap(message["requestId"] as? String))
  }

  private func frame(type: String, payload: String) -> String {
    #"{"type":"session","message":{"type":"\#(type)","payload":\#(payload)}}"#
  }
}
