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
  var name: String = ""

  static let empty = RemoteConnection(
    method: .direct,
    endpoint: "",
    usesTLS: true,
    password: "",
    pairingLink: "",
    name: ""
  )
}

struct SavedPaseoInstance: Identifiable, Sendable, Equatable {
  var id: String
  var name: String
  var subtitle: String
}

struct RemoteProject: Identifiable, Sendable, Equatable {
  var id: String
  var name: String
  var subtitle: String?
  var rootPath: String? = nil
}

struct RemoteDirectoryEntry: Identifiable, Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case file
    case directory
  }

  var path: String
  var kind: Kind

  var id: String { path }
  var name: String {
    path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
  }
}

struct RemoteAgentConfiguration: Codable, Sendable, Equatable {
  var provider: String
  var model: String?
  var modeID: String? = nil
}

struct RemoteAgentModel: Identifiable, Sendable, Equatable {
  var id: String
  var label: String
  var isDefault: Bool
  var thinkingOptions: [RemoteThinkingOption] = []
  var defaultThinkingOptionID: String? = nil
}

struct RemoteThinkingOption: Identifiable, Sendable, Equatable {
  var id: String
  var label: String
  var description: String?
  var isDefault: Bool
}

struct RemoteAgentMode: Identifiable, Sendable, Equatable {
  var id: String
  var label: String
  var description: String?
}

struct RemoteAgentSettings: Sendable, Equatable {
  var agentID: String
  var provider: String
  var cwd: String
  var modelID: String?
  var thinkingOptionID: String?
  var effectiveThinkingOptionID: String?
  var currentModeID: String? = nil
  var availableModes: [RemoteAgentMode] = []
  var models: [RemoteAgentModel]
  var canApply: Bool
  var supportsThinking: Bool
  var status: String
}

struct RemoteAgentSettingsApplyResult: Sendable, Equatable {
  var notice: String?
}

struct RemoteAgentProvider: Identifiable, Sendable, Equatable {
  var id: String
  var available: Bool
  var error: String?
  var label: String? = nil
  var models: [RemoteAgentModel] = []
  var modes: [RemoteAgentMode] = []
  var defaultModeID: String? = nil
}

struct RemoteAgentOverviewGroup: Identifiable, Sendable, Equatable {
  var project: RemoteProject
  var threads: [RemoteThread]
  var error: String?

  var id: String { project.id }
}

struct RemoteGitChangedFile: Identifiable, Sendable, Equatable {
  var path: String
  var additions: Int
  var deletions: Int
  var status: String?

  var id: String { path }
}

struct RemoteGitStatus: Sendable, Equatable {
  var files: [RemoteGitChangedFile]
  var additions: Int
  var deletions: Int
  var diffByPath: [String: String] = [:]
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
  var modeID: String? = nil
  var cwd: String
  var prompt: String
  var images: [RemoteDraftImage] = []
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
  var cwd: String? = nil
  var parentAgentID: String? = nil
}

struct RemoteProviderSubagent: Identifiable, Sendable, Equatable {
  enum Status: String, Sendable, Equatable {
    case running
    case completed
    case failed
    case canceled
  }

  var id: String
  var parentAgentID: String
  var parentSubagentID: String?
  var provider: String
  var title: String?
  var description: String?
  var status: Status
  var cwd: String?
  var subtitle: String?

  var displayTitle: String {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty { return trimmed }
    return "Untitled subagent"
  }
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
  var clientMessageID: String? = nil
  var images: [RemoteDraftImage] = []
  var isThinkingTrace = false
  var thinkingIsEncrypted = false
  var compaction: RemoteCompaction? = nil
}

struct RemoteCompaction: Sendable, Equatable {
  enum Status: String, Sendable, Equatable {
    case loading
    case completed
  }

  var status: Status
  var turnID: String? = nil
  var trigger: String? = nil
  var preTokens: Int? = nil
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
  var input: PaseoJSONValue? = nil
  var questions: [RemoteQuestion]? = nil
}

