import SwiftUI

enum OesapRoute: Hashable {
  case agentOverview
  case usage
  case settings
  case addInstance
  case project(String)
  case chat(String)
  case newChat(String)
  case agentConfiguration(String)
}

struct WorkspaceRootView: View {
  @Bindable var model: OesapModel
  @State private var path: [OesapRoute] = []
  @State private var splitProjectID: String?
  @State private var detailRoute: OesapRoute?
  @State private var presentedRoute: OesapRoute?
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var confirmsDisconnect = false
  @State private var observedInstanceID: String?

  private var usesSplitNavigation: Bool {
    #if targetEnvironment(macCatalyst)
      true
    #else
      UIDevice.current.userInterfaceIdiom == .pad
    #endif
  }

  private var hasWorkspace: Bool {
    model.connectionState == .connected || !model.projects.isEmpty || model.workspaceError != nil
  }

  var body: some View {
    Group {
      if usesSplitNavigation && hasWorkspace {
        splitNavigation
      } else {
        compactNavigation
      }
    }
    .focusedSceneValue(
      \.workspaceActions,
      WorkspaceActions(
        canCreateThread: hasWorkspace && model.selectedProjectID != nil
          && (!usesSplitNavigation || splitProjectID == model.selectedProjectID)
          && model.connectionState == .connected,
        newThread: {
          guard let id = model.selectedProjectID else { return }
          open(.newChat(id))
        },
        refresh: { Task { await model.refreshWorkspace() } },
        settings: { open(.settings) }
      )
    )
    .sheet(item: $presentedRoute) { route in
      NavigationStack {
        destination(route)
          .navigationDestination(for: OesapRoute.self) { destination($0) }
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { presentedRoute = nil }
            }
          }
      }
      #if targetEnvironment(macCatalyst)
        .frame(minWidth: 480, idealWidth: 580, minHeight: 480, idealHeight: 650)
      #endif
    }
    .onChange(of: model.activeInstanceID) { _, newValue in
      guard newValue != observedInstanceID else { return }
      observedInstanceID = newValue
      resetWorkspaceNavigation()
      // Keep Settings visible when switching fails, so the connection stays actionable.
      if path.contains(.settings) { path = [.settings] } else { path.removeAll() }
    }
    .onChange(of: model.projects.map(\.id)) { _, projectIDs in
      guard let splitProjectID, !projectIDs.contains(splitProjectID) else { return }
      resetWorkspaceNavigation()
    }
    .onChange(of: model.selectedThreadID) { _, threadID in
      guard case .chat(let displayedThreadID) = detailRoute,
        displayedThreadID != threadID
      else { return }
      // A workspace refresh may remove the displayed remote thread.
      detailRoute = nil
      preferredCompactColumn = .content
    }
    .task {
      observedInstanceID = model.activeInstanceID
      await model.refreshSavedInstances()
    }
    .confirmationDialog(
      "Disconnect from this host?", isPresented: $confirmsDisconnect, titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) {
        Task {
          await model.disconnect()
          resetWorkspaceNavigation()
          path.removeAll()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Credentials for the selected instance will be removed. Other saved instances will remain on this device. Unsent drafts will be discarded. Agents on your Paseo host will keep running."
      )
    }
    .tint(.accentColor)
  }

  private var compactNavigation: some View {
    NavigationStack(path: $path) {
      Group {
        if hasWorkspace {
          ProjectListView(model: model, onOpenAgentOverview: { open(.agentOverview) }) { project in
            Task {
              await model.selectProject(project.id)
              path.append(.project(project.id))
            }
          }
        } else {
          ConnectionSetupView(model: model, onOpenSettings: { open(.settings) })
        }
      }
      .toolbar { if hasWorkspace { connectionToolbar } }
      .navigationDestination(for: OesapRoute.self) { destination($0) }
    }
  }

  private var splitNavigation: some View {
    NavigationSplitView(
      columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn
    ) {
      ProjectListView(
        model: model,
        selection: Binding(get: { splitProjectID }, set: { selectSplitProject($0) }),
        onOpenAgentOverview: { open(.agentOverview) },
        onOpenProject: { selectSplitProject($0.id) }
      )
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
      .toolbar { connectionToolbar }
      .accessibilityIdentifier("workspace-project-sidebar")
    } content: {
      if let projectID = splitProjectID {
        ThreadListView(
          model: model,
          projectID: projectID,
          selection: Binding(
            get: { if case .chat(let id) = detailRoute { id } else { nil } },
            set: { id in
              guard let id else {
                detailRoute = nil
                return
              }
              showThread(id)
            }
          ),
          onNewThread: { open(.newChat(projectID)) },
          onOpenAgent: { open(.agentConfiguration(projectID)) },
          onOpenThread: { showThread($0.id) }
        )
        .id(projectID)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        .accessibilityIdentifier("workspace-thread-list")
      } else {
        ContentUnavailableView("Choose a project", systemImage: "folder")
          .navigationTitle("Threads")
      }
    } detail: {
      NavigationStack {
        if let detailRoute {
          destination(detailRoute)
            .id(detailRoute)
        } else {
          ContentUnavailableView(
            "Choose a thread",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Select an agent thread to view its conversation.")
          )
        }
      }
      .accessibilityIdentifier("workspace-detail")
    }
    .navigationSplitViewStyle(.balanced)
  }

  @ToolbarContentBuilder
  private var connectionToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button("Usage", systemImage: "chart.bar") { open(.usage) }
          .accessibilityIdentifier("host-usage-button")
        Button("Settings", systemImage: "gearshape") { open(.settings) }
          .accessibilityIdentifier("settings-button")
        Divider()
        Button("Reconnect", systemImage: "arrow.clockwise") { Task { await model.reconnect() } }
          .disabled(model.connectionState.isBusy)
        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
          confirmsDisconnect = true
        }
      } label: {
        Image(systemName: "ellipsis.circle").accessibilityLabel("Connection options")
      }
      .accessibilityIdentifier("connection-options")
    }
  }

  @ViewBuilder
  private func destination(_ route: OesapRoute) -> some View {
    switch route {
    case .agentOverview:
      AgentOverviewView(model: model) { threadID in
        if usesSplitNavigation {
          splitProjectID = model.selectedProjectID
          presentedRoute = nil
          detailRoute = .chat(threadID)
          preferredCompactColumn = .detail
        } else {
          path.append(.chat(threadID))
        }
      }
    case .usage:
      ProviderUsageView(model: model)
    case .settings:
      SettingsView(
        model: model,
        onAddInstance: { open(.addInstance) },
        onSelected: {
          path.removeAll()
          presentedRoute = nil
          resetWorkspaceNavigation()
        }
      )
    case .addInstance:
      ConnectionSetupView(
        model: model,
        title: "Add Paseo instance",
        showsReconnectAction: false,
        onConnected: {
          path.removeAll()
          presentedRoute = nil
          resetWorkspaceNavigation()
        }
      )
    case .project(let id):
      ThreadListView(
        model: model, projectID: id,
        onNewThread: { open(.newChat(id)) },
        onOpenAgent: { open(.agentConfiguration(id)) },
        onOpenThread: { thread in showThread(thread.id) }
      )
    case .chat(let id):
      ChatView(model: model, threadID: id)
    case .newChat(let projectID):
      NewChatView(
        model: model, projectID: projectID,
        onOpenAgent: { open(.agentConfiguration(projectID)) },
        onCreated: { threadID in
          if usesSplitNavigation {
            guard detailRoute == .newChat(projectID) else { return }
            detailRoute = .chat(threadID)
          } else {
            guard path.last == .newChat(projectID) else { return }
            path.removeLast()
            path.append(.chat(threadID))
          }
        }
      )
    case .agentConfiguration(let projectID):
      AgentConfigurationView(model: model, projectID: projectID)
    }
  }

  private func open(_ route: OesapRoute) {
    guard usesSplitNavigation else {
      path.append(route)
      return
    }
    switch route {
    case .chat, .newChat:
      detailRoute = route
      preferredCompactColumn = .detail
    case .project(let id):
      selectSplitProject(id)
    default:
      presentedRoute = route
    }
  }

  private func selectSplitProject(_ id: String?) {
    guard id != splitProjectID else { return }
    detailRoute = nil
    splitProjectID = id
    preferredCompactColumn = id == nil ? .sidebar : .content
  }

  private func showThread(_ id: String) {
    if usesSplitNavigation && detailRoute == .chat(id) {
      preferredCompactColumn = .detail
      return
    }
    model.selectThread(id)
    open(.chat(id))
  }

  private func resetWorkspaceNavigation() {
    splitProjectID = nil
    detailRoute = nil
    preferredCompactColumn = .sidebar
  }
}

