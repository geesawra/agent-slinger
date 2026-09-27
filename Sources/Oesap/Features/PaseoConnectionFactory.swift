import Foundation

actor PaseoConnectionFactory: OesapConnectionFactory {
  private let store = ConnectionStore()
  private var activeService: PaseoRemoteServiceAdapter?
  private var generation = 0

  func savedConnectionExists() async -> Bool {
    do { return try !store.list().isEmpty } catch { return false }
  }

  func listSavedInstances() async throws -> [SavedPaseoInstance] {
    try store.list().map(\.summary)
  }

  func activeInstanceID() async throws -> String? {
    try store.activeID()
  }

  func selectSavedInstance(id: String) async throws -> any OesapRemoteService {
    // Persist the choice before connecting. If the selected host is offline,
    // Reconnect still knows which saved host the user chose.
    let record = try store.list().first(where: { $0.id == id })
    guard let record else {
      throw RemoteServiceError.unavailable("That saved Paseo instance is no longer available.")
    }
    try store.select(id: id)

    generation += 1
    let attempt = generation
    let previousService = activeService
    activeService = nil
    await previousService?.disconnect()
    guard attempt == generation else { throw CancellationError() }

    let service = PaseoRemoteServiceAdapter(config: record.config)
    do {
      try await service.connect()
      try Task.checkCancellation()
      guard attempt == generation else {
        await service.disconnect()
        throw CancellationError()
      }
      activeService = service
      return service
    } catch {
      await service.disconnect()
      throw error
    }
  }

  func connect(_ connection: RemoteConnection) async throws -> any OesapRemoteService {
    generation += 1
    let attempt = generation
    let previousService = activeService
    activeService = nil
    await previousService?.disconnect()
    guard attempt == generation else { throw CancellationError() }

    let config: PaseoConnectionConfig
    switch connection.method {
    case .direct:
      config = try PaseoConnectionConfig.direct(
        endpoint: connection.endpoint,
        useTLS: connection.usesTLS,
        password: connection.password
      )
    case .relay:
      config = try PaseoConnectionConfig.relay(pairingLink: connection.pairingLink)
    }
    let service = PaseoRemoteServiceAdapter(config: config)
    do {
      try await service.connect()
      try Task.checkCancellation()
      guard attempt == generation else {
        await service.disconnect()
        throw CancellationError()
      }
      try store.saveAndSelect(config, name: connection.name)
      activeService = service
      return service
    } catch {
      await service.disconnect()
      throw error
    }
  }

  func reconnect() async throws -> any OesapRemoteService {
    generation += 1
    let attempt = generation
    let previousService = activeService
    activeService = nil
    await previousService?.disconnect()
    guard attempt == generation else { throw CancellationError() }
    guard let record = try store.activeConnection() else {
      throw RemoteServiceError.unavailable(
        "There is no selected Paseo connection. Choose a saved host or connect to one first.")
    }
    let service = PaseoRemoteServiceAdapter(config: record.config)
    do {
      try await service.connect()
      guard attempt == generation else {
        await service.disconnect()
        throw CancellationError()
      }
      activeService = service
      return service
    } catch {
      await service.disconnect()
      throw error
    }
  }

  func removeSavedInstance(id: String) async throws {
    let activeID = try store.activeID()
    try store.remove(id: id)
    guard activeID == id else { return }
    generation += 1
    let previousService = activeService
    activeService = nil
    await previousService?.disconnect()
  }

  func disconnect() async throws {
    generation += 1
    let previousService = activeService
    activeService = nil
    let clearError: Error?
    do {
      if let activeID = try store.activeID() {
        try store.remove(id: activeID)
      }
      clearError = nil
    } catch {
      clearError = error
    }
    await previousService?.disconnect()
    if let clearError { throw clearError }
  }
}

extension PaseoJSONValue {
  fileprivate var validUsageNumber: Double? {
    guard case .number(let value) = self, value.isFinite, value >= 0 else { return nil }
    return value
  }
}

