import XCTest

@testable import Oesap

final class PaseoFeatureAdapterTests: XCTestCase {
  func testOverviewConnectionsCoalesceAndPromoteWithoutChangingSelectionDuringRefresh() async throws
  {
    let store = ConnectionStore(storage: MemoryConnectionStoreStorage())
    let first = try store.saveAndSelect(
      PaseoConnectionConfig.direct(endpoint: "one.example:6767", useTLS: true, password: ""),
      name: "Work")
    let second = try store.saveAndSelect(
      PaseoConnectionConfig.direct(endpoint: "two.example:6767", useTLS: true, password: ""),
      name: "Home")
    try store.select(id: first.id)
    let gate = AdapterTestGate()
    let firstClient = AdapterTestClient()
    let secondClient = AdapterTestClient(connectionGate: gate)
    let firstAdapter = PaseoRemoteServiceAdapter(client: firstClient)
    let secondAdapter = PaseoRemoteServiceAdapter(client: secondClient)
    let factory = PaseoConnectionFactory(store: store) { config in
      config.endpoint.hasPrefix("one.") ? firstAdapter : secondAdapter
    }
    _ = try await factory.selectSavedInstance(id: first.id)
    let connecting = Task { try await factory.connectForOverview(instanceID: second.id) }
    await gate.waitUntilEntered()
    let overlapping = Task { try await factory.connectForOverview(instanceID: second.id) }
    XCTAssertEqual(try store.activeID(), first.id)
    await gate.open()
    _ = try await connecting.value
    _ = try await overlapping.value
    let connections = await secondClient.connectionCount()
    XCTAssertEqual(connections, 1)
    let firstDisconnects = await firstClient.disconnectCount()
    XCTAssertEqual(firstDisconnects, 0)
    XCTAssertEqual(try store.activeID(), first.id)

    _ = try await factory.selectSavedInstance(id: second.id)
    let promotedConnections = await secondClient.connectionCount()
    XCTAssertEqual(promotedConnections, 1)
    await factory.disconnectOverviewServices()
    let promotedDisconnects = await secondClient.disconnectCount()
    XCTAssertEqual(promotedDisconnects, 0)
    XCTAssertEqual(try store.list().count, 2)
    _ = try await factory.connectForOverview(instanceID: second.id)
    let activeConnections = await secondClient.connectionCount()
    XCTAssertEqual(activeConnections, 1)
    try await factory.disconnect()
  }

  func testCancellingOverviewCallerCancelsAndClosesItsConnectionAttempt() async throws {
    let store = ConnectionStore(storage: MemoryConnectionStoreStorage())
    let record = try store.saveAndSelect(
      PaseoConnectionConfig.direct(endpoint: "one.example:6767", useTLS: true, password: ""),
      name: "Work")
    let gate = AdapterTestGate()
    let client = AdapterTestClient(connectionGate: gate)
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let factory = PaseoConnectionFactory(store: store) { _ in adapter }
    let connecting = Task { try await factory.connectForOverview(instanceID: record.id) }
    await gate.waitUntilEntered()
    connecting.cancel()
    await gate.open()
    do {
      _ = try await connecting.value
      XCTFail("A cancelled caller must not leave a connected overview service")
    } catch {}
    let connected = await adapter.isConnected()
    XCTAssertFalse(connected)
    _ = try await factory.connectForOverview(instanceID: record.id)
    let connections = await client.connectionCount()
    XCTAssertEqual(connections, 2)
    await factory.disconnectOverviewServices()
  }

  func testRemovingHostDuringOverviewConnectionClosesLateHandshake() async throws {
    let store = ConnectionStore(storage: MemoryConnectionStoreStorage())
    let record = try store.saveAndSelect(
      PaseoConnectionConfig.direct(endpoint: "one.example:6767", useTLS: true, password: ""),
      name: "Work")
    let gate = AdapterTestGate()
    let client = AdapterTestClient(connectionGate: gate)
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let factory = PaseoConnectionFactory(store: store) { _ in adapter }
    let connecting = Task { try await factory.connectForOverview(instanceID: record.id) }
    await gate.waitUntilEntered()
    try await factory.removeSavedInstance(id: record.id)
    await gate.open()
    do {
      _ = try await connecting.value
      XCTFail("A removed host must not return a late connected service")
    } catch {}
    let connected = await adapter.isConnected()
    XCTAssertFalse(connected)
    XCTAssertTrue(try store.list().isEmpty)
  }