struct RemoteQuestion: Identifiable, Sendable, Equatable {
  var id: String
  var answerKey: String
  var header: String
  var prompt: String
  var options: [RemoteQuestionOption]
  var allowsMultipleSelection: Bool
  var allowsOtherAnswer: Bool
  var isRequired: Bool
  var placeholder: String?
}

struct RemoteQuestionOption: Identifiable, Sendable, Equatable {
  var id: String { label }
  var label: String
  var description: String?
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
  func supportsProviderSubagents() async -> Bool
  func providerUsage() async throws -> RemoteProviderUsageSnapshot
  func providerSubagents(parentAgentID: String) async throws -> [RemoteProviderSubagent]
  func providerSubagentHistory(parentAgentID: String, subagentID: String) async throws
    -> RemoteTimeline
  func contextUsage(agentID: String) async throws -> RemoteContextUsage?
  func agentProviders(cwd: String) async throws -> [RemoteAgentProvider]
  func agentSettings(agentID: String) async throws -> RemoteAgentSettings
  func applyAgentSettings(
    agentID: String, modelID: String?, thinkingOptionID: String?, modeID: String?
  ) async throws -> RemoteAgentSettingsApplyResult
  func applyAgentMode(agentID: String, modeID: String) async throws
    -> RemoteAgentSettingsApplyResult
  func applyAgentThinking(
    agentID: String, thinkingOptionID: String?, modeID: String?
  ) async throws -> RemoteAgentSettingsApplyResult
  func createThread(_ intent: RemoteNewThreadIntent) async throws -> RemoteNewThreadResult
  func connectionEvents() async -> AsyncStream<RemoteConnectionEvent>
  func projects() async throws -> [RemoteProject]
  func directoryEntries(cwd: String?) async throws -> [RemoteDirectoryEntry]
  func gitStatus(cwd: String) async throws -> RemoteGitStatus
  func addProject(path: String) async throws -> RemoteProject
  func threads(projectID: String) async throws -> [RemoteThread]
  func archiveThread(agentID: String) async throws
  func markThreadRead(agentID: String) async throws
  func history(agentID: String, before cursor: RemoteTimelineCursor?) async throws -> RemoteTimeline
  func events(agentID: String) async throws -> AsyncThrowingStream<RemoteTimelineUpdate, Error>
  func send(agentID: String, text: String) async throws
  func supportsAgentRequestReceipts() async -> Bool
  func send(
    agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior
  ) async throws
  func send(
    agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior,
    images: [RemoteDraftImage]
  ) async throws
  func readImage(cwd: String, path: String, maxBytes: Int) async throws -> Data
  func stop(agentID: String) async throws -> RemoteAgentControlSnapshot?
  func pendingPermissions() async throws -> [RemotePermission]
  func answerPermission(_ permission: RemotePermission, allow: Bool) async throws
  func answerQuestion(_ permission: RemotePermission, answers: [String: String]?) async throws
  func disconnect() async
}