extension OesapRoute: Identifiable {
  var id: Self { self }
}

struct WorkspaceActions {
  var canCreateThread: Bool
  var newThread: () -> Void
  var refresh: () -> Void
  var settings: () -> Void
}

private struct WorkspaceActionsKey: FocusedValueKey {
  typealias Value = WorkspaceActions
}

extension FocusedValues {
  var workspaceActions: WorkspaceActions? {
    get { self[WorkspaceActionsKey.self] }
    set { self[WorkspaceActionsKey.self] = newValue }
  }
}

struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceActions) private var actions

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Thread") { actions?.newThread() }
        .keyboardShortcut("n")
        .disabled(actions?.canCreateThread != true)
    }
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") { actions?.settings() }
        .keyboardShortcut(",")
        .disabled(actions == nil)
    }
    CommandGroup(after: .toolbar) {
      Button("Refresh Workspace") { actions?.refresh() }
        .keyboardShortcut("r")
        .disabled(actions == nil)
    }
    SidebarCommands()
  }
}

private struct ProjectListView: View {
  @Bindable var model: OesapModel
  var selection: Binding<String?>? = nil
  var onOpenAgentOverview: () -> Void
  var onOpenProject: (RemoteProject) -> Void

  var body: some View {
    List(selection: selection) {
      if model.connectionState != .connected {
        ConnectionStatusRow(model: model)
      }

      if let error = model.workspaceError {
        Section {
          ConnectionErrorNotice(message: error, identifier: "workspace-error")
          Button("Reconnect") { Task { await model.reconnect() } }
            .disabled(model.connectionState.isBusy)
        }
      }

      if model.loadingProjects {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading projects…").foregroundStyle(.secondary)
          }
        }
      } else if model.projects.isEmpty && model.workspaceError == nil {
        ContentUnavailableView(
          "No projects yet",
          systemImage: "folder",
          description: Text("Projects on this Paseo host will appear here.")
        )
        .listRowSeparator(.hidden)
      } else {
        Section {
          ForEach(model.projects) { project in
            if selection != nil {
              NavigationLink(value: project.id) {
                ProjectRow(project: project, showsDisclosure: false)
              }
              .accessibilityIdentifier("project-\(project.id)")
            } else {
              Button {
                onOpenProject(project)
              } label: {
                ProjectRow(project: project, showsDisclosure: true)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("project-\(project.id)")
            }
          }
        } header: {
          Text("Projects").foregroundStyle(Color.primary.opacity(0.75))
        }
      }
    }
    .overlay(alignment: .top) {
      if model.connectionState == .reconnecting {
        ProgressView("Reconnecting…")
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 8)
      }
    }
    .navigationTitle("Projects")
    .refreshable { await model.refreshWorkspace() }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(action: onOpenAgentOverview) {
          Label("Agents", systemImage: "cpu")
        }
        .accessibilityIdentifier("agents-overview-button")
      }
    }
  }
}