  func testGitSnapshotMapsCountsAndRendersFileDiff() async throws {
    let adapter = PaseoRemoteServiceAdapter(client: AdapterTestClient())
    let status = try await adapter.gitStatus(cwd: "/fixture/worktree")
    XCTAssertEqual(status.additions, 1)
    XCTAssertEqual(status.deletions, 1)
    XCTAssertEqual(status.files.map(\.path), ["Sources/Example.swift"])
    XCTAssertEqual(
      status.diffByPath["Sources/Example.swift"],
      "diff --git a/Sources/Example.swift b/Sources/Example.swift\n--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -1,1 +1,1 @@\n-old\n+new"
    )
  }

  func testNonGitWorkspaceDoesNotRequestDiff() async throws {
    let client = AdapterTestClient(isGit: false)
    let adapter = PaseoRemoteServiceAdapter(client: client)
    do {
      _ = try await adapter.gitStatus(cwd: "/fixture/not-a-repo")
      XCTFail("A non-Git workspace cannot have a repository diff")
    } catch let error as RemoteServiceError {
      XCTAssertEqual(error.localizedDescription, "This agent is not in a Git repository.")
    }
    let diffCalls = await client.checkoutDiffCallCount()
    XCTAssertEqual(diffCalls, 0)
  }

  func testAgentControlForwardsIntentAndMapsStopSnapshot() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let supportsReceipts = await adapter.supportsAgentRequestReceipts()
    XCTAssertTrue(supportsReceipts)

    try await adapter.send(
      agentID: "agent-1", text: "Keep going", messageID: "immutable-id", behavior: .steer)
    let sent = await client.recordedSend()
    XCTAssertEqual(sent?.agentID, "agent-1")
    XCTAssertEqual(sent?.text, "Keep going")
    XCTAssertEqual(sent?.messageID, "immutable-id")
    XCTAssertEqual(sent?.behavior, .steer)