extension OesapRemoteService {
  func gitStatus(cwd: String) async throws -> RemoteGitStatus {
    throw RemoteServiceError.unavailable("This host does not support repository changes.")
  }
  func directoryEntries(cwd: String?) async throws -> [RemoteDirectoryEntry] {
    throw RemoteServiceError.unavailable("This host does not support directory browsing.")
  }
  func addProject(path: String) async throws -> RemoteProject {
    throw RemoteServiceError.unavailable("This host does not support adding projects.")
  }
  func archiveThread(agentID: String) async throws {
    throw RemoteServiceError.unavailable("This host does not support archiving threads.")
  }
  func markThreadRead(agentID: String) async throws {
    throw RemoteServiceError.unavailable("This host does not support marking threads as read.")
  }
  func serverID() async -> String? { nil }
  func supportsNewThreads() async -> Bool { false }
  func supportsProviderUsage() async -> Bool { false }
  func supportsProviderSubagents() async -> Bool { false }
  func providerSubagents(parentAgentID: String) async throws -> [RemoteProviderSubagent] {
    throw RemoteServiceError.unavailable("This host does not support provider subagents.")
  }
  func providerSubagentHistory(parentAgentID: String, subagentID: String) async throws
    -> RemoteTimeline
  {
    throw RemoteServiceError.unavailable("This host does not support provider subagent timelines.")
  }
  func providerUsage() async throws -> RemoteProviderUsageSnapshot {
    throw RemoteServiceError.unavailable("This host does not support provider usage.")
  }
  func contextUsage(agentID: String) async throws -> RemoteContextUsage? { nil }
  func agentProviders(cwd: String) async throws -> [RemoteAgentProvider] { [] }
  func agentSettings(agentID: String) async throws -> RemoteAgentSettings {
    throw RemoteServiceError.unavailable("This host does not support agent settings.")
  }
  func applyAgentSettings(
    agentID: String, modelID: String?, thinkingOptionID: String?, modeID: String?
  ) async throws -> RemoteAgentSettingsApplyResult {
    throw RemoteServiceError.unavailable("This host does not support agent settings updates.")
  }
  func applyAgentSettings(
    agentID: String, modelID: String?, thinkingOptionID: String?
  ) async throws -> RemoteAgentSettingsApplyResult {
    try await applyAgentSettings(
      agentID: agentID, modelID: modelID, thinkingOptionID: thinkingOptionID, modeID: nil)
  }
  func applyAgentMode(agentID: String, modeID: String) async throws
    -> RemoteAgentSettingsApplyResult
  {
    throw RemoteServiceError.unavailable("This host does not support agent mode updates.")
  }
  func applyAgentThinking(
    agentID: String, thinkingOptionID: String?, modeID: String?
  ) async throws -> RemoteAgentSettingsApplyResult {
    throw RemoteServiceError.unavailable("This host does not support agent effort updates.")
  }
  func createThread(_ intent: RemoteNewThreadIntent) async throws -> RemoteNewThreadResult {
    throw RemoteServiceError.unavailable("This host does not support new thread creation.")
  }
  func supportsAgentRequestReceipts() async -> Bool { false }
  func answerQuestion(_ permission: RemotePermission, answers: [String: String]?) async throws {
    throw RemoteServiceError.unavailable("This host does not support structured agent questions.")
  }
  func send(
    agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior
  ) async throws {
    throw RemoteServiceError.unavailable("Explicit active-turn send behavior is not supported.")
  }
  func send(
    agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior,
    images: [RemoteDraftImage]
  ) async throws {
    if images.isEmpty {
      return try await send(
        agentID: agentID, text: text, messageID: messageID,
        behavior: behavior)
    }
    throw RemoteServiceError.unavailable("Image messages are not supported by this service.")
  }
  func readImage(cwd: String, path: String, maxBytes: Int) async throws -> Data {
    throw RemoteServiceError.unavailable("Image previews are not supported by this service.")
  }
  func stop(agentID: String) async throws -> RemoteAgentControlSnapshot? {
    throw RemoteServiceError.unavailable("Stopping agents is not supported by this service.")
  }
}

protocol OesapConnectionFactory: Sendable {
  func savedConnectionExists() async -> Bool
  func listSavedInstances() async throws -> [SavedPaseoInstance]
  func activeInstanceID() async throws -> String?
  func selectSavedInstance(id: String) async throws -> any OesapRemoteService
  func removeSavedInstance(id: String) async throws
  func connect(_ connection: RemoteConnection) async throws -> any OesapRemoteService
  func reconnect() async throws -> any OesapRemoteService
  func disconnect() async throws
}

