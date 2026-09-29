import Foundation

/// Text frame boundary implemented by the direct and relay transports.
protocol PaseoFrameTransport: Sendable {
  func connect() async throws
  func send(_ text: String) async throws
  func receive() async throws -> String
  func close() async
}

extension PaseoTransport: PaseoFrameTransport {}

/// Small Swift adapter for the subset of the Paseo WebSocket protocol used by Oesap.
public actor PaseoProtocolClient: PaseoService {
  private struct PendingRequest {
    let responseType: String
    let allowError: Bool
    let continuation: CheckedContinuation<PaseoJSONValue, Error>
    let timeout: Task<Void, Never>
    var sendTask: Task<Void, Never>?
  }

  private struct TimelineObservation {
    let agentID: String
    let continuation: AsyncThrowingStream<PaseoTimelineEvent, Error>.Continuation
    var lastSequence: Int?
    var epoch: String?
  }

  private struct IncomingEnvelope: Decodable {
    let type: String
    let message: IncomingMessage?
  }

  private struct IncomingMessage: Decodable {
    let type: String
    let payload: PaseoJSONValue?
    let requestId: String?
  }

  private let transport: any PaseoFrameTransport
  private let clientID: String
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var receiver: Task<Void, Never>?
  private var serverInfo: PaseoConnectionInfo?
  private var connectionState: PaseoConnectionState = .disconnected
  private var handshake: CheckedContinuation<PaseoConnectionInfo, Error>?
  private var handshakeTimeout: Task<Void, Never>?
  private var pending: [String: PendingRequest] = [:]
  private var subscriptions: [String: TimelineObservation] = [:]
  private var pendingTimelineSubscriptions: [String: Int] = [:]
  private var earlyTimelineEvents: [String: [IncomingMessage]] = [:]
  private var earlyTimelineOverflow = Set<String>()
  private var connectionObservers: [UUID: AsyncStream<PaseoConnectionState>.Continuation] = [:]

  init(
    transport: any PaseoFrameTransport,
    clientID: String = "oesap-ios-\(UUID().uuidString.lowercased())"
  ) {
    self.transport = transport
    self.clientID = clientID
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder
    self.decoder = JSONDecoder()
  }

  public func connect() async throws -> PaseoConnectionInfo {
    if let serverInfo { return serverInfo }
    guard receiver == nil else { throw PaseoProtocolError.notConnected }
    setConnectionState(.connecting)
    do {
      try await transport.connect()
    } catch {
      setConnectionState(Self.failureState(for: error))
      throw error
    }
    receiver = Task { await self.receiveLoop() }

    let hello: [String: PaseoJSONValue] = [
      "type": .string("hello"),
      "clientId": .string(clientID),
      "clientType": .string("mobile"),
      "protocolVersion": .number(1),
      "capabilities": .object([
        "all_providers": .bool(true),
        "owned_subscriptions": .bool(true),
        "selective_agent_timeline": .bool(true),
        "explicit_event_subscriptions": .bool(true),
        "timeline_replacement_invalidation": .bool(true),
        "timeline_notifications": .bool(true),
        "project_updates": .bool(true),
      ]),
    ]
    let text = try encode(hello)

    do {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          handshake = continuation
          handshakeTimeout = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self.failHandshake(PaseoProtocolError.requestTimedOut("the hello handshake"))
          }
          Task {
            do {
              try await transport.send(text)
            } catch {
              self.failHandshake(error)
            }
          }
        }
      } onCancel: {
        Task { await self.failHandshake(CancellationError()) }
      }
    } catch {
      receiver?.cancel()
      await transport.close()
      receiver = nil
      failAll(error)
      serverInfo = nil
      setConnectionState(Self.failureState(for: error))
      throw error
    }
  }

  public func connectionEvents() async -> AsyncStream<PaseoConnectionState> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<PaseoConnectionState>.makeStream(
      bufferingPolicy: .bufferingNewest(8))
    connectionObservers[id] = continuation
    continuation.yield(connectionState)
    continuation.onTermination = { @Sendable _ in
      Task { await self.removeConnectionObserver(id) }
    }
    return stream
  }

  public func listProjects() async throws -> [PaseoProject] {
    try requireConnected()
    try requireFeature("projectList", as: "project listing")
    let payload = try await request(
      type: "project.list.request",
      responseType: "project.list.response",
      operation: "project listing"
    )
    guard let rows = payload["projects"]?.arrayValue else {
      throw PaseoProtocolError.malformedMessage("project list omitted its projects array")
    }
    let projects = try rows.map(decodeProject)
    var projectIDs = Set<String>()
    for project in projects {
      guard projectIDs.insert(project.id).inserted else {
        throw PaseoProtocolError.malformedMessage("project list contained a duplicate project id")
      }
    }
    return projects
  }

  public func directoryEntries(cwd: String?) async throws -> [PaseoDirectoryEntry] {
    try requireConnected()
    var fields: [String: PaseoJSONValue] = [
      "query": .string(""),
      "includeDirectories": .bool(true),
      "includeFiles": .bool(true),
      "limit": .number(100),
    ]
    if let cwd, !cwd.isEmpty { fields["cwd"] = .string(cwd) }
    let payload = try await request(
      type: "directory_suggestions_request",
      fields: fields,
      responseType: "directory_suggestions_response",
      operation: "host directory browsing",
      allowError: true,
      timeoutSeconds: 45
    )
    if let error = payload["error"]?.stringValue, !error.isEmpty {
      throw PaseoProtocolError.requestRejected(error)
    }
    guard let directoryPaths = payload["directories"]?.arrayValue else {
      throw PaseoProtocolError.malformedMessage("directory suggestions omitted their directories")
    }

    var entries: [PaseoDirectoryEntry] = []
    var seenPaths = Set<String>()
    for value in payload["entries"]?.arrayValue ?? [] {
      guard let path = value["path"]?.stringValue, !path.isEmpty,
        let kind = value["kind"]?.stringValue.flatMap(PaseoDirectoryEntry.Kind.init(rawValue:))
      else {
        throw PaseoProtocolError.malformedMessage("directory suggestion contained an invalid entry")
      }
      if seenPaths.insert(path).inserted {
        entries.append(PaseoDirectoryEntry(path: path, kind: kind))
      }
    }
    for value in directoryPaths {
      guard let path = value.stringValue, !path.isEmpty else {
        throw PaseoProtocolError.malformedMessage("directory suggestion contained an invalid path")
      }
      if seenPaths.insert(path).inserted {
        entries.append(PaseoDirectoryEntry(path: path, kind: .directory))
      }
    }
    return entries
  }

  public func addProject(path: String) async throws -> PaseoProject {
    try requireConnected()
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose a folder before adding a project.")
    }
    let payload = try await request(
      type: "project.add.request",
      fields: ["cwd": .string(trimmedPath)],
      responseType: "project.add.response",
      operation: "project registration",
      allowError: true,
      timeoutSeconds: 45
    )
    if let error = payload["error"]?.stringValue, !error.isEmpty {
      throw PaseoProtocolError.requestRejected(error)
    }
    guard let project = payload["project"], case .object = project else {
      throw PaseoProtocolError.requestRejected("The Paseo host did not register that folder.")
    }
    return try decodeProject(project)
  }

  public func checkoutStatus(cwd: String) async throws -> PaseoCheckoutStatus {
    try requireConnected()
    guard !cwd.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose a workspace before checking git status.")
    }
    let payload = try await request(
      type: "checkout_status_request",
      fields: ["cwd": .string(cwd)],
      responseType: "checkout_status_response",
      operation: "git status", allowError: true, timeoutSeconds: 60)
    guard payload["cwd"]?.stringValue == cwd,
      let isGit = payload["isGit"]?.boolValue,
      let isPaseoOwnedWorktree = payload["isPaseoOwnedWorktree"]?.boolValue,
      let hasRemote = payload["hasRemote"]?.boolValue
    else {
      throw PaseoProtocolError.malformedMessage("git status response omitted required fields")
    }
    let aheadBehind: PaseoCheckoutAheadBehind?
    if let value = payload["aheadBehind"], case .object = value {
      guard let ahead = value["ahead"]?.intValue, ahead >= 0,
        let behind = value["behind"]?.intValue, behind >= 0
      else {
        throw PaseoProtocolError.malformedMessage("git status had invalid ahead/behind counts")
      }
      aheadBehind = PaseoCheckoutAheadBehind(ahead: ahead, behind: behind)
    } else {
      aheadBehind = nil
    }
    if isGit && (payload["repoRoot"]?.stringValue == nil || payload["isDirty"]?.boolValue == nil) {
      throw PaseoProtocolError.malformedMessage("git status omitted repository details")
    }
    return PaseoCheckoutStatus(
      cwd: cwd, isGit: isGit, isPaseoOwnedWorktree: isPaseoOwnedWorktree,
      repoRoot: payload["repoRoot"]?.stringValue,
      currentBranch: payload["currentBranch"]?.stringValue,
      isDirty: payload["isDirty"]?.boolValue,
      baseRef: payload["baseRef"]?.stringValue,
      aheadBehind: aheadBehind,
      aheadOfOrigin: payload["aheadOfOrigin"]?.intValue,
      behindOfOrigin: payload["behindOfOrigin"]?.intValue,
      hasRemote: hasRemote, remoteURL: payload["remoteUrl"]?.stringValue,
      upstreamRef: payload["upstreamRef"]?.stringValue,
      error: try decodeCheckoutError(payload["error"]))
  }

  public func checkoutDiff(cwd: String) async throws -> PaseoCheckoutDiff {
    try requireConnected()
    guard !cwd.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose a workspace before checking changes.")
    }
    let payload = try await request(
      type: "checkout.diff.get.request",
      fields: [
        "cwd": .string(cwd),
        "compare": .object(["mode": .string("uncommitted")]),
      ],
      responseType: "checkout.diff.get.response",
      operation: "git diff", allowError: true, timeoutSeconds: 60)
    guard payload["cwd"]?.stringValue == cwd,
      let rows = payload["files"]?.arrayValue
    else { throw PaseoProtocolError.malformedMessage("git diff response omitted its files") }
    return PaseoCheckoutDiff(
      cwd: cwd,
      files: try rows.map(decodeDiffFile),
      diffTooLarge: payload["diffTooLarge"]?.boolValue ?? false,
      error: try decodeCheckoutError(payload["error"]))
  }

  public func supportsProviderUsage() async -> Bool {
    serverInfo?.features["providerUsageList"] == true
  }

  public func supportsAgentRequestReceipts() async -> Bool {
    serverInfo?.features["agentRequestReceipts"] == true
  }

  public func agentContextUsage(agentID: String) async throws -> PaseoAgentContextUsage {
    try requireConnected()
    guard !agentID.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose an agent before checking context usage.")
    }
    let payload = try await request(
      type: "fetch_agent_request",
      fields: ["agentId": .string(agentID)],
      responseType: "fetch_agent_response",
      operation: "agent context usage"
    )
    guard let agent = payload["agent"], agent.objectValue != nil else {
      throw PaseoProtocolError.requestRejected("The agent is no longer available.")
    }
    return PaseoAgentContextUsage(
      usedTokens: agent["lastUsage"]?["contextWindowUsedTokens"]?.nonNegativeNumber,
      maxTokens: agent["lastUsage"]?["contextWindowMaxTokens"]?.nonNegativeNumber)
  }

  public func listProviderUsage() async throws -> PaseoProviderUsageSnapshot {
    try requireConnected()
    try requireFeature("providerUsageList", as: "provider usage")
    let payload = try await request(
      type: "provider.usage.list.request",
      responseType: "provider.usage.list.response",
      operation: "provider usage"
    )
    guard let fetchedAt = payload["fetchedAt"]?.stringValue,
      let entries = payload["providers"]?.arrayValue
    else {
      throw PaseoProtocolError.malformedMessage("provider usage omitted fetchedAt or providers")
    }
    return PaseoProviderUsageSnapshot(
      fetchedAt: fetchedAt, providers: try entries.map(decodeProviderUsage))
  }

  public func listProviders(cwd: String) async throws -> [PaseoProvider] {
    try requireConnected()
    try requireFeature("providersSnapshot", as: "provider discovery")
    try requireFeature("providersSnapshotCwd", as: "project-specific provider discovery")
    let payload = try await request(
      type: "get_providers_snapshot_request",
      fields: ["cwd": .string(cwd)],
      responseType: "get_providers_snapshot_response",
      operation: "provider discovery"
    )
    guard let fullEntries = payload["entries"]?.arrayValue else {
      throw PaseoProtocolError.malformedMessage("provider snapshot omitted its entries")
    }
    let compactSnapshot = payload["compactSnapshot"]
    let entries =
      fullEntries.isEmpty
      ? (compactSnapshot?["entries"]?.arrayValue ?? fullEntries) : fullEntries
    let thinkingSets = compactSnapshot?["thinkingSets"]?.arrayValue ?? []
    return try entries.map { entry in
      guard let id = entry["provider"]?.stringValue, !id.isEmpty,
        let status = entry["status"]?.stringValue
      else {
        throw PaseoProtocolError.malformedMessage("provider snapshot omitted provider or status")
      }
      let models = try (entry["models"]?.arrayValue ?? []).compactMap {
        model
          -> PaseoProviderModel? in
        guard model["isSelectable"]?.boolValue != false else { return nil }
        guard let modelID = model["id"]?.stringValue,
          let label = model["label"]?.stringValue
        else { throw PaseoProtocolError.malformedMessage("provider model omitted id or label") }
        let thinkingSet: PaseoJSONValue?
        if let index = model["thinkingSet"]?.intValue {
          guard thinkingSets.indices.contains(index) else {
            throw PaseoProtocolError.malformedMessage(
              "provider model referenced an invalid thinking set")
          }
          thinkingSet = thinkingSets[index]
        } else {
          thinkingSet = nil
        }
        let thinkingRows = try optionalArray(
          model["thinkingOptions"] ?? thinkingSet?["options"], field: "model thinking options")
        let thinkingOptions = try thinkingRows.map { option in
          guard let optionID = option["id"]?.stringValue, !optionID.isEmpty,
            let optionLabel = option["label"]?.stringValue
          else {
            throw PaseoProtocolError.malformedMessage("thinking option omitted id or label")
          }
          return PaseoThinkingOption(
            id: optionID, label: optionLabel, description: option["description"]?.stringValue,
            isDefault: option["isDefault"]?.boolValue == true)
        }
        let defaultThinkingOptionID =
          model["defaultThinkingOptionId"]?.stringValue
          ?? thinkingSet?["defaultOptionId"]?.stringValue
          ?? thinkingOptions.first(where: \.isDefault)?.id
        return PaseoProviderModel(
          id: modelID, label: label, isDefault: model["isDefault"]?.boolValue == true,
          thinkingOptions: thinkingOptions, defaultThinkingOptionID: defaultThinkingOptionID)
      }
      let modes = try optionalArray(entry["modes"], field: "provider modes").map { mode in
        guard let modeID = mode["id"]?.stringValue, !modeID.isEmpty,
          let label = mode["label"]?.stringValue
        else { throw PaseoProtocolError.malformedMessage("provider mode omitted id or label") }
        return PaseoAgentMode(
          id: modeID, label: label, description: mode["description"]?.stringValue)
      }
      return PaseoProvider(
        id: id, label: entry["label"]?.stringValue ?? id,
        available: status == "ready" && entry["enabled"]?.boolValue != false,
        error: entry["error"]?.stringValue, models: models, modes: modes,
        defaultModeID: entry["defaultModeId"]?.stringValue)
    }
  }

  public func agentSettings(agentID: String) async throws -> PaseoAgentSettings {
    try requireConnected()
    guard !agentID.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose an agent before editing settings.")
    }
    let payload = try await request(
      type: "fetch_agent_request", fields: ["agentId": .string(agentID)],
      responseType: "fetch_agent_response", operation: "agent settings")
    guard let agent = payload["agent"], agent.objectValue != nil else {
      throw PaseoProtocolError.requestRejected("The agent is no longer available.")
    }
    guard let actualID = agent["id"]?.stringValue, actualID == agentID,
      let provider = agent["provider"]?.stringValue, !provider.isEmpty,
      let cwd = agent["cwd"]?.stringValue,
      let status = agent["status"]?.stringValue
    else {
      throw PaseoProtocolError.malformedMessage("agent settings omitted or mismatched identity")
    }
    let modeRows = try optionalArray(agent["availableModes"], field: "available modes")
    let availableModes = try modeRows.map { mode in
      guard let modeID = mode["id"]?.stringValue, !modeID.isEmpty,
        let label = mode["label"]?.stringValue
      else {
        throw PaseoProtocolError.malformedMessage("agent mode omitted id or label")
      }
      return PaseoAgentMode(
        id: modeID, label: label, description: mode["description"]?.stringValue)
    }
    return PaseoAgentSettings(
      agentID: actualID, provider: provider, cwd: cwd, status: status,
      modelID: try optionalNullableString(agent["model"], field: "agent model"),
      thinkingOptionID: try optionalNullableString(
        agent["thinkingOptionId"], field: "agent thinking option"),
      effectiveThinkingOptionID: try optionalNullableString(
        agent["effectiveThinkingOptionId"], field: "effective thinking option"),
      currentModeID: try optionalNullableString(agent["currentModeId"], field: "agent mode"),
      availableModes: availableModes)
  }

  public func applyAgentSettings(
    agentID: String, modelID: String?, thinkingOptionID: String?, modeID: String?
  ) async throws -> PaseoAgentSettingsApplyResult {
    var config: [String: PaseoJSONValue] = [
      "modelId": modelID.map(PaseoJSONValue.string) ?? .null
    ]
    if serverInfo?.features["agentThinkingUpdate"] == true {
      config["thinkingOptionId"] = thinkingOptionID.map(PaseoJSONValue.string) ?? .null
    }
    if let modeID, !modeID.isEmpty {
      config["modeId"] = .string(modeID)
    }
    return try await applyAgentConfig(agentID: agentID, config: config)
  }

  public func applyAgentMode(agentID: String, modeID: String) async throws
    -> PaseoAgentSettingsApplyResult
  {
    guard !modeID.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose a permission mode before applying.")
    }
    return try await applyAgentConfig(
      agentID: agentID, config: ["modeId": .string(modeID)])
  }

  public func applyAgentThinking(
    agentID: String, thinkingOptionID: String?, modeID: String?
  ) async throws -> PaseoAgentSettingsApplyResult {
    try requireConnected()
    try requireFeature("agentThinkingUpdate", as: "agent thinking update")
    var config: [String: PaseoJSONValue] = [
      "thinkingOptionId": thinkingOptionID.map(PaseoJSONValue.string) ?? .null
    ]
    if let modeID, !modeID.isEmpty {
      config["modeId"] = .string(modeID)
    }
    return try await applyAgentConfig(agentID: agentID, config: config)
  }

  private func applyAgentConfig(
    agentID: String, config: [String: PaseoJSONValue]
  ) async throws -> PaseoAgentSettingsApplyResult {
    try requireConnected()
    try requireFeature("agentConfigApply", as: "agent settings update")
    guard !agentID.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose an agent before editing settings.")
    }
    let payload = try await request(
      type: "agent.config.apply.request",
      fields: ["agentId": .string(agentID), "config": .object(config)],
      responseType: "agent.config.apply.response", operation: "agent settings update",
      allowError: true)
    guard payload["agentId"]?.stringValue == agentID,
      let accepted = payload["accepted"]?.boolValue
    else {
      throw PaseoProtocolError.malformedMessage("agent settings response omitted its result")
    }
    guard accepted else {
      throw PaseoProtocolError.requestRejected(
        payload["error"]?.stringValue ?? "The Paseo host rejected the agent settings.")
    }
    let notice = payload["notice"]?["message"]?.stringValue
    return PaseoAgentSettingsApplyResult(notice: notice)
  }

  public func createAgent(_ intent: PaseoAgentCreationIntent) async throws
    -> PaseoAgentCreationResult
  {
    try requireConnected()
    try requireFeature("creationLifecycle", as: "new thread creation")
    guard !intent.idempotencyKey.isEmpty, !intent.clientMessageID.isEmpty,
      !intent.provider.isEmpty, !intent.cwd.isEmpty,
      !intent.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !intent.images.isEmpty
    else { throw PaseoProtocolError.requestRejected("New thread details are incomplete.") }
    try validateImages(intent.images)
    var config: [String: PaseoJSONValue] = [
      "provider": .string(intent.provider), "cwd": .string(intent.cwd),
    ]
    if let model = intent.model, !model.isEmpty { config["model"] = .string(model) }
    if let modeID = intent.modeID, !modeID.isEmpty { config["modeId"] = .string(modeID) }
    var fields: [String: PaseoJSONValue] = [
      "idempotencyKey": .string(intent.idempotencyKey),
      "clientMessageId": .string(intent.clientMessageID),
      "config": .object(config),
      "initialPrompt": .string(intent.initialPrompt),
      "subscribe": .bool(false),
    ]
    if !intent.images.isEmpty { fields["images"] = .array(intent.images.map(Self.imageJSON)) }
    let payload = try await request(
      type: "agent.create.request",
      fields: fields,
      responseType: "agent.create.response",
      operation: "new thread creation",
      allowError: true,
      timeoutSeconds: 60
    )
    guard let responseError = payload["error"], payload["agent"] != nil else {
      throw PaseoProtocolError.malformedMessage("new thread response omitted agent or error")
    }
    switch responseError {
    case .null, .string: break
    default:
      throw PaseoProtocolError.malformedMessage("new thread response had an invalid error")
    }
    var rawAgent =
      payload["agent"]?.objectValue == nil
      ? payload["creation"]?["agent"] : payload["agent"]
    if rawAgent?.objectValue == nil,
      payload["creation"]?["outcomeUnknown"]?.boolValue == true,
      let reservedID = payload["creation"]?["agentId"]?.stringValue,
      !reservedID.isEmpty
    {
      // A reserved ID is not proof of creation. Ask the host for the actual
      // agent snapshot before exposing a thread in the UI.
      if let fetched = try? await request(
        type: "fetch_agent_request",
        fields: ["agentId": .string(reservedID)],
        responseType: "fetch_agent_response",
        operation: "created thread reconciliation"
      ), fetched["agent"]?["id"]?.stringValue == reservedID {
        rawAgent = fetched["agent"]
      }
    }
    let agent: PaseoCreatedAgent?
    if let rawAgent, case .object = rawAgent {
      guard let id = rawAgent["id"]?.stringValue, !id.isEmpty,
        let provider = rawAgent["provider"]?.stringValue,
        let status = rawAgent["status"]?.stringValue
      else { throw PaseoProtocolError.malformedMessage("created agent omitted required fields") }
      agent = PaseoCreatedAgent(
        id: id, title: rawAgent["title"]?.stringValue, provider: provider,
        model: rawAgent["model"]?.stringValue, status: status,
        requiresAttention: rawAgent["requiresAttention"]?.boolValue ?? false,
        attentionReason: rawAgent["attentionReason"]?.stringValue,
        cwd: rawAgent["cwd"]?.stringValue)
    } else {
      agent = nil
    }
    let error = responseError.stringValue ?? payload["creation"]?["error"]?.stringValue
    let phase = payload["creation"]?["phase"]?.stringValue
    let failed = phase == "failed"
    let failedStage = payload["creation"]?["failedStage"]?.stringValue
    let outcomeUnknown = payload["creation"]?["outcomeUnknown"]?.boolValue == true
    return PaseoAgentCreationResult(
      agent: agent,
      promptAccepted: agent != nil && error == nil && (phase == nil || phase == "completed"),
      error: error,
      safeToRestart: agent == nil && failed && !outcomeUnknown
        && (failedStage == "workspace" || failedStage == "agent"))
  }

  public func listThreads(projectID: String, page: PaseoPageRequest = .first) async throws
    -> PaseoPage<PaseoThread>
  {
    try requireConnected()
    try requireFeature("stableProjectIdentity", as: "stable project thread filtering")
    guard !projectID.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose a project before listing its threads.")
    }
    let payload = try await request(
      type: "fetch_agents_request",
      fields: [
        "filter": .object([
          // Upstream maps project placement.projectKey to the stable project.projectId.
          "projectKeys": .array([.string(projectID)]),
          "includeArchived": .bool(false),
        ]),
        "page": pageJSON(page),
      ],
      responseType: "fetch_agents_response",
      operation: "thread listing"
    )
    guard let entries = payload["entries"]?.arrayValue,
      let pageInfo = payload["pageInfo"],
      let hasMore = pageInfo["hasMore"]?.boolValue
    else {
      throw PaseoProtocolError.malformedMessage(
        "thread list omitted its entries or page information")
    }
    let nextCursor = try nullableString(pageInfo["nextCursor"], field: "thread page next cursor")
    let previousCursor = try nullableString(
      pageInfo["prevCursor"], field: "thread page previous cursor")
    guard !hasMore || nextCursor?.isEmpty == false else {
      throw PaseoProtocolError.malformedMessage(
        "thread page reported more rows without a next cursor")
    }
    let threads = try entries.map(decodeThread)
    return PaseoPage(
      items: threads,
      nextCursor: nextCursor,
      previousCursor: previousCursor,
      hasMore: hasMore
    )
  }

  public func archiveAgent(agentID: String) async throws {
    try requireConnected()
    guard !agentID.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose a thread before archiving it.")
    }
    let payload = try await request(
      type: "archive_agent_request",
      fields: ["agentId": .string(agentID)],
      responseType: "agent_archived",
      operation: "thread archive"
    )
    guard payload["agentId"]?.stringValue == agentID,
      let archivedAt = payload["archivedAt"]?.stringValue,
      !archivedAt.isEmpty
    else {
      throw PaseoProtocolError.malformedMessage("thread archive returned an invalid result")
    }
  }

  public func clearAgentAttention(agentID: String) async throws {
    try requireConnected()
    guard !agentID.isEmpty else {
      throw PaseoProtocolError.requestRejected("Choose a thread before marking it as read.")
    }
    _ = try await request(
      type: "clear_agent_attention",
      fields: ["agentId": .string(agentID)],
      responseType: "clear_agent_attention_response",
      operation: "mark thread as read"
    )
  }

  public func history(
    agentID: String,
    direction: PaseoTimelineDirection = .tail,
    cursor: PaseoTimelineCursor? = nil,
    limit: Int = 100
  ) async throws -> PaseoTimelinePage {
    try requireConnected()
    let boundedLimit = min(max(limit, 1), 200)
    var fields: [String: PaseoJSONValue] = [
      "agentId": .string(agentID),
      "direction": .string(direction.rawValue),
      "limit": .number(Double(boundedLimit)),
      "projection": .string("projected"),
    ]
    if let cursor {
      guard cursor.sequence >= 0 else {
        throw PaseoProtocolError.requestRejected("Timeline cursors must be non-negative.")
      }
      fields["cursor"] = cursorJSON(cursor)
    }
    let payload = try await request(
      type: "fetch_agent_timeline_request",
      fields: fields,
      responseType: "fetch_agent_timeline_response",
      operation: "timeline history"
    )
    guard let rawError = payload["error"] else {
      throw PaseoProtocolError.malformedMessage("timeline history omitted its error field")
    }
    switch rawError {
    case .null: break
    case .string(let error) where !error.isEmpty: throw PaseoProtocolError.requestRejected(error)
    case .string: break
    default:
      throw PaseoProtocolError.malformedMessage("timeline history contained an invalid error field")
    }
    guard let responseDirection = payload["direction"]?.stringValue,
      PaseoTimelineDirection(rawValue: responseDirection) != nil,
      payload["projection"]?.stringValue != nil,
      payload["agent"] != nil,
      let window = payload["window"], case .object = window,
      window["minSeq"]?.intValue != nil,
      window["maxSeq"]?.intValue != nil,
      window["nextSeq"]?.intValue != nil,
      let epoch = payload["epoch"]?.stringValue, !epoch.isEmpty,
      let hasOlder = payload["hasOlder"]?.boolValue,
      let hasNewer = payload["hasNewer"]?.boolValue,
      let reset = payload["reset"]?.boolValue,
      let staleCursor = payload["staleCursor"]?.boolValue,
      let gap = payload["gap"]?.boolValue,
      let rawStartCursor = payload["startCursor"],
      let rawEndCursor = payload["endCursor"],
      let responseAgentID = payload["agentId"]?.stringValue
    else {
      throw PaseoProtocolError.malformedMessage(
        "timeline history omitted required cursor or state fields")
    }
    let startCursor = try nullableCursor(rawStartCursor)
    let endCursor = try nullableCursor(rawEndCursor)
    guard let rawEntries = payload["entries"]?.arrayValue else {
      throw PaseoProtocolError.malformedMessage("timeline history omitted its entries array")
    }
    let entries = try rawEntries.map { try decodeTimelineEntry($0, epoch: epoch) }
    return PaseoTimelinePage(
      agentID: responseAgentID,
      epoch: epoch,
      entries: entries,
      startCursor: startCursor,
      endCursor: endCursor,
      hasOlder: hasOlder,
      hasNewer: hasNewer,
      reset: reset,
      staleCursor: staleCursor,
      gap: gap
    )
  }

  public func events(agentID: String, after cursor: PaseoTimelineCursor? = nil) async throws
    -> AsyncThrowingStream<PaseoTimelineEvent, Error>
  {
    try requireConnected()
    try requireFeature("ownedSubscriptions", as: "owned timeline subscriptions")
    try requireFeature("selectiveAgentTimeline", as: "selective live timelines")

    pendingTimelineSubscriptions[agentID, default: 0] += 1
    let payload: PaseoJSONValue
    do {
      payload = try await request(
        type: "agent.timeline.set_subscription.request",
        fields: ["agentIds": .array([.string(agentID)])],
        responseType: "agent.timeline.set_subscription.response",
        operation: "timeline subscription"
      )
    } catch {
      decrementPendingTimelineSubscription(agentID)
      throw error
    }
    guard serverInfo != nil else {
      decrementPendingTimelineSubscription(agentID)
      throw PaseoProtocolError.notConnected
    }
    guard let subscriptionID = payload["subscriptionId"]?.stringValue, !subscriptionID.isEmpty
    else {
      decrementPendingTimelineSubscription(agentID)
      throw PaseoProtocolError.malformedMessage("timeline subscription omitted its subscription id")
    }
    let (stream, continuation) = AsyncThrowingStream<PaseoTimelineEvent, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(256))
    subscriptions[subscriptionID] = TimelineObservation(
      agentID: agentID,
      continuation: continuation,
      lastSequence: cursor?.sequence,
      epoch: cursor?.epoch
    )
    decrementPendingTimelineSubscription(agentID)
    let earlyEvents = earlyTimelineEvents[agentID] ?? []
    let remainingEarlyEvents = earlyEvents.filter {
      $0.payload?["subscriptionId"]?.stringValue != subscriptionID
    }
    if remainingEarlyEvents.isEmpty {
      earlyTimelineEvents.removeValue(forKey: agentID)
    } else {
      earlyTimelineEvents[agentID] = remainingEarlyEvents
    }
    if earlyTimelineOverflow.contains(agentID) {
      continuation.yield(.reloadRequired(agentID: agentID, reason: .bufferOverflow))
      if pendingTimelineSubscriptions[agentID] == nil { earlyTimelineOverflow.remove(agentID) }
    }
    for early in earlyEvents where early.payload?["subscriptionId"]?.stringValue == subscriptionID {
      routeTimelineMessage(early)
    }
    continuation.onTermination = { @Sendable _ in
      Task { await self.releaseTimelineSubscription(subscriptionID) }
    }
    return stream
  }

  public func send(agentID: String, text: String) async throws {
    try await sendMessage(
      agentID: agentID, text: text, messageID: UUID().uuidString.lowercased(),
      activeTurnBehavior: nil, images: [])
  }

  public func send(
    agentID: String, text: String, messageID: String,
    activeTurnBehavior: PaseoActiveTurnBehavior
  ) async throws {
    guard !messageID.isEmpty else {
      throw PaseoProtocolError.requestRejected("The message ID must not be empty.")
    }
    try await sendMessage(
      agentID: agentID, text: text, messageID: messageID,
      activeTurnBehavior: activeTurnBehavior, images: [])
  }

  public func send(
    agentID: String, text: String, messageID: String,
    activeTurnBehavior: PaseoActiveTurnBehavior, images: [PaseoImage]
  ) async throws {
    guard !messageID.isEmpty else {
      throw PaseoProtocolError.requestRejected("The message ID must not be empty.")
    }
    try await sendMessage(
      agentID: agentID, text: text, messageID: messageID,
      activeTurnBehavior: activeTurnBehavior, images: images)
  }

  private func sendMessage(
    agentID: String, text: String, messageID: String,
    activeTurnBehavior: PaseoActiveTurnBehavior?, images: [PaseoImage]
  ) async throws {
    try requireConnected()
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
      throw PaseoProtocolError.requestRejected("Add a message or image before sending.")
    }
    try validateImages(images)
    var fields: [String: PaseoJSONValue] = [
      "agentId": .string(agentID), "text": .string(text), "messageId": .string(messageID),
    ]
    if let activeTurnBehavior {
      fields["activeTurnBehavior"] = .string(activeTurnBehavior.rawValue)
    }
    if !images.isEmpty { fields["images"] = .array(images.map(Self.imageJSON)) }
    let payload = try await request(
      type: "send_agent_message_request",
      fields: fields,
      responseType: "send_agent_message_response",
      operation: "message send", allowError: true
    )
    guard payload["agentId"]?.stringValue == agentID else {
      throw PaseoProtocolError.malformedMessage("message send response had a mismatched agent id")
    }
    if let error = payload["error"]?.stringValue, !error.isEmpty {
      throw PaseoProtocolError.requestRejected(error)
    }
    guard let accepted = payload["accepted"]?.boolValue else {
      throw PaseoProtocolError.malformedMessage("message send response omitted acceptance")
    }
    guard accepted else {
      throw PaseoProtocolError.requestRejected(
        payload["error"]?.stringValue ?? "The host did not accept the message.")
    }
  }

  public func readImage(cwd: String, path: String, maxBytes: Int) async throws -> Data {
    try requireConnected()
    guard !cwd.isEmpty, !path.isEmpty, maxBytes > 0,
      maxBytes <= RemoteImageLimits.maximumDisplayBytes
    else { throw PaseoProtocolError.requestRejected("Invalid image preview request.") }
    // The legacy JSON response carries base64. Do not request the optional
    // binary transfer, which requires a separate frame decoder.
    let payload = try await request(
      type: "file_explorer_request",
      fields: [
        "cwd": .string(cwd), "path": .string(path), "mode": .string("file"),
        "maxBytes": .number(Double(maxBytes)),
      ],
      responseType: "file_explorer_response", operation: "image preview",
      allowError: true)
    if let error = payload["error"]?.stringValue, !error.isEmpty {
      throw PaseoProtocolError.requestRejected(error)
    }
    guard payload["mode"]?.stringValue == "file",
      let file = payload["file"], case .object = file,
      file["kind"]?.stringValue == "image",
      file["encoding"]?.stringValue == "base64",
      let mime = file["mimeType"]?.stringValue, mime.hasPrefix("image/"),
      let size = file["size"]?.intValue, size >= 0, size <= maxBytes,
      let encoded = file["content"]?.stringValue,
      encoded.utf8.count <= ((maxBytes + 2) / 3) * 4 + 4,
      let bytes = Data(base64Encoded: encoded), bytes.count == size
    else { throw PaseoProtocolError.malformedMessage("image preview returned invalid image data") }
    return bytes
  }

  private static func imageJSON(_ image: PaseoImage) -> PaseoJSONValue {
    .object([
      "data": .string(image.data.base64EncodedString()),
      "mimeType": .string(image.mimeType),
    ])
  }

  private func validateImages(_ images: [PaseoImage]) throws {
    guard images.count <= RemoteImageLimits.maximumCount,
      images.allSatisfy({
        !$0.data.isEmpty && $0.data.count <= RemoteImageLimits.maximumOutgoingBytes
          && $0.mimeType.hasPrefix("image/")
      })
    else {
      throw PaseoProtocolError.requestRejected("An attached image is too large or unsupported.")
    }
  }

  public func cancelAgent(agentID: String) async throws -> PaseoAgentControlSnapshot? {
    try requireConnected()
    let payload = try await request(
      type: "cancel_agent_request", fields: ["agentId": .string(agentID)],
      responseType: "cancel_agent_response", operation: "agent stop", allowError: true)
    guard payload["agentId"]?.stringValue == agentID else {
      throw PaseoProtocolError.malformedMessage("agent stop response had a mismatched agent id")
    }
    if let error = payload["error"]?.stringValue, !error.isEmpty {
      throw PaseoProtocolError.requestRejected(error)
    }
    guard let agent = payload["agent"] else {
      throw PaseoProtocolError.malformedMessage("agent stop response omitted its agent snapshot")
    }
    if agent == .null { return nil }
    guard agent.objectValue != nil,
      let id = agent["id"]?.stringValue, id == agentID,
      let status = agent["status"]?.stringValue
    else {
      throw PaseoProtocolError.malformedMessage("agent stop response had an invalid agent snapshot")
    }
    return PaseoAgentControlSnapshot(
      id: id, status: status,
      requiresAttention: agent["requiresAttention"]?.boolValue ?? false,
      attentionReason: agent["attentionReason"]?.stringValue)
  }

  public func pendingPermissions() async throws -> [PaseoPermissionRequest] {
    try requireConnected()
    var cursor: String?
    var seenCursors = Set<String>()
    var permissions: [PaseoPermissionRequest] = []
    while true {
      var fields: [String: PaseoJSONValue] = [
        "filter": .object(["includeArchived": .bool(false)]),
        "page": .object(["limit": .number(200)]),
      ]
      if let cursor {
        fields["page"] = .object(["limit": .number(200), "cursor": .string(cursor)])
      }
      let payload = try await request(
        type: "fetch_agents_request",
        fields: fields,
        responseType: "fetch_agents_response",
        operation: "pending permission lookup"
      )
      guard let entries = payload["entries"]?.arrayValue,
        let pageInfo = payload["pageInfo"],
        let hasMore = pageInfo["hasMore"]?.boolValue
      else {
        throw PaseoProtocolError.malformedMessage(
          "permission lookup omitted its entries or page information")
      }
      for entry in entries {
        guard let agent = entry["agent"], let agentID = agent["id"]?.stringValue else { continue }
        guard let requests = agent["pendingPermissions"]?.arrayValue else {
          throw PaseoProtocolError.malformedMessage("agent record omitted pending permission data")
        }
        permissions.append(
          contentsOf: try requests.map { try decodePermission($0, agentID: agentID) })
      }
      guard hasMore else { break }
      guard
        let next = try nullableString(pageInfo["nextCursor"], field: "permission page next cursor"),
        !next.isEmpty,
        seenCursors.insert(next).inserted
      else {
        throw PaseoProtocolError.malformedMessage(
          "permission lookup returned a repeated or missing page cursor")
      }
      cursor = next
    }
    return permissions
  }

  public func answerPermission(
    agentID: String, requestID: String, decision: PaseoPermissionDecision
  ) async throws {
    try requireConnected()
    let response: PaseoJSONValue
    switch decision {
    case .allow(let actionID, let updatedInput):
      var values: [String: PaseoJSONValue] = ["behavior": .string("allow")]
      if let actionID { values["selectedActionId"] = .string(actionID) }
      if let updatedInput { values["updatedInput"] = updatedInput }
      response = .object(values)
    case .deny(let actionID, let message, let interrupt):
      var values: [String: PaseoJSONValue] = ["behavior": .string("deny")]
      if let actionID { values["selectedActionId"] = .string(actionID) }
      if let message { values["message"] = .string(message) }
      if let interrupt { values["interrupt"] = .bool(interrupt) }
      response = .object(values)
    }
    let resolved = try await request(
      type: "agent_permission_response",
      fields: ["agentId": .string(agentID), "response": response],
      requestID: requestID,
      responseType: "agent_permission_resolved",
      operation: "permission response"
    )
    guard resolved["agentId"]?.stringValue == agentID,
      resolved["requestId"]?.stringValue == requestID
    else {
      throw PaseoProtocolError.unexpectedResponse("agent_permission_resolved")
    }
  }

  public func disconnect() async {
    // Cancel before closing the socket so its receive failure cannot publish
    // an unexpected-loss diagnostic for an intentional disconnect.
    receiver?.cancel()
    await transport.close()
    receiver = nil
    failAll(PaseoProtocolError.disconnected("the client closed the connection"))
    serverInfo = nil
    setConnectionState(.disconnected)
  }

  private func receiveLoop() async {
    do {
      while !Task.isCancelled {
        let text = try await transport.receive()
        try receiveFrame(text)
      }
    } catch {
      guard !Task.isCancelled else { return }
      await transport.close()
      guard !Task.isCancelled else { return }
      // Keep typed transport failures through the hello handshake, pending
      // requests, and timelines. The connection observer also needs the cause
      // when an idle socket has no other consumer to receive its error.
      failAll(error)
      serverInfo = nil
      receiver = nil
      setConnectionState(Self.failureState(for: error))
    }
  }

  private func receiveFrame(_ text: String) throws {
    guard let data = text.data(using: .utf8) else {
      throw PaseoProtocolError.malformedMessage("frame was not UTF-8")
    }
    let envelope: IncomingEnvelope
    do {
      envelope = try decoder.decode(IncomingEnvelope.self, from: data)
    } catch {
      throw PaseoProtocolError.malformedMessage("invalid WebSocket envelope")
    }
    if envelope.type == "pong" { return }
    if envelope.type == "session", let message = envelope.message {
      if message.type == "status", message.payload?["status"]?.stringValue == "server_info" {
        let info = decodeConnectionInfo(message.payload)
        serverInfo = info
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        if let handshake {
          self.handshake = nil
          handshake.resume(returning: info)
        }
        setConnectionState(.connected(info))
        return
      }
      if resolvePending(message) { return }
      routeTimelineMessage(message)
      return
    }
    if envelope.type == "session" {
      throw PaseoProtocolError.malformedMessage("session envelope omitted its message")
    }
    // recording_state and future WebSocket-level messages do not affect this MVP flow.
  }

  private func resolvePending(_ message: IncomingMessage) -> Bool {
    let payload = message.payload
    let requestID = payload?["requestId"]?.stringValue ?? message.requestId
    guard let requestID, let item = pending.removeValue(forKey: requestID) else { return false }
    item.timeout.cancel()
    guard item.responseType == message.type else {
      item.continuation.resume(throwing: PaseoProtocolError.unexpectedResponse(message.type))
      return true
    }
    let responsePayload = payload ?? .object([:])
    if !item.allowError, let error = responsePayload["error"]?.stringValue, !error.isEmpty {
      item.continuation.resume(throwing: PaseoProtocolError.requestRejected(error))
    } else {
      item.continuation.resume(returning: responsePayload)
    }
    return true
  }

  private func routeTimelineMessage(_ message: IncomingMessage) {
    guard let payload = message.payload else { return }
    switch message.type {
    case "agent_stream":
      guard let agentID = payload["agentId"]?.stringValue,
        let event = payload["event"],
        let timestamp = payload["timestamp"]?.stringValue
      else { return }
      let subscriptionID = payload["subscriptionId"]?.stringValue
      if let subscriptionID, subscriptions[subscriptionID] == nil,
        pendingTimelineSubscriptions[agentID, default: 0] > 0
      {
        var buffered = earlyTimelineEvents[agentID, default: []]
        if buffered.count >= 128 {
          buffered.removeFirst()
          earlyTimelineOverflow.insert(agentID)
        }
        buffered.append(message)
        earlyTimelineEvents[agentID] = buffered
        return
      }
      let matchingIDs =
        subscriptionID.map { [$0] }
        ?? subscriptions.compactMap { $0.value.agentID == agentID ? $0.key : nil }
      for id in matchingIDs {
        guard var observation = subscriptions[id], observation.agentID == agentID else { continue }
        let epoch = payload["epoch"]?.stringValue
        let sequence = payload["seq"]?.intValue
        if let priorEpoch = observation.epoch, let epoch, priorEpoch != epoch {
          observation.continuation.yield(
            .reloadRequired(agentID: agentID, reason: .replacement(epoch: epoch)))
          observation.epoch = epoch
          observation.lastSequence = nil
          subscriptions[id] = observation
          continue
        }
        if let sequence, let last = observation.lastSequence, last < Int.max, sequence > last + 1 {
          observation.continuation.yield(
            .reloadRequired(
              agentID: agentID, reason: .sequenceGap(expected: last + 1, received: sequence)))
          observation.lastSequence = sequence
          observation.epoch = epoch ?? observation.epoch
          subscriptions[id] = observation
          continue
        }
        if let sequence, let last = observation.lastSequence, sequence <= last { continue }
        observation.lastSequence = sequence ?? observation.lastSequence
        observation.epoch = epoch ?? observation.epoch
        if let permissionEvent = decodePermissionEvent(event, agentID: agentID) {
          observation.continuation.yield(permissionEvent)
        }
        let result = observation.continuation.yield(
          .item(
            agentID: agentID, event: event, timestamp: timestamp, sequence: sequence, epoch: epoch))
        if case .dropped = result {
          observation.continuation.yield(.reloadRequired(agentID: agentID, reason: .bufferOverflow))
        }
        subscriptions[id] = observation
      }
    case "agent.timeline.replacement":
      guard let agentID = payload["agentId"]?.stringValue,
        let epoch = payload["epoch"]?.stringValue
      else { return }
      withMatchingSubscriptions(payload, agentID: agentID) { observation in
        observation.lastSequence = nil
        observation.epoch = epoch
        observation.continuation.yield(
          .reloadRequired(agentID: agentID, reason: .replacement(epoch: epoch)))
      }
    case "agent_permission_request":
      guard let agentID = payload["agentId"]?.stringValue,
        let request = payload["request"],
        let permission = try? decodePermission(request, agentID: agentID)
      else { return }
      withMatchingSubscriptions(payload, agentID: agentID) { observation in
        observation.continuation.yield(.permissionRequested(permission))
      }
    case "agent_permission_resolved":
      guard let agentID = payload["agentId"]?.stringValue,
        let requestID = payload["requestId"]?.stringValue
      else { return }
      withMatchingSubscriptions(payload, agentID: agentID) { observation in
        observation.continuation.yield(.permissionResolved(agentID: agentID, requestID: requestID))
      }
    default:
      break
    }
  }

  private func withMatchingSubscriptions(
    _ payload: PaseoJSONValue, agentID: String, update: (inout TimelineObservation) -> Void
  ) {
    let subscriptionID = payload["subscriptionId"]?.stringValue
    let ids =
      subscriptionID.map { [$0] }
      ?? subscriptions.compactMap { $0.value.agentID == agentID ? $0.key : nil }
    for id in ids {
      guard var observation = subscriptions[id], observation.agentID == agentID else { continue }
      update(&observation)
      subscriptions[id] = observation
    }
  }

  private func request(
    type: String,
    fields: [String: PaseoJSONValue] = [:],
    requestID suppliedRequestID: String? = nil,
    responseType: String,
    operation: String,
    allowError: Bool = false,
    timeoutSeconds: UInt64 = 20
  ) async throws -> PaseoJSONValue {
    try requireConnected()
    let id = suppliedRequestID ?? UUID().uuidString.lowercased()
    var message = fields
    message["type"] = .string(type)
    message["requestId"] = .string(id)
    let text = try encode(["type": .string("session"), "message": .object(message)])
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let timeout = Task {
          try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
          guard !Task.isCancelled else { return }
          self.expireRequest(id, operation: operation)
        }
        pending[id] = PendingRequest(
          responseType: responseType, allowError: allowError,
          continuation: continuation, timeout: timeout, sendTask: nil)
        let sendTask = Task {
          guard !Task.isCancelled else { return }
          do {
            try await transport.send(text)
          } catch {
            self.failRequest(id, error: error)
          }
        }
        pending[id]?.sendTask = sendTask
      }
    } onCancel: {
      Task { await self.cancelRequest(id) }
    }
  }

  private func releaseTimelineSubscription(_ id: String) async {
    guard let observation = subscriptions.removeValue(forKey: id) else { return }
    observation.continuation.finish()
    guard serverInfo != nil else { return }
    let message: [String: PaseoJSONValue] = [
      "type": .string("session"),
      "message": .object([
        "type": .string("subscription.release.request"),
        "requestId": .string(UUID().uuidString.lowercased()),
        "subscriptionId": .string(id),
      ]),
    ]
    guard let text = try? encode(message) else { return }
    try? await transport.send(text)
  }

  private func requireConnected() throws {
    guard serverInfo != nil else { throw PaseoProtocolError.notConnected }
  }

  private func requireFeature(_ feature: String, as name: String) throws {
    guard serverInfo?.features[feature] == true else {
      throw PaseoProtocolError.unsupportedCapability(name)
    }
  }

  private func encode(_ object: [String: PaseoJSONValue]) throws -> String {
    do {
      return String(decoding: try encoder.encode(PaseoJSONValue.object(object)), as: UTF8.self)
    } catch {
      throw PaseoProtocolError.malformedMessage("could not encode request")
    }
  }

  private func decodeConnectionInfo(_ payload: PaseoJSONValue?) -> PaseoConnectionInfo {
    let features =
      payload?["features"]?.objectValue?.reduce(into: [String: Bool]()) { result, pair in
        if case .bool(let value) = pair.value { result[pair.key] = value }
      } ?? [:]
    return PaseoConnectionInfo(
      serverID: payload?["serverId"]?.stringValue ?? "unknown",
      hostname: payload?["hostname"]?.stringValue,
      version: payload?["version"]?.stringValue,
      features: features
    )
  }

  private func decodeProject(_ value: PaseoJSONValue) throws -> PaseoProject {
    guard let id = value["projectId"]?.stringValue,
      let name = value["projectCustomName"]?.stringValue
        ?? value["projectDisplayName"]?.stringValue,
      let rootPath = value["projectRootPath"]?.stringValue,
      let kind = value["projectKind"]?.stringValue
    else {
      throw PaseoProtocolError.malformedMessage("project record omitted required fields")
    }
    return PaseoProject(
      id: id, key: value["projectKey"]?.stringValue, name: name, rootPath: rootPath, kind: kind)
  }

  private func decodeCheckoutError(_ value: PaseoJSONValue?) throws -> PaseoCheckoutError? {
    guard let value else { return nil }
    if case .null = value { return nil }
    guard let code = value["code"]?.stringValue,
      let message = value["message"]?.stringValue
    else { throw PaseoProtocolError.malformedMessage("checkout error omitted its code or message") }
    return PaseoCheckoutError(code: code, message: message)
  }

  private func decodeDiffFile(_ value: PaseoJSONValue) throws -> PaseoDiffFile {
    guard let path = value["path"]?.stringValue, !path.isEmpty,
      let isNew = value["isNew"]?.boolValue,
      let isDeleted = value["isDeleted"]?.boolValue,
      let additions = value["additions"]?.intValue, additions >= 0,
      let deletions = value["deletions"]?.intValue, deletions >= 0,
      let rawHunks = value["hunks"]?.arrayValue
    else { throw PaseoProtocolError.malformedMessage("git diff contained an invalid file") }
    let status: PaseoDiffFile.Status?
    if let rawStatus = value["status"]?.stringValue {
      status = PaseoDiffFile.Status(rawValue: rawStatus)
    } else {
      status = nil
    }
    return PaseoDiffFile(
      path: path, oldPath: value["oldPath"]?.stringValue,
      isNew: isNew, isDeleted: isDeleted, additions: additions, deletions: deletions,
      hunks: try rawHunks.map(decodeDiffHunk), status: status)
  }

  private func decodeDiffHunk(_ value: PaseoJSONValue) throws -> PaseoDiffHunk {
    guard let oldStart = value["oldStart"]?.intValue, oldStart >= 0,
      let oldCount = value["oldCount"]?.intValue, oldCount >= 0,
      let newStart = value["newStart"]?.intValue, newStart >= 0,
      let newCount = value["newCount"]?.intValue, newCount >= 0,
      let rawLines = value["lines"]?.arrayValue
    else { throw PaseoProtocolError.malformedMessage("git diff contained an invalid hunk") }
    return PaseoDiffHunk(
      oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
      lines: try rawLines.map(decodeDiffLine))
  }

  private func decodeDiffLine(_ value: PaseoJSONValue) throws -> PaseoDiffLine {
    guard let rawKind = value["type"]?.stringValue,
      let kind = PaseoDiffLine.Kind(rawValue: rawKind),
      let content = value["content"]?.stringValue
    else { throw PaseoProtocolError.malformedMessage("git diff contained an invalid line") }
    let tokens: [PaseoDiffToken]?
    if let rawTokens = value["tokens"]?.arrayValue {
      tokens = try rawTokens.map { token in
        guard let text = token["text"]?.stringValue else {
          throw PaseoProtocolError.malformedMessage("git diff contained an invalid token")
        }
        return PaseoDiffToken(text: text, style: token["style"]?.stringValue)
      }
    } else {
      tokens = nil
    }
    return PaseoDiffLine(kind: kind, content: content, tokens: tokens)
  }

  private func decodeThread(_ value: PaseoJSONValue) throws -> PaseoThread {
    guard let agent = value["agent"], let project = value["project"],
      let id = agent["id"]?.stringValue,
      let provider = agent["provider"]?.stringValue,
      let status = agent["status"]?.stringValue,
      let cwd = agent["cwd"]?.stringValue,
      let createdAt = agent["createdAt"]?.stringValue,
      let updatedAt = agent["updatedAt"]?.stringValue,
      let projectKey = project["projectKey"]?.stringValue,
      let projectName = project["projectName"]?.stringValue
    else {
      throw PaseoProtocolError.malformedMessage("thread record omitted required fields")
    }
    guard let rawPermissions = agent["pendingPermissions"]?.arrayValue else {
      throw PaseoProtocolError.malformedMessage("thread record omitted pending permission data")
    }
    let permissions = try rawPermissions.map { try decodePermission($0, agentID: id) }
    return PaseoThread(
      id: id,
      title: agent["title"]?.stringValue,
      provider: provider,
      model: agent["model"]?.stringValue,
      status: status,
      cwd: cwd,
      createdAt: createdAt,
      updatedAt: updatedAt,
      archivedAt: agent["archivedAt"]?.stringValue,
      requiresAttention: agent["requiresAttention"]?.boolValue ?? false,
      attentionReason: agent["attentionReason"]?.stringValue,
      parentAgentID: agent["labels"]?["paseo.parent-agent-id"]?.stringValue,
      projectKey: projectKey,
      projectName: projectName,
      pendingPermissions: permissions,
      contextWindowUsedTokens: agent["lastUsage"]?["contextWindowUsedTokens"]?.nonNegativeNumber,
      contextWindowMaxTokens: agent["lastUsage"]?["contextWindowMaxTokens"]?.nonNegativeNumber
    )
  }

  private func decodeProviderUsage(_ value: PaseoJSONValue) throws -> PaseoProviderUsage {
    guard let id = value["providerId"]?.stringValue, !id.isEmpty,
      let displayName = value["displayName"]?.stringValue,
      let status = value["status"]?.stringValue,
      let windows = value["windows"]?.arrayValue
    else {
      throw PaseoProtocolError.malformedMessage("provider usage omitted required fields")
    }
    let balances: [PaseoJSONValue]
    if let raw = value["balances"] {
      guard let decoded = raw.arrayValue else {
        throw PaseoProtocolError.malformedMessage("provider usage balances were invalid")
      }
      balances = decoded
    } else {
      balances = []
    }
    let details: [PaseoJSONValue]
    if let raw = value["details"] {
      guard let decoded = raw.arrayValue else {
        throw PaseoProtocolError.malformedMessage("provider usage details were invalid")
      }
      details = decoded
    } else {
      details = []
    }
    return PaseoProviderUsage(
      id: id, displayName: displayName, status: status,
      planLabel: value["planLabel"]?.stringValue,
      sourceLabel: value["sourceLabel"]?.stringValue,
      fetchedAt: value["fetchedAt"]?.stringValue,
      nextRefreshAt: value["nextRefreshAt"]?.stringValue,
      windows: try windows.map { window in
        guard let id = window["id"]?.stringValue, !id.isEmpty,
          let label = window["label"]?.stringValue
        else {
          throw PaseoProtocolError.malformedMessage("provider usage window omitted id or label")
        }
        return PaseoProviderUsageWindow(
          id: id, label: label,
          usedPct: window["usedPct"]?.finiteNumber,
          remainingPct: window["remainingPct"]?.finiteNumber,
          resetsAt: window["resetsAt"]?.stringValue,
          runsOutAt: window["runsOutAt"]?.stringValue,
          shortfallPct: window["shortfallPct"]?.finiteNumber,
          tone: window["tone"]?.stringValue)
      },
      balances: try balances.map { balance in
        guard let id = balance["id"]?.stringValue, !id.isEmpty,
          let label = balance["label"]?.stringValue,
          let unit = balance["unit"]?.stringValue
        else { throw PaseoProtocolError.malformedMessage("provider usage balance omitted fields") }
        return PaseoProviderUsageBalance(
          id: id, label: label,
          used: balance["used"]?.finiteNumber,
          remaining: balance["remaining"]?.finiteNumber,
          limit: balance["limit"]?.finiteNumber,
          unit: unit, resetsAt: balance["resetsAt"]?.stringValue,
          tone: balance["tone"]?.stringValue)
      },
      details: try details.map { detail in
        guard let id = detail["id"]?.stringValue, !id.isEmpty,
          let label = detail["label"]?.stringValue,
          let text = detail["value"]?.stringValue
        else { throw PaseoProtocolError.malformedMessage("provider usage detail omitted fields") }
        return PaseoProviderUsageDetail(
          id: id, label: label, value: text, tone: detail["tone"]?.stringValue)
      },
      error: value["error"]?.stringValue)
  }

  private func decodePermission(_ value: PaseoJSONValue, agentID: String) throws
    -> PaseoPermissionRequest
  {
    guard let id = value["id"]?.stringValue,
      let provider = value["provider"]?.stringValue,
      let name = value["name"]?.stringValue,
      let kind = value["kind"]?.stringValue
    else {
      throw PaseoProtocolError.malformedMessage("permission request omitted required fields")
    }
    let rawActions = try optionalArray(value["actions"], field: "permission actions")
    let actions = try rawActions.map { action -> PaseoPermissionAction in
      guard let id = action["id"]?.stringValue, let label = action["label"]?.stringValue,
        let behavior = action["behavior"]?.stringValue
      else {
        throw PaseoProtocolError.malformedMessage("permission action omitted required fields")
      }
      return PaseoPermissionAction(
        id: id, label: label, behavior: behavior, intent: action["intent"]?.stringValue)
    }
    return PaseoPermissionRequest(
      id: id,
      agentID: agentID,
      provider: provider,
      name: name,
      kind: kind,
      title: value["title"]?.stringValue,
      description: value["description"]?.stringValue,
      input: value["input"],
      actions: actions
    )
  }

  private func decodePermissionEvent(_ event: PaseoJSONValue, agentID: String)
    -> PaseoTimelineEvent?
  {
    switch event["type"]?.stringValue {
    case "permission_requested":
      guard let request = event["request"],
        let permission = try? decodePermission(request, agentID: agentID)
      else { return nil }
      return .permissionRequested(permission)
    case "permission_resolved":
      guard let requestID = event["requestId"]?.stringValue else { return nil }
      return .permissionResolved(agentID: agentID, requestID: requestID)
    default:
      return nil
    }
  }

  private func decodeTimelineEntry(_ value: PaseoJSONValue, epoch: String) throws
    -> PaseoTimelineEntry
  {
    guard let provider = value["provider"]?.stringValue,
      let item = value["item"],
      let timestamp = value["timestamp"]?.stringValue,
      let start = value["seqStart"]?.intValue,
      let end = value["seqEnd"]?.intValue,
      let collapsedValues = value["collapsed"]?.arrayValue
    else {
      throw PaseoProtocolError.malformedMessage("timeline entry omitted required fields")
    }
    let id = "\(epoch):\(start)-\(end)"
    return PaseoTimelineEntry(
      id: id,
      provider: provider,
      item: item,
      turnID: value["turnId"]?.stringValue,
      timestamp: timestamp,
      startSequence: start,
      endSequence: end,
      collapsed: try collapsedValues.map {
        guard let collapsed = $0.stringValue else {
          throw PaseoProtocolError.malformedMessage(
            "timeline entry contained an invalid collapsed marker")
        }
        return collapsed
      }
    )
  }

  private func nullableString(_ value: PaseoJSONValue?, field: String) throws -> String? {
    guard let value else { throw PaseoProtocolError.malformedMessage("response omitted \(field)") }
    switch value {
    case .null: return nil
    case .string(let string): return string
    default: throw PaseoProtocolError.malformedMessage("response contained an invalid \(field)")
    }
  }

  private func optionalNullableString(_ value: PaseoJSONValue?, field: String) throws -> String? {
    guard let value else { return nil }
    return try nullableString(value, field: field)
  }

  private func optionalArray(_ value: PaseoJSONValue?, field: String) throws -> [PaseoJSONValue] {
    guard let value else { return [] }
    guard let values = value.arrayValue else {
      throw PaseoProtocolError.malformedMessage("response contained invalid \(field)")
    }
    return values
  }

  private func nullableCursor(_ value: PaseoJSONValue) throws -> PaseoTimelineCursor? {
    if case .null = value { return nil }
    guard case .object = value,
      let epoch = value["epoch"]?.stringValue, !epoch.isEmpty,
      let sequence = value["seq"]?.intValue, sequence >= 0
    else {
      throw PaseoProtocolError.malformedMessage("timeline response contained an invalid cursor")
    }
    return PaseoTimelineCursor(epoch: epoch, sequence: sequence)
  }

  private func cursorJSON(_ cursor: PaseoTimelineCursor) -> PaseoJSONValue {
    .object(["epoch": .string(cursor.epoch), "seq": .number(Double(cursor.sequence))])
  }

  private func pageJSON(_ page: PaseoPageRequest) -> PaseoJSONValue {
    var values: [String: PaseoJSONValue] = ["limit": .number(Double(page.limit))]
    if let cursor = page.cursor { values["cursor"] = .string(cursor) }
    return .object(values)
  }

  private static func failureState(for error: Error) -> PaseoConnectionState {
    if error is CancellationError || (error as? PaseoConnectionError) == .cancelled {
      return .disconnected
    }
    if let error = error as? PaseoConnectionError {
      return .failed(reason: error.localizedDescription)
    }
    if let error = error as? PaseoProtocolError {
      return .failed(reason: error.localizedDescription)
    }
    // Foundation errors may embed URLs, credentials, or host paths in their
    // userInfo. Unexpected errors are not a safe user-facing diagnostic.
    return .failed(reason: "The Paseo connection ended unexpectedly.")
  }

  private func setConnectionState(_ state: PaseoConnectionState) {
    connectionState = state
    for continuation in connectionObservers.values { continuation.yield(state) }
  }

  private func removeConnectionObserver(_ id: UUID) {
    connectionObservers.removeValue(forKey: id)
  }

  private func decrementPendingTimelineSubscription(_ agentID: String) {
    let count = pendingTimelineSubscriptions[agentID, default: 0]
    if count <= 1 {
      pendingTimelineSubscriptions.removeValue(forKey: agentID)
    } else {
      pendingTimelineSubscriptions[agentID] = count - 1
    }
  }

  private func failHandshake(_ error: Error) {
    handshakeTimeout?.cancel()
    handshakeTimeout = nil
    guard let handshake else { return }
    self.handshake = nil
    handshake.resume(throwing: error)
  }

  private func expireRequest(_ id: String, operation: String) {
    guard let item = pending.removeValue(forKey: id) else { return }
    item.sendTask?.cancel()
    item.timeout.cancel()
    item.continuation.resume(throwing: PaseoProtocolError.requestTimedOut(operation))
  }

  private func cancelRequest(_ id: String) {
    guard let item = pending.removeValue(forKey: id) else { return }
    item.timeout.cancel()
    item.sendTask?.cancel()
    item.continuation.resume(throwing: CancellationError())
  }

  private func failRequest(_ id: String, error: Error) {
    guard let item = pending.removeValue(forKey: id) else { return }
    item.timeout.cancel()
    item.sendTask?.cancel()
    item.continuation.resume(throwing: error)
  }

  private func failAll(_ error: Error) {
    failHandshake(error)
    for (_, item) in pending {
      item.timeout.cancel()
      item.sendTask?.cancel()
      item.continuation.resume(throwing: error)
    }
    pending.removeAll()
    for (_, observation) in subscriptions {
      observation.continuation.finish(throwing: error)
    }
    subscriptions.removeAll()
    pendingTimelineSubscriptions.removeAll()
    earlyTimelineEvents.removeAll()
    earlyTimelineOverflow.removeAll()
  }
}

extension PaseoJSONValue {
  fileprivate var finiteNumber: Double? {
    guard case .number(let value) = self, value.isFinite else { return nil }
    return value
  }

  fileprivate var nonNegativeNumber: Double? {
    guard let value = finiteNumber, value >= 0 else { return nil }
    return value
  }
  fileprivate var arrayValue: [PaseoJSONValue]? {
    guard case .array(let values) = self else { return nil }
    return values
  }

  fileprivate var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }
}
