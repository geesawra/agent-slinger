import Foundation
import Observation

private func withConnectionAttemptTimeout<T: Sendable>(
  _ timeout: Duration,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw PaseoConnectionError.timedOut
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else {
      throw PaseoConnectionError.timedOut
    }
    return result
  }
}

@MainActor
@Observable
final class OesapModel {
  private static let connectionAttemptTimeout: Duration = .seconds(30)
  private static let maximumConnectionRetries = 3
  private static let initialConnectionBackoffSeconds = 1
  private static let maximumConnectionBackoffSeconds = 5 * 60

  enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    var isBusy: Bool {
      self == .connecting || self == .reconnecting
    }
  }

  private(set) var connectionState: ConnectionState = .disconnected
  private(set) var hasSavedConnection = false
  private(set) var loadingSavedConnections = true
  private(set) var savedInstances: [SavedPaseoInstance] = []
  private(set) var activeInstanceID: String?
  private(set) var instanceError: String?
  private(set) var projects: [RemoteProject] = []
  private(set) var threads: [RemoteThread] = []
  private(set) var messages: [RemoteMessage] = []
  private(set) var bufferedAgentMessageIDs: Set<String> = []
  private(set) var timelineStructureRevision = 0
  @ObservationIgnored private var messageIndices: [String: Int] = [:]
  @ObservationIgnored private var bufferedAgentMessageTexts: [String: String] = [:]
  private(set) var performanceFixtureStreamBytes = 0
  private(set) var permissions: [RemotePermission] = []
  private(set) var historyMayBeIncomplete = false
  private(set) var loadingProjects = false
  private(set) var loadingThreads = false
  private(set) var loadingHistory = false
  private(set) var loadingOlderMessages = false
  private(set) var timelineHasOlder = false
  private(set) var sendingMessage = false
  private(set) var agentRequestReceiptsSupported = false
  private(set) var canCreateThreads = false
  private(set) var agentProviders: [RemoteAgentProvider] = []
  private(set) var loadingAgentOptions = false
  private(set) var agentConfigurationError: String?
  private(set) var agentConfigurationRevision = 0
  private(set) var agentOverviewGroups: [RemoteAgentOverviewGroup] = []
  private(set) var loadingAgentOverview = false
  private(set) var agentOverviewError: String?
  private(set) var agentOverviewIsStale = false
  private(set) var agentOverviewUpdatedAt: Date?
  private(set) var providerSubagentsByParent: [String: [RemoteProviderSubagent]] = [:]
  private(set) var providerSubagentErrors: [String: String] = [:]
  private(set) var loadingProviderSubagentParents: Set<String> = []
  private(set) var gitStatus: RemoteGitStatus?
  private(set) var gitStatusError: String?
  private(set) var loadingGitStatus = false
  private(set) var gitDiffByPath: [String: String] = [:]
  private(set) var gitDiffErrorByPath: [String: String] = [:]
  private(set) var providerUsageProviders: [RemoteProviderUsage] = []
  private(set) var providerUsageFetchedAt: Date?
  private(set) var providerUsageError: String?
  private(set) var providerUsageIsStale = false
  private(set) var loadingProviderUsage = false
  private(set) var providerUsageSupported = false
  private(set) var loadingContextUsage = false
  private(set) var contextUsageError: String?
  private(set) var sessionSettings: RemoteAgentSettings?
  private(set) var sessionDetailsLoading = false
  private(set) var sessionDetailsApplying = false
  private(set) var sessionDetailsError: String?
  private(set) var sessionDetailsNotice: String?
  private(set) var sessionDraftModelID: String?
  private(set) var sessionDraftThinkingOptionID: String?
  private(set) var sessionDraftModeID: String?
  private(set) var answeringPermissionID: String?
  private(set) var timelineGeneration = 0
  private(set) var connectError: String?
  private(set) var workspaceError: String?
  private(set) var workspaceNotice: String?
  private(set) var timelineError: String?
  private(set) var messageError: String?
  private(set) var permissionError: String?
  private(set) var selectedProjectID: String?
  private(set) var selectedThreadID: String?

  @ObservationIgnored private let connectionFactory: any OesapConnectionFactory
  @ObservationIgnored private let agentConfigurationStore: AgentConfigurationStore
  @ObservationIgnored private var service: (any OesapRemoteService)?
  @ObservationIgnored private var connectedServerID: String?
  @ObservationIgnored private var agentControlServerID: String?
  @ObservationIgnored private var pendingNewThreadIntents: [String: RemoteNewThreadIntent] = [:]
  @ObservationIgnored private var pendingNewThreadResults: [String: RemoteNewThreadResult] = [:]
  private struct PendingAgentMessage {
    let messageID: String
    let text: String
    let draftText: String
    let images: [RemoteDraftImage]
    let behavior: RemoteActiveTurnBehavior
    let receiptSupport: Bool
  }

  private var agentActionFeedback: [String: RemoteAgentActionFeedback] = [:]
  private var agentSendFeedback: [String: RemoteAgentActionFeedback] = [:]
  @ObservationIgnored private var pendingAgentMessages: [String: PendingAgentMessage] = [:]
  @ObservationIgnored private var agentSendTokens: [String: UUID] = [:]
  @ObservationIgnored private var agentStopTokens: [String: UUID] = [:]
  @ObservationIgnored private var threadStateRevisions: [String: Int] = [:]
  private var drafts: [String: String] = [:]
  private var imageDrafts: [String: [RemoteDraftImage]] = [:]
  @ObservationIgnored private var acceptedMessageImages: [String: [String: [RemoteDraftImage]]] =
    [:]
  @ObservationIgnored private var connectionObservationTask: Task<Void, Never>?
  @ObservationIgnored private var connectionGeneration = 0
  @ObservationIgnored private var startupConnectionStarted = false
  @ObservationIgnored private var shouldReconnectAfterBackground = false
  @ObservationIgnored private var appIsInBackground = false
  @ObservationIgnored private var foregroundReconnectScheduled = false
  @ObservationIgnored private var savedInstancesRefreshGeneration = 0
  @ObservationIgnored private var olderTimelineCursor: RemoteTimelineCursor?
  @ObservationIgnored private var latestTimelineCursor: RemoteTimelineCursor?
  @ObservationIgnored private var projectSelectionGeneration = 0
  @ObservationIgnored private var threadSelectionGeneration = 0
  @ObservationIgnored private var agentOverviewRefreshGeneration = 0
  @ObservationIgnored private var agentOverviewRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var agentOverviewRefreshTaskID: UUID?
  @ObservationIgnored private var agentOverviewRefreshQueued = false
  @ObservationIgnored private var gitRequestGeneration = 0
  @ObservationIgnored private var cachedGitDiffByPath: [String: String] = [:]
  @ObservationIgnored private var providerUsageRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var providerUsageRefreshTaskID: UUID?
  @ObservationIgnored private var providerUsageRefreshQueued = false
  @ObservationIgnored private var contextUsageRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var contextUsageRequestGeneration = 0
  @ObservationIgnored private var contextUsageRevision = 0
  @ObservationIgnored private var sessionDetailsThreadID: String?
  @ObservationIgnored private var sessionDetailsGeneration = 0
  @ObservationIgnored private var sessionDetailsRequestGeneration = 0
  private var activeSessionSettingsMutation: UUID?
  private var activeSessionSettingsMutationThreadID: String?

  private struct AgentOverviewLoadResult: Sendable {
    let index: Int
    let threads: [RemoteThread]?
    let error: String?
  }

  init(
    connectionFactory: any OesapConnectionFactory,
    agentConfigurationStore: AgentConfigurationStore = AgentConfigurationStore()
  ) {
    self.connectionFactory = connectionFactory
    self.agentConfigurationStore = agentConfigurationStore
    selectedProjectID = UserDefaults.standard.string(forKey: Self.selectedProjectKey)
    selectedThreadID = UserDefaults.standard.string(forKey: Self.selectedThreadKey)
  }

  var selectedProject: RemoteProject? {
    projects.first { $0.id == selectedProjectID }
  }

  var selectedThread: RemoteThread? {
    threads.first { $0.id == selectedThreadID }
  }

  func contextUsage(for threadID: String) -> RemoteContextUsage? {
    threads.first(where: { $0.id == threadID })?.contextUsage
  }

  func providerUsage(for providerID: String) -> RemoteProviderUsage? {
    providerUsageProviders.first(where: { $0.id == providerID })
  }

  var sessionSettingsHaveChanges: Bool {
    guard let settings = sessionSettings else { return false }
    return sessionDraftModelID != settings.modelID
      || (settings.supportsThinking
        && sessionDraftThinkingOptionID != settings.thinkingOptionID)
      || sessionDraftModeID != settings.currentModeID
  }

  var canApplySessionSettings: Bool {
    guard activeSessionSettingsMutation == nil, connectionState == .connected,
      !sessionDetailsLoading, !sessionDetailsApplying,
      let settings = sessionSettings, settings.canApply,
      !settings.models.isEmpty || !settings.availableModes.isEmpty,
      sessionSettingsHaveChanges,
      sessionDetailsThreadID == selectedThreadID
    else { return false }
    let modelID = sessionDraftModelID
    if modelID != settings.modelID,
      let modelID,
      !settings.models.contains(where: { $0.id == modelID })
    {
      return false
    }
    if settings.supportsThinking,
      sessionDraftThinkingOptionID != settings.thinkingOptionID,
      let optionID = sessionDraftThinkingOptionID
    {
      guard
        sessionModel(for: modelID, in: settings)?.thinkingOptions.contains(where: {
          $0.id == optionID
        }) == true
      else { return false }
    }
    if sessionDraftModeID != settings.currentModeID {
      guard let modeID = sessionDraftModeID,
        settings.availableModes.contains(where: { $0.id == modeID })
      else { return false }
    }
    return true
  }

  var sessionSettingsMutationPendingElsewhere: Bool {
    activeSessionSettingsMutation != nil
      && activeSessionSettingsMutationThreadID != sessionDetailsThreadID
  }

  func openSessionDetails(threadID: String) async {
    clearSessionDetails()
    sessionDetailsThreadID = threadID
    await refreshSessionDetails(threadID: threadID, preserveDraft: false)
    if sessionDetailsThreadID == threadID {
      await refreshContextUsage(threadID: threadID)
    }
  }

  func refreshSessionDetails(threadID: String) async {
    await refreshSessionDetails(threadID: threadID, preserveDraft: true)
  }

  func chooseSessionModel(_ modelID: String?) {
    guard let settings = sessionSettings, settings.canApply,
      sessionDetailsThreadID == selectedThreadID, !sessionDetailsApplying
    else { return }
    guard modelID == nil || settings.models.contains(where: { $0.id == modelID }) else { return }
    guard sessionDraftModelID != modelID else { return }
    sessionDraftModelID = modelID
    guard settings.supportsThinking else { return }
    sessionDraftThinkingOptionID = nil
  }

  func chooseSessionThinkingOption(_ optionID: String?) {
    guard let settings = sessionSettings, settings.canApply, settings.supportsThinking,
      sessionDetailsThreadID == selectedThreadID, !sessionDetailsApplying,
      let model = sessionModel(for: sessionDraftModelID, in: settings)
    else { return }
    guard optionID == nil || model.thinkingOptions.contains(where: { $0.id == optionID }) else {
      return
    }
    sessionDraftThinkingOptionID = optionID
  }

  func chooseSessionMode(_ modeID: String?) {
    guard let settings = sessionSettings, settings.canApply,
      sessionDetailsThreadID == selectedThreadID, !sessionDetailsApplying
    else { return }
    guard
      modeID == settings.currentModeID
        || settings.availableModes.contains(where: { $0.id == modeID })
    else { return }
    sessionDraftModeID = modeID
  }

  @discardableResult
  func applySessionSettings(threadID: String) async -> Bool {
    guard activeSessionSettingsMutation == nil, connectionState == .connected,
      sessionDetailsThreadID == threadID, selectedThreadID == threadID,
      let settings = sessionSettings, canApplySessionSettings,
      let remote = service
    else { return false }
    let modelID = sessionDraftModelID
    let thinkingOptionID = settings.supportsThinking ? sessionDraftThinkingOptionID : nil
    let modeChanged = sessionDraftModeID != settings.currentModeID
    let modelChanged = modelID != settings.modelID
    let effortChanged =
      settings.supportsThinking
      && thinkingOptionID != settings.thinkingOptionID
    let modeID = modeChanged ? sessionDraftModeID : nil
    let generation = connectionGeneration
    let selectionGeneration = threadSelectionGeneration
    let detailsGeneration = sessionDetailsGeneration
    let serverID = connectedServerID
    let mutationID = UUID()
    activeSessionSettingsMutation = mutationID
    activeSessionSettingsMutationThreadID = threadID
    sessionDetailsRequestGeneration += 1
    sessionDetailsApplying = true
    sessionDetailsError = nil
    sessionDetailsNotice = nil
    var applyNotice: String?
    var applyError: String?
    do {
      if modelChanged {
        applyNotice = try await remote.applyAgentSettings(
          agentID: threadID, modelID: modelID, thinkingOptionID: thinkingOptionID,
          modeID: modeID
        ).notice
      } else if effortChanged {
        applyNotice = try await remote.applyAgentThinking(
          agentID: threadID, thinkingOptionID: thinkingOptionID, modeID: modeID
        ).notice
      } else if let modeID {
        applyNotice = try await remote.applyAgentMode(
          agentID: threadID, modeID: modeID
        ).notice
      }
    } catch {
      applyError = error.localizedDescription
    }
    // The host may apply the model before rejecting the effort. Always read back.
    var refreshed: RemoteAgentSettings?
    var refreshError: String?
    do {
      refreshed = try await remote.agentSettings(agentID: threadID)
    } catch {
      refreshError = error.localizedDescription
    }
    guard activeSessionSettingsMutation == mutationID else { return false }
    activeSessionSettingsMutation = nil
    activeSessionSettingsMutationThreadID = nil
    sessionDetailsApplying = false
    guard connectionGeneration == generation,
      threadSelectionGeneration == selectionGeneration,
      sessionDetailsGeneration == detailsGeneration,
      selectedThreadID == threadID, sessionDetailsThreadID == threadID,
      connectedServerID == serverID
    else { return false }
    if let refreshed {
      installSessionSettings(refreshed, threadID: threadID)
      if applyError == nil {
        sessionDraftModelID = refreshed.modelID
        sessionDraftThinkingOptionID = refreshed.thinkingOptionID
        sessionDraftModeID = refreshed.currentModeID
      }
    }
    if let applyError, let refreshError {
      sessionDetailsError =
        "The host could not apply these settings: \(applyError). Current settings could not be loaded: \(refreshError)"
    } else if let applyError {
      sessionDetailsError = "The host could not apply these settings: \(applyError)"
    } else if let refreshError {
      sessionDetailsError =
        "The change may have applied, but current settings could not be loaded: \(refreshError)"
    } else {
      sessionDetailsNotice = applyNotice ?? "Current settings loaded from the host."
    }
    return applyError == nil && refreshError == nil
  }

  private func refreshSessionDetails(threadID: String, preserveDraft: Bool) async {
    guard !sessionDetailsApplying else { return }
    guard connectionState == .connected, selectedThreadID == threadID,
      sessionDetailsThreadID == threadID, let remote = service
    else {
      if sessionDetailsThreadID == threadID {
        sessionDetailsError = "Reconnect to load session settings."
      }
      return
    }
    let generation = connectionGeneration
    let selectionGeneration = threadSelectionGeneration
    let detailsGeneration = sessionDetailsGeneration
    let serverID = connectedServerID
    sessionDetailsRequestGeneration += 1
    let requestGeneration = sessionDetailsRequestGeneration
    sessionDetailsLoading = true
    sessionDetailsError = nil
    do {
      let fetched = try await remote.agentSettings(agentID: threadID)
      guard connectionGeneration == generation,
        threadSelectionGeneration == selectionGeneration,
        sessionDetailsGeneration == detailsGeneration,
        sessionDetailsRequestGeneration == requestGeneration,
        selectedThreadID == threadID, sessionDetailsThreadID == threadID,
        connectedServerID == serverID
      else { return }
      let hadDraft = preserveDraft && sessionSettingsHaveChanges
      installSessionSettings(fetched, threadID: threadID)
      if !hadDraft {
        sessionDraftModelID = fetched.modelID
        sessionDraftThinkingOptionID = fetched.thinkingOptionID
        sessionDraftModeID = fetched.currentModeID
      }
      sessionDetailsLoading = false
    } catch {
      guard connectionGeneration == generation,
        threadSelectionGeneration == selectionGeneration,
        sessionDetailsGeneration == detailsGeneration,
        sessionDetailsRequestGeneration == requestGeneration,
        selectedThreadID == threadID, sessionDetailsThreadID == threadID,
        connectedServerID == serverID
      else { return }
      sessionDetailsLoading = false
      sessionDetailsError = error.localizedDescription
    }
  }

  private func clearSessionDetails() {
    sessionDetailsGeneration += 1
    sessionDetailsRequestGeneration += 1
    sessionDetailsThreadID = nil
    sessionSettings = nil
    sessionDetailsLoading = false
    sessionDetailsApplying = false
    sessionDetailsError = nil
    sessionDetailsNotice = nil
    sessionDraftModelID = nil
    sessionDraftThinkingOptionID = nil
    sessionDraftModeID = nil
  }

  private func sessionModel(
    for modelID: String?, in settings: RemoteAgentSettings
  ) -> RemoteAgentModel? {
    if let modelID { return settings.models.first { $0.id == modelID } }
    return settings.models.first(where: \.isDefault)
  }

  private func installSessionSettings(_ settings: RemoteAgentSettings, threadID: String) {
    sessionSettings = settings
    if let index = threads.firstIndex(where: { $0.id == threadID }) {
      threads[index].model = settings.modelID
    }
  }

  func refreshProviderUsage() async {
    await startProviderUsageRefresh().value
  }

  func refreshUsageForSelectedThread() async {
    let threadID = selectedThreadID
    async let providerRefresh: Void = refreshProviderUsage()
    if let threadID { await refreshContextUsage(threadID: threadID) }
    await providerRefresh
  }

  func refreshContextUsage(threadID: String) async {
    guard connectionState == .connected, selectedThreadID == threadID, let service else { return }
    let generation = connectionGeneration
    let selectionGeneration = threadSelectionGeneration
    contextUsageRequestGeneration += 1
    let requestGeneration = contextUsageRequestGeneration
    let revision = contextUsageRevision
    loadingContextUsage = true
    contextUsageError = nil
    defer {
      if contextUsageRequestGeneration == requestGeneration { loadingContextUsage = false }
    }
    do {
      let usage = try await service.contextUsage(agentID: threadID)
      guard connectionGeneration == generation,
        threadSelectionGeneration == selectionGeneration,
        selectedThreadID == threadID,
        contextUsageRequestGeneration == requestGeneration,
        contextUsageRevision == revision,
        !Task.isCancelled
      else { return }
      if let index = threads.firstIndex(where: { $0.id == threadID }) {
        threads[index].contextUsage = usage
      }
    } catch {
      guard connectionGeneration == generation,
        threadSelectionGeneration == selectionGeneration,
        selectedThreadID == threadID,
        contextUsageRequestGeneration == requestGeneration,
        contextUsageRevision == revision,
        !Task.isCancelled
      else { return }
      let summary =
        contextUsage(for: threadID) == nil
        ? "Context usage couldn’t be loaded."
        : "Context usage couldn’t be refreshed. Last reported values remain visible."
      contextUsageError = "\(summary) \(error.localizedDescription)"
    }
  }

  var selectedPermission: RemotePermission? {
    permissions.first { $0.agentID == selectedThreadID }
  }

  func refreshSavedConnectionState() async {
    await refreshSavedInstances()
  }

  func start() async {
    guard !startupConnectionStarted else { return }
    defer { scheduleForegroundReconnectIfNeeded() }
    startupConnectionStarted = true
    await refreshSavedInstances()
    loadingSavedConnections = false
    guard !Task.isCancelled, connectionState == .disconnected,
      let instanceID = activeInstanceID ?? savedInstances.first?.id
    else { return }
    _ = await selectSavedInstance(instanceID)
  }

  func appDidEnterBackground() {
    appIsInBackground = true
    shouldReconnectAfterBackground = true
  }

  func appDidBecomeActive() async {
    appIsInBackground = false
    guard shouldReconnectAfterBackground else { return }

    if loadingSavedConnections {
      await refreshSavedInstances()
    }
    guard !appIsInBackground else { return }
    guard !loadingSavedConnections else { return }
    guard hasSavedConnection, activeInstanceID != nil else {
      shouldReconnectAfterBackground = false
      return
    }
    guard !connectionState.isBusy else { return }
    shouldReconnectAfterBackground = false
    await reconnect()
  }

  private func scheduleForegroundReconnectIfNeeded() {
    guard shouldReconnectAfterBackground, !appIsInBackground,
      !loadingSavedConnections, !connectionState.isBusy,
      !foregroundReconnectScheduled
    else { return }
    foregroundReconnectScheduled = true
    Task { [weak self] in
      guard let self else { return }
      self.foregroundReconnectScheduled = false
      guard self.shouldReconnectAfterBackground, !self.appIsInBackground,
        !self.loadingSavedConnections, !self.connectionState.isBusy
      else { return }
      guard self.hasSavedConnection, self.activeInstanceID != nil else {
        self.shouldReconnectAfterBackground = false
        return
      }
      self.shouldReconnectAfterBackground = false
      await self.reconnect()
    }
  }

  func refreshSavedInstances() async {
    savedInstancesRefreshGeneration += 1
    let refreshGeneration = savedInstancesRefreshGeneration
    let generation = connectionGeneration
    do {
      let instances = try await connectionFactory.listSavedInstances()
      let activeID = try await connectionFactory.activeInstanceID()
      guard connectionGeneration == generation,
        savedInstancesRefreshGeneration == refreshGeneration
      else { return }
      savedInstances = instances
      activeInstanceID = activeID
      hasSavedConnection = !instances.isEmpty
      instanceError = nil
    } catch {
      guard connectionGeneration == generation,
        savedInstancesRefreshGeneration == refreshGeneration
      else { return }
      instanceError = error.localizedDescription
    }
  }

  func connect(_ connection: RemoteConnection) async {
    defer { scheduleForegroundReconnectIfNeeded() }
    let previousService = service
    let preserveInitialSelection =
      previousService == nil && activeInstanceID == nil
      && projects.isEmpty && threads.isEmpty && messages.isEmpty
    let generation = invalidateConnection()
    service = nil
    connectedServerID = nil
    clearWorkspaceForInstanceChange(preserveSelection: preserveInitialSelection)
    connectionState = .connecting
    clearErrors()
    instanceError = nil
    await previousService?.disconnect()
    guard connectionGeneration == generation else { return }
    do {
      let factory = connectionFactory
      let connectedService = try await connectWithRetry(generation: generation) {
        try await factory.connect(connection)
      }
      guard connectionGeneration == generation else {
        await connectedService.disconnect()
        return
      }
      if Task.isCancelled {
        // The factory has returned, so this attempt's credentials were saved.
        // Clear only this completed attempt; cancellation before that point
        // leaves any previously saved host intact.
        await disconnect()
        return
      }
      let serverID = await connectedService.serverID()
      let supportsNewThreads = await connectedService.supportsNewThreads()
      let supportsProviderUsage = await connectedService.supportsProviderUsage()
      let supportsAgentRequestReceipts = await connectedService.supportsAgentRequestReceipts()
      guard connectionGeneration == generation else {
        await connectedService.disconnect()
        return
      }
      if Task.isCancelled {
        await disconnect()
        return
      }
      service = connectedService
      connectedServerID = serverID
      if agentControlServerID != nil && agentControlServerID != serverID {
        clearAgentControlState()
      }
      agentControlServerID = serverID
      canCreateThreads = supportsNewThreads
      providerUsageSupported = supportsProviderUsage
      agentRequestReceiptsSupported = supportsAgentRequestReceipts
      connectionState = .connected
      timelineGeneration += 1
      startObservingConnection(connectedService, generation: generation)
      await reloadWorkspace(preserveSelection: preserveInitialSelection, generation: generation)
      if connectionGeneration == generation { _ = startProviderUsageRefresh() }
      if connectionGeneration == generation { await refreshSavedInstances() }
      if connectionGeneration == generation, Task.isCancelled { await disconnect() }
    } catch {
      guard connectionGeneration == generation else { return }
      if error is CancellationError {
        connectionState = .disconnected
        await refreshSavedInstances()
        return
      }
      service = nil
      connectedServerID = nil
      canCreateThreads = false
      providerUsageSupported = false
      agentRequestReceiptsSupported = false
      connectionState = .disconnected
      connectError = error.localizedDescription
      await refreshSavedInstances()
      if connectionGeneration == generation { instanceError = error.localizedDescription }
    }
  }

  @discardableResult
  func selectSavedInstance(_ id: String) async -> Bool {
    defer { scheduleForegroundReconnectIfNeeded() }
    guard savedInstances.contains(where: { $0.id == id }) else {
      instanceError = "This saved Paseo instance is no longer available. Refresh and try again."
      return false
    }
    if activeInstanceID == id, connectionState == .connected { return true }

    let previousService = service
    let generation = invalidateConnection()
    service = nil
    connectedServerID = nil
    clearWorkspaceForInstanceChange()
    activeInstanceID = id
    connectionState = .connecting
    clearErrors()
    instanceError = nil
    await previousService?.disconnect()
    guard connectionGeneration == generation else { return false }

    do {
      let factory = connectionFactory
      let connectedService = try await connectWithRetry(generation: generation) {
        try await factory.selectSavedInstance(id: id)
      }
      guard connectionGeneration == generation else {
        await connectedService.disconnect()
        return false
      }
      if Task.isCancelled {
        await connectedService.disconnect()
        guard connectionGeneration == generation else { return false }
        connectionState = .disconnected
        await refreshSavedInstances()
        return false
      }
      let serverID = await connectedService.serverID()
      let supportsNewThreads = await connectedService.supportsNewThreads()
      let supportsProviderUsage = await connectedService.supportsProviderUsage()
      let supportsAgentRequestReceipts = await connectedService.supportsAgentRequestReceipts()
      guard connectionGeneration == generation else {
        await connectedService.disconnect()
        return false
      }
      if Task.isCancelled {
        await connectedService.disconnect()
        guard connectionGeneration == generation else { return false }
        connectionState = .disconnected
        await refreshSavedInstances()
        return false
      }
      service = connectedService
      connectedServerID = serverID
      agentControlServerID = serverID
      canCreateThreads = supportsNewThreads
      providerUsageSupported = supportsProviderUsage
      agentRequestReceiptsSupported = supportsAgentRequestReceipts
      connectionState = .connected
      timelineGeneration += 1
      startObservingConnection(connectedService, generation: generation)
      await reloadWorkspace(preserveSelection: false, generation: generation)
      if connectionGeneration == generation { _ = startProviderUsageRefresh() }
      if connectionGeneration == generation { await refreshSavedInstances() }
      if connectionGeneration == generation, Task.isCancelled {
        await markConnectionLost(
          generation: generation,
          reason: "Switching instances was cancelled. Reconnect to continue.")
      }
      return connectionGeneration == generation && connectionState == .connected
    } catch {
      guard connectionGeneration == generation else { return false }
      service = nil
      connectedServerID = nil
      canCreateThreads = false
      providerUsageSupported = false
      agentRequestReceiptsSupported = false
      connectionState = .disconnected
      connectError = error.localizedDescription
      await refreshSavedInstances()
      if connectionGeneration == generation { instanceError = error.localizedDescription }
      return false
    }
  }

  func removeSavedInstance(_ id: String) async {
    let removesActiveInstance = activeInstanceID == id
    let generation: Int
    let previousService: (any OesapRemoteService)?
    if removesActiveInstance {
      previousService = service
      generation = invalidateConnection()
      service = nil
      connectedServerID = nil
      clearWorkspaceForInstanceChange()
      connectionState = .disconnected
      clearErrors()
    } else {
      previousService = nil
      generation = connectionGeneration
    }
    instanceError = nil
    await previousService?.disconnect()
    guard connectionGeneration == generation else { return }
    do {
      try await connectionFactory.removeSavedInstance(id: id)
      guard connectionGeneration == generation else { return }
      await refreshSavedInstances()
    } catch {
      guard connectionGeneration == generation else { return }
      await refreshSavedInstances()
      guard connectionGeneration == generation else { return }
      instanceError = error.localizedDescription
      if removesActiveInstance, connectionGeneration == generation {
        connectError = error.localizedDescription
      }
    }
  }

  func reconnect() async {
    guard !connectionState.isBusy else { return }
    defer { scheduleForegroundReconnectIfNeeded() }
    let priorServerID = agentControlServerID ?? connectedServerID
    prepareAgentActionsForConnectionChange()
    let generation = invalidateConnection()
    service = nil
    canCreateThreads = false
    agentProviders = []
    loadingAgentOptions = false
    agentOverviewIsStale = true
    providerUsageIsStale = true
    loadingProviderUsage = false
    loadingAgentOverview = false
    agentOverviewRefreshGeneration += 1
    connectionState = .reconnecting
    clearErrors()
    do {
      let factory = connectionFactory
      let connectedService = try await connectWithRetry(generation: generation) {
        try await factory.reconnect()
      }
      guard connectionGeneration == generation else {
        await connectedService.disconnect()
        return
      }
      if Task.isCancelled {
        await connectedService.disconnect()
        guard connectionGeneration == generation else { return }
        connectionState = .disconnected
        await refreshSavedInstances()
        return
      }
      let serverID = await connectedService.serverID()
      let supportsNewThreads = await connectedService.supportsNewThreads()
      let supportsProviderUsage = await connectedService.supportsProviderUsage()
      let supportsAgentRequestReceipts = await connectedService.supportsAgentRequestReceipts()
      guard connectionGeneration == generation else {
        await connectedService.disconnect()
        return
      }
      if Task.isCancelled {
        await connectedService.disconnect()
        guard connectionGeneration == generation else { return }
        connectionState = .disconnected
        await refreshSavedInstances()
        return
      }
      if priorServerID == nil || priorServerID != serverID {
        clearAgentOverview()
        clearProviderSubagents()
        clearProviderUsage()
        clearCachedContextUsage()
        clearAgentControlState()
      }
      service = connectedService
      connectedServerID = serverID
      agentControlServerID = serverID
      agentRequestReceiptsSupported = supportsAgentRequestReceipts
      canCreateThreads = supportsNewThreads
      providerUsageSupported = supportsProviderUsage
      connectionState = .connected
      timelineGeneration += 1
      startObservingConnection(connectedService, generation: generation)
      await reloadWorkspace(preserveSelection: true, generation: generation)
      if connectionGeneration == generation { _ = startProviderUsageRefresh() }
      if connectionGeneration == generation { await refreshSavedInstances() }
      if connectionGeneration == generation, Task.isCancelled {
        await markConnectionLost(
          generation: generation, reason: "Reconnect was cancelled. Try again to continue.")
      }
    } catch {
      guard connectionGeneration == generation else { return }
      if error is CancellationError {
        connectionState = .disconnected
        await refreshSavedInstances()
        return
      }
      service = nil
      canCreateThreads = false
      providerUsageSupported = false
      agentRequestReceiptsSupported = false
      connectionState = .disconnected
      connectError = error.localizedDescription
      workspaceError =
        "Reconnect failed. Your open thread and draft stay in this app while it is open.\n\n\(error.localizedDescription)"
      await refreshSavedInstances()
      if connectionGeneration == generation { instanceError = error.localizedDescription }
    }
  }

  func disconnect() async {
    let generation = invalidateConnection()
    let previousService = service
    service = nil
    connectedServerID = nil
    agentControlServerID = nil
    canCreateThreads = false
    agentProviders = []
    pendingNewThreadIntents.removeAll()
    pendingNewThreadResults.removeAll()
    clearAgentControlState()
    clearAgentOverview()
    clearProviderSubagents()
    clearProviderUsage()
    connectionState = .disconnected
    projects = []
    threads = []
    replaceMessages([])
    permissions = []
    loadingProjects = false
    loadingThreads = false
    loadingHistory = false
    loadingContextUsage = false
    loadingOlderMessages = false
    sendingMessage = false
    agentRequestReceiptsSupported = false
    answeringPermissionID = nil
    historyMayBeIncomplete = false
    drafts.removeAll()
    imageDrafts.removeAll()
    acceptedMessageImages.removeAll()
    loadingAgentOptions = false
    agentConfigurationError = nil
    timelineHasOlder = false
    olderTimelineCursor = nil
    latestTimelineCursor = nil
    workspaceError = nil
    workspaceNotice = nil
    timelineError = nil
    messageError = nil
    permissionError = nil
    selectedProjectID = nil
    selectedThreadID = nil
    projectSelectionGeneration += 1
    threadSelectionGeneration += 1
    timelineGeneration += 1
    UserDefaults.standard.removeObject(forKey: Self.selectedProjectKey)
    UserDefaults.standard.removeObject(forKey: Self.selectedThreadKey)

    var cleanupError: String?
    do { try await connectionFactory.disconnect() } catch {
      cleanupError =
        "The active connection closed, but saved credentials could not be cleared: \(error.localizedDescription)"
    }
    await previousService?.disconnect()
    guard connectionGeneration == generation else { return }
    connectError = cleanupError
    await refreshSavedInstances()
    if connectionGeneration == generation, let cleanupError { instanceError = cleanupError }
  }

  private func connectWithRetry(
    generation expectedGeneration: Int,
    operation: @escaping @Sendable () async throws -> any OesapRemoteService
  ) async throws -> any OesapRemoteService {
    var retries = 0
    while true {
      try Task.checkCancellation()
      guard connectionGeneration == expectedGeneration else { throw CancellationError() }
      do {
        return try await withConnectionAttemptTimeout(
          Self.connectionAttemptTimeout, operation: operation)
      } catch {
        guard connectionGeneration == expectedGeneration else { throw CancellationError() }
        if Task.isCancelled || error is CancellationError
          || (error as? PaseoConnectionError) == .cancelled
        {
          throw error
        }
        guard retries < Self.maximumConnectionRetries else { throw error }
        let exponentialDelay = Self.initialConnectionBackoffSeconds << retries
        let delay = min(exponentialDelay, Self.maximumConnectionBackoffSeconds)
        try await Task.sleep(for: .seconds(delay))
        retries += 1
      }
    }
  }

  func selectProject(_ id: String) async {
    guard projects.contains(where: { $0.id == id }) else { return }
    workspaceNotice = nil
    clearGitChanges()
    projectSelectionGeneration += 1
    threadSelectionGeneration += 1
    clearSessionDetails()
    selectedProjectID = id
    agentProviders = []
    loadingAgentOptions = false
    agentConfigurationError = nil
    UserDefaults.standard.set(id, forKey: Self.selectedProjectKey)
    selectedThreadID = nil
    UserDefaults.standard.removeObject(forKey: Self.selectedThreadKey)
    threads = []
    replaceMessages([])
    permissions = []
    timelineHasOlder = false
    olderTimelineCursor = nil
    latestTimelineCursor = nil
    await loadThreads(
      projectID: id, generation: connectionGeneration,
      selectionGeneration: projectSelectionGeneration)
  }

  func selectThread(_ id: String) {
    clearGitChanges()
    clearSessionDetails()
    contextUsageRefreshTask?.cancel()
    contextUsageRefreshTask = nil
    contextUsageRequestGeneration += 1
    contextUsageRevision += 1
    loadingContextUsage = false
    contextUsageError = nil
    threadSelectionGeneration += 1
    selectedThreadID = id
    UserDefaults.standard.set(id, forKey: Self.selectedThreadKey)
    replaceMessages([])
    timelineError = nil
    timelineHasOlder = false
    olderTimelineCursor = nil
    latestTimelineCursor = nil
  }

  func refreshGitStatus(threadID: String) async {
    guard selectedThreadID == threadID else { return }
    guard connectionState == .connected, let service else {
      gitStatusError = "Reconnect to load repository changes."
      return
    }
    guard let cwd = gitWorkingDirectory(for: threadID) else {
      gitStatusError = "This agent has no working directory."
      return
    }
    gitRequestGeneration += 1
    let requestGeneration = gitRequestGeneration
    let connectionGeneration = connectionGeneration
    loadingGitStatus = true
    gitStatusError = nil
    gitStatus = nil
    gitDiffByPath = [:]
    cachedGitDiffByPath = [:]
    gitDiffErrorByPath = [:]
    do {
      let status = try await service.gitStatus(cwd: cwd)
      guard selectedThreadID == threadID,
        self.connectionGeneration == connectionGeneration,
        gitRequestGeneration == requestGeneration
      else { return }
      gitStatus = status
      cachedGitDiffByPath = status.diffByPath
      gitDiffByPath = [:]
      gitDiffErrorByPath = [:]
      loadingGitStatus = false
    } catch {
      guard selectedThreadID == threadID, self.connectionGeneration == connectionGeneration,
        gitRequestGeneration == requestGeneration
      else { return }
      gitStatusError = error.localizedDescription
      loadingGitStatus = false
    }
  }

  func loadGitDiff(threadID: String, path: String) async {
    guard selectedThreadID == threadID,
      gitStatus?.files.contains(where: { $0.path == path }) == true,
      connectionState == .connected
    else { return }
    gitDiffErrorByPath.removeValue(forKey: path)
    if let diff = cachedGitDiffByPath[path] {
      gitDiffByPath[path] = diff
    } else {
      gitDiffErrorByPath[path] = "This file’s diff is unavailable."
    }
  }

  private func gitWorkingDirectory(for threadID: String) -> String? {
    guard let thread = threads.first(where: { $0.id == threadID }) else { return nil }
    if let cwd = thread.cwd, !cwd.isEmpty { return cwd }
    return selectedProject?.rootPath
  }

  private func clearGitChanges() {
    gitRequestGeneration += 1
    gitStatus = nil
    gitStatusError = nil
    loadingGitStatus = false
    gitDiffByPath = [:]
    cachedGitDiffByPath = [:]
    gitDiffErrorByPath = [:]
  }

  func refreshAgentOverview() async {
    if let agentOverviewRefreshTask {
      agentOverviewRefreshQueued = true
      await agentOverviewRefreshTask.value
      return
    }
    let taskID = UUID()
    agentOverviewRefreshTaskID = taskID
    let task = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled && self.agentOverviewRefreshTaskID == taskID {
        self.agentOverviewRefreshQueued = false
        await self.performAgentOverviewRefresh()
        if !self.agentOverviewRefreshQueued { break }
      }
      if self.agentOverviewRefreshTaskID == taskID {
        self.agentOverviewRefreshTask = nil
        self.agentOverviewRefreshTaskID = nil
      }
    }
    agentOverviewRefreshTask = task
    await task.value
  }

  private func startProviderUsageRefresh() -> Task<Void, Never> {
    if let providerUsageRefreshTask {
      providerUsageRefreshQueued = true
      return providerUsageRefreshTask
    }
    let taskID = UUID()
    providerUsageRefreshTaskID = taskID
    let task = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled && self.providerUsageRefreshTaskID == taskID {
        self.providerUsageRefreshQueued = false
        await self.performProviderUsageRefresh()
        if !self.providerUsageRefreshQueued { break }
      }
      if self.providerUsageRefreshTaskID == taskID {
        self.providerUsageRefreshTask = nil
        self.providerUsageRefreshTaskID = nil
      }
    }
    providerUsageRefreshTask = task
    return task
  }

  private func performProviderUsageRefresh() async {
    guard !Task.isCancelled else { return }
    guard connectionState == .connected, let service else {
      providerUsageIsStale = true
      providerUsageError = "Reconnect to refresh provider usage."
      return
    }
    guard providerUsageSupported else {
      providerUsageIsStale = true
      providerUsageError = "Update the Paseo host to view provider usage."
      return
    }
    let generation = connectionGeneration
    let serverID = connectedServerID
    loadingProviderUsage = true
    providerUsageError = nil
    defer {
      if connectionGeneration == generation { loadingProviderUsage = false }
    }
    do {
      let snapshot = try await service.providerUsage()
      guard connectionGeneration == generation, connectedServerID == serverID,
        connectionState == .connected, !Task.isCancelled
      else { return }
      providerUsageProviders = snapshot.providers
      providerUsageFetchedAt = snapshot.fetchedAt
      providerUsageIsStale = false
    } catch {
      guard connectionGeneration == generation, connectedServerID == serverID,
        connectionState == .connected, !Task.isCancelled
      else { return }
      providerUsageIsStale = true
      let summary =
        providerUsageProviders.isEmpty
        ? "Provider usage couldn’t be loaded."
        : "Provider usage couldn’t be refreshed. Last available values remain visible."
      providerUsageError = "\(summary) \(error.localizedDescription)"
    }
  }

  private func startContextUsageRefresh(threadID: String) {
    contextUsageRefreshTask?.cancel()
    contextUsageRefreshTask = Task { [weak self] in
      await self?.refreshContextUsage(threadID: threadID)
    }
  }

  private func performAgentOverviewRefresh() async {
    guard !Task.isCancelled else { return }
    guard connectionState == .connected, let service else {
      agentOverviewIsStale = !agentOverviewGroups.isEmpty
      agentOverviewError = "Reconnect to refresh agents on this host."
      return
    }
    let generation = connectionGeneration
    agentOverviewRefreshGeneration += 1
    let refreshGeneration = agentOverviewRefreshGeneration
    let previousGroups = Dictionary(uniqueKeysWithValues: agentOverviewGroups.map { ($0.id, $0) })
    loadingAgentOverview = true
    agentOverviewError = nil
    defer {
      if connectionGeneration == generation,
        agentOverviewRefreshGeneration == refreshGeneration
      {
        loadingAgentOverview = false
      }
    }

    let sourceProjects: [RemoteProject]
    do {
      sourceProjects = try await service.projects()
    } catch {
      guard connectionGeneration == generation,
        agentOverviewRefreshGeneration == refreshGeneration,
        !Task.isCancelled
      else { return }
      agentOverviewIsStale = true
      agentOverviewError =
        "The project catalog couldn’t be refreshed. Last available agents remain visible. \(error.localizedDescription)"
      return
    }
    guard connectionGeneration == generation,
      agentOverviewRefreshGeneration == refreshGeneration,
      connectionState == .connected, !Task.isCancelled
    else { return }

    let results: [AgentOverviewLoadResult] = await withTaskGroup(of: AgentOverviewLoadResult.self) {
      group -> [AgentOverviewLoadResult] in
      if Task.isCancelled {
        group.cancelAll()
        return []
      }
      var nextIndex = 0
      let initialCount = min(4, sourceProjects.count)
      for _ in 0..<initialCount {
        let index = nextIndex
        nextIndex += 1
        let project = sourceProjects[index]
        group.addTask {
          do {
            return AgentOverviewLoadResult(
              index: index, threads: try await service.threads(projectID: project.id), error: nil)
          } catch {
            return AgentOverviewLoadResult(
              index: index, threads: nil, error: error.localizedDescription)
          }
        }
      }
      var loaded: [AgentOverviewLoadResult] = []
      while let result = await group.next() {
        if Task.isCancelled {
          group.cancelAll()
          break
        }
        loaded.append(result)
        if nextIndex < sourceProjects.count {
          let index = nextIndex
          nextIndex += 1
          let project = sourceProjects[index]
          group.addTask {
            do {
              return AgentOverviewLoadResult(
                index: index, threads: try await service.threads(projectID: project.id), error: nil)
            } catch {
              return AgentOverviewLoadResult(
                index: index, threads: nil, error: error.localizedDescription)
            }
          }
        }
      }
      return loaded
    }
    guard connectionGeneration == generation,
      agentOverviewRefreshGeneration == refreshGeneration,
      connectionState == .connected,
      !Task.isCancelled
    else { return }

    let resultsByIndex = Dictionary(uniqueKeysWithValues: results.map { ($0.index, $0) })
    var anyError = false
    var anySuccess = sourceProjects.isEmpty
    agentOverviewGroups = sourceProjects.enumerated().map { index, project in
      let result = resultsByIndex[index]
      if let threads = result?.threads {
        anySuccess = true
        return RemoteAgentOverviewGroup(project: project, threads: threads, error: nil)
      }
      anyError = true
      return RemoteAgentOverviewGroup(
        project: project, threads: previousGroups[project.id]?.threads ?? [],
        error: result?.error ?? "The project’s agents couldn’t be loaded.")
    }
    if anySuccess { agentOverviewUpdatedAt = Date() }
    agentOverviewIsStale = anyError
    if anyError {
      agentOverviewError =
        anySuccess
        ? "Some projects couldn’t be refreshed. Their last available agents remain visible."
        : "Agents couldn’t be refreshed. Last available results remain visible."
    }
  }

  func refreshProviderSubagents(parentAgentID: String) async {
    guard connectionState == .connected, let service, !parentAgentID.isEmpty else { return }
    let generation = connectionGeneration
    let supported = await service.supportsProviderSubagents()
    guard connectionGeneration == generation, connectionState == .connected,
      !Task.isCancelled
    else { return }
    guard supported else {
      providerSubagentsByParent[parentAgentID] = []
      providerSubagentErrors.removeValue(forKey: parentAgentID)
      return
    }
    loadingProviderSubagentParents.insert(parentAgentID)
    providerSubagentErrors.removeValue(forKey: parentAgentID)
    defer {
      if connectionGeneration == generation {
        loadingProviderSubagentParents.remove(parentAgentID)
      }
    }
    do {
      let subagents = try await service.providerSubagents(parentAgentID: parentAgentID)
      guard connectionGeneration == generation, connectionState == .connected,
        !Task.isCancelled
      else { return }
      providerSubagentsByParent[parentAgentID] = subagents
    } catch {
      guard connectionGeneration == generation, !Task.isCancelled else { return }
      providerSubagentErrors[parentAgentID] = error.localizedDescription
    }
  }

  func loadProviderSubagentHistory(parentAgentID: String, subagentID: String) async throws
    -> RemoteTimeline
  {
    guard connectionState == .connected, let service else {
      throw RemoteServiceError.connectionLost("Reconnect to view this provider subagent.")
    }
    return try await service.providerSubagentHistory(
      parentAgentID: parentAgentID, subagentID: subagentID)
  }

  @discardableResult
  func openAgent(projectID: String, threadID: String) -> Bool {
    guard connectionState == .connected,
      let group = agentOverviewGroups.first(where: { $0.project.id == projectID }),
      group.threads.contains(where: { $0.id == threadID })
    else { return false }
    if let index = projects.firstIndex(where: { $0.id == projectID }) {
      projects[index] = group.project
    } else {
      projects.append(group.project)
    }
    projectSelectionGeneration += 1
    selectedProjectID = projectID
    UserDefaults.standard.set(projectID, forKey: Self.selectedProjectKey)
    recordThreadSnapshots(group.threads)
    threads = group.threads
    loadingThreads = false
    agentProviders = []
    loadingAgentOptions = false
    selectThread(threadID)
    return true
  }

  func refreshWorkspace() async {
    await reloadWorkspace(preserveSelection: true, generation: connectionGeneration)
  }

  func directoryEntries(cwd: String?) async throws -> [RemoteDirectoryEntry] {
    guard connectionState == .connected, let service else {
      throw RemoteServiceError.connectionLost("Reconnect before browsing folders on this host.")
    }
    let generation = connectionGeneration
    let entries = try await service.directoryEntries(cwd: cwd)
    guard connectionGeneration == generation, connectionState == .connected else {
      throw RemoteServiceError.connectionLost("The host changed while browsing folders.")
    }
    return entries
  }

  func addProject(path: String) async throws -> String {
    guard connectionState == .connected, let remote = service else {
      throw RemoteServiceError.connectionLost("Reconnect before adding a project.")
    }
    let generation = connectionGeneration
    let project = try await remote.addProject(path: path)
    guard connectionGeneration == generation, connectionState == .connected else {
      throw RemoteServiceError.connectionLost("The host disconnected while adding the project.")
    }

    if !projects.contains(where: { $0.id == project.id }) {
      projects.append(project)
    }
    await reloadWorkspace(preserveSelection: true, generation: generation)
    guard connectionGeneration == generation, connectionState == .connected else {
      throw RemoteServiceError.connectionLost("The host disconnected while refreshing projects.")
    }
    if !projects.contains(where: { $0.id == project.id }) {
      projects.append(project)
    }
    await selectProject(project.id)
    return project.id
  }

  func refreshThreads(projectID: String) async {
    await loadThreads(
      projectID: projectID, generation: connectionGeneration,
      selectionGeneration: projectSelectionGeneration, reconcileStopWait: true)
  }

  func subagentHistory(_ agentID: String) async throws -> RemoteTimeline {
    guard connectionState == .connected, let service else {
      throw RemoteServiceError.connectionLost("Connect to a host to load this subagent.")
    }
    let generation = connectionGeneration
    let timeline = try await service.history(agentID: agentID, before: nil)
    guard connectionGeneration == generation, connectionState == .connected else {
      throw RemoteServiceError.connectionLost("The host changed while loading this subagent.")
    }
    return RemoteTimeline(
      messages: timeline.messages.map { imageOverlay($0, threadID: agentID) },
      historyMayBeIncomplete: timeline.historyMayBeIncomplete,
      hasOlder: timeline.hasOlder,
      olderCursor: timeline.olderCursor,
      latestCursor: timeline.latestCursor)
  }

  func subagentEvents(_ agentID: String) async throws
    -> AsyncThrowingStream<RemoteTimelineUpdate, Error>
  {
    guard connectionState == .connected, let service else {
      throw RemoteServiceError.connectionLost("Connect to a host to follow this subagent.")
    }
    return try await service.events(agentID: agentID)
  }

  func loadSubagentImage(source: String, agentID: String) async throws -> Data {
    guard connectionState == .connected, let service,
      let group = agentOverviewGroups.first(where: { $0.threads.contains { $0.id == agentID } }),
      let thread = group.threads.first(where: { $0.id == agentID }),
      let workspaceRoot = (thread.cwd?.isEmpty == false ? thread.cwd : nil)
        ?? group.project.rootPath,
      let target = Self.imageReadTarget(source: source, workspaceRoot: workspaceRoot)
    else { throw RemoteServiceError.unavailable("Image preview is unavailable for this subagent.") }
    let generation = connectionGeneration
    let data = try await service.readImage(
      cwd: target.cwd, path: target.path, maxBytes: RemoteImageLimits.maximumDisplayBytes)
    guard connectionGeneration == generation, connectionState == .connected, !Task.isCancelled
    else { throw CancellationError() }
    return data
  }

  func archiveSubagent(_ agentID: String) async throws {
    guard connectionState == .connected, let service,
      agentOverviewGroups.contains(where: { $0.threads.contains { $0.id == agentID } })
    else { throw RemoteServiceError.unavailable("This subagent is no longer available.") }
    let generation = connectionGeneration
    try await service.archiveThread(agentID: agentID)
    guard connectionGeneration == generation, connectionState == .connected else {
      throw RemoteServiceError.connectionLost("The host changed while archiving this subagent.")
    }
    for index in agentOverviewGroups.indices {
      agentOverviewGroups[index].threads.removeAll { $0.id == agentID }
    }
  }

  func markThreadRead(_ threadID: String, reportsFailure: Bool = true) async {
    guard connectionState == .connected, let service,
      let thread = threads.first(where: { $0.id == threadID }), thread.requiresAttention
    else { return }
    let generation = connectionGeneration
    do {
      try await service.markThreadRead(agentID: threadID)
      guard connectionGeneration == generation, connectionState == .connected,
        let index = threads.firstIndex(where: { $0.id == threadID })
      else { return }
      threads[index].requiresAttention = false
      threads[index].attentionReason = nil
    } catch {
      guard connectionGeneration == generation else { return }
      if reportsFailure {
        workspaceError =
          "Thread couldn’t be marked as read. Try again. \(error.localizedDescription)"
      }
      if Self.isConnectionFailure(error) {
        await markConnectionLost(
          generation: generation,
          reason: "The host disconnected while marking the thread as read.",
          replaceWorkspaceError: reportsFailure)
      }
    }
  }

  func archiveThread(_ threadID: String) async {
    guard connectionState == .connected, let service,
      threads.contains(where: { $0.id == threadID })
    else { return }
    let generation = connectionGeneration
    do {
      try await service.archiveThread(agentID: threadID)
      guard connectionGeneration == generation, connectionState == .connected else { return }
      threads.removeAll { $0.id == threadID }
      permissions.removeAll { $0.agentID == threadID }
      if selectedThreadID == threadID {
        clearSessionDetails()
        contextUsageRefreshTask?.cancel()
        contextUsageRefreshTask = nil
        contextUsageRequestGeneration += 1
        contextUsageRevision += 1
        loadingContextUsage = false
        contextUsageError = nil
        threadSelectionGeneration += 1
        selectedThreadID = nil
        UserDefaults.standard.removeObject(forKey: Self.selectedThreadKey)
        replaceMessages([])
        timelineGeneration += 1
        timelineError = nil
        timelineHasOlder = false
        olderTimelineCursor = nil
        latestTimelineCursor = nil
      }
      workspaceError = nil
    } catch {
      guard connectionGeneration == generation else { return }
      workspaceError = "Thread couldn’t be archived. Try again. \(error.localizedDescription)"
      if Self.isConnectionFailure(error) {
        await markConnectionLost(
          generation: generation,
          reason: "The host disconnected while archiving the thread.")
      }
    }
  }

  func draft(for threadID: String) -> String {
    drafts[threadID, default: ""]
  }

  func setDraft(_ value: String, for threadID: String) {
    drafts[threadID] = value
  }

  func draftImages(for threadID: String) -> [RemoteDraftImage] {
    imageDrafts[threadID, default: []]
  }

  @discardableResult
  func setDraftImages(_ images: [RemoteDraftImage], for threadID: String) -> Bool {
    guard Self.validImages(images) else {
      messageError = "Attach up to six images, each no larger than 2 MB."
      return false
    }
    imageDrafts[threadID] = images
    return true
  }

  @discardableResult
  func addDraftImage(_ image: RemoteDraftImage, for threadID: String) -> Bool {
    setDraftImages(draftImages(for: threadID) + [image], for: threadID)
  }

  func removeDraftImage(id: String, for threadID: String) {
    imageDrafts[threadID]?.removeAll { $0.id == id }
  }

  private static func validImages(_ images: [RemoteDraftImage]) -> Bool {
    images.count <= RemoteImageLimits.maximumCount
      && Set(images.map(\.id)).count == images.count
      && images.allSatisfy {
        !$0.data.isEmpty && $0.data.count <= RemoteImageLimits.maximumOutgoingBytes
          && $0.mimeType.hasPrefix("image/")
      }
  }

  func agentActionFeedback(for threadID: String) -> RemoteAgentActionFeedback? {
    guard let key = agentControlKey(for: threadID) else { return nil }
    if let stopFeedback = agentActionFeedback[key] { return stopFeedback }
    return agentSendFeedback[key]
  }

  func agentSendFeedback(for threadID: String) -> RemoteAgentActionFeedback? {
    guard let key = agentControlKey(for: threadID) else { return nil }
    return agentSendFeedback[key]
  }

  func agentStopFeedback(for threadID: String) -> RemoteAgentActionFeedback? {
    guard let key = agentControlKey(for: threadID) else { return nil }
    return agentActionFeedback[key]
  }

  func isSendingAgentMessage(for threadID: String) -> Bool {
    agentSendFeedback(for: threadID)?.phase == .sending
  }

  func isStoppingAgent(_ threadID: String) -> Bool {
    agentActionFeedback(for: threadID)?.phase == .stopping
  }

  func isStopRequestPending(_ threadID: String) -> Bool {
    guard let key = agentControlKey(for: threadID) else { return false }
    let phase = agentActionFeedback[key]?.phase
    return phase == .stopping || phase == .stopWaiting
  }

  func hasUncertainAgentMessage(for threadID: String) -> Bool {
    guard let key = agentControlKey(for: threadID), pendingAgentMessages[key] != nil else {
      return false
    }
    return agentSendFeedback[key]?.phase == .sendUncertain
  }

  func canRetryAgentMessage(for threadID: String) -> Bool {
    guard let key = agentControlKey(for: threadID),
      let pending = pendingAgentMessages[key], pending.receiptSupport,
      agentRequestReceiptsSupported
    else { return false }
    return agentSendFeedback[key]?.phase == .sendUncertain
  }

  func requiresAgentMessageReview(for threadID: String) -> Bool {
    hasUncertainAgentMessage(for: threadID)
  }

  func threadStateRevision(for threadID: String) -> Int {
    guard let key = agentControlKey(for: threadID) else { return 0 }
    return threadStateRevisions[key, default: 0]
  }

  func agentControlAvailable(for threadID: String) -> Bool {
    connectionState == .connected && agentControlKey(for: threadID) != nil
  }

  func newThreadDraftKey(for projectID: String) -> String {
    "new:\(scope(for: projectID) ?? "unidentified:\(connectionGeneration):\(projectID)")"
  }

  func agentConfiguration(for projectID: String) -> RemoteAgentConfiguration? {
    _ = agentConfigurationRevision
    guard let connectedServerID, projects.contains(where: { $0.id == projectID }) else {
      return nil
    }
    return agentConfigurationStore.configuration(
      serverID: connectedServerID, projectID: projectID)
  }

  @discardableResult
  func saveAgentConfiguration(
    _ configuration: RemoteAgentConfiguration, for projectID: String
  ) -> Bool {
    guard let connectedServerID, projects.contains(where: { $0.id == projectID }) else {
      agentConfigurationError = "Connect to a host and select a project before saving its agent."
      return false
    }
    let saved = agentConfigurationStore.save(
      configuration, serverID: connectedServerID, projectID: projectID)
    agentConfigurationError = saved ? nil : "This host has no stable identity or agent provider."
    if saved { agentConfigurationRevision += 1 }
    return saved
  }

  func agentModels(for providerID: String) -> [RemoteAgentModel] {
    agentProviders.first(where: { $0.id == providerID })?.models ?? []
  }

  func refreshAgentOptions(projectID: String) async {
    guard connectionState == .connected, let service,
      selectedProjectID == projectID,
      let rootPath = projects.first(where: { $0.id == projectID })?.rootPath,
      !rootPath.isEmpty
    else {
      agentConfigurationError = "Select a connected project to load its agent options."
      return
    }
    let generation = connectionGeneration
    let selectionGeneration = projectSelectionGeneration
    loadingAgentOptions = true
    agentConfigurationError = nil
    do {
      let providers = try await service.agentProviders(cwd: rootPath)
      guard connectionGeneration == generation,
        projectSelectionGeneration == selectionGeneration,
        selectedProjectID == projectID, !Task.isCancelled
      else { return }
      agentProviders = providers
      loadingAgentOptions = false
    } catch {
      guard connectionGeneration == generation,
        projectSelectionGeneration == selectionGeneration,
        selectedProjectID == projectID, !Task.isCancelled
      else { return }
      agentProviders = []
      loadingAgentOptions = false
      agentConfigurationError = "Agent options couldn’t be loaded. \(error.localizedDescription)"
    }
  }

  func sendFirstMessage(projectID: String, text: String) async -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let draftKey = newThreadDraftKey(for: projectID)
    let images = draftImages(for: draftKey)
    let pendingIntent = scope(for: projectID).flatMap { pendingNewThreadIntents[$0] }
    guard !trimmed.isEmpty || !images.isEmpty || pendingIntent != nil, !sendingMessage else {
      return nil
    }
    guard pendingIntent != nil || Self.validImages(images) else { return nil }
    guard connectionState == .connected, let service, canCreateThreads else {
      messageError =
        "This Paseo host must support new thread creation. Reconnect or update the host."
      return nil
    }
    guard selectedProjectID == projectID,
      let project = projects.first(where: { $0.id == projectID }),
      let rootPath = project.rootPath, !rootPath.isEmpty,
      let scope = scope(for: projectID)
    else {
      messageError = "Select a project with a stable host identity before starting a thread."
      return nil
    }
    let intent: RemoteNewThreadIntent
    if let pending = pendingNewThreadIntents[scope] {
      // A retry must replay the original intent even if the draft or settings changed.
      intent = pending
    } else {
      guard let configuration = agentConfiguration(for: projectID) else {
        messageError = "Set this project’s agent on this device before starting a thread."
        return nil
      }
      intent = RemoteNewThreadIntent(
        idempotencyKey: UUID().uuidString.lowercased(),
        clientMessageID: UUID().uuidString.lowercased(),
        projectID: projectID,
        provider: configuration.provider,
        model: configuration.model,
        modeID: configuration.modeID,
        cwd: rootPath,
        prompt: trimmed, images: images)
      pendingNewThreadIntents[scope] = intent
    }
    if drafts[draftKey, default: ""].isEmpty { drafts[draftKey] = text }
    let generation = connectionGeneration
    let selectionGeneration = projectSelectionGeneration
    let threadGeneration = threadSelectionGeneration
    let serverID = connectedServerID
    sendingMessage = true
    messageError = nil
    defer { if connectionGeneration == generation { sendingMessage = false } }
    do {
      let result: RemoteNewThreadResult
      if let cached = pendingNewThreadResults[scope] {
        result = cached
      } else {
        result = try await service.createThread(intent)
        if result.thread != nil { pendingNewThreadResults[scope] = result }
      }
      guard connectionGeneration == generation,
        projectSelectionGeneration == selectionGeneration,
        threadSelectionGeneration == threadGeneration,
        selectedProjectID == projectID,
        connectedServerID == serverID, !Task.isCancelled
      else { return nil }
      guard let thread = result.thread else {
        if result.safeToRestart { pendingNewThreadIntents[scope] = nil }
        messageError =
          result.safeToRestart
          ? "The host did not create a thread. Your draft stays in this app while it is open; check the agent setting and try again. \(result.error ?? "")"
          : "Thread creation couldn’t be confirmed. Your first message stays in this app while it is open; retry will check the same request. \(result.error ?? "")"
        return nil
      }
      let currentDraft = drafts[draftKey] ?? ""
      let submittedImageIDs = Set(intent.images.map(\.id))
      let currentImages = imageDrafts[draftKey] ?? []
      if result.promptAccepted {
        if !intent.images.isEmpty {
          acceptedMessageImages[thread.id, default: [:]][intent.clientMessageID] = intent.images
        }
        if currentDraft != text || trimmed != intent.prompt {
          drafts[thread.id] = currentDraft
        }
        imageDrafts[thread.id] = currentImages.filter { !submittedImageIDs.contains($0.id) }
      } else {
        drafts[thread.id] = currentDraft.isEmpty ? intent.prompt : currentDraft
        imageDrafts[thread.id] = currentImages
      }
      drafts[draftKey] = ""
      imageDrafts[draftKey] = []
      if !result.promptAccepted {
        messageError =
          "The thread was created, but delivery of its first message wasn’t confirmed. Your draft stays in this app while it is open. Check the timeline before sending again. \(result.error ?? "")"
      }
      if let existingIndex = threads.firstIndex(where: { $0.id == thread.id }) {
        threads[existingIndex] = thread
      } else {
        threads.insert(thread, at: 0)
      }
      selectThread(thread.id)
      pendingNewThreadIntents[scope] = nil
      pendingNewThreadResults[scope] = nil
      return thread.id
    } catch {
      guard connectionGeneration == generation,
        projectSelectionGeneration == selectionGeneration,
        threadSelectionGeneration == threadGeneration,
        selectedProjectID == projectID, connectedServerID == serverID
      else { return nil }
      messageError =
        "Thread creation couldn’t be confirmed. Your first message stays in this app while it is open; retry will use the same request. \(error.localizedDescription)"
      return nil
    }
  }

  private func scope(for projectID: String) -> String? {
    guard let connectedServerID,
      !connectedServerID.isEmpty, connectedServerID != "unknown"
    else { return nil }
    return "\(connectedServerID.utf8.count):\(connectedServerID):\(projectID)"
  }

  func send(threadID: String, text: String) async -> Bool {
    let isRunning = threads.first(where: { $0.id == threadID })?.state == .running
    return await send(
      threadID: threadID, text: text, behavior: isRunning ? .steer : .interrupt,
      expectedStateRevision: threadStateRevision(for: threadID),
      selectedDuringActiveTurn: isRunning)
  }

  @discardableResult
  func send(
    threadID: String, text: String, behavior: RemoteActiveTurnBehavior,
    expectedStateRevision: Int, selectedDuringActiveTurn: Bool,
    images suppliedImages: [RemoteDraftImage]? = nil
  ) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let images = suppliedImages ?? draftImages(for: threadID)
    guard !trimmed.isEmpty || !images.isEmpty, Self.validImages(images),
      connectionState == .connected, let service,
      selectedThreadID == threadID,
      let key = agentControlKey(for: threadID)
    else { return false }
    guard pendingAgentMessages[key] == nil else { return false }
    guard agentStopTokens[key] == nil else { return false }
    let currentState = threads.first(where: { $0.id == threadID })?.state
    guard threadStateRevisions[key, default: 0] == expectedStateRevision,
      (currentState == .running) == selectedDuringActiveTurn
    else {
      agentSendFeedback[key] = RemoteAgentActionFeedback(
        phase: .failed,
        message: "The agent state changed. Review its current state and send again.")
      return false
    }

    let intent = PendingAgentMessage(
      messageID: UUID().uuidString.lowercased(), text: trimmed, draftText: text,
      images: images, behavior: behavior, receiptSupport: agentRequestReceiptsSupported)
    pendingAgentMessages[key] = intent
    agentActionFeedback[key] = nil
    let token = UUID()
    agentSendTokens[key] = token
    agentSendFeedback[key] = RemoteAgentActionFeedback(
      phase: .sending, message: "Sending message…")
    return await performAgentSend(
      intent, threadID: threadID, key: key, token: token, service: service)
  }

  @discardableResult
  func retryAgentMessage(threadID: String) async -> Bool {
    guard connectionState == .connected, let service,
      let key = agentControlKey(for: threadID),
      let intent = pendingAgentMessages[key], intent.receiptSupport,
      agentRequestReceiptsSupported,
      agentSendFeedback[key]?.phase == .sendUncertain,
      agentStopTokens[key] == nil
    else { return false }
    let token = UUID()
    agentSendTokens[key] = token
    agentSendFeedback[key] = RemoteAgentActionFeedback(
      phase: .sending, message: "Retrying the original message…")
    return await performAgentSend(
      intent, threadID: threadID, key: key, token: token, service: service)
  }

  func discardUncertainAgentMessage(threadID: String) {
    guard let key = agentControlKey(for: threadID),
      pendingAgentMessages[key] != nil,
      agentSendFeedback[key]?.phase == .sendUncertain
    else { return }
    pendingAgentMessages[key] = nil
    agentSendTokens[key] = nil
    agentSendFeedback[key] = nil
  }

  func stopAgent(threadID: String, expectedStateRevision: Int) async {
    guard connectionState == .connected, selectedThreadID == threadID,
      let service, let key = agentControlKey(for: threadID),
      agentStopTokens[key] == nil, agentSendTokens[key] == nil,
      let thread = threads.first(where: { $0.id == threadID }), thread.state == .running
    else { return }
    let stateRevision = threadStateRevisions[key, default: 0]
    guard stateRevision == expectedStateRevision else {
      agentActionFeedback[key] = RemoteAgentActionFeedback(
        phase: .failed,
        message: "The agent state changed. Review it and confirm Stop again.")
      return
    }
    let generation = connectionGeneration
    let serverID = connectedServerID
    let token = UUID()
    agentStopTokens[key] = token
    agentActionFeedback[key] = RemoteAgentActionFeedback(
      phase: .stopping, message: "Stopping agent…")
    do {
      let snapshot = try await service.stop(agentID: threadID)
      guard agentStopTokens[key] == token else { return }
      agentStopTokens[key] = nil
      guard connectionGeneration == generation, connectedServerID == serverID else { return }
      if threadStateRevisions[key, default: 0] != stateRevision {
        if threads.first(where: { $0.id == threadID })?.state == .running {
          agentActionFeedback[key] = RemoteAgentActionFeedback(
            phase: .stopWaiting, message: "Stop requested; waiting for host state.")
        } else if let state = threads.first(where: { $0.id == threadID })?.state,
          Self.isKnownStoppedState(state)
        {
          agentActionFeedback[key] = RemoteAgentActionFeedback(
            phase: .stopped, message: "Agent stopped.")
        } else {
          agentActionFeedback[key] = RemoteAgentActionFeedback(
            phase: .stopWaiting, message: "Stop requested; waiting for host state.")
        }
        return
      }
      if let snapshot, snapshot.id != threadID {
        agentActionFeedback[key] = RemoteAgentActionFeedback(
          phase: .failed,
          message: "The host response didn’t match this agent. Check its current state.")
        return
      }
      guard let snapshot, snapshot.state != .running else {
        agentActionFeedback[key] = RemoteAgentActionFeedback(
          phase: .stopWaiting, message: "Stop requested; waiting for host state.")
        return
      }
      guard snapshot.state == .idle || snapshot.state == .closed || snapshot.state == .failed
      else {
        agentActionFeedback[key] = RemoteAgentActionFeedback(
          phase: .stopWaiting, message: "Stop requested; waiting for host state.")
        return
      }
      updateThread(
        threadID, state: snapshot.state,
        requiresAttention: snapshot.requiresAttention, reason: snapshot.attentionReason)
      agentActionFeedback[key] = RemoteAgentActionFeedback(
        phase: .stopped, message: "Agent stopped.")
    } catch {
      guard agentStopTokens[key] == token else { return }
      agentStopTokens[key] = nil
      guard connectionGeneration == generation, connectedServerID == serverID else { return }
      agentActionFeedback[key] = RemoteAgentActionFeedback(
        phase: .failed,
        message: "Stop couldn’t be confirmed. Review the agent state before trying again.")
    }
  }

  func watchTimeline(threadID: String) async {
    guard let service, connectionState == .connected else {
      timelineError = "Connect to a host to load this timeline."
      return
    }
    let generation = connectionGeneration
    let selectionGeneration = threadSelectionGeneration
    loadingHistory = true
    timelineError = nil
    permissionError = nil
    do {
      // This view owns only its timeline subscription. Subscribe before loading
      // the authoritative snapshot so updates arriving during history loading
      // remain buffered; the app-level connection observer owns host liveness.
      let updates = try await service.events(agentID: threadID)
      guard
        isCurrentTimeline(
          threadID: threadID, generation: generation,
          selectionGeneration: selectionGeneration)
      else { return }
      let history = try await service.history(agentID: threadID, before: nil)
      guard
        isCurrentTimeline(
          threadID: threadID, generation: generation,
          selectionGeneration: selectionGeneration)
      else { return }
      replaceMessages(history.messages.map { imageOverlay($0, threadID: threadID) })
      historyMayBeIncomplete = history.historyMayBeIncomplete
      timelineHasOlder = history.hasOlder
      olderTimelineCursor = history.olderCursor
      latestTimelineCursor = history.latestCursor
      loadingHistory = false
      startContextUsageRefresh(threadID: threadID)
      await refreshPermissions(using: service, generation: generation)
      guard
        isCurrentTimeline(
          threadID: threadID, generation: generation,
          selectionGeneration: selectionGeneration)
      else { return }
      for try await update in updates {
        guard
          isCurrentTimeline(
            threadID: threadID, generation: generation,
            selectionGeneration: selectionGeneration)
        else { return }
        switch update {
        case .message(let message, let cursor, let isDelta):
          appendMessage(message, cursor: cursor, isDelta: isDelta)
        case .historyChanged:
          await refreshThreadsForSelectedProject(using: service, generation: generation)
          await refreshPermissions(using: service, generation: generation)
          guard
            isCurrentTimeline(
              threadID: threadID, generation: generation,
              selectionGeneration: selectionGeneration)
          else { return }
          let refreshedHistory = try await service.history(agentID: threadID, before: nil)
          guard
            isCurrentTimeline(
              threadID: threadID, generation: generation,
              selectionGeneration: selectionGeneration)
          else { return }
          replaceMessages(refreshedHistory.messages.map { imageOverlay($0, threadID: threadID) })
          historyMayBeIncomplete = refreshedHistory.historyMayBeIncomplete
          timelineHasOlder = refreshedHistory.hasOlder
          olderTimelineCursor = refreshedHistory.olderCursor
          latestTimelineCursor = refreshedHistory.latestCursor
        case .threadState(let state, let requiresAttention, let reason):
          updateThread(threadID, state: state, requiresAttention: requiresAttention, reason: reason)
          if let key = agentControlKey(for: threadID),
            agentSendFeedback[key]?.phase == .accepted
          {
            agentSendFeedback[key] = nil
          }
          if state != .running && state != .initializing {
            commitBufferedAgentMessages()
          }
        case .contextUsage(let usage):
          if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index].contextUsage = threads[index].contextUsage?.merging(usage) ?? usage
            contextUsageRevision += 1
            contextUsageError = nil
          }
        case .contextUsageNeedsRefresh:
          startContextUsageRefresh(threadID: threadID)
        case .permissionRequested(let permission):
          commitBufferedAgentMessages()
          if let existingIndex = permissions.firstIndex(where: { $0.id == permission.id }) {
            permissions[existingIndex] = permission
          } else {
            permissions.append(permission)
          }
          updateThread(threadID, state: .waiting, requiresAttention: true, reason: permission.title)
        case .permissionResolved(let requestID):
          permissions.removeAll { $0.id == requestID }
        }
      }
      if isCurrentTimeline(
        threadID: threadID, generation: generation,
        selectionGeneration: selectionGeneration)
      {
        commitBufferedAgentMessages()
        // A timeline ending does not prove the host socket ended. Keep the
        // connection available for other screens and offer timeline recovery.
        timelineError = "The live timeline ended. Reconnect to restore updates."
      }
    } catch is CancellationError {
      return
    } catch {
      guard
        isCurrentTimeline(
          threadID: threadID, generation: generation,
          selectionGeneration: selectionGeneration)
      else { return }
      commitBufferedAgentMessages()
      loadingHistory = false
      timelineError =
        "The timeline connection ended. Reconnect to restore this history and its live updates. \(error.localizedDescription)"
    }
    if isCurrentTimeline(
      threadID: threadID, generation: generation,
      selectionGeneration: selectionGeneration)
    {
      loadingHistory = false
    }
  }

  func loadOlderMessages(threadID: String) async {
    guard !loadingOlderMessages,
      timelineHasOlder,
      let cursor = olderTimelineCursor,
      let service
    else { return }
    let generation = connectionGeneration
    let selectionGeneration = threadSelectionGeneration
    loadingOlderMessages = true
    defer {
      if isCurrentTimeline(
        threadID: threadID, generation: generation,
        selectionGeneration: selectionGeneration)
      {
        loadingOlderMessages = false
      }
    }
    do {
      let older = try await service.history(agentID: threadID, before: cursor)
      guard
        isCurrentTimeline(
          threadID: threadID, generation: generation,
          selectionGeneration: selectionGeneration)
      else { return }
      let knownIDs = Set(messages.map(\.id))
      replaceMessages(
        older.messages.filter { !knownIDs.contains($0.id) }
          .map { imageOverlay($0, threadID: threadID) } + messages)
      timelineHasOlder = older.hasOlder
      olderTimelineCursor = older.olderCursor
      historyMayBeIncomplete = historyMayBeIncomplete || older.historyMayBeIncomplete
    } catch {
      guard
        isCurrentTimeline(
          threadID: threadID, generation: generation,
          selectionGeneration: selectionGeneration)
      else { return }
      timelineError = "Earlier messages couldn’t be loaded. \(error.localizedDescription)"
    }
  }

  func answerPermission(_ permission: RemotePermission, allow: Bool) async {
    guard let service, answeringPermissionID == nil else { return }
    let generation = connectionGeneration
    answeringPermissionID = permission.id
    permissionError = nil
    defer { if connectionGeneration == generation { answeringPermissionID = nil } }
    do {
      try await service.answerPermission(permission, allow: allow)
      guard connectionGeneration == generation else { return }
      permissions.removeAll { $0.id == permission.id }
    } catch {
      guard connectionGeneration == generation else { return }
      permissionError =
        "Your response wasn’t sent. Reconnect and try again. \(error.localizedDescription)"
    }
  }

  func answerQuestion(_ permission: RemotePermission, answers: [String: String]?) async {
    guard let service, answeringPermissionID == nil else { return }
    let generation = connectionGeneration
    answeringPermissionID = permission.id
    permissionError = nil
    defer { if connectionGeneration == generation { answeringPermissionID = nil } }
    do {
      try await service.answerQuestion(permission, answers: answers)
      guard connectionGeneration == generation else { return }
      permissions.removeAll { $0.id == permission.id }
    } catch {
      guard connectionGeneration == generation else { return }
      permissionError =
        "Your response wasn’t sent. Reconnect and try again. \(error.localizedDescription)"
    }
  }

  func clearMessageError() {
    messageError = nil
  }

  private func reloadWorkspace(preserveSelection: Bool, generation: Int) async {
    guard connectionGeneration == generation, let service else { return }
    loadingProjects = true
    workspaceError = nil
    workspaceNotice = nil
    do {
      let loadedProjects = try await service.projects()
      guard connectionGeneration == generation, !Task.isCancelled else { return }
      let requestedProjectID = preserveSelection ? selectedProjectID : nil
      if let requestedProjectID,
        !loadedProjects.contains(where: { $0.id == requestedProjectID })
      {
        workspaceNotice =
          "The workspace you were viewing is no longer available on this host. It may have been archived."
      }
      projects = loadedProjects
      loadingProjects = false
      await refreshPermissions(using: service, generation: generation)
      guard connectionGeneration == generation, !Task.isCancelled else { return }
      guard !loadedProjects.isEmpty else {
        projectSelectionGeneration += 1
        threadSelectionGeneration += 1
        selectedProjectID = nil
        selectedThreadID = nil
        threads = []
        replaceMessages([])
        permissions = []
        UserDefaults.standard.removeObject(forKey: Self.selectedProjectKey)
        UserDefaults.standard.removeObject(forKey: Self.selectedThreadKey)
        return
      }
      let nextProjectID =
        loadedProjects.contains { $0.id == requestedProjectID }
        ? requestedProjectID
        : loadedProjects.first?.id
      guard let nextProjectID else { return }
      if selectedProjectID != nextProjectID {
        projectSelectionGeneration += 1
        threadSelectionGeneration += 1
        selectedThreadID = nil
        replaceMessages([])
      }
      selectedProjectID = nextProjectID
      UserDefaults.standard.set(nextProjectID, forKey: Self.selectedProjectKey)
      let selectionGeneration = projectSelectionGeneration
      await loadThreads(
        projectID: nextProjectID, generation: generation,
        selectionGeneration: selectionGeneration)
      guard connectionGeneration == generation,
        projectSelectionGeneration == selectionGeneration,
        selectedProjectID == nextProjectID
      else { return }
      if let requestedThreadID = selectedThreadID,
        threads.contains(where: { $0.id == requestedThreadID })
      {
        selectedThreadID = requestedThreadID
        UserDefaults.standard.set(requestedThreadID, forKey: Self.selectedThreadKey)
      } else if !preserveSelection || !threads.contains(where: { $0.id == selectedThreadID }) {
        threadSelectionGeneration += 1
        selectedThreadID = nil
        UserDefaults.standard.removeObject(forKey: Self.selectedThreadKey)
      }
    } catch {
      guard connectionGeneration == generation, !Task.isCancelled else { return }
      loadingProjects = false
      workspaceError =
        "Projects couldn’t be loaded. Try again. \(error.localizedDescription)"
      if Self.isConnectionFailure(error) {
        await markConnectionLost(
          generation: generation, reason: workspaceError ?? "The host disconnected.",
          replaceWorkspaceError: false)
      }
    }
  }

  private func loadThreads(
    projectID: String, generation: Int,
    selectionGeneration: Int, reconcileStopWait: Bool = false
  ) async {
    guard connectionGeneration == generation,
      projectSelectionGeneration == selectionGeneration,
      selectedProjectID == projectID,
      let service
    else { return }
    loadingThreads = true
    workspaceError = nil
    do {
      let loadedThreads = try await service.threads(projectID: projectID)
      guard connectionGeneration == generation, !Task.isCancelled,
        projectSelectionGeneration == selectionGeneration,
        selectedProjectID == projectID
      else { return }
      recordThreadSnapshots(loadedThreads, reconcileStopWait: reconcileStopWait)
      threads = loadedThreads
      loadingThreads = false
    } catch {
      guard connectionGeneration == generation, !Task.isCancelled,
        projectSelectionGeneration == selectionGeneration,
        selectedProjectID == projectID
      else { return }
      loadingThreads = false
      workspaceError =
        "Threads couldn’t be loaded for this project. Try again. \(error.localizedDescription)"
      if Self.isConnectionFailure(error) {
        await markConnectionLost(
          generation: generation, reason: workspaceError ?? "The host disconnected.",
          replaceWorkspaceError: false)
      }
    }
  }

  private static func isConnectionFailure(_ error: Error) -> Bool {
    if let remoteError = error as? RemoteServiceError {
      switch remoteError {
      case .connectionLost, .authentication: return true
      case .unavailable: return false
      }
    }
    if let protocolError = error as? PaseoProtocolError {
      switch protocolError {
      case .notConnected, .disconnected: return true
      case .malformedMessage, .requestTimedOut, .unsupportedCapability, .requestRejected,
        .unexpectedResponse:
        return false
      }
    }
    if let transportError = error as? PaseoConnectionError {
      switch transportError {
      case .disconnected, .authenticationFailed, .encryptionFailed, .malformedFrame: return true
      case .transportFailure: return true
      case .invalidEndpoint, .invalidPairingLink, .invalidDaemonKey, .unsupportedPairingVersion,
        .timedOut, .cancelled, .keychainFailure:
        return false
      }
    }
    return false
  }

  private func refreshThreadsForSelectedProject(
    using service: any OesapRemoteService,
    generation: Int
  ) async {
    guard let selectedProjectID else { return }
    let selectionGeneration = projectSelectionGeneration
    do {
      let loadedThreads = try await service.threads(projectID: selectedProjectID)
      guard connectionGeneration == generation,
        projectSelectionGeneration == selectionGeneration,
        self.selectedProjectID == selectedProjectID
      else { return }
      recordThreadSnapshots(loadedThreads)
      threads = loadedThreads
    } catch {
      guard connectionGeneration == generation,
        projectSelectionGeneration == selectionGeneration,
        self.selectedProjectID == selectedProjectID
      else { return }
      workspaceError = "Agent status could not be refreshed. \(error.localizedDescription)"
    }
  }

  private func updateThread(
    _ threadID: String,
    state: RemoteThread.State,
    requiresAttention: Bool,
    reason: String?
  ) {
    guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
    threads[index].state = state
    threads[index].requiresAttention = requiresAttention
    threads[index].attentionReason = reason
    if let key = agentControlKey(for: threadID) {
      threadStateRevisions[key, default: 0] += 1
      if agentActionFeedback[key]?.phase == .stopWaiting {
        if state == .running {
          agentActionFeedback[key] = nil
        } else if Self.isKnownStoppedState(state) {
          agentActionFeedback[key] = RemoteAgentActionFeedback(
            phase: .stopped, message: "Agent stopped.")
        }
      } else if agentActionFeedback[key]?.phase == .stopped, state == .running {
        agentActionFeedback[key] = nil
      }
    }
  }

  private func recordThreadSnapshots(
    _ snapshots: [RemoteThread], reconcileStopWait: Bool = false
  ) {
    for thread in snapshots {
      guard let key = agentControlKey(for: thread.id) else { continue }
      threadStateRevisions[key, default: 0] += 1
      if reconcileStopWait && agentActionFeedback[key]?.phase == .stopWaiting {
        if thread.state == .running {
          agentActionFeedback[key] = nil
        } else if Self.isKnownStoppedState(thread.state) {
          agentActionFeedback[key] = RemoteAgentActionFeedback(
            phase: .stopped, message: "Agent stopped.")
        }
      } else if agentActionFeedback[key]?.phase == .stopped, thread.state == .running {
        agentActionFeedback[key] = nil
      }
    }
  }

  private func agentControlKey(for threadID: String) -> String? {
    guard let serverID = agentControlServerID ?? connectedServerID,
      !serverID.isEmpty, serverID != "unknown"
    else { return nil }
    return "\(serverID.utf8.count):\(serverID):\(threadID.utf8.count):\(threadID)"
  }

  private func clearAgentControlState() {
    agentActionFeedback.removeAll()
    agentSendFeedback.removeAll()
    pendingAgentMessages.removeAll()
    agentSendTokens.removeAll()
    agentStopTokens.removeAll()
    threadStateRevisions.removeAll()
    imageDrafts.removeAll()
    acceptedMessageImages.removeAll()
  }

  private static func isKnownStoppedState(_ state: RemoteThread.State) -> Bool {
    state == .idle || state == .closed || state == .failed
  }

  private func prepareAgentActionsForConnectionChange() {
    for key in agentSendTokens.keys {
      if let pending = pendingAgentMessages[key] {
        agentSendFeedback[key] = RemoteAgentActionFeedback(
          phase: .sendUncertain,
          message: "Delivery couldn’t be confirmed. Check the timeline before sending again.",
          canRetrySend: pending.receiptSupport && agentRequestReceiptsSupported,
          requiresUncertaintyReview: !(pending.receiptSupport && agentRequestReceiptsSupported))
      }
    }
    for key in agentStopTokens.keys {
      agentActionFeedback[key] = RemoteAgentActionFeedback(
        phase: .failed,
        message: "Stop couldn’t be confirmed. Review the agent state before trying again.")
    }
    agentSendTokens.removeAll()
    agentStopTokens.removeAll()
  }

  private func performAgentSend(
    _ intent: PendingAgentMessage, threadID: String, key: String, token: UUID,
    service: any OesapRemoteService
  ) async -> Bool {
    let hostID = agentControlServerID ?? connectedServerID
    let generation = connectionGeneration
    do {
      try await service.send(
        agentID: threadID, text: intent.text, messageID: intent.messageID,
        behavior: intent.behavior, images: intent.images)
      guard agentSendTokens[key] == token,
        pendingAgentMessages[key]?.messageID == intent.messageID,
        connectionGeneration == generation,
        (agentControlServerID ?? connectedServerID) == hostID
      else { return false }
      agentSendTokens[key] = nil
      pendingAgentMessages[key] = nil
      if drafts[threadID] == intent.draftText {
        drafts[threadID] = ""
      }
      let submittedImageIDs = Set(intent.images.map(\.id))
      imageDrafts[threadID]?.removeAll { submittedImageIDs.contains($0.id) }
      if !intent.images.isEmpty {
        acceptedMessageImages[threadID, default: [:]][intent.messageID] = intent.images
        for index in messages.indices {
          messages[index] = imageOverlay(messages[index], threadID: threadID)
        }
      }
      if threads.first(where: { $0.id == threadID })?.state == .running {
        agentSendFeedback[key] = nil
      } else {
        agentSendFeedback[key] = RemoteAgentActionFeedback(
          phase: .accepted, message: "Message accepted by host.")
      }
      return true
    } catch {
      guard agentSendTokens[key] == token,
        pendingAgentMessages[key]?.messageID == intent.messageID,
        connectionGeneration == generation,
        (agentControlServerID ?? connectedServerID) == hostID
      else { return false }
      agentSendTokens[key] = nil
      agentSendFeedback[key] = RemoteAgentActionFeedback(
        phase: .sendUncertain,
        message: "Delivery couldn’t be confirmed. Check the timeline before sending again.",
        canRetrySend: intent.receiptSupport && agentRequestReceiptsSupported,
        requiresUncertaintyReview: !(intent.receiptSupport && agentRequestReceiptsSupported))
      return false
    }
  }

  private func startObservingConnection(_ service: any OesapRemoteService, generation: Int) {
    connectionObservationTask?.cancel()
    connectionObservationTask = Task { [weak self] in
      let events = await service.connectionEvents()
      for await event in events {
        guard let self, self.connectionGeneration == generation else { return }
        switch event {
        case .connected:
          self.connectionState = .connected
        case .disconnected(let reason):
          await self.markConnectionLost(
            generation: generation,
            reason: "The Paseo host disconnected. Reconnect to continue. \(reason)"
          )
          return
        }
      }
    }
  }

  private func refreshPermissions(
    using service: any OesapRemoteService,
    generation: Int
  ) async {
    do {
      let loadedPermissions = try await service.pendingPermissions()
      guard connectionGeneration == generation, !Task.isCancelled else { return }
      permissions = loadedPermissions
    } catch {
      guard connectionGeneration == generation, !Task.isCancelled else { return }
      permissionError = "Agent approval requests are temporarily unavailable."
    }
  }

  private func replaceMessages(_ replacement: [RemoteMessage]) {
    messages = replacement
    #if DEBUG
      performanceFixtureStreamBytes = 0
    #endif
    bufferedAgentMessageIDs.removeAll()
    bufferedAgentMessageTexts.removeAll()
    messageIndices.removeAll(keepingCapacity: true)
    for (index, message) in replacement.enumerated() {
      // Preserve the existing first-match behavior for defensive handling of
      // duplicate IDs in a host snapshot.
      if messageIndices[message.id] == nil { messageIndices[message.id] = index }
    }
    timelineStructureRevision += 1
  }

  private func appendMessage(_ message: RemoteMessage, cursor: RemoteTimelineCursor?, isDelta: Bool)
  {
    var message = selectedThreadID.map { imageOverlay(message, threadID: $0) } ?? message
    if let compaction = message.compaction, compaction.status == .completed,
      messageIndices[message.id] == nil,
      let loadingIndex = messages.lastIndex(where: {
        $0.compaction?.status == .loading && $0.compaction?.turnID == compaction.turnID
      })
    {
      message.id = messages[loadingIndex].id
    }
    if let cursor, let latest = latestTimelineCursor, cursor.epoch == latest.epoch {
      if cursor.sequence < latest.sequence { return }
      if cursor.sequence == latest.sequence,
        isDelta || messageIndices[message.id] == nil
      {
        return
      }
    }
    if isDelta, message.author == .agent, !message.isThinkingTrace, message.toolCall == nil {
      appendBufferedAgentDelta(message)
      if let cursor { latestTimelineCursor = cursor }
      return
    }
    if let existingIndex = messageIndices[message.id] {
      if isDelta, message.toolCall == nil, messages[existingIndex].toolCall == nil {
        messages[existingIndex].text += message.text
      } else {
        var replacement = message
        if message.toolCall != nil || message.isThinkingTrace || message.compaction != nil {
          replacement.timestamp = messages[existingIndex].timestamp ?? message.timestamp
        }
        messages[existingIndex] = replacement
      }
    } else {
      messageIndices[message.id] = messages.count
      messages.append(message)
      timelineStructureRevision += 1
    }
    if let cursor { latestTimelineCursor = cursor }
  }

  private func appendBufferedAgentDelta(_ message: RemoteMessage) {
    #if DEBUG
      if message.id == "demo-performance-stream" {
        performanceFixtureStreamBytes += message.text.utf8.count
      }
    #endif
    if let existingIndex = messageIndices[message.id] {
      if bufferedAgentMessageIDs.insert(message.id).inserted {
        bufferedAgentMessageTexts[message.id] = messages[existingIndex].text + message.text
        messages[existingIndex].text = ""
      } else {
        bufferedAgentMessageTexts[message.id, default: ""] += message.text
      }
    } else {
      var placeholder = message
      placeholder.text = ""
      messageIndices[message.id] = messages.count
      messages.append(placeholder)
      bufferedAgentMessageIDs.insert(message.id)
      bufferedAgentMessageTexts[message.id] = message.text
      timelineStructureRevision += 1
    }
  }

  private func commitBufferedAgentMessages() {
    guard !bufferedAgentMessageIDs.isEmpty else { return }
    for messageID in bufferedAgentMessageIDs {
      guard let index = messageIndices[messageID],
        let text = bufferedAgentMessageTexts[messageID]
      else { continue }
      messages[index].text = text
    }
    bufferedAgentMessageIDs.removeAll()
    bufferedAgentMessageTexts.removeAll()
  }

  private func imageOverlay(_ message: RemoteMessage, threadID: String) -> RemoteMessage {
    guard message.author == .user else { return message }
    var result = message
    if let clientMessageID = message.clientMessageID
      ?? (acceptedMessageImages[threadID]?[message.id] != nil ? message.id : nil),
      let images = acceptedMessageImages[threadID]?[clientMessageID]
    {
      result.images = images
    }
    return result
  }

  /// Fetches an image referenced by an assistant's Markdown from the current
  /// daemon. The source is a host path, never a path on the iPhone.
  func loadRemoteImage(source: String, threadID: String) async throws -> Data {
    guard connectionState == .connected, selectedThreadID == threadID,
      let service, let projectID = selectedProjectID,
      let thread = threads.first(where: { $0.id == threadID }),
      let workspaceRoot = (thread.cwd?.isEmpty == false ? thread.cwd : nil)
        ?? projects.first(where: { $0.id == projectID })?.rootPath,
      let target = Self.imageReadTarget(source: source, workspaceRoot: workspaceRoot)
    else { throw RemoteServiceError.unavailable("Image preview is unavailable for this thread.") }
    let generation = connectionGeneration
    let selectionGeneration = threadSelectionGeneration
    let serverID = connectedServerID
    let data = try await service.readImage(
      cwd: target.cwd, path: target.path, maxBytes: RemoteImageLimits.maximumDisplayBytes)
    guard connectionGeneration == generation,
      threadSelectionGeneration == selectionGeneration,
      selectedThreadID == threadID, connectedServerID == serverID, !Task.isCancelled
    else { throw CancellationError() }
    return data
  }

  private static func imageReadTarget(source: String, workspaceRoot: String)
    -> (cwd: String, path: String)?
  {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lower = trimmed.lowercased()
    guard !lower.hasPrefix("http:"), !lower.hasPrefix("https:"),
      !lower.hasPrefix("data:"), !lower.hasPrefix("blob:")
    else { return nil }
    let path: String
    if lower.hasPrefix("file://") {
      guard let url = URL(string: trimmed), url.isFileURL,
        url.host == nil || url.host == "" || url.host == "localhost"
      else { return nil }
      path = url.path
    } else {
      if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression)
        != nil && trimmed.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) == nil
      {
        return nil
      }
      path = trimmed
    }
    if path == "~" || path.hasPrefix("~/") { return ("~", path) }
    if path.hasPrefix("/") {
      let root =
        workspaceRoot.hasSuffix("/")
        ? String(workspaceRoot.dropLast()) : workspaceRoot
      let cwd = path == root || path.hasPrefix(root + "/") ? workspaceRoot : "/"
      return (cwd, path)
    }
    if path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
      return (String(path.prefix(2)) + "/", path)
    }
    guard workspaceRoot.hasPrefix("/") else { return nil }
    return (workspaceRoot, path)
  }

  private func isCurrentTimeline(
    threadID: String, generation: Int,
    selectionGeneration: Int
  ) -> Bool {
    !Task.isCancelled && connectionGeneration == generation
      && threadSelectionGeneration == selectionGeneration
      && selectedThreadID == threadID && service != nil
  }

  @discardableResult
  private func invalidateConnection() -> Int {
    clearGitChanges()
    clearSessionDetails()
    // A settings request can still be awaiting a response from the old host.
    // Releasing its token lets the newly selected host accept settings changes;
    // the old request's mutation-ID check discards any late response.
    activeSessionSettingsMutation = nil
    activeSessionSettingsMutationThreadID = nil
    connectionObservationTask?.cancel()
    connectionObservationTask = nil
    agentOverviewRefreshTask?.cancel()
    agentOverviewRefreshTask = nil
    agentOverviewRefreshTaskID = nil
    agentOverviewRefreshQueued = false
    providerUsageRefreshTask?.cancel()
    providerUsageRefreshTask = nil
    providerUsageRefreshTaskID = nil
    providerUsageRefreshQueued = false
    contextUsageRefreshTask?.cancel()
    contextUsageRefreshTask = nil
    contextUsageRequestGeneration += 1
    connectionGeneration += 1
    return connectionGeneration
  }

  private func markConnectionLost(
    generation: Int, reason: String,
    replaceWorkspaceError: Bool = true
  ) async {
    guard connectionGeneration == generation else { return }
    prepareAgentActionsForConnectionChange()
    let oldService = service
    invalidateConnection()
    service = nil
    canCreateThreads = false
    agentProviders = []
    loadingAgentOptions = false
    connectionState = .disconnected
    loadingProjects = false
    loadingThreads = false
    loadingHistory = false
    loadingOlderMessages = false
    sendingMessage = false
    loadingAgentOverview = false
    loadingProviderUsage = false
    loadingContextUsage = false
    providerUsageIsStale = true
    agentOverviewIsStale = !agentOverviewGroups.isEmpty
    agentOverviewRefreshGeneration += 1
    answeringPermissionID = nil
    connectError = reason
    if replaceWorkspaceError { workspaceError = reason }
    await oldService?.disconnect()
    await refreshSavedInstances()
  }

  private func clearWorkspaceForInstanceChange(preserveSelection: Bool = false) {
    connectedServerID = nil
    agentControlServerID = nil
    canCreateThreads = false
    agentRequestReceiptsSupported = false
    agentProviders = []
    loadingAgentOptions = false
    agentConfigurationError = nil
    agentConfigurationRevision += 1
    clearAgentControlState()
    pendingNewThreadIntents.removeAll()
    pendingNewThreadResults.removeAll()
    clearAgentOverview()
    clearProviderSubagents()
    clearProviderUsage()
    clearCachedContextUsage()

    projects = []
    threads = []
    workspaceNotice = nil
    replaceMessages([])
    permissions = []
    loadingProjects = false
    loadingThreads = false
    loadingHistory = false
    loadingOlderMessages = false
    loadingContextUsage = false
    sendingMessage = false
    answeringPermissionID = nil
    historyMayBeIncomplete = false
    timelineHasOlder = false
    olderTimelineCursor = nil
    latestTimelineCursor = nil
    drafts.removeAll()
    if !preserveSelection {
      selectedProjectID = nil
      selectedThreadID = nil
      UserDefaults.standard.removeObject(forKey: Self.selectedProjectKey)
      UserDefaults.standard.removeObject(forKey: Self.selectedThreadKey)
    }
    projectSelectionGeneration += 1
    threadSelectionGeneration += 1
    timelineGeneration += 1
    clearErrors()
    workspaceError = nil
  }

  private func clearErrors() {
    connectError = nil
    workspaceError = nil
    timelineError = nil
    messageError = nil
    permissionError = nil
  }

  private func clearAgentOverview() {
    agentOverviewRefreshGeneration += 1
    agentOverviewGroups = []
    loadingAgentOverview = false
    agentOverviewError = nil
    agentOverviewIsStale = false
    agentOverviewUpdatedAt = nil
  }

  private func clearProviderSubagents() {
    providerSubagentsByParent = [:]
    providerSubagentErrors = [:]
    loadingProviderSubagentParents = []
  }

  private func clearProviderUsage() {
    providerUsageProviders = []
    providerUsageFetchedAt = nil
    providerUsageError = nil
    providerUsageIsStale = false
    loadingProviderUsage = false
    providerUsageSupported = false
    loadingContextUsage = false
    contextUsageError = nil
  }

  private func clearCachedContextUsage() {
    for index in threads.indices { threads[index].contextUsage = nil }
    contextUsageRevision += 1
  }

  private static let selectedProjectKey = "selectedProjectID"
  private static let selectedThreadKey = "selectedThreadID"
}
