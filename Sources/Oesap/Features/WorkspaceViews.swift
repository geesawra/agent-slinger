import SwiftUI
import UIKit

enum OesapRoute: Hashable {
  case agentOverview
  case usage
  case settings
  case addInstance
  case addProject
  case project(String)
  case chat(String)
  case newChat(String)
  case agentConfiguration(String)
}

struct ConnectionProgressIndicator: View {
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(title)
        .font(.subheadline)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityIdentifier("connection-progress")
  }
}

struct WorkspaceRootView: View {
  @Bindable var model: OesapModel
  @Environment(\.scenePhase) private var scenePhase
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
    model.loadingSavedConnections || model.hasSavedConnection
      || model.connectionState == .connected || !model.projects.isEmpty
      || model.workspaceError != nil
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
        canRefreshWorkspace: hasWorkspace && model.connectionState == .connected,
        canOpenSettings: !model.loadingSavedConnections,
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
      let archivedProjectIsInCompactPath = path.contains { route in
        switch route {
        case .project(let id), .newChat(let id), .agentConfiguration(let id):
          !projectIDs.contains(id)
        default:
          false
        }
      }
      if archivedProjectIsInCompactPath { path.removeAll() }
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
      await model.start()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        model.appDidEnterBackground()
      } else if phase == .active {
        Task { await model.appDidBecomeActive() }
      }
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
          ProjectListView(
            model: model,
            onOpenAgentOverview: { open(.agentOverview) },
            onAddProject: { open(.addProject) }
          ) { project in
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
        onAddProject: { open(.addProject) },
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
    ToolbarItem(placement: PlatformToolbarPlacements.connectionProgress) {
      if model.loadingSavedConnections || model.connectionState.isBusy {
        ConnectionProgressIndicator(
          title: model.loadingSavedConnections
            ? "Loading…"
            : model.connectionState == .reconnecting ? "Reconnecting…" : "Connecting…")
      }
    }
    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button("Usage", systemImage: "chart.bar") { open(.usage) }
          .accessibilityIdentifier("host-usage-button")
        Button("Settings", systemImage: "gearshape") { open(.settings) }
          .accessibilityIdentifier("settings-button")
        Divider()
        Button("Reconnect", systemImage: "arrow.clockwise") { Task { await model.reconnect() } }
          .disabled(
            model.connectionState.isBusy || model.loadingSavedConnections
              || model.activeInstanceID == nil)
        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
          confirmsDisconnect = true
        }
        .disabled(model.connectionState.isBusy || model.loadingSavedConnections)
      } label: {
        Image(systemName: "ellipsis.circle").accessibilityLabel("Connection options")
      }
      .disabled(model.loadingSavedConnections)
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
    case .addProject:
      ProjectDirectoryPickerView(model: model) { projectID in
        if usesSplitNavigation {
          presentedRoute = nil
          selectSplitProject(projectID)
        } else {
          if path.last == .addProject { path.removeLast() }
          path.append(.project(projectID))
        }
      }
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
  var canRefreshWorkspace: Bool
  var canOpenSettings: Bool
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
        .disabled(actions?.canOpenSettings != true)
    }
    CommandGroup(after: .toolbar) {
      Button("Refresh Workspace") { actions?.refresh() }
        .keyboardShortcut("r")
        .disabled(actions?.canRefreshWorkspace != true)
    }
    SidebarCommands()
  }
}

private struct ProjectListView: View {
  @Bindable var model: OesapModel
  var selection: Binding<String?>? = nil
  var onOpenAgentOverview: () -> Void
  var onAddProject: () -> Void
  var onOpenProject: (RemoteProject) -> Void

  var body: some View {
    List(selection: selection) {
      #if targetEnvironment(macCatalyst)
        Section {
          Button(action: onOpenAgentOverview) {
            Label("Agents", systemImage: "cpu")
          }
          .disabled(model.connectionState.isBusy || model.loadingSavedConnections)
          .accessibilityIdentifier("agents-overview-button")

          Button(action: onAddProject) {
            Label("Add project", systemImage: "plus")
          }
          .disabled(model.connectionState != .connected)
          .accessibilityIdentifier("add-project-button")
        }
      #endif

      if model.loadingSavedConnections {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Checking saved connections…").foregroundStyle(.secondary)
          }
        }
      } else if model.connectionState == .connecting {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Connecting to saved host…").foregroundStyle(.secondary)
          }
        }
      } else if model.connectionState != .connected && model.connectionState != .reconnecting {
        ConnectionStatusRow(model: model)
      }

      if let notice = model.workspaceNotice {
        Section {
          Label(notice, systemImage: "archivebox")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("workspace-unavailable-notice")
        }
        .listRowSeparator(.hidden)
      }

      if let error = model.workspaceError, model.connectionState == .connected {
        Section {
          ConnectionErrorNotice(message: error, identifier: "workspace-error")
          Button("Reconnect") { Task { await model.reconnect() } }
            .disabled(model.connectionState.isBusy)
        }
      }

      if model.loadingSavedConnections || model.connectionState == .connecting {
        EmptyView()
      } else if model.loadingProjects {
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
          description: Text("Add a folder from this Paseo host to get started.")
        )
        .listRowSeparator(.hidden)
      } else {
        Section {
          ForEach(model.projects) { project in
            if selection != nil {
              NavigationLink(value: project.id) {
                ProjectRow(project: project, showsDisclosure: false)
              }
              .disabled(model.connectionState.isBusy)
              .accessibilityIdentifier("project-\(project.id)")
            } else {
              Button {
                onOpenProject(project)
              } label: {
                ProjectRow(project: project, showsDisclosure: true)
              }
              .buttonStyle(.plain)
              .disabled(model.connectionState.isBusy)
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
    .navigationBarTitleDisplayMode(model.connectionState.isBusy ? .inline : .large)
    .refreshable { await model.refreshWorkspace() }
    #if !targetEnvironment(macCatalyst)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: onOpenAgentOverview) {
            Label("Agents", systemImage: "cpu")
          }
          .disabled(model.connectionState.isBusy || model.loadingSavedConnections)
          .accessibilityIdentifier("agents-overview-button")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: onAddProject) {
            Image(systemName: "plus")
          }
          .disabled(model.connectionState != .connected)
          .accessibilityLabel("Add project")
          .accessibilityIdentifier("add-project-button")
        }
      }
    #endif
  }
}

