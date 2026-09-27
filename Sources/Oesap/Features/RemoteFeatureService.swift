import Foundation

struct RemoteConnection: Sendable, Equatable {
  enum Method: String, CaseIterable, Identifiable, Sendable {
    case direct = "Direct connection"
    case relay = "Relay pairing"

    var id: String { rawValue }
  }

  var method: Method
  var endpoint: String
  var usesTLS: Bool
  var password: String
  var pairingLink: String

  static let empty = RemoteConnection(
    method: .direct,
    endpoint: "",
    usesTLS: true,
    password: "",
    pairingLink: ""
  )
}

struct RemoteProject: Identifiable, Sendable, Equatable {
  var id: String
  var name: String
  var subtitle: String?
  var rootPath: String? = nil
}

struct RemoteAgentConfiguration: Codable, Sendable, Equatable {
  var provider: String
  var model: String?
}

struct RemoteAgentModel: Identifiable, Sendable, Equatable {
  var id: String
  var label: String
  var isDefault: Bool
}

struct RemoteAgentProvider: Identifiable, Sendable, Equatable {
  var id: String
  var available: Bool
  var error: String?
  var label: String? = nil
  var models: [RemoteAgentModel] = []
}

struct RemoteAgentOverviewGroup: Identifiable, Sendable, Equatable {
  var project: RemoteProject
  var threads: [RemoteThread]
  var error: String?

  var id: String { project.id }
}

struct RemoteContextUsage: Sendable, Equatable {
  var usedTokens: Double?
  var maxTokens: Double?

  var fractionUsed: Double? {
    guard let usedTokens, let maxTokens, maxTokens > 0 else { return nil }
    return usedTokens / maxTokens
  }

  var isEmpty: Bool { usedTokens == nil && maxTokens == nil }

  func merging(_ newer: RemoteContextUsage) -> RemoteContextUsage {
    RemoteContextUsage(
      usedTokens: newer.usedTokens ?? usedTokens,
      maxTokens: newer.maxTokens ?? maxTokens)
  }
}

struct RemoteProviderUsageSnapshot: Sendable, Equatable {
  var fetchedAt: Date?
  var providers: [RemoteProviderUsage]
}

struct RemoteProviderUsage: Identifiable, Sendable, Equatable {
  enum Status: Sendable, Equatable {
    case available
    case unavailable
    case error
    case unknown(String)
  }

  enum Tone: Sendable, Equatable {
    case `default`
    case ok
    case warning
    case danger
    case unknown(String)
  }

  var id: String
  var displayName: String
  var status: Status
  var planLabel: String?
  var sourceLabel: String?
  var fetchedAt: Date?
  var nextRefreshAt: Date?
  var windows: [Window]
  var balances: [Balance]
  var details: [Detail]
  var error: String?

  struct Window: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var usedPct: Double?
    var remainingPct: Double?
    var resetsAt: Date?
    var runsOutAt: Date?
    var shortfallPct: Double?
    var tone: Tone?
  }

  struct Balance: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var used: Double?
    var remaining: Double?
    var limit: Double?
    var unit: String
    var resetsAt: Date?
    var tone: Tone?
  }

  struct Detail: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var value: String
    var tone: Tone?
  }
}

struct RemoteNewThreadIntent: Sendable, Equatable {
  var idempotencyKey: String
  var clientMessageID: String
  var projectID: String
  var provider: String
  var model: String?
  var cwd: String
  var prompt: String
}

struct RemoteNewThreadResult: Sendable, Equatable {
  var thread: RemoteThread?
  var promptAccepted: Bool
  var error: String?
  var safeToRestart: Bool = false
}

struct RemoteThread: Identifiable, Sendable, Equatable {
  enum State: Sendable, Equatable {
    case initializing
    case running
    case idle
    case closed
    case waiting
    case failed
    case unknown(String)

