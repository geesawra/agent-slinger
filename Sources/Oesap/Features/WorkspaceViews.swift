import SwiftUI

enum OesapRoute: Hashable {
  case agentOverview
  case usage
  case project(String)
  case chat(String)
  case newChat(String)
  case agentConfiguration(String)
}

struct WorkspaceRootView: View {
  @Bindable var model: OesapModel
  @State private var path: [OesapRoute] = []
  @State private var confirmsDisconnect = false

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if model.connectionState == .connected || !model.projects.isEmpty
          || model.workspaceError != nil
        {
          ProjectListView(
            model: model,
            onOpenAgentOverview: { path.append(.agentOverview) }
          ) { project in
            Task {
              await model.selectProject(project.id)
              path.append(.project(project.id))
            }
          }
        } else {
          ConnectionSetupView(model: model)
        }
      }
      .toolbar {
        if model.connectionState == .connected || !model.projects.isEmpty
          || model.workspaceError != nil
        {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button("Usage", systemImage: "chart.bar") {
                path.append(.usage)
              }
              .accessibilityIdentifier("host-usage-button")

              Divider()

              Button("Reconnect", systemImage: "arrow.clockwise") {
                Task { await model.reconnect() }
              }
              .disabled(model.connectionState.isBusy)

              Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                confirmsDisconnect = true
              }
            } label: {
              Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Connection options")
            }
            .accessibilityIdentifier("connection-options")
          }
        }
      }
      .navigationDestination(for: OesapRoute.self) { route in
        switch route {
        case .agentOverview:
          AgentOverviewView(model: model) { threadID in
            path.append(.chat(threadID))
          }
        case .usage:
          ProviderUsageView(model: model)
        case .project(let id):
          ThreadListView(
            model: model,
            projectID: id,
            onNewThread: { path.append(.newChat(id)) },
            onOpenAgent: { path.append(.agentConfiguration(id)) }
          ) { thread in
            model.selectThread(thread.id)
            path.append(.chat(thread.id))
          }
        case .chat(let id):
          ChatView(model: model, threadID: id)
        case .newChat(let projectID):
          NewChatView(
            model: model,
            projectID: projectID,
            onOpenAgent: { path.append(.agentConfiguration(projectID)) },
            onCreated: { threadID in
              guard path.last == .newChat(projectID) else { return }
              path.removeLast()
              path.append(.chat(threadID))
            }
          )
        case .agentConfiguration(let projectID):
          AgentConfigurationView(model: model, projectID: projectID)
        }
      }
    }
    .confirmationDialog(
      "Disconnect from this host?", isPresented: $confirmsDisconnect, titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) {
        Task {
          await model.disconnect()
          path.removeAll()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your saved connection and credentials will be removed from this device.")
    }
    .tint(.accentColor)
  }
}

private struct ProjectListView: View {
  @Bindable var model: OesapModel
  var onOpenAgentOverview: () -> Void
  var onOpenProject: (RemoteProject) -> Void

  var body: some View {
    List {
      if model.connectionState != .connected {
        ConnectionStatusRow(model: model)
      }

      if let error = model.workspaceError {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
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
        Section("Projects") {
          ForEach(model.projects) { project in
            Button {
              onOpenProject(project)
            } label: {
              HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                  .font(.title2)
                  .foregroundStyle(.tint)
                  .frame(width: 38, height: 38)
                  .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                  Text(project.name).font(.headline).foregroundStyle(.primary)
                  if let subtitle = project.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                  .font(.footnote.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project-\(project.id)")
          }
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

private struct ThreadListView: View {
  @Bindable var model: OesapModel
  let projectID: String
  var onNewThread: () -> Void
  var onOpenAgent: () -> Void
  var onOpenThread: (RemoteThread) -> Void

  var body: some View {
    List {
      if model.connectionState != .connected {
        ConnectionStatusRow(model: model)
      }

      if let error = model.workspaceError {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Button("Reconnect") { Task { await model.reconnect() } }
            .disabled(model.connectionState.isBusy)
        }
      }

      if model.loadingThreads {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading agent threads…").foregroundStyle(.secondary)
          }
        }
      } else if model.threads.isEmpty && model.workspaceError == nil {
        ContentUnavailableView(
          "No agent threads",
          systemImage: "bubble.left.and.bubble.right",
          description: Text("Start an agent on this project in Paseo to see its thread here.")
        )
        .listRowSeparator(.hidden)
      } else {
        Section("Agent threads") {
          ForEach(model.threads) { thread in
            Button {
              onOpenThread(thread)
            } label: {
              ThreadRow(thread: thread)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("thread-\(thread.id)")
          }
        }
      }
    }
    .navigationTitle(model.selectedProject?.name ?? "Threads")
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

  var body: some View {
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
          if thread.requiresAttention {
            Text("Attention")
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(.orange.opacity(0.14), in: Capsule())
              .foregroundStyle(.orange)
          }
        }
        HStack(spacing: 6) {
          Text(thread.state.label)
          if let provider = thread.provider {
            Text("·")
            Text(provider)
          }
          if let model = thread.model {
            Text("·")
            Text(model)
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        if thread.requiresAttention, let reason = thread.attentionReason {
          Text(reason).font(.footnote).foregroundStyle(.orange)
        }
      }

      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.top, 4)
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
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
          Text("Your open timeline and unsent drafts stay available while you reconnect.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Button("Reconnect") { Task { await model.reconnect() } }
            .disabled(model.connectionState.isBusy || !model.hasSavedConnection)
            .padding(.top, 3)
        }
      }
      .padding(.vertical, 4)
    }
  }
}