private struct ProjectDirectoryPickerView: View {
  private enum NavigationChange {
    case reset
    case push
    case pop
    case keep
  }

  @Bindable var model: OesapModel
  var onAdded: (String) -> Void

  @State private var pathStack: [String] = []
  @State private var entries: [RemoteDirectoryEntry] = []
  @State private var loading = false
  @State private var adding = false
  @State private var error: String?

  private var currentPath: String? { pathStack.last }
  private var sortedEntries: [RemoteDirectoryEntry] {
    entries.sorted { lhs, rhs in
      if lhs.kind != rhs.kind { return lhs.kind == .directory }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  var body: some View {
    List {
      if let currentPath {
        Section {
          if pathStack.count > 1 {
            Text(currentPath)
              .font(.footnote.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .lineLimit(2)
            Button {
              let parent = pathStack[pathStack.count - 2]
              Task { await browse(to: parent, change: .pop) }
            } label: {
              Label("Back", systemImage: "arrow.up")
            }
            .disabled(loading)
          } else {
            Label("Home", systemImage: "house")
              .foregroundStyle(.secondary)
          }
        }
      }

      if let error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
          Button("Try again") { Task { await browse(to: currentPath, change: .keep) } }
            .disabled(loading)
        }
      }

      if loading {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading folders…").foregroundStyle(.secondary)
          }
        }
      } else if sortedEntries.isEmpty && error == nil {
        ContentUnavailableView(
          "This folder is empty",
          systemImage: "folder",
          description: Text("Browse to a folder on the Paseo host, then add it as a project.")
        )
        .listRowSeparator(.hidden)
      } else {
        Section(pathStack.count == 1 ? "Home" : "Contents") {
          ForEach(sortedEntries) { entry in
            if entry.kind == .directory {
              Button {
                Task { await browse(to: entry.path, change: .push) }
              } label: {
                DirectoryEntryRow(entry: entry, isNavigable: true)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("directory-\(entry.id)")
              .disabled(loading || adding)
            } else {
              DirectoryEntryRow(entry: entry, isNavigable: false)
                .accessibilityIdentifier("file-\(entry.id)")
            }
          }
        }
      }
    }
    .navigationTitle(
      currentPath.map { pathStack.count == 1 ? "Home" : Self.pathName($0) } ?? "Home"
    )
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      if let currentPath {
        Button {
          Task { await addCurrentFolder(currentPath) }
        } label: {
          HStack {
            if adding { ProgressView().padding(.trailing, 4) }
            Label(adding ? "Adding project…" : "Add this folder", systemImage: "plus")
              .frame(maxWidth: .infinity)
          }
          .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(adding || loading || model.connectionState != .connected)
        .accessibilityIdentifier("register-project-button")
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
      }
    }
    .task { await browse(to: "~", change: .reset) }
  }