actor PaseoRemoteServiceAdapter: OesapRemoteService {
  private static let eventBufferLimit = 256

  private let client: any PaseoService
  private var connectedInfo: PaseoConnectionInfo?
  private var historyCursors: [String: PaseoTimelineCursor] = [:]
  private var snapshotCursors: [String: PaseoTimelineCursor] = [:]
  private var resnapshotEpochs: [String: String] = [:]
  private var liveMessageSequences: [String: [String: Int]] = [:]
  private var toolSnapshots: [String: [String: [String: PaseoJSONValue]]] = [:]
  private var eventContinuations:
    [String: AsyncThrowingStream<RemoteTimelineUpdate, Error>.Continuation] = [:]
  private var eventReaderTasks: [String: Task<Void, Never>] = [:]
  private var pendingEvents: [String: [PaseoTimelineEvent]] = [:]
  private var historyReady: Set<String> = []
  private var eventTokens: [String: UUID] = [:]

  init(config: PaseoConnectionConfig) {
    client = PaseoProtocolClient(transport: PaseoTransport(config: config))
  }

  init(client: any PaseoService) {
    self.client = client
  }

  func connect() async throws {
    connectedInfo = try await client.connect()
  }

  func serverID() async -> String? { connectedInfo?.serverID }

  func supportsNewThreads() async -> Bool {
    connectedInfo?.features["creationLifecycle"] == true
  }

  func supportsProviderUsage() async -> Bool {
    connectedInfo?.features["providerUsageList"] == true
  }

  func supportsAgentRequestReceipts() async -> Bool {
    await client.supportsAgentRequestReceipts()
  }

  func providerUsage() async throws -> RemoteProviderUsageSnapshot {
    let snapshot = try await client.listProviderUsage()
    return RemoteProviderUsageSnapshot(
      fetchedAt: Self.parseTimestamp(snapshot.fetchedAt),
      providers: snapshot.providers.map { provider in
        RemoteProviderUsage(
          id: provider.id, displayName: provider.displayName,
          status: Self.mapUsageStatus(provider.status),
          planLabel: provider.planLabel, sourceLabel: provider.sourceLabel,
          fetchedAt: provider.fetchedAt.flatMap(Self.parseTimestamp),
          nextRefreshAt: provider.nextRefreshAt.flatMap(Self.parseTimestamp),
          windows: provider.windows.map { window in
            RemoteProviderUsage.Window(
              id: window.id, label: window.label,
              usedPct: window.usedPct, remainingPct: window.remainingPct,
              resetsAt: window.resetsAt.flatMap(Self.parseTimestamp),
              runsOutAt: window.runsOutAt.flatMap(Self.parseTimestamp),
              shortfallPct: window.shortfallPct, tone: Self.mapUsageTone(window.tone))
          },
          balances: provider.balances.map { balance in
            RemoteProviderUsage.Balance(
              id: balance.id, label: balance.label,
              used: balance.used, remaining: balance.remaining, limit: balance.limit,
              unit: balance.unit,
              resetsAt: balance.resetsAt.flatMap(Self.parseTimestamp),
              tone: Self.mapUsageTone(balance.tone))
          },
          details: provider.details.map { detail in
            RemoteProviderUsage.Detail(
              id: detail.id, label: detail.label, value: detail.value,
              tone: Self.mapUsageTone(detail.tone))
          },
          error: provider.error)
      })
  }

  func contextUsage(agentID: String) async throws -> RemoteContextUsage? {
    let usage = try await client.agentContextUsage(agentID: agentID)
    return Self.mapContextUsage(used: usage.usedTokens, max: usage.maxTokens)
  }

  func agentProviders(cwd: String) async throws -> [RemoteAgentProvider] {
    try await client.listProviders(cwd: cwd).map { provider in
      RemoteAgentProvider(
        id: provider.id, available: provider.available, error: provider.error,
        label: provider.label,
        models: provider.models.map(Self.mapAgentModel))
    }
  }

  func agentSettings(agentID: String) async throws -> RemoteAgentSettings {
    let agent = try await client.agentSettings(agentID: agentID)
    let providers: [PaseoProvider]
    do {
      providers = try await client.listProviders(cwd: agent.cwd)
    } catch PaseoProtocolError.unsupportedCapability {
      // Older hosts still expose the authoritative agent snapshot for read-only details.
      providers = []
    }
    let selectedProvider = providers.first(where: { $0.id == agent.provider })
    let models = selectedProvider?.models.map(Self.mapAgentModel) ?? []
    let canApply =
      connectedInfo?.features["agentConfigApply"] == true
      && selectedProvider?.available == true
      && (!models.isEmpty || !agent.availableModes.isEmpty)
    return RemoteAgentSettings(
      agentID: agent.agentID, provider: agent.provider, cwd: agent.cwd,
      modelID: agent.modelID, thinkingOptionID: agent.thinkingOptionID,
      effectiveThinkingOptionID: agent.effectiveThinkingOptionID,
      currentModeID: agent.currentModeID,
      availableModes: agent.availableModes.map {
        RemoteAgentMode(id: $0.id, label: $0.label, description: $0.description)
      }, models: models,
      canApply: canApply,
      supportsThinking: canApply && connectedInfo?.features["agentThinkingUpdate"] == true
        && models.contains(where: { !$0.thinkingOptions.isEmpty }),
      status: agent.status)
  }

  func applyAgentSettings(
    agentID: String, modelID: String?, thinkingOptionID: String?, modeID: String?
  ) async throws -> RemoteAgentSettingsApplyResult {
    let result = try await client.applyAgentSettings(
      agentID: agentID, modelID: modelID, thinkingOptionID: thinkingOptionID, modeID: modeID)
    return RemoteAgentSettingsApplyResult(notice: result.notice)
  }

  func applyAgentMode(agentID: String, modeID: String) async throws
    -> RemoteAgentSettingsApplyResult
  {
    let result = try await client.applyAgentMode(agentID: agentID, modeID: modeID)
    return RemoteAgentSettingsApplyResult(notice: result.notice)
  }

  func applyAgentThinking(
    agentID: String, thinkingOptionID: String?, modeID: String?
  ) async throws -> RemoteAgentSettingsApplyResult {
    let result = try await client.applyAgentThinking(
      agentID: agentID, thinkingOptionID: thinkingOptionID, modeID: modeID)
    return RemoteAgentSettingsApplyResult(notice: result.notice)
  }

  private static func mapAgentModel(_ model: PaseoProviderModel) -> RemoteAgentModel {
    RemoteAgentModel(
      id: model.id, label: model.label, isDefault: model.isDefault,
      thinkingOptions: model.thinkingOptions.map {
        RemoteThinkingOption(
          id: $0.id, label: $0.label, description: $0.description,
          isDefault: $0.isDefault)
      },
      defaultThinkingOptionID: model.defaultThinkingOptionID)
  }

  func createThread(_ intent: RemoteNewThreadIntent) async throws -> RemoteNewThreadResult {
    let result = try await client.createAgent(
      PaseoAgentCreationIntent(
        idempotencyKey: intent.idempotencyKey,
        clientMessageID: intent.clientMessageID,
        provider: intent.provider,
        model: intent.model,
        cwd: intent.cwd,
        initialPrompt: intent.prompt,
        images: intent.images.map { PaseoImage(data: $0.data, mimeType: $0.mimeType) }))
    let thread = result.agent.map { agent in
      RemoteThread(
        id: agent.id,
        title: agent.title ?? "New thread",
        provider: agent.provider,
        model: agent.model,
        state: Self.mapState(agent.status),
        requiresAttention: agent.requiresAttention,
        attentionReason: agent.attentionReason, cwd: agent.cwd)
    }
    return RemoteNewThreadResult(
      thread: thread, promptAccepted: result.promptAccepted, error: result.error,
      safeToRestart: result.safeToRestart)
  }

  func connectionEvents() async -> AsyncStream<RemoteConnectionEvent> {
    let source = await client.connectionEvents()
    return AsyncStream { continuation in
      let task = Task {
        for await state in source {
          switch state {
          case .connected:
            continuation.yield(.connected)
          case .connecting:
            break
          case .disconnected:
            continuation.yield(.disconnected("The Paseo host closed the connection."))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  func projects() async throws -> [RemoteProject] {
    let loadedProjects = try await client.listProjects()
    return loadedProjects.map { project in
      RemoteProject(
        id: project.id, name: project.name, subtitle: project.rootPath,
        rootPath: project.rootPath)
    }
  }

  func threads(projectID: String) async throws -> [RemoteThread] {
    var cursor: String?
    var seenCursors = Set<String>()
    var results: [RemoteThread] = []
    repeat {
      let page = try await client.listThreads(
        projectID: projectID,
        page: PaseoPageRequest(cursor: cursor, limit: 100)
      )
      results.append(contentsOf: page.items.map(Self.mapThread))
      guard page.hasMore else { break }
      guard
        let nextCursor = page.nextCursor,
        !nextCursor.isEmpty,
        seenCursors.insert(nextCursor).inserted
      else {
        throw RemoteServiceError.unavailable(
          "The Paseo host returned an invalid project thread page cursor.")
      }
      cursor = nextCursor
    } while true
    return results
  }

  func history(agentID: String, before cursor: RemoteTimelineCursor?) async throws -> RemoteTimeline
  {
    if cursor == nil {
      // A refresh may overlap live delivery. Hold those events until the
      // returned snapshot has seeded cursors and tool lifecycle state.
      historyReady.remove(agentID)
      if pendingEvents[agentID] == nil { pendingEvents[agentID] = [] }
    }
    let paseoCursor = cursor.map { PaseoTimelineCursor(epoch: $0.epoch, sequence: $0.sequence) }
    let page = try await client.history(
      agentID: agentID,
      direction: cursor == nil ? .tail : .before,
      cursor: paseoCursor,
      limit: 100
    )
    let mapped = Self.mapMessages(page.entries)
    if cursor == nil {
      toolSnapshots[agentID] = mapped.toolSnapshots
      historyCursors[agentID] = page.endCursor
      snapshotCursors[agentID] = page.endCursor
      resnapshotEpochs[agentID] = nil
      historyReady.insert(agentID)
      let buffered = pendingEvents.removeValue(forKey: agentID) ?? []
      let token = eventTokens[agentID]
      for event in buffered {
        guard emitLiveEvent(event, agentID: agentID), eventTokens[agentID] == token else { break }
      }
    } else {
      for (id, snapshot) in mapped.toolSnapshots where toolSnapshots[agentID]?[id] == nil {
        toolSnapshots[agentID, default: [:]][id] = snapshot
      }
    }
    return RemoteTimeline(
      messages: mapped.messages,
      historyMayBeIncomplete: page.gap || page.staleCursor || page.reset,
      hasOlder: page.hasOlder,
      olderCursor: page.startCursor.map {
        RemoteTimelineCursor(epoch: $0.epoch, sequence: $0.sequence)
      },
      latestCursor: cursor == nil ? page.endCursor.map(Self.mapCursor) : nil
    )
  }

  func events(agentID: String) async throws -> AsyncThrowingStream<RemoteTimelineUpdate, Error> {
    let source = try await client.events(agentID: agentID, after: historyCursors[agentID])
    let (stream, continuation) = AsyncThrowingStream<RemoteTimelineUpdate, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(Self.eventBufferLimit))
    let token = UUID()
    eventContinuations[agentID]?.finish()
    eventReaderTasks[agentID]?.cancel()
    eventContinuations[agentID] = continuation
    eventTokens[agentID] = token
    pendingEvents[agentID] = []
    historyReady.remove(agentID)
    let task = Task {
      do {
        for try await event in source {
          self.receiveLiveEvent(event, agentID: agentID, token: token)
        }
        self.finishEventStream(agentID: agentID, token: token)
      } catch {
        self.finishEventStream(agentID: agentID, token: token, error: error)
      }
    }
    eventReaderTasks[agentID] = task
    continuation.onTermination = { @Sendable _ in
      Task { await self.cancelEventStream(agentID: agentID, token: token) }
    }
    return stream
  }

  func send(agentID: String, text: String) async throws {
    try await client.send(agentID: agentID, text: text)
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
    let activeTurnBehavior: PaseoActiveTurnBehavior =
      switch behavior {
      case .interrupt: .interrupt
      case .steer: .steer
      }
    try await client.send(
      agentID: agentID, text: text, messageID: messageID,
      activeTurnBehavior: activeTurnBehavior,
      images: images.map { PaseoImage(data: $0.data, mimeType: $0.mimeType) })
  }

  func readImage(cwd: String, path: String, maxBytes: Int) async throws -> Data {
    try await client.readImage(cwd: cwd, path: path, maxBytes: maxBytes)
  }

  func stop(agentID: String) async throws -> RemoteAgentControlSnapshot? {
    guard let snapshot = try await client.cancelAgent(agentID: agentID) else { return nil }
    return RemoteAgentControlSnapshot(
      id: snapshot.id, state: Self.mapState(snapshot.status),
      requiresAttention: snapshot.requiresAttention,
      attentionReason: snapshot.attentionReason)
  }

  func pendingPermissions() async throws -> [RemotePermission] {
    let requests = try await client.pendingPermissions()
    return requests.map(Self.mapPermission)
  }

  func answerPermission(_ permission: RemotePermission, allow: Bool) async throws {
    let decision: PaseoPermissionDecision
    if allow {
      decision = .allow(actionID: permission.allowActionID)
    } else {
      decision = .deny(actionID: permission.denyActionID, message: nil, interrupt: nil)
    }
    try await client.answerPermission(
      agentID: permission.agentID, requestID: permission.id, decision: decision)
  }

  func disconnect() async {
    await client.disconnect()
    historyCursors.removeAll()
    snapshotCursors.removeAll()
    resnapshotEpochs.removeAll()
    liveMessageSequences.removeAll()
    toolSnapshots.removeAll()
    pendingEvents.removeAll()
    historyReady.removeAll()
    for task in eventReaderTasks.values {
      task.cancel()
    }
    eventReaderTasks.removeAll()
    for continuation in eventContinuations.values {
      continuation.finish()
    }
    eventContinuations.removeAll()
    eventTokens.removeAll()
  }

  private func receiveLiveEvent(_ event: PaseoTimelineEvent, agentID: String, token: UUID) {
    guard eventTokens[agentID] == token else { return }
    guard historyReady.contains(agentID) else {
      var buffered = pendingEvents[agentID, default: []]
      guard buffered.count < Self.eventBufferLimit else {
        failEventStream(
          agentID: agentID,
          token: token,
          error: Self.eventOverflowError("while loading the timeline snapshot")
        )
        return
      }
      buffered.append(event)
      pendingEvents[agentID] = buffered
      return
    }
    emitLiveEvent(event, agentID: agentID)
  }

  @discardableResult
  private func emitLiveEvent(_ event: PaseoTimelineEvent, agentID: String) -> Bool {
    guard let continuation = eventContinuations[agentID] else { return false }
    for update in mapLiveEvent(event, agentID: agentID) {
      switch continuation.yield(update) {
      case .enqueued:
        continue
      case .dropped:
        guard let token = eventTokens[agentID] else { return false }
        failEventStream(
          agentID: agentID,
          token: token,
          error: Self.eventOverflowError("while delivering live updates")
        )
        return false
      case .terminated:
        if let token = eventTokens[agentID] {
          cancelEventStream(agentID: agentID, token: token)
        }
        return false
      @unknown default:
        guard let token = eventTokens[agentID] else { return false }
        failEventStream(
          agentID: agentID,
          token: token,
          error: Self.eventOverflowError("while delivering live updates")
        )
        return false
      }
    }
    return true
  }

  private func failEventStream(agentID: String, token: UUID, error: Error) {
    guard eventTokens[agentID] == token else { return }
    eventReaderTasks.removeValue(forKey: agentID)?.cancel()
    finishEventStream(agentID: agentID, token: token, error: error)
  }

  private static func eventOverflowError(_ phase: String) -> RemoteServiceError {
    .connectionLost(
      "Live timeline updates exceeded the buffer \(phase). Reconnect to restore the timeline.")
  }

  private func mapLiveEvent(_ event: PaseoTimelineEvent, agentID: String) -> [RemoteTimelineUpdate]
  {
    switch event {
    case .item(_, let value, let timestamp, let sequence, let epoch):
      let cursor = epoch.flatMap { epoch in
        sequence.map { PaseoTimelineCursor(epoch: epoch, sequence: $0) }
      }
      if let cursor, let snapshot = historyCursors[agentID] {
        if cursor.epoch != snapshot.epoch {
          if resnapshotEpochs[agentID] == cursor.epoch { return [] }
          resnapshotEpochs[agentID] = cursor.epoch
          historyCursors[agentID] = cursor
          return [.historyChanged]
        }
        if let snapshotCursor = snapshotCursors[agentID],
          cursor.epoch == snapshotCursor.epoch,
          cursor.sequence <= snapshotCursor.sequence
        {
          return []
        }
        if cursor.sequence < snapshot.sequence { return [] }
        if cursor.sequence > snapshot.sequence {
          if snapshot.sequence < Int.max, cursor.sequence > snapshot.sequence + 1 {
            historyCursors[agentID] = cursor
            return [.historyChanged]
          }
          historyCursors[agentID] = cursor
        }
      }
      let type = value["type"]?.stringValue
      if type == "timeline", let item = value["item"] {
        let fallbackID = "live:\(epoch ?? "epoch"):\(sequence ?? 0)"
        if item["type"]?.stringValue == "assistant_message",
          let messageID = item["messageId"]?.stringValue,
          let text = item["text"]?.stringValue
        {
          let priorSequence = liveMessageSequences[agentID]?[messageID]
          if let sequence { liveMessageSequences[agentID, default: [:]][messageID] = sequence }
          let message = RemoteMessage(
            id: messageID, author: .agent, text: text, timestamp: Self.parseTimestamp(timestamp))
          let isDelta =
            priorSequence.map { previous in sequence.map { $0 > previous } ?? false } ?? true
          return [.message(message, cursor: cursor.map(Self.mapCursor), isDelta: isDelta)]
        }
        let turnID = value["turnId"]?.stringValue
        var displayItem = item
        if item["type"]?.stringValue == "tool_call", let object = item.objectValue,
          let call = RemoteToolCallMapper.map(object, turnID: turnID)
        {
          let prior = toolSnapshots[agentID]?[call.rowID]
          let merged = prior.map { RemoteToolCallMapper.merge($0, with: object) } ?? object
          toolSnapshots[agentID, default: [:]][call.rowID] = merged
          displayItem = .object(merged)
        }
        guard
          let message = Self.mapTimelineItem(
            displayItem, fallbackID: fallbackID, timestamp: timestamp, turnID: turnID)
        else { return [] }
        return [.message(message, cursor: cursor.map(Self.mapCursor), isDelta: false)]
      }
      switch type {
      case "turn_started": return [.threadState(.running, requiresAttention: false, reason: nil)]
      case "turn_completed":
        var updates: [RemoteTimelineUpdate] = [
          .threadState(.idle, requiresAttention: false, reason: nil)
        ]
        let usage = Self.mapContextUsage(
          used: value["usage"]?["contextWindowUsedTokens"]?.validUsageNumber,
          max: value["usage"]?["contextWindowMaxTokens"]?.validUsageNumber)
        if let usage { updates.append(.contextUsage(usage)) }
        if usage?.usedTokens == nil || usage?.maxTokens == nil {
          updates.append(.contextUsageNeedsRefresh)
        }
        return updates
      case "turn_canceled":
        return [
          .threadState(.idle, requiresAttention: false, reason: nil),
          .contextUsageNeedsRefresh,
        ]
      case "turn_failed":
        return [
          .threadState(.failed, requiresAttention: true, reason: value["error"]?.stringValue),
          .contextUsageNeedsRefresh,
        ]
      case "attention_required":
        return [
          .threadState(.waiting, requiresAttention: true, reason: value["reason"]?.stringValue)
        ]
      default: return []
      }
    case .reloadRequired:
      return [.historyChanged]
    case .permissionRequested(let request):
      return [.permissionRequested(Self.mapPermission(request))]
    case .permissionResolved(_, let requestID):
      return [.permissionResolved(requestID)]
    }
  }

  private func finishEventStream(agentID: String, token: UUID, error: Error? = nil) {
    guard eventTokens[agentID] == token else { return }
    let continuation = eventContinuations.removeValue(forKey: agentID)
    eventReaderTasks[agentID] = nil
    eventTokens[agentID] = nil
    historyReady.remove(agentID)
    pendingEvents[agentID] = nil
    if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
  }

  private func cancelEventStream(agentID: String, token: UUID) {
    guard eventTokens[agentID] == token else { return }
    eventReaderTasks.removeValue(forKey: agentID)?.cancel()
    eventContinuations.removeValue(forKey: agentID)?.finish()
    eventTokens[agentID] = nil
    pendingEvents[agentID] = nil
    historyReady.remove(agentID)
  }

  #if DEBUG
    func bufferedUpdateCountForTesting(agentID: String) -> Int {
      pendingEvents[agentID]?.count ?? 0
    }
  #endif

  private static func mapCursor(_ cursor: PaseoTimelineCursor) -> RemoteTimelineCursor {
    RemoteTimelineCursor(epoch: cursor.epoch, sequence: cursor.sequence)
  }

  private static func mapThread(_ thread: PaseoThread) -> RemoteThread {
    let title = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return RemoteThread(
      id: thread.id,
      title: title?.isEmpty == false ? title ?? "Untitled thread" : "Untitled thread",
      provider: thread.provider,
      model: thread.model,
      state: mapState(thread.status),
      requiresAttention: thread.requiresAttention,
      attentionReason: thread.attentionReason,
      contextUsage: mapContextUsage(
        used: thread.contextWindowUsedTokens, max: thread.contextWindowMaxTokens),
      cwd: thread.cwd
    )
  }

  private static func mapContextUsage(used: Double?, max: Double?) -> RemoteContextUsage? {
    let used = used.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    let max = max.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    guard used != nil || max != nil else { return nil }
    return RemoteContextUsage(usedTokens: used, maxTokens: max)
  }

  private static func mapUsageStatus(_ value: String) -> RemoteProviderUsage.Status {
    switch value {
    case "available": .available
    case "unavailable": .unavailable
    case "error": .error
    default: .unknown(value)
    }
  }

  private static func mapUsageTone(_ value: String?) -> RemoteProviderUsage.Tone? {
    guard let value else { return nil }
    return switch value {
    case "default": .default
    case "ok": .ok
    case "warning": .warning
    case "danger": .danger
    default: .unknown(value)
    }
  }

  private static func mapState(_ status: String) -> RemoteThread.State {
    switch status {
    case "initializing": .initializing
    case "running": .running
    case "idle": .idle
    case "closed": .closed
    case "error": .failed
    default: .unknown(status)
    }
  }

  private struct MappedMessages {
    let messages: [RemoteMessage]
    let toolSnapshots: [String: [String: PaseoJSONValue]]
  }

  private static func mapMessages(_ entries: [PaseoTimelineEntry]) -> MappedMessages {
    var messages: [RemoteMessage] = []
    var toolSnapshots: [String: [String: PaseoJSONValue]] = [:]
    var toolSequences: [String: Int] = [:]
    for entry in entries {
      var item = entry.item
      if item["type"]?.stringValue == "tool_call", let object = item.objectValue,
        let call = RemoteToolCallMapper.map(object, turnID: entry.turnID)
      {
        guard entry.endSequence >= toolSequences[call.rowID, default: Int.min] else { continue }
        let prior = toolSnapshots[call.rowID]
        let merged = prior.map { RemoteToolCallMapper.merge($0, with: object) } ?? object
        toolSnapshots[call.rowID] = merged
        toolSequences[call.rowID] = entry.endSequence
        item = .object(merged)
      }
      guard
        let message = mapTimelineItem(
          item, fallbackID: entry.id, timestamp: entry.timestamp, turnID: entry.turnID)
      else { continue }
      if let index = messages.firstIndex(where: { $0.id == message.id }) {
        if message.toolCall != nil {
          var replacement = message
          replacement.timestamp = messages[index].timestamp ?? message.timestamp
          messages[index] = replacement
        } else {
          messages[index].text += message.text
          messages[index].timestamp = message.timestamp ?? messages[index].timestamp
        }
      } else {
        messages.append(message)
      }
    }
    return MappedMessages(messages: messages, toolSnapshots: toolSnapshots)
  }

  private static func mapTimelineItem(
    _ value: PaseoJSONValue,
    fallbackID: String,
    timestamp: String?,
    turnID: String? = nil
  ) -> RemoteMessage? {
    guard let object = value.objectValue,
      let type = object["type"]?.stringValue
    else { return nil }
    let id = object["messageId"]?.stringValue ?? fallbackID
    let date = timestamp.flatMap(parseTimestamp)
    switch type {
    case "user_message":
      guard let text = object["text"]?.stringValue else { return nil }
      return RemoteMessage(
        id: id, author: .user, text: text, timestamp: date,
        clientMessageID: object["clientMessageId"]?.stringValue)
    case "assistant_message", "reasoning":
      guard let text = object["text"]?.stringValue else { return nil }
      return RemoteMessage(id: id, author: .agent, text: text, timestamp: date)
    case "error", "notification":
      let text = object["message"]?.stringValue ?? "Agent activity"
      return RemoteMessage(id: id, author: .system, text: text, timestamp: date)
    case "tool_call":
      guard let toolCall = RemoteToolCallMapper.map(object, turnID: turnID) else { return nil }
      return RemoteMessage(
        id: toolCall.rowID, author: .agent,
        text: [toolCall.title, toolCall.summary].compactMap { $0 }.joined(separator: " · "),
        timestamp: date, toolCall: toolCall)
    case "plan":
      return RemoteMessage(
        id: id, author: .agent, text: object["text"]?.stringValue ?? "Plan updated.",
        timestamp: date)
    case "todo":
      return RemoteMessage(
        id: id, author: .system, text: "Agent checklist updated.", timestamp: date)
    case "compaction":
      return RemoteMessage(
        id: id, author: .system, text: "Conversation context compacted.", timestamp: date)
    default:
      return nil
    }
  }

  private static func mapPermission(_ permission: PaseoPermissionRequest) -> RemotePermission {
    let allowAction = permission.actions.first { $0.behavior == "allow" }
    let denyAction = permission.actions.first { $0.behavior == "deny" }
    let supportsSimpleDecision =
      permission.kind == "tool"
      || (permission.kind != "question" && permission.kind != "other" && allowAction != nil
        && denyAction != nil)
    var detail = permission.description
    if let input = permission.input, let inputDescription = jsonText(input) {
      detail = [detail, "Input: \(inputDescription)"].compactMap { $0 }.joined(separator: "\n\n")
    }
    return RemotePermission(
      id: permission.id,
      agentID: permission.agentID,
      title: permission.title ?? permission.name,
      detail: detail,
      kind: permission.kind,
      supportsSimpleDecision: supportsSimpleDecision,
      allowActionID: allowAction?.id,
      denyActionID: denyAction?.id,
      allowLabel: allowAction?.label,
      denyLabel: denyAction?.label
    )
  }

  private static func jsonText(_ value: PaseoJSONValue) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func parseTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let parsed = fractional.date(from: value) { return parsed }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: value)
  }
}
