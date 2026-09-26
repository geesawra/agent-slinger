import Foundation
import Observation

@MainActor
@Observable
final class OesapModel {
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
  private(set) var projects: [RemoteProject] = []
  private(set) var threads: [RemoteThread] = []
  private(set) var messages: [RemoteMessage] = []
  private(set) var permissions: [RemotePermission] = []
  private(set) var historyMayBeIncomplete = false
  private(set) var loadingProjects = false
  private(set) var loadingThreads = false
  private(set) var loadingHistory = false
  private(set) var loadingOlderMessages = false
  private(set) var timelineHasOlder = false
  private(set) var sendingMessage = false
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
  private(set) var providerUsageProviders: [RemoteProviderUsage] = []
  private(set) var providerUsageFetchedAt: Date?
  private(set) var providerUsageError: String?
  private(set) var providerUsageIsStale = false
  private(set) var loadingProviderUsage = false
  private(set) var providerUsageSupported = false
  private(set) var loadingContextUsage = false
  private(set) var contextUsageError: String?
  private(set) var answeringPermissionID: String?
  private(set) var timelineGeneration = 0
  private(set) var connectError: String?
  private(set) var workspaceError: String?
  private(set) var timelineError: String?
  private(set) var messageError: String?
  private(set) var permissionError: String?
  private(set) var selectedProjectID: String?
  private(set) var selectedThreadID: String?