private struct ProjectRow: View {
  let project: RemoteProject
  var showsDisclosure: Bool

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "folder.fill")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 38, height: 38)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 4) {
        Text(project.name).font(.headline).foregroundStyle(.primary)
        if let subtitle = project.subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(Color.primary.opacity(0.75))
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if showsDisclosure {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .contentShape(Rectangle())
  }
}

private struct ThreadListView: View {
  @Bindable var model: OesapModel
  let projectID: String
  var selection: Binding<String?>? = nil
  var onNewThread: () -> Void
  var onOpenAgent: () -> Void
  var onOpenThread: (RemoteThread) -> Void

  var body: some View {
    List(selection: selection) {
      if model.connectionState != .connected {
        ConnectionStatusRow(model: model)
      }

      if let error = model.workspaceError {
        Section {
          ConnectionErrorNotice(message: error, identifier: "workspace-error")
          Button("Reconnect") { Task { await model.reconnect() } }
            .disabled(model.connectionState.isBusy)
        }
      }

      if model.selectedProjectID != projectID || model.loadingThreads {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading agent threads…").foregroundStyle(.secondary)
          }
        }
      } else if model.threads.isEmpty && model.workspaceError == nil {
        if model.connectionState != .connected {
          ContentUnavailableView(
            "No agent threads",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Reconnect to load this project’s agent threads.")
          )
          .listRowSeparator(.hidden)
        } else if !model.canCreateThreads {
          ContentUnavailableView(
            "No agent threads",
            systemImage: "bubble.left.and.bubble.right",
            description: Text(
              "This Paseo host can’t start threads from Oesap yet. Update Paseo on the host to enable new threads."
            )
          )
          .accessibilityIdentifier("empty-threads-unsupported")
          .listRowSeparator(.hidden)
        } else {
          ContentUnavailableView {
            Label("No agent threads", systemImage: "bubble.left.and.bubble.right")
          } description: {
            Text("Start a new thread in Oesap to begin working with an agent on this project.")
          } actions: {
            Button(action: onNewThread) {
              Label("New thread", systemImage: "plus")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("empty-threads-new-thread-button")
          }
          .accessibilityIdentifier("empty-threads-supported")
          .listRowSeparator(.hidden)
        }
      } else {
        Section {
          ForEach(model.threads) { thread in
            if selection != nil {
              NavigationLink(value: thread.id) {
                ThreadRow(thread: thread, showsDisclosure: false)
              }
              .accessibilityIdentifier("thread-\(thread.id)")
            } else {
              Button {
                onOpenThread(thread)
              } label: {
                ThreadRow(thread: thread)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("thread-\(thread.id)")
            }
          }
        } header: {
          Text("Agent threads").foregroundStyle(Color.primary.opacity(0.75))
        }
      }
    }
    .navigationTitle(model.projects.first { $0.id == projectID }?.name ?? "Threads")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button(action: onOpenAgent) {
          Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Project Agent")
        .accessibilityIdentifier("project-agent-button")

        Button(action: onNewThread) {
          Image(systemName: "plus")
        }
        .disabled(model.connectionState != .connected)
        .accessibilityLabel("New thread")
        .accessibilityIdentifier("new-thread-button")
      }
    }
    .refreshable { await model.refreshThreads(projectID: projectID) }
    .task(id: projectID) {
      if model.selectedProjectID != projectID {
        await model.selectProject(projectID)
      } else if model.threads.isEmpty && !model.loadingThreads {
        await model.refreshThreads(projectID: projectID)
      }
    }
  }
}

