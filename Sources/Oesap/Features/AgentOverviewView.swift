import SwiftUI

struct AgentOverviewView: View {
  @Bindable var model: OesapModel
  var onOpenThread: (String) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var filter = AgentOverviewFilter.active
  @State private var navigationError: String?

  private var allThreads: [RemoteThread] {
    model.agentOverviewGroups.flatMap(\.threads)
  }

  private var visibleThreadCount: Int {
    model.agentOverviewGroups.reduce(0) { count, group in
      count + group.threads.filter(filter.includes).count
    }
  }

  private var hasProjectErrors: Bool {
    model.agentOverviewGroups.contains { $0.error != nil }
  }

  private var counts: (running: Int, attention: Int, errors: Int) {
    var running = 0
    var attention = 0
    var errors = 0
    for thread in allThreads {
      if thread.state == .running { running += 1 }
      if thread.state == .failed { errors += 1 }
      if thread.requiresAttention || thread.state == .waiting { attention += 1 }
    }
    return (running, attention, errors)
  }

  var body: some View {
    List {
      overviewSummary

      if model.connectionState != .connected {
        offlineStatus
      } else if model.agentOverviewError != nil || model.agentOverviewIsStale || hasProjectErrors {
        refreshStatus
      }

      if model.loadingAgentOverview && model.agentOverviewGroups.isEmpty {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading agents…")
              .foregroundStyle(.secondary)
          }
        }
      } else if model.agentOverviewGroups.isEmpty {
        if model.agentOverviewError == nil {
          Section {
            ContentUnavailableView(
              "No agents found",
              systemImage: "cpu",
              description: Text("Agents discovered on this Paseo host will appear here.")
            )
            .listRowSeparator(.hidden)
          }
        }
      } else {
        if visibleThreadCount == 0 {
          Section {
            ContentUnavailableView(
              emptyTitle,
              systemImage: filter == .active ? "checkmark.circle" : "cpu",
              description: Text(emptyDescription)
            )
            .listRowSeparator(.hidden)
          }
        }

        ForEach(model.agentOverviewGroups) { group in
          let threads = group.threads.filter(filter.includes)
          if !threads.isEmpty || group.error != nil {
            Section(group.project.name) {
              if let error = group.error {
                Label {
                  Text(verbatim: error)
                    .accessibilityIdentifier("overview-project-error-\(group.project.id)")
                } icon: {
                  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.subheadline)
              }
              ForEach(threads) { thread in
                Button {
                  open(thread, in: group)
                } label: {
                  AgentOverviewRow(thread: thread)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overview-agent-\(thread.id)")
              }
            }
          }
        }
      }

      if let navigationError {
        Section {
          Label {
            Text(navigationError).foregroundStyle(.primary)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
          }
          Button("Refresh overview") { Task { await model.refreshAgentOverview() } }
        }
      }
    }
    .navigationTitle("Agents")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
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
        .accessibilityLabel("Refresh agents")
        .accessibilityIdentifier("refresh-agent-overview")
      }
    }
    .refreshable { await model.refreshAgentOverview() }
    .onAppear { Task { await model.refreshAgentOverview() } }
    .onChange(of: model.timelineGeneration) { _, _ in
      guard model.connectionState == .connected else { return }
      Task { await model.refreshAgentOverview() }
    }
  }

  private var overviewSummary: some View {
    Section {
      Picker("Agent filter", selection: $filter) {
        ForEach(AgentOverviewFilter.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("agent-overview-filter")

      let errorLabel = counts.errors == 1 ? "error" : "errors"
      Text(
        "\(counts.running) running · \(counts.attention) need attention · \(counts.errors) \(errorLabel)"
      )
      .font(.subheadline.weight(.medium))
      .accessibilityIdentifier("agent-overview-summary")

      if let updatedAt = model.agentOverviewUpdatedAt {
        Text("Snapshot updated \(updatedAt.formatted(date: .omitted, time: .shortened))")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        Text("Snapshot status · pull to refresh")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

    }
  }

  private var refreshStatus: some View {
    Section {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          refreshStatusDetails
          retryAgentOverviewButton(expanded: true)
        }
      } else {
        HStack(alignment: .top, spacing: 10) {
          refreshStatusDetails
          Spacer(minLength: 4)
          retryAgentOverviewButton(expanded: false)
        }
      }
    }
  }

  private var refreshStatusDetails: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .padding(.top, 2)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(
          hasProjectErrors ? "Some project states are unavailable" : "Agent status is unavailable"
        )
        .font(.subheadline.weight(.semibold))
        Text(refreshStatusDescription)
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
      }
    }
  }

  private func retryAgentOverviewButton(expanded: Bool) -> some View {
    Button {
      Task { await model.refreshAgentOverview() }
    } label: {
      Text("Retry")
        .frame(minWidth: 44, maxWidth: expanded ? .infinity : nil, minHeight: 44)
        .contentShape(Rectangle())
    }
    .font(.subheadline.weight(.medium))
    .disabled(model.loadingAgentOverview)
    .accessibilityIdentifier("retry-agent-overview")
  }

  private var refreshStatusDescription: String {
    if hasProjectErrors {
      return "Showing last-known rows; counts include loaded project results."
    }
    return model.agentOverviewError ?? "Pull to refresh to load current agent status."
  }

  private var offlineStatus: some View {
    Section {
      Label {
        Text("Host disconnected").foregroundStyle(.primary)
      } icon: {
        Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
      }
      .font(.headline)
      Text(
        model.agentOverviewGroups.isEmpty
          ? "Reconnect to load agent status for this host."
          : "Showing last known agent states. Reconnect to refresh this overview."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      Button("Reconnect") { Task { await model.reconnect() } }
        .disabled(model.connectionState.isBusy || !model.hasSavedConnection)
    }
  }

  private var emptyTitle: String {
    if model.agentOverviewError != nil || hasProjectErrors { return "Agent status unavailable" }
    if filter == .active { return "No active agents" }
    return "No agents in these projects"
  }

  private var emptyDescription: String {
    if model.agentOverviewError != nil || hasProjectErrors {
      return "Some project states could not be loaded. Review the errors above or below."
    }
    if filter == .active {
      return "Switch to All to include idle agents."
    }
    return "Agents discovered on this Paseo host will appear here."
  }

  private func open(_ thread: RemoteThread, in group: RemoteAgentOverviewGroup) {
    guard model.openAgent(projectID: group.project.id, threadID: thread.id) else {
      navigationError = "This agent is no longer available in the overview. Refresh and try again."
      return
    }
    navigationError = nil
    onOpenThread(thread.id)
  }
}