extension OesapConnectionFactory {
  func listSavedInstances() async throws -> [SavedPaseoInstance] { [] }
  func activeInstanceID() async throws -> String? { nil }
  func selectSavedInstance(id: String) async throws -> any OesapRemoteService {
    throw RemoteServiceError.unavailable("Selecting saved Paseo instances is not supported here.")
  }
  func removeSavedInstance(id: String) async throws {}
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
      case images
      case performance
    }

    private let mode: Mode
    private var currentService: DemoRemoteService?
    private var savedInstances: [SavedPaseoInstance] = []
    private var selectedInstanceID: String?

    init(mode: Mode = .normal) {
      self.mode = mode
      if ProcessInfo.processInfo.arguments.contains("--demo-saved-connection") {
        let instanceID = "demo-saved-instance"
        savedInstances = [
          SavedPaseoInstance(id: instanceID, name: "Demo host", subtitle: "Demo connection")
        ]
        selectedInstanceID = instanceID
      }
    }

    func savedConnectionExists() async -> Bool { !savedInstances.isEmpty }

    func listSavedInstances() async throws -> [SavedPaseoInstance] { savedInstances }

    func activeInstanceID() async throws -> String? { selectedInstanceID }

    func selectSavedInstance(id: String) async throws -> any OesapRemoteService {
      guard savedInstances.contains(where: { $0.id == id }) else {
        throw RemoteServiceError.unavailable("That saved Paseo instance is no longer available.")
      }
      await currentService?.disconnect()
      let service = makeService()
      currentService = service
      selectedInstanceID = id
      return service
    }

    func connect(_ connection: RemoteConnection) async throws -> any OesapRemoteService {
      if mode == .failure {
        throw RemoteServiceError.authentication(
          "The demo rejected this connection. Check the credentials and try again.")
      }
      let service = makeService()
      let trimmedName = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let name: String
      if !trimmedName.isEmpty {
        name = trimmedName
      } else if !connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        name = connection.endpoint
      } else {
        name = connection.method == .relay ? "Demo relay" : "Demo host"
      }
      let subtitle =
        switch connection.method {
        case .direct:
          "Direct · \(connection.usesTLS ? "TLS" : "No TLS") · \(connection.endpoint)"
        case .relay:
          "Relay pairing · encrypted"
        }
      let instance = SavedPaseoInstance(id: UUID().uuidString, name: name, subtitle: subtitle)
      savedInstances.append(instance)
      selectedInstanceID = instance.id
      currentService = service
      return service
    }

    func reconnect() async throws -> any OesapRemoteService {
      guard let selectedInstanceID,
        savedInstances.contains(where: { $0.id == selectedInstanceID }),
        let currentService
      else {
        throw RemoteServiceError.connectionLost("There is no active demo connection to restore.")
      }
      return currentService
    }

    func removeSavedInstance(id: String) async throws {
      savedInstances.removeAll(where: { $0.id == id })
      guard selectedInstanceID == id else { return }
      selectedInstanceID = nil
      await currentService?.disconnect()
      currentService = nil
    }

    func disconnect() async throws {
      if let selectedInstanceID {
        savedInstances.removeAll(where: { $0.id == selectedInstanceID })
      }
      selectedInstanceID = nil
      await currentService?.disconnect()
      currentService = nil
    }

    private func makeService() -> DemoRemoteService {
      DemoRemoteService(
        isEmpty: mode == .empty, failsSending: mode == .sendFailure,
        creationSupported: mode != .creationUnsupported,
        overviewEmpty: mode == .overviewEmpty,
        overviewFailure: mode == .overviewFailure,
        usageSupported: mode != .usageUnsupported,
        usageUnavailable: mode == .usageUnavailable,
        usageFailure: mode == .usageFailure,
        agentControlSupported: mode == .agentControl,
        imageFixtures: mode == .images, performanceFixtures: mode == .performance)
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
    private let imageFixtures: Bool
    private let performanceFixtures: Bool
    private var performanceTasks: [String: Task<Void, Never>] = [:]
    private var performanceSteps: [String: Int] = [:]
    private var performanceText: [String: String] = [:]
    private var subscriptionIDs: [String: UUID] = [:]
    private var continuations:
      [String: AsyncThrowingStream<RemoteTimelineUpdate, Error>.Continuation] = [:]
    private var sentMessages: [String: [RemoteMessage]] = [:]
    private var acceptedMessageIDs: [String: Set<String>] = [:]
    private var createdThreads: [RemoteThread] = []
    private var archivedThreadIDs: Set<String> = []
    private var readThreadIDs: Set<String> = []
    private var creations: [String: RemoteNewThreadResult] = [:]
    private var resolvedPermissions: Set<String> = []
    private var stoppedAgents: Set<String> = []
    private var agentSettingsByID: [String: RemoteAgentSettings] = [:]
    private var closed = false

    init(
      isEmpty: Bool = false, failsSending: Bool = false,
      creationSupported: Bool = true, overviewEmpty: Bool = false,
      overviewFailure: Bool = false, usageSupported: Bool = true,
      usageUnavailable: Bool = false, usageFailure: Bool = false,
      agentControlSupported: Bool = false, imageFixtures: Bool = false,
      performanceFixtures: Bool = false
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
      self.imageFixtures = imageFixtures
      self.performanceFixtures = performanceFixtures
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
            RemoteAgentModel(
              id: "gpt-6-sol", label: "GPT-6 Sol", isDefault: true,
              thinkingOptions: [
                RemoteThinkingOption(
                  id: "medium", label: "Medium", description: nil, isDefault: true),
                RemoteThinkingOption(id: "high", label: "High", description: nil, isDefault: false),
                RemoteThinkingOption(
                  id: "xhigh", label: "Extra high", description: nil, isDefault: false),
              ], defaultThinkingOptionID: "medium"),
            RemoteAgentModel(
              id: "gpt-6-astra", label: "GPT-6 Astra", isDefault: false,
              thinkingOptions: [
                RemoteThinkingOption(id: "high", label: "High", description: nil, isDefault: true),
                RemoteThinkingOption(
                  id: "xhigh", label: "Extra high", description: nil, isDefault: false),
                RemoteThinkingOption(id: "max", label: "Max", description: nil, isDefault: false),
              ], defaultThinkingOptionID: "high"),
          ],
          modes: [
            RemoteAgentMode(
              id: "auto", label: "Default Permissions",
              description: "Edit files and run commands with the default approval flow."),
            RemoteAgentMode(
              id: "auto-review", label: "Auto-review",
              description: "Review eligible permission requests automatically."),
            RemoteAgentMode(
              id: "full-access", label: "Full Access",
              description: "Edit files, run commands, and access the network without prompts."),
          ], defaultModeID: "auto")
      ]
    }

    func agentSettings(agentID: String) async throws -> RemoteAgentSettings {
      try ensureConnected()
      if let stored = agentSettingsByID[agentID] { return stored }
      let projectThreads = try await threads(projectID: "demo-project")
      let toolsThreads = try await threads(projectID: "demo-tools-project")
      let allThreads = projectThreads + toolsThreads
      guard let thread = allThreads.first(where: { $0.id == agentID }),
        let provider = thread.provider
      else {
        throw RemoteServiceError.unavailable("The demo agent is no longer available.")
      }
      let providers = try await agentProviders(cwd: thread.cwd ?? "/demo/oesap")
      let models = providers.first(where: { $0.id == provider })?.models ?? []
      let selected =
        models.first(where: { $0.id == thread.model })
        ?? models.first(where: \.isDefault)
      let modes =
        provider == "codex"
        ? [
          RemoteAgentMode(
            id: "auto", label: "Default Permissions",
            description: "Edit files and run commands with the default approval flow."),
          RemoteAgentMode(
            id: "auto-review", label: "Auto-review",
            description: "Review eligible permission requests automatically."),
          RemoteAgentMode(
            id: "full-access", label: "Full Access",
            description: "Edit files, run commands, and access the network without prompts."),
        ] : []
      let settings = RemoteAgentSettings(
        agentID: agentID, provider: provider, cwd: thread.cwd ?? "/demo/oesap",
        modelID: thread.model, thinkingOptionID: nil,
        effectiveThinkingOptionID: selected?.defaultThinkingOptionID,
        currentModeID: modes.isEmpty ? nil : "auto", availableModes: modes,
        models: models, canApply: !models.isEmpty || !modes.isEmpty,
        supportsThinking: models.contains(where: { !$0.thinkingOptions.isEmpty }),
        status: thread.state.label)
      agentSettingsByID[agentID] = settings
      return settings
    }

    func applyAgentSettings(
      agentID: String, modelID: String?, thinkingOptionID: String?, modeID: String?
    ) async throws -> RemoteAgentSettingsApplyResult {
      var settings = try await agentSettings(agentID: agentID)
      guard settings.canApply else {
        throw RemoteServiceError.unavailable("The demo agent cannot change settings.")
      }
      let model =
        modelID.flatMap { id in settings.models.first(where: { $0.id == id }) }
        ?? settings.models.first(where: \.isDefault)
      guard let model, modelID == nil || model.id == modelID else {
        throw RemoteServiceError.unavailable("The selected model is unavailable.")
      }
      if let thinkingOptionID,
        !model.thinkingOptions.contains(where: { $0.id == thinkingOptionID })
      {
        throw RemoteServiceError.unavailable("The selected reasoning level is unavailable.")
      }
      if let modeID, !settings.availableModes.contains(where: { $0.id == modeID }) {
        throw RemoteServiceError.unavailable("The selected permission mode is unavailable.")
      }
      settings.modelID = modelID
      settings.thinkingOptionID = thinkingOptionID
      settings.effectiveThinkingOptionID = thinkingOptionID ?? model.defaultThinkingOptionID
      if let modeID { settings.currentModeID = modeID }
      agentSettingsByID[agentID] = settings
      return RemoteAgentSettingsApplyResult(
        notice: settings.status == "Running" ? "Settings apply next turn" : nil)
    }

    func applyAgentMode(agentID: String, modeID: String) async throws
      -> RemoteAgentSettingsApplyResult
    {
      var settings = try await agentSettings(agentID: agentID)
      guard settings.canApply,
        settings.availableModes.contains(where: { $0.id == modeID })
      else {
        throw RemoteServiceError.unavailable("The selected permission mode is unavailable.")
      }
      settings.currentModeID = modeID
      agentSettingsByID[agentID] = settings
      return RemoteAgentSettingsApplyResult(
        notice: settings.status == "Running" ? "Permission mode applies next turn" : nil)
    }

    func applyAgentThinking(
      agentID: String, thinkingOptionID: String?, modeID: String?
    ) async throws -> RemoteAgentSettingsApplyResult {
      var settings = try await agentSettings(agentID: agentID)
      guard settings.canApply, settings.supportsThinking else {
        throw RemoteServiceError.unavailable("The demo agent cannot change effort.")
      }
      let model =
        settings.modelID.flatMap { id in
          settings.models.first(where: { $0.id == id })
        } ?? settings.models.first(where: \.isDefault)
      guard let model,
        thinkingOptionID == nil
          || model.thinkingOptions.contains(where: { $0.id == thinkingOptionID })
      else {
        throw RemoteServiceError.unavailable("The selected reasoning level is unavailable.")
      }
      if let modeID, !settings.availableModes.contains(where: { $0.id == modeID }) {
        throw RemoteServiceError.unavailable("The selected permission mode is unavailable.")
      }
      settings.thinkingOptionID = thinkingOptionID
      settings.effectiveThinkingOptionID = thinkingOptionID ?? model.defaultThinkingOptionID
      if let modeID { settings.currentModeID = modeID }
      agentSettingsByID[agentID] = settings
      return RemoteAgentSettingsApplyResult(
        notice: settings.status == "Running" ? "Settings apply next turn" : nil)
    }

    func createThread(_ intent: RemoteNewThreadIntent) async throws -> RemoteNewThreadResult {
      try ensureConnected()
      guard creationSupported else {
        throw RemoteServiceError.unavailable("This demo host does not support new threads.")
      }
      if let previous = creations[intent.idempotencyKey] { return previous }
      let id = "demo-created-\(creations.count + 1)"
      let thread = RemoteThread(
        id: id, title: intent.prompt.isEmpty ? "Image request" : String(intent.prompt.prefix(56)),
        provider: intent.provider,
        model: intent.model, state: .running, requiresAttention: false, attentionReason: nil,
        cwd: intent.cwd)
      createdThreads.insert(thread, at: 0)
      var settings = try await agentSettings(agentID: id)
      settings.currentModeID = intent.modeID ?? settings.currentModeID
      agentSettingsByID[id] = settings
      let timestamp = Date(timeIntervalSince1970: 1_780_000_300)
      sentMessages[id] = [
        RemoteMessage(
          id: "\(id)-prompt", author: .user, text: intent.prompt, timestamp: timestamp,
          clientMessageID: intent.clientMessageID, images: intent.images),
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
          id: "demo-project", name: "Agent Slinger demo", subtitle: "~/Projects/oesap",
          rootPath: "/demo/oesap"),
        RemoteProject(
          id: "demo-tools-project", name: "Agent Slinger tools", subtitle: "~/Projects/tools",
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
        return visibleThreads([
          RemoteThread(
            id: "demo-tools-running", title: "Check tool integrations", provider: "codex",
            model: "gpt-6-sol", state: .running, requiresAttention: false,
            attentionReason: nil,
            contextUsage: RemoteContextUsage(usedTokens: 64_000, maxTokens: 200_000)),
          RemoteThread(
            id: "demo-tools-failed", title: "Fix release build", provider: "codex",
            model: "gpt-6-astra", state: .failed, requiresAttention: true,
            attentionReason: "An agent run failed."),
        ])
      }
      guard projectID == "demo-project" else { return [] }
      return visibleThreads(
        createdThreads + [
          RemoteThread(
            id: "demo-agent-running",
            title: "Build the iOS app",
            provider: "codex",
            model: "gpt-6-sol",
            state: stoppedAgents.contains("demo-agent-running") ? .idle : .running,
            requiresAttention: false,
            attentionReason: nil,
            contextUsage: RemoteContextUsage(usedTokens: 64_000, maxTokens: 200_000),
            cwd: "/demo/oesap"
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
        ])
    }

    func archiveThread(agentID: String) async throws {
      try ensureConnected()
      archivedThreadIDs.insert(agentID)
    }

    func markThreadRead(agentID: String) async throws {
      try ensureConnected()
      readThreadIDs.insert(agentID)
    }

    private func applyReadState(_ thread: RemoteThread) -> RemoteThread {
      guard readThreadIDs.contains(thread.id) else { return thread }
      return RemoteThread(
        id: thread.id, title: thread.title, provider: thread.provider, model: thread.model,
        state: thread.state, requiresAttention: false, attentionReason: nil,
        contextUsage: thread.contextUsage, cwd: thread.cwd)
    }

    private func visibleThreads(_ threads: [RemoteThread]) -> [RemoteThread] {
      threads
        .filter { !archivedThreadIDs.contains($0.id) }
        .map { applyReadState($0) }
    }

    func history(agentID: String, before cursor: RemoteTimelineCursor?) async throws
      -> RemoteTimeline
    {
      try ensureConnected()
      guard !isEmpty else { return RemoteTimeline(messages: [], historyMayBeIncomplete: false) }
      if cursor != nil {
        return RemoteTimeline(messages: [], historyMayBeIncomplete: false)
      }
      var initial: [RemoteMessage]
      let baseTime = Date(timeIntervalSince1970: 1_780_000_000)
      if performanceFixtures && agentID == "demo-agent-running" {
        initial = (0..<1_000).map { index in
          RemoteMessage(
            id: "demo-performance-\(index)", author: index.isMultiple(of: 4) ? .user : .agent,
            text: """
              ## Timeline item \(index + 1)

              A deterministic **Markdown** fixture with `native rendering`.

              - Keep the draft responsive
              - Preserve the reader’s position
              """,
            timestamp: baseTime.addingTimeInterval(Double(index)))
        }
        if let text = performanceText[agentID] {
          initial.append(
            .init(
              id: "demo-performance-stream", author: .agent, text: text,
              timestamp: baseTime.addingTimeInterval(1_000)))
        }
      } else if agentID.hasPrefix("demo-created-") {
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
            timestamp: baseTime,
            images: imageFixtures
              ? [
                RemoteDraftImage(
                  id: "demo-image", data: DemoImageFixture.pngData, mimeType: "image/png",
                  fileName: "demo-preview.png")
              ] : []),
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
        if imageFixtures && agentID == "demo-agent-running" {
          initial.append(
            RemoteMessage(
              id: "demo-image-reply", author: .agent,
              text:
                "Here is a generated preview:\n\n![Synthetic image](artifacts/demo-preview.png)",
              timestamp: baseTime.addingTimeInterval(2)))
        }
      }
      return RemoteTimeline(
        messages: initial + sentMessages[agentID, default: []], historyMayBeIncomplete: false)
    }

    func events(agentID: String) async throws -> AsyncThrowingStream<RemoteTimelineUpdate, Error> {
      try ensureConnected()
      performanceTasks[agentID]?.cancel()
      continuations[agentID]?.finish()
      let subscriptionID = UUID()
      subscriptionIDs[agentID] = subscriptionID
      let stream = AsyncThrowingStream<RemoteTimelineUpdate, Error> { continuation in
        continuations[agentID] = continuation
        continuation.onTermination = { [weak self] _ in
          Task { await self?.removeContinuation(for: agentID, id: subscriptionID) }
        }
      }
      if performanceFixtures && agentID == "demo-agent-running" {
        // A bounded, cancellable offline load scenario. Its task is owned by
        // this subscription and stopped on navigation or disconnect.
        performanceTasks[agentID] = Task { [weak self] in
          do {
            try await Task.sleep(for: .milliseconds(500))
            for _ in 0..<5_000 {
              try Task.checkCancellation()
              guard let self, await self.emitPerformanceChunk(agentID: agentID) else { return }
              try await Task.sleep(for: .milliseconds(10))
            }
          } catch {}
        }
      }
      return stream
    }

    private func emitPerformanceChunk(agentID: String) -> Bool {
      let step = performanceSteps[agentID, default: 0]
      guard step < 5_000, !closed, let continuation = continuations[agentID] else { return false }
      let chunks = [
        "Live ", "**Markdown** ", "keeps ", "up ", "with ", "the ", "stream.\n\n",
        "`swift test`\n\n",
      ]
      let chunk = step == 4_999 ? "\n\n**Streaming complete.**" : chunks[step % chunks.count]
      performanceText[agentID, default: ""] += chunk
      performanceSteps[agentID] = step + 1
      continuation.yield(
        .message(
          .init(
            id: "demo-performance-stream", author: .agent, text: chunk,
            timestamp: Date(timeIntervalSince1970: 1_780_001_000)),
          cursor: nil, isDelta: true))
      if step == 4_999 {
        stoppedAgents.insert(agentID)
        continuation.yield(.threadState(.idle, requiresAttention: false, reason: nil))
      }
      return true
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
      try await send(
        agentID: agentID, text: text, messageID: messageID,
        behavior: behavior, images: [])
    }

    func send(
      agentID: String, text: String, messageID: String, behavior: RemoteActiveTurnBehavior,
      images: [RemoteDraftImage]
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
        id: "demo-user-\(index)", author: .user, text: text, timestamp: timestamp,
        clientMessageID: messageID, images: images)
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

    func gitStatus(cwd: String) async throws -> RemoteGitStatus {
      try ensureConnected()
      let path = "Sources/Oesap/Features/ChatView.swift"
      return RemoteGitStatus(
        files: [RemoteGitChangedFile(path: path, additions: 2, deletions: 1, status: "ok")],
        additions: 2, deletions: 1,
        diffByPath: [
          path:
            "diff --git a/\(path) b/\(path)\n@@ -1,3 +1,4 @@\n import SwiftUI\n-old title\n+new title\n+another line\n"
        ])
    }

    func readImage(cwd: String, path: String, maxBytes: Int) async throws -> Data {
      try ensureConnected()
      guard imageFixtures, cwd == "/demo/oesap", path == "artifacts/demo-preview.png",
        DemoImageFixture.pngData.count <= maxBytes
      else { throw RemoteServiceError.unavailable("The demo image was not found.") }
      return DemoImageFixture.pngData
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
      for task in performanceTasks.values { task.cancel() }
      performanceTasks.removeAll()
      subscriptionIDs.removeAll()
      for continuation in continuations.values {
        continuation.finish()
      }
      continuations.removeAll()
    }

    private func ensureConnected() throws {
      if closed { throw RemoteServiceError.connectionLost("The demo connection has been closed.") }
    }

    private func removeContinuation(for agentID: String, id: UUID) {
      guard subscriptionIDs[agentID] == id else { return }
      subscriptionIDs[agentID] = nil
      continuations[agentID] = nil
      performanceTasks.removeValue(forKey: agentID)?.cancel()
    }
  }
#endif