    var label: String {
      switch self {
      case .initializing: "Starting"
      case .running: "Running"
      case .idle: "Idle"
      case .closed: "Closed"
      case .waiting: "Needs attention"
      case .failed: "Failed"
      case .unknown(let value): value.isEmpty ? "Unknown" : value
      }
    }

    var symbol: String {
      switch self {
      case .initializing: "hourglass.circle"
      case .running: "play.circle.fill"
      case .idle: "pause.circle"
      case .closed: "checkmark.circle"
      case .waiting: "hand.raised.circle.fill"
      case .failed: "exclamationmark.circle.fill"
      case .unknown: "questionmark.circle"
      }
    }
  }

  var id: String
  var title: String
  var provider: String?
  var model: String?
  var state: State
  var requiresAttention: Bool
  var attentionReason: String?
  var contextUsage: RemoteContextUsage? = nil
}

enum RemoteActiveTurnBehavior: String, Sendable, Equatable {
  case interrupt
  case steer
}

struct RemoteAgentControlSnapshot: Sendable, Equatable {
  var id: String
  var state: RemoteThread.State
  var requiresAttention: Bool
  var attentionReason: String?
}

struct RemoteAgentActionFeedback: Sendable, Equatable {
  enum Phase: Sendable, Equatable {
    case sending
    case accepted
    case sendUncertain
    case stopping
    case stopWaiting
    case stopped
    case failed
  }

  var phase: Phase
  var message: String
  var canRetrySend: Bool = false
  var requiresUncertaintyReview: Bool = false

  var isBusy: Bool { phase == .sending || phase == .stopping }
}

struct RemoteMessage: Identifiable, Sendable, Equatable {
  enum Author: Sendable, Equatable {
    case user
    case agent
    case system
  }

  var id: String
  var author: Author
  var text: String
  var timestamp: Date?
  var toolCall: RemoteToolCall? = nil
}

struct RemoteToolCall: Sendable, Equatable {
  enum Status: Sendable, Equatable {
    case running
    case completed
    case failed
    case canceled
    case unknown(String)
  }

  var callID: String
  var turnID: String? = nil
  var name: String
  var title: String
  var summary: String? = nil
  var status: Status
  var command: String? = nil
  var cwd: String? = nil
  var exitCode: Int? = nil
  var errorText: String? = nil
  var sections: [RemoteToolCallSection] = []

  var rowID: String {
    guard let turnID, !turnID.isEmpty else { return "tool:call:\(callID)" }
    return "tool:turn:\(turnID.utf8.count):\(turnID):\(callID)"
  }
}

struct RemoteToolCallSection: Identifiable, Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case text
    case code
    case filePreview
    case diff
  }

  var id: String
  var kind: Kind
  var title: String
  var content: String
  var path: String? = nil
  var language: String? = nil
  var offset: Int? = nil
  var limit: Int? = nil
}

struct RemoteTimeline: Sendable, Equatable {
  var messages: [RemoteMessage]
  var historyMayBeIncomplete: Bool
  var hasOlder: Bool = false
  var olderCursor: RemoteTimelineCursor?
  var latestCursor: RemoteTimelineCursor?
}

struct RemoteTimelineCursor: Sendable, Equatable {
  var epoch: String
  var sequence: Int
}

struct RemotePermission: Identifiable, Sendable, Equatable {
  var id: String
  var agentID: String
  var title: String
  var detail: String?
  var kind: String
  var supportsSimpleDecision: Bool
  var allowActionID: String?
  var denyActionID: String?
  var allowLabel: String?
  var denyLabel: String?
}

enum RemoteTimelineUpdate: Sendable {
  case message(RemoteMessage, cursor: RemoteTimelineCursor?, isDelta: Bool)
  case historyChanged
  case threadState(RemoteThread.State, requiresAttention: Bool, reason: String?)
  case contextUsage(RemoteContextUsage)
  case contextUsageNeedsRefresh
  case permissionRequested(RemotePermission)
  case permissionResolved(String)
}