  private func browse(to path: String?, change: NavigationChange) async {
    guard !loading, !adding else { return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let result = try await model.directoryEntries(cwd: path)
      entries = result.map { entry in
        RemoteDirectoryEntry(
          path: Self.path(entry.path, relativeTo: path), kind: entry.kind)
      }
      switch change {
      case .reset:
        pathStack = path.map { [$0] } ?? []
      case .push:
        if let path {
          pathStack.append(path)
        }
      case .pop:
        if !pathStack.isEmpty { pathStack.removeLast() }
      case .keep:
        break
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func addCurrentFolder(_ path: String) async {
    guard !adding else { return }
    adding = true
    error = nil
    defer { adding = false }
    do {
      let projectID = try await model.addProject(path: path)
      onAdded(projectID)
    } catch {
      self.error = error.localizedDescription
    }
  }

  private static func pathName(_ path: String) -> String {
    path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
  }

  private static func path(_ entryPath: String, relativeTo directory: String?) -> String {
    guard let directory, !entryPath.hasPrefix("/"), !entryPath.hasPrefix("\\"),
      !(entryPath.count >= 2 && entryPath[entryPath.index(after: entryPath.startIndex)] == ":")
    else { return entryPath }

    let separator = directory.contains("\\") ? "\\" : "/"
    return directory.hasSuffix("/") || directory.hasSuffix("\\")
      ? directory + entryPath
      : directory + separator + entryPath
  }
}

private struct DirectoryEntryRow: View {
  let entry: RemoteDirectoryEntry
  let isNavigable: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: entry.kind == .directory ? "folder.fill" : "doc")
        .foregroundStyle(entry.kind == .directory ? Color.accentColor : Color.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)
      Text(entry.name)
        .foregroundStyle(entry.kind == .directory ? .primary : .secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      if isNavigable {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
    .padding(.vertical, 4)
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

      if let error = model.workspaceError, model.connectionState == .connected {
        Section {
          ConnectionErrorNotice(message: error, identifier: "workspace-error")
          Button("Reconnect") { Task { await model.reconnect() } }
            .disabled(model.connectionState.isBusy)
        }
      }

      if !model.loadingProjects && !model.projects.contains(where: { $0.id == projectID }) {
        ContentUnavailableView(
          "Workspace unavailable",
          systemImage: "archivebox",
          description: Text(
            "This workspace is no longer available on this host. It may have been archived."
          )
        )
      } else if model.selectedProjectID != projectID || model.loadingThreads {
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
              "This Paseo host can’t start threads from Agent Slinger yet. Update Paseo on the host to enable new threads."
            )
          )
          .accessibilityIdentifier("empty-threads-unsupported")
          .listRowSeparator(.hidden)
        } else {
          ContentUnavailableView {
            Label("No agent threads", systemImage: "bubble.left.and.bubble.right")
          } description: {
            Text("Start a new thread in Agent Slinger to begin working with an agent on this project.")
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
              .disabled(model.connectionState.isBusy)
              .accessibilityIdentifier("thread-\(thread.id)")
              .contextMenu { threadContextMenu(for: thread) }
            } else {
              Button {
                onOpenThread(thread)
              } label: {
                ThreadRow(thread: thread)
              }
              .buttonStyle(.plain)
              .disabled(model.connectionState.isBusy)
              .accessibilityIdentifier("thread-\(thread.id)")
              .contextMenu { threadContextMenu(for: thread) }
            }
          }
        } header: {
          Text("Agent threads").foregroundStyle(Color.primary.opacity(0.75))
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if model.selectedProjectID == projectID,
        !model.loadingThreads,
        model.threads.isEmpty,
        model.workspaceError == nil,
        model.connectionState == .connected,
        model.canCreateThreads
      {
        Button(action: onNewThread) {
          Label("New thread", systemImage: "plus")
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("empty-threads-new-thread-button")
        .padding(.horizontal)
        .padding(.vertical, 10)
      }
    }
    .navigationTitle(model.projects.first { $0.id == projectID }?.name ?? "Threads")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button(action: onOpenAgent) {
          Image(systemName: "person.crop.circle")
        }
        .disabled(model.connectionState.isBusy)
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
      if model.projects.contains(where: { $0.id == projectID }),
        model.selectedProjectID != projectID
      {
        await model.selectProject(projectID)
      } else if model.projects.contains(where: { $0.id == projectID }),
        model.threads.isEmpty && !model.loadingThreads
      {
        await model.refreshThreads(projectID: projectID)
      }
    }
  }

  @ViewBuilder
  private func threadContextMenu(for thread: RemoteThread) -> some View {
    Button {
      Task { await model.markThreadRead(thread.id) }
    } label: {
      Label("Mark as Read", systemImage: "envelope.open")
    }
    .disabled(!thread.requiresAttention || model.connectionState != .connected)

    Button(role: .destructive) {
      Task { await model.archiveThread(thread.id) }
    } label: {
      Label("Archive Thread", systemImage: "archivebox")
    }
    .disabled(model.connectionState != .connected)
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

  private var connectionDetails: String? { model.workspaceError ?? model.connectError }

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
          if let connectionDetails {
            HStack(alignment: .top, spacing: 9) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding(.top, 2)
              VStack(alignment: .leading, spacing: 8) {
                Text(connectionDetails)
                  .font(.footnote)
                  .foregroundStyle(.primary)
                  .fixedSize(horizontal: false, vertical: true)
                  .textSelection(.enabled)
                Button("Copy details", systemImage: "doc.on.doc") {
                  UIPasteboard.general.string = connectionDetails
                }
                .buttonStyle(.borderless)
              }
            }
            .padding(.top, 5)
            Divider().padding(.top, 3)
          }
          Button("Reconnect") { Task { await model.reconnect() } }
            .disabled(model.connectionState.isBusy || model.activeInstanceID == nil)
            .padding(.top, 3)
        }
      }
      .padding(.vertical, 4)
    }
  }
}