    let snapshot = try await adapter.stop(agentID: "agent-1")
    XCTAssertEqual(snapshot?.id, "agent-1")
    XCTAssertEqual(snapshot?.state, .idle)
    XCTAssertTrue(snapshot?.requiresAttention == true)
    XCTAssertEqual(snapshot?.attentionReason, "Review")
  }

  func testHistoryAndLiveMessagesKeepImageSourceTextAndClientReceiptIdentity() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let historyItem = PaseoTimelineEntry(
      id: "epoch-1:5-5", provider: "codex",
      item: .object([
        "type": .string("user_message"), "text": .string("See image"),
        "clientMessageId": .string("local-image-id"),
        "images": .array([.object(["futureField": .bool(true)])]),
      ]), turnID: nil, timestamp: "2026-09-25T12:30:45.123Z",
      startSequence: 5, endSequence: 5, collapsed: [])
    await client.setTimelinePages(tail: [toolPage([historyItem], end: 5)])
    let stream = try await adapter.events(agentID: "agent-1")
    let history = try await adapter.history(agentID: "agent-1", before: nil)
    XCTAssertEqual(history.messages.first?.clientMessageID, "local-image-id")
    XCTAssertEqual(
      history.messages.first?.images, [],
      "The daemon timeline does not retain submitted image bytes")

    let next = Task { () throws -> RemoteTimelineUpdate? in
      var iterator = stream.makeAsyncIterator()
      return try await iterator.next()
    }
    await client.emit(
      .item(
        agentID: "agent-1",
        event: .object([
          "type": .string("timeline"),
          "item": .object([
            "type": .string("assistant_message"),
            "text": .string("![chart](artifacts/chart.png)"),
            "messageId": .string("assistant-image"),
          ]),
        ]), timestamp: "2026-09-25T12:30:46Z", sequence: 6, epoch: "epoch-1"))
    guard case .message(let message, _, _) = try await next.value else {
      return XCTFail("Expected live assistant message")
    }
    XCTAssertEqual(message.text, "![chart](artifacts/chart.png)")
    await adapter.disconnect()
  }

  func testHistoryWatermarkDropsBufferedOverlapAndKeepsLaterLiveMessage() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let stream = try await adapter.events(agentID: "agent-1")
    let overlap = assistantEvent(sequence: 5, text: "already in history", messageID: "message-1")
    await client.emit(overlap)
    _ = try await adapter.history(agentID: "agent-1", before: nil)

    let nextUpdate = Task { () throws -> RemoteTimelineUpdate? in
      var iterator = stream.makeAsyncIterator()
      return try await iterator.next()
    }
    await client.emit(assistantEvent(sequence: 6, text: "new live text", messageID: "message-2"))
    guard case .message(let message, let cursor, let isDelta) = try await nextUpdate.value else {
      return XCTFail("Expected the new live timeline item")
    }

    XCTAssertEqual(message.id, "message-2")
    XCTAssertEqual(message.text, "new live text")
    XCTAssertEqual(cursor, RemoteTimelineCursor(epoch: "epoch-1", sequence: 6))
    XCTAssertTrue(isDelta)
    await adapter.disconnect()
  }

  func testInitialLiveSequenceGapRequestsHistoryReload() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let stream = try await adapter.events(agentID: "agent-1")
    _ = try await adapter.history(agentID: "agent-1", before: nil)

    let nextUpdate = Task { () throws -> RemoteTimelineUpdate? in
      var iterator = stream.makeAsyncIterator()
      return try await iterator.next()
    }
    await client.emit(assistantEvent(sequence: 7, text: "gap", messageID: "message-gap"))
    guard case .historyChanged = try await nextUpdate.value else {
      return XCTFail("A gap at stream startup must reload the authoritative timeline")
    }
    await adapter.disconnect()
  }

  func testAssistantChunksKeepTheirMessageIdentityAndAreMarkedAsDeltas() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let stream = try await adapter.events(agentID: "agent-1")
    _ = try await adapter.history(agentID: "agent-1", before: nil)

    let collected = Task { () throws -> [RemoteTimelineUpdate] in
      var iterator = stream.makeAsyncIterator()
      var updates: [RemoteTimelineUpdate] = []
      for _ in 0..<2 {
        if let update = try await iterator.next() { updates.append(update) }
      }
      return updates
    }
    await client.emit(assistantEvent(sequence: 6, text: "Hello ", messageID: "message-2"))
    await client.emit(assistantEvent(sequence: 7, text: "world", messageID: "message-2"))
    let updates = try await collected.value

    XCTAssertEqual(updates.count, 2)
    guard case .message(let first, let firstCursor, let firstIsDelta) = updates[0],
      case .message(let second, let secondCursor, let secondIsDelta) = updates[1]
    else {
      return XCTFail("Expected two streamed message chunks")
    }
    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(first.id, "message-2")
    XCTAssertEqual(first.text, "Hello ")
    XCTAssertEqual(second.text, "world")
    XCTAssertEqual(firstCursor?.sequence, 6)
    XCTAssertEqual(secondCursor?.sequence, 7)
    XCTAssertTrue(firstIsDelta)
    XCTAssertTrue(secondIsDelta)
    XCTAssertNotNil(first.timestamp, "Fractional ISO-8601 timestamps should parse")
    await adapter.disconnect()
  }

  func testPreSnapshotEventOverflowTerminatesSubscriptionWithRecoverableError() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let stream = try await adapter.events(agentID: "agent-1")
    await client.emitMany(
      (6...262).map { sequence in
        assistantEvent(sequence: sequence, text: "chunk", messageID: "message-\(sequence)")
      })
    let readerStopped = await waitForUpstreamTermination(client)
    guard readerStopped else {
      XCTFail("The adapter did not cancel the upstream timeline after overflow")
      await adapter.disconnect()
      return
    }

    var iterator = stream.makeAsyncIterator()
    do {
      _ = try await iterator.next()
      XCTFail("The adapter must terminate when its pre-snapshot queue overflows")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("while loading the timeline snapshot"))
    }
    await adapter.disconnect()
  }

  func testSlowTimelineConsumerGetsAnExplicitOverflowError() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let stream = try await adapter.events(agentID: "agent-1")
    _ = try await adapter.history(agentID: "agent-1", before: nil)
    await client.emitMany(
      (6...262).map { sequence in
        assistantEvent(sequence: sequence, text: "chunk", messageID: "message-\(sequence)")
      })
    let readerStopped = await waitForUpstreamTermination(client)
    guard readerStopped else {
      XCTFail("The adapter did not cancel the upstream timeline after overflow")
      await adapter.disconnect()
      return
    }

    var iterator = stream.makeAsyncIterator()
    var delivered = 0
    do {
      while try await iterator.next() != nil { delivered += 1 }
      XCTFail("The adapter must report when a slow consumer loses timeline updates")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("while delivering live updates"))
    }
    XCTAssertEqual(delivered, 256)
    await adapter.disconnect()
  }

  func testRepeatedThreadPageCursorFailsInsteadOfReturningPartialResults() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let thread = PaseoThread(
      id: "agent-1", title: "Thread", provider: "codex", model: nil, status: "idle",
      cwd: "/workspace", createdAt: "", updatedAt: "", archivedAt: nil,
      requiresAttention: false, attentionReason: nil, projectKey: "project-1",
      projectName: "Project", pendingPermissions: [])
    await client.setThreadPages([
      PaseoPage(items: [thread], nextCursor: "same", previousCursor: nil, hasMore: true),
      PaseoPage(items: [], nextCursor: "same", previousCursor: nil, hasMore: true),
    ])

    do {
      _ = try await adapter.threads(projectID: "project-1")
      XCTFail("Repeated cursors must not silently truncate project threads")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("invalid project thread page cursor"))
    }
    await adapter.disconnect()
  }

  func testThreadMappingPreservesActivityAndFallsBackForMissingOrMalformedDates() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let dates = [
      "2026-09-25T12:01:00.125Z", "2026-09-25T14:01:00+02:00", "invalid", "",
    ]
    let threads = dates.enumerated().map { index, updatedAt in
      PaseoThread(
        id: "agent-\(index)", title: "Thread", provider: "codex", model: nil, status: "running",
        cwd: "/workspace", createdAt: index == 3 ? "invalid" : "2026-09-25T12:00:00Z",
        updatedAt: updatedAt, archivedAt: nil, requiresAttention: false, attentionReason: nil,
        projectKey: "project-1", projectName: "Project")
    }
    await client.setThreadPages([
      PaseoPage(items: threads, nextCursor: nil, previousCursor: nil, hasMore: false)
    ])

    let mapped = try await adapter.threads(projectID: "project-1")
    let activity = try XCTUnwrap(mapped[0].lastActivityAt)
    let sameMinute = try XCTUnwrap(mapped[1].lastActivityAt)
    let created = try XCTUnwrap(mapped[2].lastActivityAt)
    XCTAssertEqual(activity.timeIntervalSince(sameMinute), 0.125, accuracy: 0.001)
    XCTAssertEqual(sameMinute.timeIntervalSince(created), 60)
    XCTAssertNil(mapped[3].lastActivityAt)
    await adapter.disconnect()
  }

  func testThreadMappingPreservesLifecycleAndAttentionIndependently() async throws {
    let client = AdapterTestClient()
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let fixtures: [(String, String, Bool)] = [
      ("running-attention", "running", true),
      ("error-attention", "error", true),
      ("starting", "initializing", false),
      ("closed", "closed", false),
    ]
    let threads = fixtures.map { fixture in
      let (id, status, requiresAttention) = fixture
      return PaseoThread(
        id: id, title: id, provider: "codex", model: nil, status: status,
        cwd: "/workspace", createdAt: "", updatedAt: "", archivedAt: nil,
        requiresAttention: requiresAttention,
        attentionReason: requiresAttention ? "approval needed" : nil,
        projectKey: "project-1", projectName: "Project", pendingPermissions: [])
    }
    await client.setThreadPages([
      PaseoPage(items: threads, nextCursor: nil, previousCursor: nil, hasMore: false)
    ])

    let mapped = try await adapter.threads(projectID: "project-1")
    XCTAssertEqual(mapped.map(\.state), [.running, .failed, .initializing, .closed])
    XCTAssertEqual(mapped.map(\.requiresAttention), [true, true, false, false])
    XCTAssertEqual(mapped[0].attentionReason, "approval needed")
    XCTAssertEqual(mapped[1].attentionReason, "approval needed")
    await adapter.disconnect()
  }

  func testTerminalContextReportsUseOnlyContextFieldsAndRefreshPartialSnapshots() async throws {
    let client = AdapterTestClient()
    await client.setTimelinePages(tail: [toolPage([], end: 5)])
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let stream = try await adapter.events(agentID: "agent-1")
    _ = try await adapter.history(agentID: "agent-1", before: nil)
    let reading = Task { () throws -> [RemoteTimelineUpdate] in
      var iterator = stream.makeAsyncIterator()
      var updates: [RemoteTimelineUpdate] = []
      for _ in 0..<7 {
        guard let update = try await iterator.next() else {
          throw RemoteServiceError.unavailable("A terminal usage update was missing")
        }
        updates.append(update)
      }
      return updates
    }
    await client.emit(
      usageEvent(
        sequence: 6,
        usage: [
          "contextWindowUsedTokens": .number(25), "contextWindowMaxTokens": .number(100),
          "inputTokens": .number(9_999),
        ]))
    await client.emit(
      usageEvent(
        sequence: 7,
        usage: [
          "contextWindowUsedTokens": .number(30), "contextWindowMaxTokens": .number(0),
          "inputTokens": .number(99_999),
        ]))
    await client.emit(usageEvent(sequence: 8, usage: ["inputTokens": .number(999_999)]))
    let updates = try await reading.value

    guard case .contextUsage(let complete) = updates[1],
      case .contextUsage(let partial) = updates[3],
      case .contextUsageNeedsRefresh = updates[4],
      case .contextUsageNeedsRefresh = updates[6]
    else { return XCTFail("Expected complete context followed by partial snapshot refreshes") }
    XCTAssertEqual(complete.usedTokens, 25)
    XCTAssertEqual(complete.maxTokens, 100)
    XCTAssertEqual(partial.usedTokens, 30)
    XCTAssertNil(partial.maxTokens, "Zero is not a valid gauge denominator")
    await adapter.disconnect()
  }

  func testProjectedHistoryCoalescesLifecyclePerTurnAndCallID() async throws {
    let client = AdapterTestClient()
    let first = toolEntry(
      sequence: 3, turnID: "turn-A", callID: "shared", status: "completed",
      detail: ["type": .string("read"), "filePath": .string("/fixture/a.swift")])
    let running = toolEntry(
      sequence: 5, turnID: "turn-B", callID: "shared", status: "running",
      detail: ["type": .string("shell"), "command": .string("printf ready")])
    let completed = toolEntry(
      sequence: 6, turnID: "turn-B", callID: "shared", status: "completed",
      detail: [
        "type": .string("shell"), "output": .string("ready"), "exitCode": .number(0),
      ])
    await client.setTimelinePages(tail: [toolPage([first, running, completed], end: 6)])
    let adapter = PaseoRemoteServiceAdapter(client: client)

    let history = try await adapter.history(agentID: "agent-1", before: nil)
    XCTAssertEqual(history.messages.count, 2)
    XCTAssertEqual(history.messages.map(\.toolCall?.callID), ["shared", "shared"])
    XCTAssertNotEqual(history.messages[0].id, history.messages[1].id)
    XCTAssertEqual(history.messages[0].toolCall?.turnID, "turn-A")
    XCTAssertEqual(history.messages[1].toolCall?.turnID, "turn-B")
    XCTAssertEqual(history.messages[1].toolCall?.status, .completed)
    XCTAssertEqual(history.messages[1].toolCall?.command, "printf ready")
    XCTAssertEqual(history.messages[1].toolCall?.sections.first?.content, "ready")
    XCTAssertEqual(history.messages[1].timestamp, Self.fixtureDate)
    await adapter.disconnect()
  }

  func testLiveToolSnapshotsMergeSparseDetailsAndStickyTerminalStatus() async throws {
    let client = AdapterTestClient()
    let running = toolEntry(
      sequence: 5, turnID: "turn-A", callID: "call-1", status: "running",
      detail: [
        "type": .string("shell"), "command": .string("printf ready"),
        "cwd": .string("/fixture"),
      ])
    await client.setTimelinePages(tail: [toolPage([running], end: 5)])
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let stream = try await adapter.events(agentID: "agent-1")
    _ = try await adapter.history(agentID: "agent-1", before: nil)

    let collected = Task { () throws -> [RemoteMessage] in
      var iterator = stream.makeAsyncIterator()
      var messages: [RemoteMessage] = []
      for _ in 0..<2 {
        guard case .message(let message, _, let isDelta) = try await iterator.next() else {
          throw RemoteServiceError.unavailable("Missing tool update")
        }
        XCTAssertFalse(isDelta)
        messages.append(message)
      }
      return messages
    }
    await client.emit(
      toolEvent(
        sequence: 6, turnID: "turn-A", callID: "call-1", status: "completed",
        detail: [
          "type": .string("shell"), "output": .string("ready"), "exitCode": .number(0),
        ]))
    await client.emit(
      toolEvent(
        sequence: 7, turnID: "turn-A", callID: "call-1", status: "running",
        detail: ["type": .string("shell"), "command": .string("printf ready")]))
    let messages = try await collected.value
    XCTAssertEqual(messages.map(\.id), [messages[0].id, messages[0].id])
    XCTAssertEqual(messages[0].toolCall?.status, .completed)
    XCTAssertEqual(messages[1].toolCall?.status, .completed)
    XCTAssertEqual(messages[1].toolCall?.cwd, "/fixture")
    XCTAssertEqual(messages[1].toolCall?.sections.first?.content, "ready")
    XCTAssertFalse(messages[1].text.contains("{\"type\""))
    await adapter.disconnect()
  }

  func testTailRefreshBuffersLiveToolRevisionBeforeReseedingSnapshot() async throws {
    let gate = AdapterTestGate()
    let client = AdapterTestClient()
    let running = toolEntry(
      sequence: 5, turnID: "turn-A", callID: "call-1", status: "running",
      detail: ["type": .string("shell"), "command": .string("printf ready")])
    let stalePage = toolPage([running], end: 5)
    await client.setTimelinePages(
      tail: [stalePage, stalePage], gate: gate, gatedTailCall: 2)
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let stream = try await adapter.events(agentID: "agent-1")
    _ = try await adapter.history(agentID: "agent-1", before: nil)

    let refreshing = Task { try await adapter.history(agentID: "agent-1", before: nil) }
    await gate.waitUntilEntered()
    await client.emit(
      toolEvent(
        sequence: 6, turnID: "turn-A", callID: "call-1", status: "completed",
        detail: ["type": .string("shell"), "output": .string("ready")]))
    var buffered = false
    for _ in 0..<100 {
      if await adapter.bufferedUpdateCountForTesting(agentID: "agent-1") == 1 {
        buffered = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(buffered, "The live completion must be held while the tail refresh is in flight")
    await gate.open()
    _ = try await refreshing.value

    var iterator = stream.makeAsyncIterator()
    guard case .message(let completed, _, _) = try await iterator.next() else {
      return XCTFail("Buffered completion was not delivered")
    }
    XCTAssertEqual(completed.toolCall?.status, .completed)
    await client.emit(
      toolEvent(
        sequence: 7, turnID: "turn-A", callID: "call-1", status: "running",
        detail: ["type": .string("shell"), "command": .string("printf ready")]))
    guard case .message(let later, _, _) = try await iterator.next() else {
      return XCTFail("Later tool revision was not delivered")
    }
    XCTAssertEqual(later.toolCall?.status, .completed)
    XCTAssertEqual(later.toolCall?.sections.first?.content, "ready")
    await adapter.disconnect()
  }

  func testOlderPageDoesNotReplaceNewerToolCache() async throws {
    let client = AdapterTestClient()
    let completed = toolEntry(
      sequence: 5, turnID: "turn-B", callID: "shared", status: "completed",
      detail: ["type": .string("shell"), "command": .string("done"), "output": .string("ok")])
    let oldRunning = toolEntry(
      sequence: 2, turnID: "turn-B", callID: "shared", status: "running",
      detail: ["type": .string("shell"), "command": .string("done")])
    let oldOther = toolEntry(
      sequence: 1, turnID: "turn-A", callID: "shared", status: "completed",
      detail: ["type": .string("read"), "filePath": .string("/fixture/a.swift")])
    await client.setTimelinePages(
      tail: [toolPage([completed], end: 5, hasOlder: true)],
      older: toolPage([oldOther, oldRunning], end: 2))
    let adapter = PaseoRemoteServiceAdapter(client: client)
    let stream = try await adapter.events(agentID: "agent-1")
    let tail = try await adapter.history(agentID: "agent-1", before: nil)
    let older = try await adapter.history(
      agentID: "agent-1", before: .init(epoch: "epoch-1", sequence: 5))
    XCTAssertEqual(tail.messages.count, 1)
    XCTAssertEqual(older.messages.count, 2)
    XCTAssertNotEqual(older.messages[0].id, tail.messages[0].id)
    XCTAssertEqual(older.messages[1].id, tail.messages[0].id)

    await client.emit(
      toolEvent(
        sequence: 6, turnID: "turn-B", callID: "shared", status: "running",
        detail: ["type": .string("shell"), "command": .string("done")]))
    var iterator = stream.makeAsyncIterator()
    guard case .message(let latest, _, _) = try await iterator.next() else {
      return XCTFail("Expected the live tool revision")
    }
    XCTAssertEqual(latest.toolCall?.status, .completed)
    XCTAssertEqual(latest.toolCall?.sections.first?.content, "ok")
    await adapter.disconnect()
  }

  private static let fixtureDate: Date = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: "2026-09-25T12:30:45.123Z") ?? .distantPast
  }()

  private func toolEntry(
    sequence: Int, turnID: String, callID: String, status: String,
    detail: [String: PaseoJSONValue]
  ) -> PaseoTimelineEntry {
    PaseoTimelineEntry(
      id: "epoch-1:\(sequence)-\(sequence)", provider: "codex",
      item: toolItem(callID: callID, status: status, detail: detail),
      turnID: turnID, timestamp: "2026-09-25T12:30:45.123Z",
      startSequence: sequence, endSequence: sequence, collapsed: [])
  }

  private func toolPage(
    _ entries: [PaseoTimelineEntry], end: Int, hasOlder: Bool = false
  ) -> PaseoTimelinePage {
    PaseoTimelinePage(
      agentID: "agent-1", epoch: "epoch-1", entries: entries,
      startCursor: .init(epoch: "epoch-1", sequence: entries.first?.startSequence ?? end),
      endCursor: .init(epoch: "epoch-1", sequence: end),
      hasOlder: hasOlder, hasNewer: false, reset: false, staleCursor: false, gap: false)
  }

  private func toolEvent(
    sequence: Int, turnID: String, callID: String, status: String,
    detail: [String: PaseoJSONValue]
  ) -> PaseoTimelineEvent {
    .item(
      agentID: "agent-1",
      event: .object([
        "type": .string("timeline"), "turnId": .string(turnID),
        "item": toolItem(callID: callID, status: status, detail: detail),
      ]),
      timestamp: "2026-09-25T12:30:46.123Z", sequence: sequence, epoch: "epoch-1")
  }

  private func usageEvent(
    sequence: Int, usage: [String: PaseoJSONValue]
  ) -> PaseoTimelineEvent {
    .item(
      agentID: "agent-1",
      event: .object([
        "type": .string("turn_completed"), "provider": .string("codex"),
        "usage": .object(usage),
      ]),
      timestamp: "2026-09-25T12:30:46.123Z", sequence: sequence, epoch: "epoch-1")
  }

  private func toolItem(
    callID: String, status: String, detail: [String: PaseoJSONValue]
  ) -> PaseoJSONValue {
    .object([
      "type": .string("tool_call"), "callId": .string(callID), "name": .string("Bash"),
      "status": .string(status), "error": .null, "detail": .object(detail),
    ])
  }

  private func waitForUpstreamTermination(_ client: AdapterTestClient) async -> Bool {
    let signal = await client.sourceTerminationSignal()
    let terminated = expectation(description: "The adapter cancels the upstream timeline reader")
    let waiter = Task {
      var iterator = signal.makeAsyncIterator()
      if await iterator.next() != nil { terminated.fulfill() }
    }
    let result = await XCTWaiter.fulfillment(of: [terminated], timeout: 5)
    waiter.cancel()
    return result == .completed
  }

  private func assistantEvent(sequence: Int, text: String, messageID: String) -> PaseoTimelineEvent
  {
    .item(
      agentID: "agent-1",
      event: .object([
        "type": .string("timeline"),
        "item": .object([
          "type": .string("assistant_message"),
          "text": .string(text),
          "messageId": .string(messageID),
        ]),
      ]),
      timestamp: "2026-09-25T12:30:45.123Z",
      sequence: sequence,
      epoch: "epoch-1"
    )
  }
}

