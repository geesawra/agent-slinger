import SwiftUI

struct SubagentViewerSheet: View {
  @Bindable var model: OesapModel
  let parentID: String

  @Environment(\.dismiss) private var dismiss
  @State private var archiveTarget: RemoteThread?
  @State private var archiveError: String?

  private var subagents: [RemoteThread] {
    model.agentOverviewGroups.flatMap(\.threads)
      .filter { $0.parentAgentID == parentID }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  var body: some View {
    NavigationStack {
      List {
        if model.loadingAgentOverview && model.agentOverviewGroups.isEmpty {
          HStack(spacing: 10) {
            ProgressView()
            Text("Loading subagents…").foregroundStyle(.secondary)
          }
        } else if let error = model.agentOverviewError, model.agentOverviewGroups.isEmpty {
          ContentUnavailableView(
            "Subagents unavailable", systemImage: "person.2.slash", description: Text(error))
          Button("Retry") { Task { await model.refreshAgentOverview() } }
        } else if subagents.isEmpty {
          ContentUnavailableView(
            "No subagents", systemImage: "person.2",
            description: Text("Subagents created by this agent will appear here."))
        } else {
          if let error = model.agentOverviewError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
          ForEach(subagents) { agent in
            HStack(spacing: 8) {
              NavigationLink {
                SubagentConversationView(model: model, agent: agent)
              } label: {
                SubagentRow(agent: agent)
              }
              Button {
                archiveTarget = agent
              } label: {
                Image(systemName: "archivebox")
                  .frame(width: 44, height: 44)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("Archive \(agent.title)")
              .accessibilityIdentifier("archive-subagent-\(agent.id)")
            }
          }
        }
      }
      .navigationTitle("Subagents")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await model.refreshAgentOverview() }
          } label: {
            if model.loadingAgentOverview {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .disabled(model.loadingAgentOverview)
          .accessibilityLabel("Refresh subagents")
        }
      }
      .task { await model.refreshAgentOverview() }
      .refreshable { await model.refreshAgentOverview() }
      .confirmationDialog(
        "Archive subagent?", isPresented: Binding(
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
        Text("Archive \(agent.title)? This removes it from the active agent list on this Paseo host.")
      }
      .alert("Couldn’t archive subagent", isPresented: Binding(
        get: { archiveError != nil }, set: { if !$0 { archiveError = nil } }
      )) {
        Button("OK", role: .cancel) { archiveError = nil }
      } message: {
        Text(archiveError ?? "Try again.")
      }
    }
    .presentationDetents([.large])
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
            ContentUnavailableView("Timeline unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
          }
          ForEach(messages) { message in
            if let call = message.toolCall {
              ToolCallCard(
                call: call, rowID: message.id,
                isExpanded: Binding(
                  get: { expandedToolIDs.contains(message.id) },
                  set: { expanded in
                    if expanded { expandedToolIDs.insert(message.id) }
                    else { expandedToolIDs.remove(message.id) }
                  }))
                .id(message.id)
            } else if !message.isThinkingTrace {
              MessageBubble(
                message: message, threadID: agent.id, timelineGeneration: 0,
                loadRemoteImage: { source, id in
                  try await model.loadSubagentImage(source: source, agentID: id)
                })
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
        case .threadState, .contextUsage, .contextUsageNeedsRefresh,
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