enum RemoteConnectionEvent: Sendable {
  case connected
  case disconnected(String)
}

protocol OesapRemoteService: Sendable {
  func serverID() async -> String?
  func supportsNewThreads() async -> Bool
  func supportsProviderUsage() async -> Bool
  func providerUsage() async throws -> RemoteProviderUsageSnapshot
  func contextUsage(agentID: String) async throws -> RemoteContextUsage?
  func agentProviders(cwd: String) async throws -> [RemoteAgentProvider]
  func createThread(_ intent: RemoteNewThreadIntent) async throws -> RemoteNewThreadResult
  func connectionEvents() async -> AsyncStream<RemoteConnectionEvent>
  func projects() async throws -> [RemoteProject]
  func threads(projectID: String) async throws -> [RemoteThread]
  func history(agentID: String, before cursor: RemoteTimelineCursor?) async throws -> RemoteTimeline
  func events(agentID: String) async throws -> AsyncThrowingStream<RemoteTimelineUpdate, Error>
  func send(agentID: String, text: String) async throws
  func supportsAgentRequestReceipts() async -> Bool
  func send(
    agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior
  ) async throws
  func stop(agentID: String) async throws -> RemoteAgentControlSnapshot?
  func pendingPermissions() async throws -> [RemotePermission]
  func answerPermission(_ permission: RemotePermission, allow: Bool) async throws
  func disconnect() async
}

extension OesapRemoteService {
  func serverID() async -> String? { nil }
  func supportsNewThreads() async -> Bool { false }
  func supportsProviderUsage() async -> Bool { false }
  func providerUsage() async throws -> RemoteProviderUsageSnapshot {
    throw RemoteServiceError.unavailable("This host does not support provider usage.")
  }
  func contextUsage(agentID: String) async throws -> RemoteContextUsage? { nil }
  func agentProviders(cwd: String) async throws -> [RemoteAgentProvider] { [] }
  func createThread(_ intent: RemoteNewThreadIntent) async throws -> RemoteNewThreadResult {
    throw RemoteServiceError.unavailable("This host does not support new thread creation.")
  }
  func supportsAgentRequestReceipts() async -> Bool { false }
  func send(
    agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior
  ) async throws {
    throw RemoteServiceError.unavailable("Explicit active-turn send behavior is not supported.")
  }
  func stop(agentID: String) async throws -> RemoteAgentControlSnapshot? {
    throw RemoteServiceError.unavailable("Stopping agents is not supported by this service.")
  }
}

protocol OesapConnectionFactory: Sendable {
  func savedConnectionExists() async -> Bool
  func connect(_ connection: RemoteConnection) async throws -> any OesapRemoteService
  func reconnect() async throws -> any OesapRemoteService
  func disconnect() async throws
}

enum RemoteServiceError: LocalizedError, Sendable {
  case unavailable(String)
  case connectionLost(String)
  case authentication(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let message), .connectionLost(let message), .authentication(let message):
      message
    }
  }
}