private actor AdapterTestClient: PaseoService {
  struct SentIntent: Sendable {
    let agentID: String
    let text: String
    let messageID: String
    let behavior: PaseoActiveTurnBehavior
  }

  private var sentIntent: SentIntent?
  private let isGit: Bool
  private let connectionGate: AdapterTestGate?
  private var connections = 0
  private var disconnects = 0
  private var checkoutDiffCalls = 0
  private var continuation: AsyncThrowingStream<PaseoTimelineEvent, Error>.Continuation?
  private var threadPages: [PaseoPage<PaseoThread>] = []
  private var sourceTermination: AsyncStream<Void>?
  private var tailPages: [PaseoTimelinePage] = []
  private var olderPage: PaseoTimelinePage?
  private var tailCalls = 0
  private var historyGate: AdapterTestGate?
  private var gatedTailCall = Int.max

  init(isGit: Bool = true, connectionGate: AdapterTestGate? = nil) {
    self.isGit = isGit
    self.connectionGate = connectionGate
  }

  func connectionCount() -> Int { connections }
  func disconnectCount() -> Int { disconnects }

  func checkoutDiffCallCount() -> Int { checkoutDiffCalls }

  func connect() async throws -> PaseoConnectionInfo {
    connections += 1
    await connectionGate?.wait()
    return PaseoConnectionInfo(serverID: "test", features: [:])
  }

  func connectionEvents() async -> AsyncStream<PaseoConnectionState> {
    AsyncStream { $0.yield(.connected(PaseoConnectionInfo(serverID: "test", features: [:]))) }
  }

  func listProjects() async throws -> [PaseoProject] { [] }

  func checkoutStatus(cwd: String) async throws -> PaseoCheckoutStatus {
    PaseoCheckoutStatus(
      cwd: cwd, isGit: isGit, isPaseoOwnedWorktree: false,
      repoRoot: isGit ? cwd : nil, currentBranch: isGit ? "main" : nil,
      isDirty: isGit ? true : nil, baseRef: nil,
      aheadBehind: nil, aheadOfOrigin: nil, behindOfOrigin: nil,
      hasRemote: false, remoteURL: nil, upstreamRef: nil, error: nil)
  }

  func checkoutDiff(cwd: String) async throws -> PaseoCheckoutDiff {
    checkoutDiffCalls += 1
    return PaseoCheckoutDiff(
      cwd: cwd,
      files: [
        PaseoDiffFile(
          path: "Sources/Example.swift", isNew: false, isDeleted: false,
          additions: 1, deletions: 1,
          hunks: [
            PaseoDiffHunk(
              oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
              lines: [
                PaseoDiffLine(kind: .header, content: "@@ -1,1 +1,1 @@"),
                PaseoDiffLine(kind: .remove, content: "old"),
                PaseoDiffLine(kind: .add, content: "new"),
              ])
          ])
      ], diffTooLarge: false, error: nil)
  }

  func listThreads(projectID: String, page: PaseoPageRequest) async throws -> PaseoPage<PaseoThread>
  {
    guard !threadPages.isEmpty else {
      return PaseoPage(items: [], nextCursor: nil, previousCursor: nil, hasMore: false)
    }
    guard page.cursor != nil else { return threadPages[0] }
    return threadPages[min(1, threadPages.count - 1)]
  }

  func history(
    agentID: String,
    direction: PaseoTimelineDirection,
    cursor: PaseoTimelineCursor?,
    limit: Int
  ) async throws -> PaseoTimelinePage {
    if direction == .tail {
      tailCalls += 1
      if tailCalls == gatedTailCall { await historyGate?.wait() }
      if !tailPages.isEmpty { return tailPages[min(tailCalls - 1, tailPages.count - 1)] }
    } else if let olderPage {
      return olderPage
    }
    let entries =
      direction == .tail
      ? [
        PaseoTimelineEntry(
          id: "epoch-1:5-5",
          provider: "codex",
          item: .object([
            "type": .string("assistant_message"),
            "text": .string("already in history"),
            "messageId": .string("message-1"),
          ]),
          turnID: nil,
          timestamp: "2026-09-25T12:30:45.123Z",
          startSequence: 5,
          endSequence: 5,
          collapsed: []
        )
      ]
      : []
    return PaseoTimelinePage(
      agentID: agentID,
      epoch: "epoch-1",
      entries: entries,
      startCursor: PaseoTimelineCursor(epoch: "epoch-1", sequence: 5),
      endCursor: PaseoTimelineCursor(epoch: "epoch-1", sequence: 5),
      hasOlder: false,
      hasNewer: false,
      reset: false,
      staleCursor: false,
      gap: false
    )
  }

  func events(agentID: String, after cursor: PaseoTimelineCursor?) async throws
    -> AsyncThrowingStream<PaseoTimelineEvent, Error>
  {
    let (stream, streamContinuation) = AsyncThrowingStream<PaseoTimelineEvent, Error>.makeStream(
      bufferingPolicy: .unbounded)
    let (terminationStream, terminationContinuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    continuation = streamContinuation
    sourceTermination = terminationStream
    streamContinuation.onTermination = { @Sendable _ in
      terminationContinuation.yield(())
      terminationContinuation.finish()
    }
    return stream
  }

  func send(agentID: String, text: String) async throws {}
  func supportsAgentRequestReceipts() async -> Bool { true }
  func send(
    agentID: String, text: String, messageID: String,
    activeTurnBehavior: PaseoActiveTurnBehavior
  ) async throws {
    sentIntent = SentIntent(
      agentID: agentID, text: text, messageID: messageID, behavior: activeTurnBehavior)
  }
  func recordedSend() -> SentIntent? { sentIntent }
  func cancelAgent(agentID: String) async throws -> PaseoAgentControlSnapshot? {
    PaseoAgentControlSnapshot(
      id: agentID, status: "idle", requiresAttention: true, attentionReason: "Review")
  }
  func pendingPermissions() async throws -> [PaseoPermissionRequest] { [] }

  func answerPermission(agentID: String, requestID: String, decision: PaseoPermissionDecision)
    async throws
  {}

  func disconnect() async {
    disconnects += 1
    continuation?.finish()
    continuation = nil
  }

  func emit(_ event: PaseoTimelineEvent) {
    continuation?.yield(event)
  }

  func emitMany(_ events: [PaseoTimelineEvent]) {
    for event in events { continuation?.yield(event) }
  }

  func setThreadPages(_ pages: [PaseoPage<PaseoThread>]) {
    threadPages = pages
  }

  func setTimelinePages(
    tail: [PaseoTimelinePage], older: PaseoTimelinePage? = nil,
    gate: AdapterTestGate? = nil, gatedTailCall: Int = .max
  ) {
    tailPages = tail
    olderPage = older
    historyGate = gate
    self.gatedTailCall = gatedTailCall
  }

  func sourceTerminationSignal() -> AsyncStream<Void> {
    sourceTermination ?? AsyncStream { $0.finish() }
  }
}

private actor AdapterTestGate {
  private var waiter: CheckedContinuation<Void, Never>?
  private var entryWaiter: CheckedContinuation<Void, Never>?
  private var opened = false

  func wait() async {
    guard !opened else { return }
    await withCheckedContinuation { continuation in
      waiter = continuation
      entryWaiter?.resume()
      entryWaiter = nil
    }
  }

  func waitUntilEntered() async {
    guard waiter == nil else { return }
    await withCheckedContinuation { entryWaiter = $0 }
  }

  func open() {
    opened = true
    waiter?.resume()
    waiter = nil
  }
}
