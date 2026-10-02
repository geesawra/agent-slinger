import SwiftUI

struct SubagentViewerSheet: View {
  @Bindable var model: OesapModel
  let parentID: String

  @Environment(\.dismiss) private var dismiss
  @State private var archiveTarget: RemoteThread?
  @State private var archiveError: String?
  @State private var hiddenProviderSubagentIDs: Set<String> = []

  private var managedSubagents: [RemoteThread] {
    model.agentOverviewGroups.flatMap(\.threads)
      .filter { $0.parentAgentID == parentID }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  private var providerSubagents: [RemoteProviderSubagent] {
    (model.providerSubagentsByParent[parentID] ?? [])
      .filter { $0.parentSubagentID == nil && !hiddenProviderSubagentIDs.contains($0.id) }
      .sorted {
        $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
      }
  }

  private var loadingSubagents: Bool {
    model.loadingAgentOverview || model.loadingProviderSubagentParents.contains(parentID)
  }

  var body: some View {
    NavigationStack {
      List {
        if loadingSubagents && managedSubagents.isEmpty && providerSubagents.isEmpty {
          HStack(spacing: 10) {
            ProgressView()
            Text("Loading subagents…").foregroundStyle(.secondary)
          }
        } else if managedSubagents.isEmpty && providerSubagents.isEmpty,
          let error = model.providerSubagentErrors[parentID]
            ?? (model.agentOverviewGroups.isEmpty ? model.agentOverviewError : nil)
        {
          ContentUnavailableView(
            "Subagents unavailable", systemImage: "person.2.slash",
            description: Text("\(error)\nPull down to refresh to try again."))
        } else if managedSubagents.isEmpty && providerSubagents.isEmpty {
          ContentUnavailableView(
            "No subagents", systemImage: "person.2",
            description: Text("Subagents created by this agent will appear here."))
        } else {
          if let error = model.agentOverviewError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
          if let error = model.providerSubagentErrors[parentID] {
            VStack(alignment: .leading, spacing: 6) {
              Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
              Text("Pull down to refresh.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          ForEach(managedSubagents) { agent in
            NavigationLink {
              SubagentConversationView(model: model, agent: agent)
            } label: {
              SubagentRow(agent: agent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                archiveTarget = agent
              } label: {
                Label("Archive", systemImage: "archivebox")
              }
              .accessibilityIdentifier("archive-subagent-\(agent.id)")
            }
          }
          ForEach(providerSubagents) { agent in
            NavigationLink {
              ProviderSubagentConversationView(model: model, agent: agent)
            } label: {
              ProviderSubagentRow(agent: agent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              if agent.status != .running {
                Button {
                  hiddenProviderSubagentIDs.insert(agent.id)
                } label: {
                  Label("Hide", systemImage: "archivebox")
                }
                .tint(.secondary)
                .accessibilityIdentifier("hide-provider-subagent-\(agent.id)")
              }
            }
            .accessibilityIdentifier("provider-subagent-\(agent.id)")
          }
        }
      }
      .navigationTitle("Subagents")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
      }
      .task { await refreshAllSubagents() }
      .refreshable { await refreshAllSubagents() }
      .confirmationDialog(
        "Archive subagent?",
        isPresented: Binding(
          get: { archiveTarget != nil }, set: { if !$0 { archiveTarget = nil } }
        ), titleVisibility: .visible, presenting: archiveTarget
      ) { agent in
        Button("Archive", role: .destructive) {
          Task {
            do {
              try await model.archiveSubagent(agent.id)
            } catch {
              archiveError = error.localizedDescription
            }
            archiveTarget = nil
          }
        }
        Button("Cancel", role: .cancel) { archiveTarget = nil }
      } message: { agent in
        Text(
          "Archive \(agent.title)? This removes it from the active agent list on this Paseo host.")
      }
      .alert(
        "Couldn’t archive subagent",
        isPresented: Binding(
          get: { archiveError != nil }, set: { if !$0 { archiveError = nil } }
        )
      ) {
        Button("OK", role: .cancel) { archiveError = nil }
      } message: {
        Text(archiveError ?? "Try again.")
      }
    }
    .presentationDetents([.large])
    .presentationContentInteraction(.scrolls)
    .interactiveDismissDisabled()
  }

  private func refreshSubagents() {
    Task { await refreshAllSubagents() }
  }

  private func refreshAllSubagents() async {
    async let overview: Void = model.refreshAgentOverview()
    async let provider: Void = model.refreshProviderSubagents(parentAgentID: parentID)
    _ = await (overview, provider)
  }
}

private struct ProviderSubagentRow: View {
  let agent: RemoteProviderSubagent

  private var statusLabel: String {
    switch agent.status {
    case .running: "Running"
    case .completed: "Completed"
    case .failed: "Failed"
    case .canceled: "Canceled"
    }
  }

  private var statusSymbol: String {
    switch agent.status {
    case .running: "play.circle.fill"
    case .completed: "checkmark.circle"
    case .failed: "exclamationmark.circle.fill"
    case .canceled: "xmark.circle"
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: statusSymbol)
        .foregroundStyle(agent.status == .failed ? Color.red : Color.accentColor)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text(agent.displayTitle).font(.body.weight(.medium)).lineLimit(2)
        Text(agent.subtitle ?? "\(agent.provider) · \(statusLabel)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        if let description = agent.description, !description.isEmpty {
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier("provider-subagent-row-\(agent.id)")
  }
}

private struct SubagentRow: View {
  let agent: RemoteThread

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: agent.state.symbol)
        .foregroundStyle(agent.state == .failed ? Color.red : Color.accentColor)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text(agent.title).font(.body.weight(.medium)).lineLimit(2)
        Text(agent.state.label)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if let reason = agent.attentionReason, agent.requiresAttention {
          Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier("subagent-row-\(agent.id)")
  }
}

private struct ProviderSubagentConversationView: View {
  @Bindable var model: OesapModel
  let agent: RemoteProviderSubagent

  @State private var messages: [RemoteMessage] = []
  @State private var loading = true
  @State private var error: String?
  @State private var expandedToolIDs: Set<String> = []

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          Label {
            Text("Read-only provider subagent · \(agent.provider) · \(statusLabel)")
              .foregroundStyle(.secondary)
          } icon: {
            Image(systemName: "person.2")
          }
          .font(.footnote)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.top, 14)

          if let description = agent.description, !description.isEmpty {
            Text(description)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 14)
          }

          if loading && messages.isEmpty {
            ProgressView("Loading conversation…")
              .frame(maxWidth: .infinity, minHeight: 150)
          }
          if let error {
            ContentUnavailableView(
              "Timeline unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
            Button("Retry") { Task { await loadHistory() } }
              .frame(maxWidth: .infinity)
          }
          if !loading && error == nil && messages.isEmpty {
            ContentUnavailableView("No conversation yet", systemImage: "text.bubble")
          }

          ForEach(messages) { message in
            if let call = message.toolCall {
              ToolCallCard(
                call: call,
                rowID: message.id,
                isExpanded: Binding(
                  get: { expandedToolIDs.contains(message.id) },
                  set: { expanded in
                    if expanded {
                      expandedToolIDs.insert(message.id)
                    } else {
                      expandedToolIDs.remove(message.id)
                    }
                  }
                )
              )
              .id(message.id)
              .padding(.horizontal, 14)
            } else {
              MessageBubble(
                message: message,
                threadID: agent.parentAgentID,
                timelineGeneration: model.timelineGeneration,
                loadRemoteImage: { source, threadID in
                  try await model.loadRemoteImage(source: source, threadID: threadID)
                }
              )
              .id(message.id)
            }
          }
        }
        .padding(.bottom, 16)
      }
      .onChange(of: messages.count) { _, _ in
        guard let lastID = messages.last?.id else { return }
        proxy.scrollTo(lastID, anchor: .bottom)
      }
    }
    .navigationTitle(agent.displayTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await loadHistory() }
        } label: {
          if loading {
            ProgressView()
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .disabled(loading)
        .accessibilityLabel("Refresh provider subagent timeline")
      }
    }
    .task { await loadHistory() }
  }

  private var statusLabel: String {
    switch agent.status {
    case .running: "Running"
    case .completed: "Completed"
    case .failed: "Failed"
    case .canceled: "Canceled"
    }
  }

  @MainActor
  private func loadHistory() async {
    loading = true
    error = nil
    defer { loading = false }
    do {
      let timeline = try await model.loadProviderSubagentHistory(
        parentAgentID: agent.parentAgentID, subagentID: agent.id)
      messages = timeline.messages
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct SubagentConversationView: View {
  @Bindable var model: OesapModel
  let agent: RemoteThread

  @State private var messages: [RemoteMessage] = []
  @State private var loading = true
  @State private var error: String?
  @State private var expandedToolIDs: Set<String> = []

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if loading && messages.isEmpty {
            ProgressView("Loading conversation…")
              .frame(maxWidth: .infinity, minHeight: 150)
          }
          if let error {
            ContentUnavailableView(
              "Timeline unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
          }
          ForEach(messages) { message in
            if let call = message.toolCall {
              ToolCallCard(
                call: call, rowID: message.id,
                isExpanded: Binding(
                  get: { expandedToolIDs.contains(message.id) },
                  set: { expanded in
                    if expanded {
                      expandedToolIDs.insert(message.id)
                    } else {
                      expandedToolIDs.remove(message.id)
                    }
                  })
              )
              .id(message.id)
            } else if !message.isThinkingTrace {
              MessageBubble(
                message: message, threadID: agent.id, timelineGeneration: 0,
                loadRemoteImage: { source, id in
                  try await model.loadSubagentImage(source: source, agentID: id)
                }
              )
              .equatable()
              .id(message.id)
            }
          }
          Color.clear.frame(height: 1).id("subagent-bottom")
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
      }
      .defaultScrollAnchor(.bottom)
      .navigationTitle(agent.title)
      .navigationBarTitleDisplayMode(.inline)
      .task(id: agent.id) {
        await followTimeline(proxy)
      }
    }
  }

  @MainActor
  private func followTimeline(_ proxy: ScrollViewProxy) async {
    do {
      let updates = try await model.subagentEvents(agent.id)
      let history = try await model.subagentHistory(agent.id)
      messages = history.messages
      loading = false
      proxy.scrollTo("subagent-bottom", anchor: .bottom)
      for try await update in updates {
        switch update {
        case .message(let message, _, let isDelta):
          if let index = messages.firstIndex(where: { $0.id == message.id }) {
            if isDelta {
              messages[index].text += message.text
              messages[index].toolCall = message.toolCall ?? messages[index].toolCall
            } else {
              messages[index] = message
            }
          } else {
            messages.append(message)
          }
          proxy.scrollTo("subagent-bottom", anchor: .bottom)
        case .historyChanged:
          messages = try await model.subagentHistory(agent.id).messages
          proxy.scrollTo("subagent-bottom", anchor: .bottom)
        case .threadState, .contextUsage, .contextUsageNeedsRefresh, .tasks,
          .permissionRequested, .permissionResolved:
          break
        }
      }
    } catch is CancellationError {
      return
    } catch {
      self.error = error.localizedDescription
    }
    loading = false
  }
}