#if DEBUG
  actor DemoConnectionFactory: OesapConnectionFactory {
    enum Mode: Sendable, Equatable {
      case normal
      case failure
      case empty
      case sendFailure
      case creationUnsupported
      case overviewEmpty
      case overviewFailure
      case usageUnsupported
      case usageUnavailable
      case usageFailure
      case agentControl
    }

    private let mode: Mode
    private var currentService: DemoRemoteService?

    init(mode: Mode = .normal) {
      self.mode = mode
    }

    func savedConnectionExists() async -> Bool { false }

    func connect(_ connection: RemoteConnection) async throws -> any OesapRemoteService {
      if mode == .failure {
        throw RemoteServiceError.authentication(
          "The demo rejected this connection. Check the credentials and try again.")
      }
      let service = DemoRemoteService(
        isEmpty: mode == .empty, failsSending: mode == .sendFailure,
        creationSupported: mode != .creationUnsupported,
        overviewEmpty: mode == .overviewEmpty,
        overviewFailure: mode == .overviewFailure,
        usageSupported: mode != .usageUnsupported,
        usageUnavailable: mode == .usageUnavailable,
        usageFailure: mode == .usageFailure,
        agentControlSupported: mode == .agentControl)
      currentService = service
      return service
    }

    func reconnect() async throws -> any OesapRemoteService {
      guard let currentService else {
        throw RemoteServiceError.connectionLost("There is no active demo connection to restore.")
      }
      return currentService
    }

    func disconnect() async throws {
      await currentService?.disconnect()
      currentService = nil
    }
  }

  actor DemoRemoteService: OesapRemoteService {
    private let isEmpty: Bool
    private let failsSending: Bool
    private let creationSupported: Bool
    private let overviewEmpty: Bool
    private let overviewFailure: Bool
    private let usageSupported: Bool
    private let usageUnavailable: Bool
    private let usageFailure: Bool
    private let agentControlSupported: Bool
    private var continuations:
      [String: AsyncThrowingStream<RemoteTimelineUpdate, Error>.Continuation] = [:]
    private var sentMessages: [String: [RemoteMessage]] = [:]
    private var acceptedMessageIDs: [String: Set<String>] = [:]
    private var createdThreads: [RemoteThread] = []
    private var creations: [String: RemoteNewThreadResult] = [:]
    private var resolvedPermissions: Set<String> = []
    private var stoppedAgents: Set<String> = []
    private var closed = false

    init(
      isEmpty: Bool = false, failsSending: Bool = false,
      creationSupported: Bool = true, overviewEmpty: Bool = false,
      overviewFailure: Bool = false, usageSupported: Bool = true,
      usageUnavailable: Bool = false, usageFailure: Bool = false,
      agentControlSupported: Bool = false
    ) {
      self.isEmpty = isEmpty
      self.failsSending = failsSending
      self.creationSupported = creationSupported
      self.overviewEmpty = overviewEmpty
      self.overviewFailure = overviewFailure
      self.usageSupported = usageSupported
      self.usageUnavailable = usageUnavailable
      self.usageFailure = usageFailure
      self.agentControlSupported = agentControlSupported
    }

    func serverID() async -> String? {
      let prefix = "--demo-server-id="
      return ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })
        .map { String($0.dropFirst(prefix.count)) } ?? "oesap-demo-host"
    }

    func supportsNewThreads() async -> Bool { creationSupported }

    func supportsProviderUsage() async -> Bool { usageSupported }

    func providerUsage() async throws -> RemoteProviderUsageSnapshot {
      try ensureConnected()
      guard usageSupported else {
        throw RemoteServiceError.unavailable("Update the demo host to view provider usage.")
      }
      if usageFailure {
        throw RemoteServiceError.unavailable("The demo host could not load provider usage.")
      }
      let fetchedAt = Date(timeIntervalSince1970: 1_779_984_000)
      if usageUnavailable {
        return RemoteProviderUsageSnapshot(
          fetchedAt: fetchedAt,
          providers: [
            RemoteProviderUsage(
              id: "codex", displayName: "Codex", status: .unavailable,
              planLabel: nil, sourceLabel: nil, fetchedAt: nil, nextRefreshAt: nil,
              windows: [], balances: [], details: [], error: nil),
            RemoteProviderUsage(
              id: "claude", displayName: "Claude Code", status: .unavailable,
              planLabel: nil, sourceLabel: nil, fetchedAt: nil, nextRefreshAt: nil,
              windows: [], balances: [], details: [], error: nil),
          ])
      }
      return RemoteProviderUsageSnapshot(
        fetchedAt: fetchedAt,
        providers: [
          RemoteProviderUsage(
            id: "codex", displayName: "Codex", status: .available,
            planLabel: "Pro", sourceLabel: "Host account", fetchedAt: fetchedAt,
            nextRefreshAt: fetchedAt.addingTimeInterval(300),
            windows: [
              RemoteProviderUsage.Window(
                id: "five_hour", label: "Five-hour window", usedPct: 38,
                remainingPct: 62, resetsAt: fetchedAt.addingTimeInterval(5 * 3600),
                runsOutAt: nil, shortfallPct: nil, tone: .ok),
              RemoteProviderUsage.Window(
                id: "weekly", label: "Weekly window", usedPct: 71,
                remainingPct: 29, resetsAt: fetchedAt.addingTimeInterval(7 * 24 * 3600),
                runsOutAt: nil, shortfallPct: nil, tone: .warning),
            ],
            balances: [
              RemoteProviderUsage.Balance(
                id: "credits", label: "Credits", used: nil, remaining: 12.5,
                limit: nil, unit: "usd", resetsAt: nil, tone: .ok)
            ],
            details: [
              RemoteProviderUsage.Detail(
                id: "plan", label: "Plan", value: "Pro", tone: nil)
            ], error: nil),
          RemoteProviderUsage(
            id: "claude", displayName: "Claude Code", status: .unavailable,
            planLabel: nil, sourceLabel: nil, fetchedAt: nil, nextRefreshAt: nil,
            windows: [], balances: [], details: [], error: nil),
          RemoteProviderUsage(
            id: "cursor", displayName: "Cursor", status: .error,
            planLabel: nil, sourceLabel: nil, fetchedAt: nil, nextRefreshAt: nil,
            windows: [], balances: [], details: [], error: "Usage provider temporarily unavailable."
          ),
        ])
    }

    func contextUsage(agentID: String) async throws -> RemoteContextUsage? {
      try ensureConnected()
      if agentID == "demo-agent-idle" {
        return RemoteContextUsage(usedTokens: 18_000, maxTokens: nil)
      }
      guard agentID == "demo-agent-running" || agentID == "demo-tools-running" else {
        return nil
      }
      return RemoteContextUsage(usedTokens: 64_000, maxTokens: 200_000)
    }

    func agentProviders(cwd: String) async throws -> [RemoteAgentProvider] {
      try ensureConnected()
      return [
        RemoteAgentProvider(
          id: "codex", available: true, error: nil, label: "Codex",
          models: [
            RemoteAgentModel(id: "gpt-6-sol", label: "GPT-6 Sol", isDefault: true),
            RemoteAgentModel(id: "gpt-6-astra", label: "GPT-6 Astra", isDefault: false),
          ])
      ]
    }

    func createThread(_ intent: RemoteNewThreadIntent) async throws -> RemoteNewThreadResult {
      try ensureConnected()
      guard creationSupported else {
        throw RemoteServiceError.unavailable("This demo host does not support new threads.")
      }
      if let previous = creations[intent.idempotencyKey] { return previous }
      let id = "demo-created-\(creations.count + 1)"
      let thread = RemoteThread(
        id: id, title: String(intent.prompt.prefix(56)), provider: intent.provider,
        model: intent.model, state: .running, requiresAttention: false, attentionReason: nil)
      createdThreads.insert(thread, at: 0)
      let timestamp = Date(timeIntervalSince1970: 1_780_000_300)
      sentMessages[id] = [
        RemoteMessage(id: "\(id)-prompt", author: .user, text: intent.prompt, timestamp: timestamp),
        RemoteMessage(
          id: "\(id)-reply", author: .agent, text: "Demo reply to the new thread.",
          timestamp: timestamp.addingTimeInterval(1)),
      ]
      let result = RemoteNewThreadResult(thread: thread, promptAccepted: true, error: nil)
      creations[intent.idempotencyKey] = result
      return result
    }

    func projects() async throws -> [RemoteProject] {
      try ensureConnected()
      guard !isEmpty else { return [] }
      return [
        RemoteProject(
          id: "demo-project", name: "Oesap demo", subtitle: "~/Projects/oesap",
          rootPath: "/demo/oesap"),
        RemoteProject(
          id: "demo-tools-project", name: "Oesap tools", subtitle: "~/Projects/tools",
          rootPath: "/demo/tools"),
      ]
    }

    func connectionEvents() async -> AsyncStream<RemoteConnectionEvent> {
      AsyncStream { continuation in
        continuation.yield(
          closed ? .disconnected("The demo connection has been closed.") : .connected)
      }
    }

    func threads(projectID: String) async throws -> [RemoteThread] {
      try ensureConnected()
      guard !isEmpty, !overviewEmpty else { return [] }
      if projectID == "demo-tools-project" {
        if overviewFailure {
          throw RemoteServiceError.unavailable("The demo tools project could not be loaded.")
        }
        return [
          RemoteThread(
            id: "demo-tools-running", title: "Check tool integrations", provider: "codex",
            model: "gpt-6-sol", state: .running, requiresAttention: false,
            attentionReason: nil,
            contextUsage: RemoteContextUsage(usedTokens: 64_000, maxTokens: 200_000)),
          RemoteThread(
            id: "demo-tools-failed", title: "Fix release build", provider: "codex",
            model: "gpt-6-astra", state: .failed, requiresAttention: true,
            attentionReason: "An agent run failed."),
        ]
      }
      guard projectID == "demo-project" else { return [] }
      return createdThreads + [
        RemoteThread(
          id: "demo-agent-running",
          title: "Build the iOS app",
          provider: "codex",
          model: "gpt-6-sol",
          state: stoppedAgents.contains("demo-agent-running") ? .idle : .running,
          requiresAttention: false,
          attentionReason: nil,
          contextUsage: RemoteContextUsage(usedTokens: 64_000, maxTokens: 200_000)
        ),
        RemoteThread(
          id: "demo-agent-attention",
          title: "Review connection flow",
          provider: "claude",
          model: nil,
          state: .waiting,
          requiresAttention: true,
          attentionReason: "The agent is waiting for approval."
        ),
        RemoteThread(
          id: "demo-agent-idle", title: "Review older changes", provider: "codex",
          model: "gpt-6-sol", state: .idle, requiresAttention: false,
          attentionReason: nil,
          contextUsage: RemoteContextUsage(usedTokens: 18_000, maxTokens: nil)),
      ]
    }

    func history(agentID: String, before cursor: RemoteTimelineCursor?) async throws
      -> RemoteTimeline
    {
      try ensureConnected()
      guard !isEmpty else { return RemoteTimeline(messages: [], historyMayBeIncomplete: false) }
      if cursor != nil {
        return RemoteTimeline(messages: [], historyMayBeIncomplete: false)
      }
      let initial: [RemoteMessage]
      let baseTime = Date(timeIntervalSince1970: 1_780_000_000)
      if agentID.hasPrefix("demo-created-") {
        initial = []
      } else if agentID == "demo-agent-attention" {
        initial = [
          RemoteMessage(
            id: "demo-permission", author: .agent, text: "May I update the project settings file?",
            timestamp: baseTime)
        ]
      } else {
        initial = [
          RemoteMessage(
            id: "demo-welcome-user", author: .user, text: "Can you add the first remote screen?",
            timestamp: baseTime),
          RemoteMessage(
            id: "demo-welcome-agent", author: .agent,
            text:
              """
              ## Project check-in

              I’ve mapped the workspace and found a clear first step.

              - **Status:** connected to the demo host
              - **Plan:** keep the conversation easy to scan
              - **Build:** `xcodebuild -scheme Oesap build`

              I’ll keep the draft intact if the connection drops.
              """,
            timestamp: baseTime.addingTimeInterval(1)),
        ]
      }
      return RemoteTimeline(
        messages: initial + sentMessages[agentID, default: []], historyMayBeIncomplete: false)
    }

    func events(agentID: String) async throws -> AsyncThrowingStream<RemoteTimelineUpdate, Error> {
      try ensureConnected()
      return AsyncThrowingStream { continuation in
        continuations[agentID] = continuation
        continuation.onTermination = { [weak self] _ in
          Task { await self?.removeContinuation(for: agentID) }
        }
      }
    }

    func supportsAgentRequestReceipts() async -> Bool { agentControlSupported }

    func send(agentID: String, text: String) async throws {
      try await send(
        agentID: agentID, text: text, messageID: UUID().uuidString.lowercased(),
        behavior: .interrupt)
    }

    func send(
      agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior
    ) async throws {
      try ensureConnected()
      if failsSending {
        throw RemoteServiceError.connectionLost("The demo could not confirm delivery.")
      }
      if acceptedMessageIDs[agentID, default: []].contains(messageID) { return }
      acceptedMessageIDs[agentID, default: []].insert(messageID)
      stoppedAgents.remove(agentID)
      continuations[agentID]?.yield(
        .threadState(.running, requiresAttention: false, reason: nil))
      let index = sentMessages[agentID, default: []].count
      let timestamp = Date(timeIntervalSince1970: 1_780_000_100 + Double(index))
      let userMessage = RemoteMessage(
        id: "demo-user-\(index)", author: .user, text: text, timestamp: timestamp)
      sentMessages[agentID, default: []].append(userMessage)
      continuations[agentID]?.yield(.message(userMessage, cursor: nil, isDelta: false))
      let reply = RemoteMessage(
        id: "demo-reply-\(index)",
        author: .agent,
        text: "Demo reply: I received your message and would continue work on this thread.",
        timestamp: timestamp.addingTimeInterval(1)
      )
      sentMessages[agentID, default: []].append(reply)
      continuations[agentID]?.yield(.message(reply, cursor: nil, isDelta: false))
    }

    func stop(agentID: String) async throws -> RemoteAgentControlSnapshot? {
      try ensureConnected()
      guard agentControlSupported else {
        throw RemoteServiceError.unavailable("The demo host does not support agent control.")
      }
      guard agentID == "demo-agent-running" else {
        throw RemoteServiceError.unavailable("The demo agent was not found.")
      }
      stoppedAgents.insert(agentID)
      continuations[agentID]?.yield(
        .threadState(.idle, requiresAttention: false, reason: nil))
      return RemoteAgentControlSnapshot(
        id: agentID, state: .idle, requiresAttention: false, attentionReason: nil)
    }

    func pendingPermissions() async throws -> [RemotePermission] {
      try ensureConnected()
      guard !isEmpty else { return [] }
      return [
        RemotePermission(
          id: "demo-permission",
          agentID: "demo-agent-attention",
          title: "Update the project settings file?",
          detail: "The agent needs approval before changing this file.",
          kind: "tool",
          supportsSimpleDecision: true,
          allowActionID: "demo-allow",
          denyActionID: "demo-deny",
          allowLabel: "Allow",
          denyLabel: "Deny"
        )
      ].filter { !resolvedPermissions.contains($0.id) }
    }

    func answerPermission(_ permission: RemotePermission, allow: Bool) async throws {
      try ensureConnected()
      resolvedPermissions.insert(permission.id)
      guard let continuation = continuations[permission.agentID] else { return }
      let text = allow ? "Approval granted." : "Request denied."
      continuation.yield(
        .message(
          RemoteMessage(
            id: "demo-permission-result", author: .system, text: text,
            timestamp: Date(timeIntervalSince1970: 1_780_000_200)),
          cursor: nil,
          isDelta: false
        ))
    }

    func disconnect() async {
      closed = true
      for continuation in continuations.values {
        continuation.finish()
      }
      continuations.removeAll()
    }

    private func ensureConnected() throws {
      if closed { throw RemoteServiceError.connectionLost("The demo connection has been closed.") }
    }

    private func removeContinuation(for agentID: String) {
      continuations[agentID] = nil
    }
  }
#endif
