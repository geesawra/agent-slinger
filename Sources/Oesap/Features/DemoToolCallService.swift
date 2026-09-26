#if DEBUG
  import Foundation

  actor DemoToolCallConnectionFactory: OesapConnectionFactory {
    private var service: DemoToolCallRemoteService?

    func savedConnectionExists() async -> Bool { false }

    func connect(_ connection: RemoteConnection) async throws -> any OesapRemoteService {
      let newService = DemoToolCallRemoteService()
      service = newService
      return newService
    }

    func reconnect() async throws -> any OesapRemoteService {
      guard let service else {
        throw RemoteServiceError.connectionLost("The tool-call demo is not connected.")
      }
      return service
    }

    func disconnect() async throws {
      await service?.disconnect()
      service = nil
    }
  }

  actor DemoToolCallRemoteService: OesapRemoteService {
    private var continuations:
      [String: AsyncThrowingStream<RemoteTimelineUpdate, Error>.Continuation] = [:]
    private var sentMessages: [String: [RemoteMessage]] = [:]
    private var toolCalls = DemoToolCallRemoteService.makeInitialToolCalls()
    private var closed = false

    func connectionEvents() async -> AsyncStream<RemoteConnectionEvent> {
      AsyncStream { continuation in
        continuation.yield(
          closed ? .disconnected("The tool-call demo connection closed.") : .connected)
      }
    }

    func projects() async throws -> [RemoteProject] {
      try ensureConnected()
      return [
        RemoteProject(
          id: "demo-tools-project", name: "Tool-call demo", subtitle: "~/Projects/oesap-demo")
      ]
    }

    func threads(projectID: String) async throws -> [RemoteThread] {
      try ensureConnected()
      guard projectID == "demo-tools-project" else { return [] }
      return [
        RemoteThread(
          id: "demo-tools-agent", title: "Inspect a tool call", provider: "Codex",
          model: "demo", state: .running, requiresAttention: false, attentionReason: nil)
      ]
    }

    func history(agentID: String, before cursor: RemoteTimelineCursor?) async throws
      -> RemoteTimeline
    {
      try ensureConnected()
      guard agentID == "demo-tools-agent", cursor == nil else {
        return RemoteTimeline(messages: [], historyMayBeIncomplete: false)
      }
      let start = Date(timeIntervalSince1970: 1_780_000_300)
      let initial = [
        RemoteMessage(
          id: "demo-tools-user-welcome", author: .user,
          text: "Can you inspect the test output and proposed change?", timestamp: start),
        RemoteMessage(
          id: "demo-tools-agent-welcome", author: .agent,
          text: "Expand the tool cards to inspect shell output, a file preview, and an edit diff.",
          timestamp: start.addingTimeInterval(1)),
      ]
      let toolMessages = toolCalls.enumerated().map { index, call in
        toolMessage(call: call, timestamp: start.addingTimeInterval(Double(index + 2)))
      }
      return RemoteTimeline(
        messages: initial + toolMessages + sentMessages[agentID, default: []],
        historyMayBeIncomplete: false)
    }

    func events(agentID: String) async throws -> AsyncThrowingStream<RemoteTimelineUpdate, Error> {
      try ensureConnected()
      return AsyncThrowingStream { continuation in
        continuations[agentID] = continuation
        continuation.onTermination = { [weak self] _ in
          Task { await self?.removeContinuation(agentID: agentID) }
        }
      }
    }

    func send(agentID: String, text: String) async throws {
      try ensureConnected()
      guard agentID == "demo-tools-agent" else {
        throw RemoteServiceError.unavailable("The demo agent was not found.")
      }
      let messageIndex = sentMessages[agentID, default: []].count
      let timestamp = Date(timeIntervalSince1970: 1_780_000_400 + Double(messageIndex * 3))
      let userMessage = RemoteMessage(
        id: "demo-tools-user-\(messageIndex)", author: .user, text: text, timestamp: timestamp)
      let reply = RemoteMessage(
        id: "demo-tools-reply-\(messageIndex)", author: .agent,
        text: "The same tool call row updated from running to completed.",
        timestamp: timestamp.addingTimeInterval(1))
      sentMessages[agentID, default: []].append(contentsOf: [userMessage, reply])
      continuations[agentID]?.yield(.message(userMessage, cursor: nil, isDelta: false))
      continuations[agentID]?.yield(.message(reply, cursor: nil, isDelta: false))

      guard let shellIndex = toolCalls.firstIndex(where: { $0.callID == "demo-shell-call" }) else {
        return
      }
      toolCalls[shellIndex].status = .completed
      toolCalls[shellIndex].exitCode = 0
      continuations[agentID]?.yield(
        .message(
          toolMessage(call: toolCalls[shellIndex], timestamp: timestamp.addingTimeInterval(2)),
          cursor: nil,
          isDelta: false
        ))
    }

    func pendingPermissions() async throws -> [RemotePermission] {
      try ensureConnected()
      return []
    }

    func answerPermission(_ permission: RemotePermission, allow: Bool) async throws {
      try ensureConnected()
    }

    func disconnect() async {
      closed = true
      for continuation in continuations.values { continuation.finish() }
      continuations.removeAll()
    }

    private func toolMessage(call: RemoteToolCall, timestamp: Date) -> RemoteMessage {
      RemoteMessage(
        id: call.rowID, author: .agent, text: call.title, timestamp: timestamp,
        toolCall: call)
    }

    private func removeContinuation(agentID: String) {
      continuations[agentID] = nil
    }

    private func ensureConnected() throws {
      if closed {
        throw RemoteServiceError.connectionLost("The tool-call demo connection has closed.")
      }
    }

    private static func makeInitialToolCalls() -> [RemoteToolCall] {
      [
        RemoteToolCall(
          callID: "demo-shell-call",
          turnID: "1",
          name: "shell",
          title: "Shell",
          summary: "The agent started a test run and is waiting for the command to finish.",
          status: .running,
          command:
            "xcodebuild test -scheme Oesap -destination 'platform=iOS Simulator,name=iPhone'",
          cwd: "/workspace/oesap",
          sections: [
            RemoteToolCallSection(
              id: "shell-output", kind: .code, title: "Output", content: sampleOutput,
              language: "text")
          ]
        ),
        RemoteToolCall(
          callID: "demo-read-call",
          turnID: "1",
          name: "read",
          title: "Read",
          summary: "Read a SwiftUI source file.",
          status: .completed,
          sections: [
            RemoteToolCallSection(
              id: "read-file", kind: .filePreview, title: "File preview",
              content:
                "struct WorkspaceRootView: View {\n  var body: some View {\n    NavigationStack {\n      ProjectListView()\n    }\n  }\n}",
              path: "Sources/Oesap/Features/WorkspaceViews.swift", language: "swift",
              offset: 1, limit: 7)
          ]
        ),
        RemoteToolCall(
          callID: "demo-edit-call",
          turnID: "1",
          name: "edit",
          title: "Edit",
          summary: "The agent proposed a small project-list navigation change.",
          status: .completed,
          sections: [
            RemoteToolCallSection(
              id: "edit-diff", kind: .diff, title: "Diff",
              content:
                "diff --git a/Sources/Oesap/Features/WorkspaceViews.swift b/Sources/Oesap/Features/WorkspaceViews.swift\n@@ -1,4 +1,5 @@\n struct WorkspaceRootView: View {\n+  @State private var selectedProject: String?\n   var body: some View {\n-    EmptyView()\n+    NavigationStack { ProjectListView() }\n   }\n }",
              path: "Sources/Oesap/Features/WorkspaceViews.swift", language: "diff")
          ]
        ),
        RemoteToolCall(
          callID: "demo-failed-call",
          turnID: "1",
          name: "shell",
          title: "Shell",
          summary: "A later command failed.",
          status: .failed,
          command: "swiftformat --lint Sources/Oesap",
          cwd: "/workspace/oesap",
          exitCode: 127,
          errorText: "swiftformat: command not found",
          sections: [
            RemoteToolCallSection(
              id: "failed-output", kind: .text, title: "Output",
              content: "Command exited with status 127.")
          ]
        ),
        RemoteToolCall(
          callID: "demo-generic-call",
          turnID: "1",
          name: "provider_extension",
          title: "Provider detail",
          summary: "An extension returned text without a specialized viewer.",
          status: .completed,
          sections: [
            RemoteToolCallSection(
              id: "generic-text", kind: .text, title: "Details",
              content: "Provider-specific content is displayed as plain text.")
          ]
        ),
      ]
    }

    private static var sampleOutput: String {
      (1...300).map { line in
        "Test case \(line): RemoteTimelineAdapterTests.testStreamRestoresHistory — passed (0.02s)"
      }.joined(separator: "\n")
    }
  }
#endif