private struct ThreadRow: View {
  let thread: RemoteThread
  var showsDisclosure = true

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 5) {
          Text(thread.title)
            .font(.headline)
            .foregroundStyle(.primary)
          if thread.requiresAttention { attentionBadge }
          statusMetadata
          attentionReason
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: thread.state.symbol)
            .font(.title3)
            .foregroundStyle(thread.requiresAttention ? .orange : .secondary)
            .frame(width: 28)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
              Text(thread.title).font(.headline).foregroundStyle(.primary)
              Spacer(minLength: 8)
              if thread.requiresAttention { attentionBadge }
            }
            statusMetadata
            attentionReason
          }

          if showsDisclosure {
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
              .padding(.top, 4)
              .accessibilityHidden(true)
          }
        }
      }
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var attentionBadge: some View {
    Text("Attention")
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.orange.opacity(0.14), in: Capsule())
      .foregroundStyle(.primary)
  }

  @ViewBuilder
  private var statusMetadata: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 2) {
        Text(thread.state.label)
          .foregroundStyle(.primary)
        if let provider = thread.provider {
          Text(provider).foregroundStyle(Color.primary.opacity(0.75))
        }
        if let model = thread.model {
          Text(model).foregroundStyle(Color.primary.opacity(0.75))
        }
      }
      .font(.subheadline)
    } else {
      HStack(spacing: 12) {
        Text(thread.state.label).foregroundStyle(.primary)
        if let provider = thread.provider {
          Text(provider).foregroundStyle(Color.primary.opacity(0.75))
        }
        if let model = thread.model {
          Text(model).foregroundStyle(Color.primary.opacity(0.75))
        }
      }
      .font(.subheadline)
    }
  }

  @ViewBuilder
  private var attentionReason: some View {
    if thread.requiresAttention, let reason = thread.attentionReason {
      Text(reason)
        .font(.footnote)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ConnectionStatusRow: View {
  @Bindable var model: OesapModel

  var body: some View {
    Section {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "wifi.exclamationmark")
          .foregroundStyle(.orange)
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 5) {
          Text("Host connection lost").font(.headline)
          Text(
            "Your open timeline and unsent drafts stay here while this app is open. Reconnect to restore live updates."
          )
          .font(.subheadline)
          .foregroundStyle(Color.primary.opacity(0.75))
          Button("Reconnect") { Task { await model.reconnect() } }
            .disabled(model.connectionState.isBusy || model.activeInstanceID == nil)
            .padding(.top, 3)
        }
      }
      .padding(.vertical, 4)
    }
  }
}