  @ObservationIgnored private let connectionFactory: any OesapConnectionFactory
  @ObservationIgnored private let agentConfigurationStore: AgentConfigurationStore
  @ObservationIgnored private var service: (any OesapRemoteService)?
  @ObservationIgnored private var connectedServerID: String?
  @ObservationIgnored private var pendingNewThreadIntents: [String: RemoteNewThreadIntent] = [:]
  @ObservationIgnored private var pendingNewThreadResults: [String: RemoteNewThreadResult] = [:]
  private var drafts: [String: String] = [:]
  @ObservationIgnored private var connectionObservationTask: Task<Void, Never>?
  @ObservationIgnored private var connectionGeneration = 0
  @ObservationIgnored private var olderTimelineCursor: RemoteTimelineCursor?
  @ObservationIgnored private var latestTimelineCursor: RemoteTimelineCursor?
  @ObservationIgnored private var projectSelectionGeneration = 0
  @ObservationIgnored private var threadSelectionGeneration = 0
  @ObservationIgnored private var agentOverviewRefreshGeneration = 0
  @ObservationIgnored private var agentOverviewRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var agentOverviewRefreshTaskID: UUID?
  @ObservationIgnored private var agentOverviewRefreshQueued = false
  @ObservationIgnored private var providerUsageRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var providerUsageRefreshTaskID: UUID?
  @ObservationIgnored private var providerUsageRefreshQueued = false
  @ObservationIgnored private var contextUsageRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var contextUsageRequestGeneration = 0
  @ObservationIgnored private var contextUsageRevision = 0

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
    let generation = connectionGeneration
    let saved = await connectionFactory.savedConnectionExists()
    guard connectionGeneration == generation else { return }
    hasSavedConnection = saved
  }

  func connect(_ connection: RemoteConnection) async {
    guard !connectionState.isBusy else { return }
    let generation = invalidateConnection()
    service = nil
    connectedServerID = nil
    canCreateThreads = false
    agentProviders = []
    loadingAgentOptions = false
    clearAgentOverview()
    clearProviderUsage()
    clearCachedContextUsage()
    connectionState = .connecting
    clearErrors()
    do {
      let connectedService = try await connectionFactory.connect(connection)
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
      canCreateThreads = supportsNewThreads
      providerUsageSupported = supportsProviderUsage
      connectionState = .connected
      hasSavedConnection = true
      timelineGeneration += 1
      startObservingConnection(connectedService, generation: generation)
      await reloadWorkspace(preserveSelection: true, generation: generation)
      if connectionGeneration == generation { _ = startProviderUsageRefresh() }
      if connectionGeneration == generation, Task.isCancelled { await disconnect() }
    } catch {
      guard connectionGeneration == generation else { return }
      if error is CancellationError {
        connectionState = .disconnected
        return
      }
      service = nil
      connectedServerID = nil
      canCreateThreads = false
      providerUsageSupported = false
      connectionState = .disconnected
      connectError = error.localizedDescription
      await refreshSavedConnectionState()
    }
  }

  func reconnect() async {
    guard !connectionState.isBusy else { return }
    let priorServerID = connectedServerID
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
      let connectedService = try await connectionFactory.reconnect()
      guard connectionGeneration == generation else {
        await connectedService.disconnect()
        return
      }
      if Task.isCancelled {
        await connectedService.disconnect()
        guard connectionGeneration == generation else { return }
        connectionState = .disconnected
        return
      }
      let serverID = await connectedService.serverID()
      let supportsNewThreads = await connectedService.supportsNewThreads()
      let supportsProviderUsage = await connectedService.supportsProviderUsage()
      guard connectionGeneration == generation else {
        await connectedService.disconnect()
        return
      }
      if Task.isCancelled {
        await connectedService.disconnect()
        guard connectionGeneration == generation else { return }
        connectionState = .disconnected
        return
      }
      if priorServerID == nil || priorServerID != serverID {
        clearAgentOverview()
        clearProviderUsage()
        clearCachedContextUsage()
      }
      service = connectedService
      connectedServerID = serverID
      canCreateThreads = supportsNewThreads
      providerUsageSupported = supportsProviderUsage
      connectionState = .connected
      timelineGeneration += 1
      startObservingConnection(connectedService, generation: generation)
      await reloadWorkspace(preserveSelection: true, generation: generation)
      if connectionGeneration == generation { _ = startProviderUsageRefresh() }
      if connectionGeneration == generation, Task.isCancelled {
        await markConnectionLost(
          generation: generation, reason: "Reconnect was cancelled. Try again to continue.")
      }
    } catch {
      guard connectionGeneration == generation else { return }
      if error is CancellationError {
        connectionState = .disconnected
        return
      }
      service = nil
      canCreateThreads = false
      providerUsageSupported = false
      connectionState = .disconnected
      connectError = error.localizedDescription
      workspaceError =
        "Reconnect failed. Your open thread and draft stay in this app while it is open. Try again when the host is reachable."
    }
  }

  func disconnect() async {
    let generation = invalidateConnection()
    let previousService = service
    service = nil
    connectedServerID = nil
    canCreateThreads = false
    agentProviders = []
    pendingNewThreadIntents.removeAll()
    pendingNewThreadResults.removeAll()
    clearAgentOverview()
    clearProviderUsage()
    connectionState = .disconnected
    projects = []
    threads = []
    messages = []
    permissions = []
    loadingProjects = false
    loadingThreads = false
    loadingHistory = false
    loadingContextUsage = false
    loadingOlderMessages = false
    sendingMessage = false
    answeringPermissionID = nil
    historyMayBeIncomplete = false
    drafts.removeAll()
    loadingAgentOptions = false
    agentConfigurationError = nil
    timelineHasOlder = false
    olderTimelineCursor = nil
    latestTimelineCursor = nil
    workspaceError = nil
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
    hasSavedConnection = cleanupError != nil
  }

  func selectProject(_ id: String) async {
    projectSelectionGeneration += 1
    threadSelectionGeneration += 1
    selectedProjectID = id
    agentProviders = []
    loadingAgentOptions = false
    agentConfigurationError = nil
    UserDefaults.standard.set(id, forKey: Self.selectedProjectKey)
    selectedThreadID = nil
    UserDefaults.standard.removeObject(forKey: Self.selectedThreadKey)
    threads = []
    messages = []
    permissions = []
    timelineHasOlder = false
    olderTimelineCursor = nil
    latestTimelineCursor = nil
    await loadThreads(
      projectID: id, generation: connectionGeneration,
      selectionGeneration: projectSelectionGeneration)
  }

  func selectThread(_ id: String) {
    contextUsageRefreshTask?.cancel()
    contextUsageRefreshTask = nil
    contextUsageRequestGeneration += 1
    contextUsageRevision += 1
    loadingContextUsage = false
    contextUsageError = nil
    threadSelectionGeneration += 1
    selectedThreadID = id
    UserDefaults.standard.set(id, forKey: Self.selectedThreadKey)
    messages = []
    timelineError = nil
    timelineHasOlder = false
    olderTimelineCursor = nil
    latestTimelineCursor = nil
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

  func refreshThreads(projectID: String) async {
    await loadThreads(
      projectID: projectID, generation: connectionGeneration,
      selectionGeneration: projectSelectionGeneration)
  }

  func draft(for threadID: String) -> String {
    drafts[threadID, default: ""]
  }

  func setDraft(_ value: String, for threadID: String) {
    drafts[threadID] = value
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
    guard !trimmed.isEmpty, !sendingMessage else { return nil }
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
        messageError = "Set this project’s agent on this iPhone before starting a thread."
        return nil
      }
      intent = RemoteNewThreadIntent(
        idempotencyKey: UUID().uuidString.lowercased(),
        clientMessageID: UUID().uuidString.lowercased(),
        projectID: projectID,
        provider: configuration.provider,
        model: configuration.model,
        cwd: rootPath,
        prompt: trimmed)
      pendingNewThreadIntents[scope] = intent
    }
    let draftKey = newThreadDraftKey(for: projectID)
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
      if result.promptAccepted {
        if currentDraft != text || trimmed != intent.prompt {
          drafts[thread.id] = currentDraft
        }
      } else {
        drafts[thread.id] = currentDraft.isEmpty ? intent.prompt : currentDraft
      }
      drafts[draftKey] = ""
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
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !sendingMessage, connectionState == .connected,
      let service
    else { return false }
    let generation = connectionGeneration
    sendingMessage = true
    messageError = nil
    defer { if connectionGeneration == generation { sendingMessage = false } }
    do {
      try await service.send(agentID: threadID, text: trimmed)
      guard connectionGeneration == generation else { return false }
      if drafts[threadID] == text { drafts[threadID] = "" }
      return true
    } catch {
      guard connectionGeneration == generation else { return false }
      messageError =
        "Delivery couldn’t be confirmed. Your draft stays in this app while it is open. Check the timeline before retrying to avoid sending it twice. \(error.localizedDescription)"
      return false
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
      // Subscribe before loading the authoritative snapshot so updates arriving
      // during history loading remain buffered by the stream.
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
      messages = history.messages
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
          messages = refreshedHistory.messages
          historyMayBeIncomplete = refreshedHistory.historyMayBeIncomplete
          timelineHasOlder = refreshedHistory.hasOlder
          olderTimelineCursor = refreshedHistory.olderCursor
          latestTimelineCursor = refreshedHistory.latestCursor
        case .threadState(let state, let requiresAttention, let reason):
          updateThread(threadID, state: state, requiresAttention: requiresAttention, reason: reason)
        case .contextUsage(let usage):
          if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index].contextUsage = threads[index].contextUsage?.merging(usage) ?? usage
            contextUsageRevision += 1
            contextUsageError = nil
          }
        case .contextUsageNeedsRefresh:
          startContextUsageRefresh(threadID: threadID)
        case .permissionRequested(let permission):
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
        timelineError = "The live timeline ended. Reconnect to restore updates."
        await markConnectionLost(
          generation: generation,
          reason: "The Paseo host disconnected. Reconnect to continue.")
      }
    } catch is CancellationError {
      return
    } catch {
      guard
        isCurrentTimeline(
          threadID: threadID, generation: generation,
          selectionGeneration: selectionGeneration)
      else { return }
      loadingHistory = false
      timelineError =
        "The timeline connection ended. Reconnect to restore this history and its live updates. \(error.localizedDescription)"
      await markConnectionLost(
        generation: generation,
        reason: "The Paseo host disconnected. Reconnect to continue.")
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
      messages = older.messages.filter { !knownIDs.contains($0.id) } + messages
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

  func clearMessageError() {
    messageError = nil
  }

  private func reloadWorkspace(preserveSelection: Bool, generation: Int) async {
    guard connectionGeneration == generation, let service else { return }
    loadingProjects = true
    workspaceError = nil
    do {
      let loadedProjects = try await service.projects()
      guard connectionGeneration == generation, !Task.isCancelled else { return }
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
        messages = []
        permissions = []
        return
      }
      let requestedProjectID = preserveSelection ? selectedProjectID : nil
      let nextProjectID =
        loadedProjects.contains { $0.id == requestedProjectID }
        ? requestedProjectID
        : loadedProjects.first?.id
      guard let nextProjectID else { return }
      if selectedProjectID != nextProjectID {
        projectSelectionGeneration += 1
        threadSelectionGeneration += 1
        selectedThreadID = nil
        messages = []
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
    selectionGeneration: Int
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

  private func appendMessage(_ message: RemoteMessage, cursor: RemoteTimelineCursor?, isDelta: Bool)
  {
    if let cursor, let latest = latestTimelineCursor, cursor.epoch == latest.epoch {
      if cursor.sequence < latest.sequence { return }
      if cursor.sequence == latest.sequence,
        isDelta || !messages.contains(where: { $0.id == message.id })
      {
        return
      }
    }
    if let existingIndex = messages.firstIndex(where: { $0.id == message.id }) {
      if isDelta, message.toolCall == nil, messages[existingIndex].toolCall == nil {
        messages[existingIndex].text += message.text
      } else {
        var replacement = message
        if message.toolCall != nil {
          replacement.timestamp = messages[existingIndex].timestamp ?? message.timestamp
        }
        messages[existingIndex] = replacement
      }
    } else {
      messages.append(message)
    }
    if let cursor { latestTimelineCursor = cursor }
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
    let oldService = service
    let currentGeneration = invalidateConnection()
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
    if replaceWorkspaceError { workspaceError = reason }
    await oldService?.disconnect()
    let saved = await connectionFactory.savedConnectionExists()
    guard connectionGeneration == currentGeneration else { return }
    hasSavedConnection = saved
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