private enum AgentOverviewFilter: String, CaseIterable, Identifiable {
  case active
  case all

  var id: Self { self }

  var title: String {
    switch self {
    case .active: "Active"
    case .all: "All"
    }
  }

  func includes(_ thread: RemoteThread) -> Bool {
    guard self == .active else { return true }
    return switch thread.state {
    case .initializing, .running, .waiting, .failed:
      true
    case .idle, .closed, .unknown:
      thread.requiresAttention
    }
  }
}

private struct AgentOverviewRow: View {
  let thread: RemoteThread

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var stateLabel: String {
    if thread.state == .failed { return "Failed" }
    if thread.requiresAttention || thread.state == .waiting { return "Needs attention" }
    return thread.state.label
  }

  private var stateSymbol: String {
    if thread.state == .failed { return "exclamationmark.circle.fill" }
    if thread.requiresAttention || thread.state == .waiting { return "hand.raised.circle.fill" }
    return thread.state.symbol
  }

  private var stateColor: Color {
    if thread.state == .failed { return .red }
    if thread.requiresAttention || thread.state == .waiting { return .orange }
    if thread.state == .running || thread.state == .initializing { return .accentColor }
    return Color(uiColor: .secondaryLabel)
  }

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 5) {
          Text(thread.title)
            .font(.headline)
            .foregroundStyle(.primary)
          providerMetadata
          stateInformation
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: stateSymbol)
            .font(.title3)
            .foregroundStyle(stateColor)
            .frame(width: 28)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 5) {
            Text(thread.title)
              .font(.headline)
              .foregroundStyle(.primary)
            providerMetadata
            stateInformation
          }
          Spacer(minLength: 8)
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
            .accessibilityHidden(true)
        }
      }
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var providerMetadata: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 2) {
        if let provider = thread.provider {
          Text(verbatim: provider)
            .foregroundStyle(Color.primary.opacity(0.75))
        }
        if let model = thread.model {
          Text(verbatim: model)
            .foregroundStyle(Color.primary.opacity(0.75))
        }
      }
      .font(.subheadline)
    } else {
      Text(verbatim: metadata)
        .font(.subheadline)
        .foregroundStyle(Color.primary.opacity(0.75))
    }
  }

  private var stateInformation: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: stateSymbol)
          .foregroundStyle(stateColor)
          .accessibilityHidden(true)
        Text(stateLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
      }
      if let reason = thread.attentionReason, thread.requiresAttention {
        Text(verbatim: reason)
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private var metadata: String {
    [thread.provider, thread.model].compactMap { $0 }.joined(separator: " · ")
  }
}
