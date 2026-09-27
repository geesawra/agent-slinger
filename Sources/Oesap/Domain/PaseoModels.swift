import Foundation

/// JSON value used for protocol fields that Paseo may extend independently of Oesap.
public indirect enum PaseoJSONValue: Codable, Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([PaseoJSONValue])
  case object([String: PaseoJSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([PaseoJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: PaseoJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  public subscript(_ key: String) -> PaseoJSONValue? {
    guard case .object(let values) = self else { return nil }
    return values[key]
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    guard case .number(let value) = self else { return nil }
    return Int(exactly: value)
  }

  public var objectValue: [String: PaseoJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }
}

public struct PaseoConnectionInfo: Sendable, Equatable {
  public let serverID: String
  public let hostname: String?
  public let version: String?
  public let features: [String: Bool]

  public init(
    serverID: String, hostname: String? = nil, version: String? = nil, features: [String: Bool]
  ) {
    self.serverID = serverID
    self.hostname = hostname
    self.version = version
    self.features = features
  }
}

public enum PaseoConnectionState: Sendable, Equatable {
  case disconnected
  case connecting
  case connected(PaseoConnectionInfo)
}

public struct PaseoProject: Sendable, Equatable, Identifiable {
  public let id: String
  /// Optional project-list descriptor field; thread filtering uses the stable `id`.
  public let key: String?
  public let name: String
  public let rootPath: String
  public let kind: String

  public init(id: String, key: String?, name: String, rootPath: String, kind: String) {
    self.id = id
    self.key = key
    self.name = name
    self.rootPath = rootPath
    self.kind = kind
  }
}

public struct PaseoProviderModel: Sendable, Equatable {
  public let id: String
  public let label: String
  public let isDefault: Bool

  public init(id: String, label: String, isDefault: Bool) {
    self.id = id
    self.label = label
    self.isDefault = isDefault
  }
}

public struct PaseoProvider: Sendable, Equatable {
  public let id: String
  public let label: String
  public let available: Bool
  public let error: String?
  public let models: [PaseoProviderModel]

  public init(
    id: String, label: String, available: Bool, error: String?, models: [PaseoProviderModel]
  ) {
    self.id = id
    self.label = label
    self.available = available
    self.error = error
    self.models = models
  }
}

public struct PaseoAgentCreationIntent: Sendable, Equatable {
  public let idempotencyKey: String
  public let clientMessageID: String
  public let provider: String
  public let model: String?
  public let cwd: String
  public let initialPrompt: String
  public let images: [PaseoImage]

  public init(
    idempotencyKey: String, clientMessageID: String, provider: String, model: String?,
    cwd: String, initialPrompt: String, images: [PaseoImage] = []
  ) {
    self.idempotencyKey = idempotencyKey
    self.clientMessageID = clientMessageID
    self.provider = provider
    self.model = model
    self.cwd = cwd
    self.initialPrompt = initialPrompt
    self.images = images
  }
}

public struct PaseoImage: Sendable, Equatable {
  public let data: Data
  public let mimeType: String

  public init(data: Data, mimeType: String) {
    self.data = data
    self.mimeType = mimeType
  }
}

public struct PaseoAgentCreationResult: Sendable, Equatable {
  public let agent: PaseoCreatedAgent?
  public let promptAccepted: Bool
  public let error: String?
  public let safeToRestart: Bool

  public init(
    agent: PaseoCreatedAgent?, promptAccepted: Bool, error: String?, safeToRestart: Bool = false
  ) {
    self.agent = agent
    self.promptAccepted = promptAccepted
    self.error = error
    self.safeToRestart = safeToRestart
  }
}

public struct PaseoCreatedAgent: Sendable, Equatable {
  public let id: String
  public let title: String?
  public let provider: String
  public let model: String?
  public let status: String
  public let requiresAttention: Bool
  public let attentionReason: String?
  public let cwd: String?

  public init(
    id: String, title: String?, provider: String, model: String?, status: String,
    requiresAttention: Bool, attentionReason: String?, cwd: String? = nil
  ) {
    self.id = id
    self.title = title
    self.provider = provider
    self.model = model
    self.status = status
    self.requiresAttention = requiresAttention
    self.attentionReason = attentionReason
    self.cwd = cwd
  }
}

public struct PaseoThread: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String?
  public let provider: String
  public let model: String?
  public let status: String
  public let cwd: String
  public let createdAt: String
  public let updatedAt: String
  public let archivedAt: String?
  public let requiresAttention: Bool
  public let attentionReason: String?
  public let projectKey: String
  public let projectName: String
  public let pendingPermissions: [PaseoPermissionRequest]
  public let contextWindowUsedTokens: Double?
  public let contextWindowMaxTokens: Double?

  public init(
    id: String,
    title: String?,
    provider: String,
    model: String?,
    status: String,
    cwd: String,
    createdAt: String,
    updatedAt: String,
    archivedAt: String?,
    requiresAttention: Bool,
    attentionReason: String?,
    projectKey: String,
    projectName: String,
    pendingPermissions: [PaseoPermissionRequest] = [],
    contextWindowUsedTokens: Double? = nil,
    contextWindowMaxTokens: Double? = nil
  ) {
    self.id = id
    self.title = title
    self.provider = provider
    self.model = model
    self.status = status
    self.cwd = cwd
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.archivedAt = archivedAt
    self.requiresAttention = requiresAttention
    self.attentionReason = attentionReason
    self.projectKey = projectKey
    self.projectName = projectName
    self.pendingPermissions = pendingPermissions
    self.contextWindowUsedTokens = contextWindowUsedTokens
    self.contextWindowMaxTokens = contextWindowMaxTokens
  }
}

public struct PaseoProviderUsageSnapshot: Sendable, Equatable {
  public let fetchedAt: String
  public let providers: [PaseoProviderUsage]
}

public struct PaseoAgentContextUsage: Sendable, Equatable {
  public let usedTokens: Double?
  public let maxTokens: Double?
}

public struct PaseoProviderUsage: Sendable, Equatable {
  public let id: String
  public let displayName: String
  public let status: String
  public let planLabel: String?
  public let sourceLabel: String?
  public let fetchedAt: String?
  public let nextRefreshAt: String?
  public let windows: [PaseoProviderUsageWindow]
  public let balances: [PaseoProviderUsageBalance]
  public let details: [PaseoProviderUsageDetail]
  public let error: String?
}

public struct PaseoProviderUsageWindow: Sendable, Equatable {
  public let id: String
  public let label: String
  public let usedPct: Double?
  public let remainingPct: Double?
  public let resetsAt: String?
  public let runsOutAt: String?
  public let shortfallPct: Double?
  public let tone: String?
}

public struct PaseoProviderUsageBalance: Sendable, Equatable {
  public let id: String
  public let label: String
  public let used: Double?
  public let remaining: Double?
  public let limit: Double?
  public let unit: String
  public let resetsAt: String?
  public let tone: String?
}

public struct PaseoProviderUsageDetail: Sendable, Equatable {
  public let id: String
  public let label: String
  public let value: String
  public let tone: String?
}

public struct PaseoPageRequest: Sendable, Equatable {
  public let cursor: String?
  public let limit: Int

  public init(cursor: String? = nil, limit: Int = 100) {
    self.cursor = cursor
    self.limit = min(max(limit, 1), 200)
  }

  public static let first = PaseoPageRequest()
}

public struct PaseoPage<Value: Sendable & Equatable>: Sendable, Equatable {
  public let items: [Value]
  public let nextCursor: String?
  public let previousCursor: String?
  public let hasMore: Bool

  public init(items: [Value], nextCursor: String?, previousCursor: String?, hasMore: Bool) {
    self.items = items
    self.nextCursor = nextCursor
    self.previousCursor = previousCursor
    self.hasMore = hasMore
  }
}

public struct PaseoTimelineCursor: Sendable, Codable, Equatable {
  public let epoch: String
  public let sequence: Int

  public init(epoch: String, sequence: Int) {
    self.epoch = epoch
    self.sequence = sequence
  }
}

public enum PaseoTimelineDirection: String, Sendable {
  case tail
  case before
  case after
}

public struct PaseoTimelineEntry: Sendable, Equatable, Identifiable {
  public let id: String
  public let provider: String
  public let item: PaseoJSONValue
  public let turnID: String?
  public let timestamp: String
  public let startSequence: Int
  public let endSequence: Int
  public let collapsed: [String]

  public init(
    id: String, provider: String, item: PaseoJSONValue, turnID: String?, timestamp: String,
    startSequence: Int, endSequence: Int, collapsed: [String]
  ) {
    self.id = id
    self.provider = provider
    self.item = item
    self.turnID = turnID
    self.timestamp = timestamp
    self.startSequence = startSequence
    self.endSequence = endSequence
    self.collapsed = collapsed
  }
}

public struct PaseoTimelinePage: Sendable, Equatable {
  public let agentID: String
  public let epoch: String
  public let entries: [PaseoTimelineEntry]
  public let startCursor: PaseoTimelineCursor?
  public let endCursor: PaseoTimelineCursor?
  public let hasOlder: Bool
  public let hasNewer: Bool
  public let reset: Bool
  public let staleCursor: Bool
  public let gap: Bool

  public init(
    agentID: String, epoch: String, entries: [PaseoTimelineEntry],
    startCursor: PaseoTimelineCursor?, endCursor: PaseoTimelineCursor?, hasOlder: Bool,
    hasNewer: Bool, reset: Bool, staleCursor: Bool, gap: Bool
  ) {
    self.agentID = agentID
    self.epoch = epoch
    self.entries = entries
    self.startCursor = startCursor
    self.endCursor = endCursor
    self.hasOlder = hasOlder
    self.hasNewer = hasNewer
    self.reset = reset
    self.staleCursor = staleCursor
    self.gap = gap
  }
}

public enum PaseoTimelineReloadReason: Sendable, Equatable {
  case replacement(epoch: String)
  case sequenceGap(expected: Int, received: Int)
  case bufferOverflow
}

public enum PaseoTimelineEvent: Sendable, Equatable {
  case item(
    agentID: String, event: PaseoJSONValue, timestamp: String, sequence: Int?, epoch: String?)
  case reloadRequired(agentID: String, reason: PaseoTimelineReloadReason)
  case permissionRequested(PaseoPermissionRequest)
  case permissionResolved(agentID: String, requestID: String)
}

public struct PaseoPermissionAction: Sendable, Equatable, Identifiable {
  public let id: String
  public let label: String
  public let behavior: String
  public let intent: String?

  public init(id: String, label: String, behavior: String, intent: String?) {
    self.id = id
    self.label = label
    self.behavior = behavior
    self.intent = intent
  }
}

public struct PaseoPermissionRequest: Sendable, Equatable, Identifiable {
  public let id: String
  public let agentID: String
  public let provider: String
  public let name: String
  public let kind: String
  public let title: String?
  public let description: String?
  public let input: PaseoJSONValue?
  public let actions: [PaseoPermissionAction]

  public init(
    id: String, agentID: String, provider: String, name: String, kind: String, title: String?,
    description: String?, input: PaseoJSONValue?, actions: [PaseoPermissionAction]
  ) {
    self.id = id
    self.agentID = agentID
    self.provider = provider
    self.name = name
    self.kind = kind
    self.title = title
    self.description = description
    self.input = input
    self.actions = actions
  }
}

public enum PaseoPermissionDecision: Sendable, Equatable {
  case allow(actionID: String?)
  case deny(actionID: String?, message: String?, interrupt: Bool?)
}

public enum PaseoActiveTurnBehavior: String, Sendable {
  case interrupt
  case steer
}

public struct PaseoAgentControlSnapshot: Sendable, Equatable {
  public let id: String
  public let status: String
  public let requiresAttention: Bool
  public let attentionReason: String?

  public init(id: String, status: String, requiresAttention: Bool, attentionReason: String?) {
    self.id = id
    self.status = status
    self.requiresAttention = requiresAttention
    self.attentionReason = attentionReason
  }
}

public enum PaseoProtocolError: Error, Sendable, Equatable, LocalizedError {
  case notConnected
  case disconnected(String)
  case malformedMessage(String)
  case requestTimedOut(String)
  case unsupportedCapability(String)
  case requestRejected(String)
  case unexpectedResponse(String)

  public var errorDescription: String? {
    switch self {
    case .notConnected: "The Paseo host is not connected."
    case .disconnected(let reason): "The Paseo connection ended: \(reason)"
    case .malformedMessage(let detail): "The Paseo host sent an invalid message: \(detail)"
    case .requestTimedOut(let operation): "The Paseo host did not answer \(operation) in time."
    case .unsupportedCapability(let capability): "The Paseo host does not support \(capability)."
    case .requestRejected(let detail): detail
    case .unexpectedResponse(let type): "The Paseo host returned an unexpected response (\(type))."
    }
  }
}

public protocol PaseoService: Sendable {
  func connect() async throws -> PaseoConnectionInfo
  func connectionEvents() async -> AsyncStream<PaseoConnectionState>
  func listProjects() async throws -> [PaseoProject]
  func agentContextUsage(agentID: String) async throws -> PaseoAgentContextUsage
  func supportsProviderUsage() async -> Bool
  func supportsAgentRequestReceipts() async -> Bool
  func listProviderUsage() async throws -> PaseoProviderUsageSnapshot
  func listProviders(cwd: String) async throws -> [PaseoProvider]
  func createAgent(_ intent: PaseoAgentCreationIntent) async throws -> PaseoAgentCreationResult
  func listThreads(projectID: String, page: PaseoPageRequest) async throws -> PaseoPage<PaseoThread>
  func history(
    agentID: String, direction: PaseoTimelineDirection, cursor: PaseoTimelineCursor?, limit: Int
  ) async throws -> PaseoTimelinePage
  func events(agentID: String, after cursor: PaseoTimelineCursor?) async throws
    -> AsyncThrowingStream<PaseoTimelineEvent, Error>
  func send(agentID: String, text: String) async throws
  func send(
    agentID: String, text: String, messageID: String,
    activeTurnBehavior: PaseoActiveTurnBehavior
  ) async throws
  func send(
    agentID: String, text: String, messageID: String,
    activeTurnBehavior: PaseoActiveTurnBehavior, images: [PaseoImage]
  ) async throws
  func readImage(cwd: String, path: String, maxBytes: Int) async throws -> Data
  func cancelAgent(agentID: String) async throws -> PaseoAgentControlSnapshot?
  func pendingPermissions() async throws -> [PaseoPermissionRequest]
  func answerPermission(agentID: String, requestID: String, decision: PaseoPermissionDecision)
    async throws
  func disconnect() async
}

extension PaseoService {
  public func agentContextUsage(agentID: String) async throws -> PaseoAgentContextUsage {
    throw PaseoProtocolError.unsupportedCapability("agent context usage")
  }
  public func supportsProviderUsage() async -> Bool { false }
  public func supportsAgentRequestReceipts() async -> Bool { false }
  public func send(
    agentID: String, text: String, messageID: String,
    activeTurnBehavior: PaseoActiveTurnBehavior
  ) async throws {
    throw PaseoProtocolError.unsupportedCapability("explicit agent message control")
  }
  public func send(
    agentID: String, text: String, messageID: String,
    activeTurnBehavior: PaseoActiveTurnBehavior, images: [PaseoImage]
  ) async throws {
    if images.isEmpty {
      return try await send(
        agentID: agentID, text: text, messageID: messageID,
        activeTurnBehavior: activeTurnBehavior)
    }
    throw PaseoProtocolError.unsupportedCapability("image messages")
  }
  public func readImage(cwd: String, path: String, maxBytes: Int) async throws -> Data {
    throw PaseoProtocolError.unsupportedCapability("image file preview")
  }
  public func cancelAgent(agentID: String) async throws -> PaseoAgentControlSnapshot? {
    throw PaseoProtocolError.unsupportedCapability("agent cancellation")
  }
  public func listProviderUsage() async throws -> PaseoProviderUsageSnapshot {
    throw PaseoProtocolError.unsupportedCapability("provider usage")
  }
  public func listProviders(cwd: String) async throws -> [PaseoProvider] {
    throw PaseoProtocolError.unsupportedCapability("provider discovery")
  }

  public func createAgent(_ intent: PaseoAgentCreationIntent) async throws
    -> PaseoAgentCreationResult
  {
    throw PaseoProtocolError.unsupportedCapability("agent creation")
  }
}

extension PaseoService {
  public func listThreads(projectID: String) async throws -> PaseoPage<PaseoThread> {
    try await listThreads(projectID: projectID, page: .first)
  }

  public func history(agentID: String) async throws -> PaseoTimelinePage {
    try await history(agentID: agentID, direction: .tail, cursor: nil, limit: 100)
  }

  public func events(agentID: String) async throws -> AsyncThrowingStream<PaseoTimelineEvent, Error>
  {
    try await events(agentID: agentID, after: nil)
  }
}
