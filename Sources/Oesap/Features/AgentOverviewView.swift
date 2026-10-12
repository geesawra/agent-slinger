import SwiftUI

struct AgentOverviewView: View {
  @Bindable var model: OesapModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var onOpenThread: (String) -> Void

  @State private var filter = AgentOverviewFilter.active
  @State private var openTask: Task<Void, Never>?

  private var hosts: [RemoteAgentOverviewHost] { model.agentOverviewHosts }
  private var allThreads: [RemoteThread] { hosts.flatMap { $0.groups.flatMap(\.threads) } }
  private var hasProjectErrors: Bool {
    hosts.contains { $0.groups.contains { $0.error != nil } }
  }
  private var hasUnavailableStates: Bool {
    hosts.contains { $0.isStale || $0.error != nil }
      || (model.agentOverviewScope == .allHosts && model.allHostAgentOverviewError != nil)
  }
  private var isLoading: Bool {
    model.agentOverviewScope == .allHosts
      ? model.loadingAllHostAgentOverview || model.loadingAgentOverview : model.loadingAgentOverview
  }

  private var counts: (running: Int, attention: Int, errors: Int) {
    var running = 0
    var attention = 0
    var errors = 0
    for thread in allThreads {
      if thread.state == .running { running += 1 }
      if thread.state == .failed { errors += 1 }
      if thread.needsAttention { attention += 1 }
    }
    return (running, attention, errors)
  }

  var body: some View {
    List {
      overviewSummary

      if let error = model.allHostAgentOverviewError, model.agentOverviewScope == .allHosts {
        Section { Label(error, systemImage: "exclamationmark.triangle.fill") }
      }
      if hasUnavailableStates {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Label(
              hasProjectErrors
                ? "Some project states are unavailable" : "Some server states are unavailable",
              systemImage: "exclamationmark.triangle.fill")
            Text(
              "Counts include last-known states. Unavailable servers or projects may be missing. Pull down to refresh."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
        }
      }

      if allThreads.filter(filter.includes).isEmpty && !isLoading && !hasUnavailableStates {
        Section {
          ContentUnavailableView(
            filter == .active ? "No active agents" : "No agents in these projects",
            systemImage: filter == .active ? "checkmark.circle" : "cpu",
            description: Text(
              filter == .active
                ? "Switch to All to include idle agents."
                : "Agents discovered on your Paseo servers will appear here.")
          )
          .listRowSeparator(.hidden)
        }
      }

      ForEach(hosts) { host in
        Section {
          if host.isLoading {
            HStack(spacing: 12) {
              ProgressView()
              Text("Refreshing agents…").foregroundStyle(.secondary)
            }
          }
          if let error = host.error, !host.groups.contains(where: { $0.error != nil }) {
            Label(error, systemImage: "wifi.exclamationmark")
              .accessibilityIdentifier("overview-server-error-\(host.id)")
          }
          ForEach(host.groups.filter { $0.error != nil }) { group in
            VStack(alignment: .leading, spacing: 4) {
              Text(verbatim: group.project.name).font(.subheadline.weight(.semibold))
              if let error = group.error {
                Label {
                  Text(verbatim: error)
                    .accessibilityIdentifier("overview-project-error-\(group.project.id)")
                } icon: {
                  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.subheadline)
              }
            }
          }
          ForEach(host.entries.filter { filter.includes($0.thread) }) { entry in
            Button {
              openTask = Task { await open(entry, on: host) }
            } label: {
              AgentOverviewRow(thread: entry.thread, projectName: entry.project.name)
            }
            .buttonStyle(.plain)
            .disabled(model.openingOverviewAgent || model.connectionState.isBusy)
            .accessibilityIdentifier(
              model.savedInstances.count > 1
                ? "overview-agent-\(host.id)-\(entry.thread.id)"
                : "overview-agent-\(entry.thread.id)"
            )
            .transition(.opacity)
          }
          if host.entries.filter({ filter.includes($0.thread) }).isEmpty,
            !host.isLoading, !host.isStale, host.error == nil
          {
            Text(filter == .active ? "No active agents on this server" : "No agents on this server")
              .foregroundStyle(.secondary)
          }
        } header: {
          Text(verbatim: host.instance.name)
            .textCase(nil)
            .accessibilityIdentifier("overview-server-\(host.id)")
        } footer: {
          if let updatedAt = host.updatedAt {
            Text(
              "\(host.isStale ? "Last known snapshot" : "Snapshot updated") \(updatedAt.formatted(date: .omitted, time: .shortened))"
            )
          } else if !host.isLoading {
            Text("No snapshot available")
          }
        }
      }

      if let error = model.overviewNavigationError {
        Section { Label(error, systemImage: "exclamationmark.triangle.fill") }
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hosts.map(\.id))
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 0.2),
      value: hosts.map { $0.entries.filter { filter.includes($0.thread) }.map(\.id) }
    )
    .navigationTitle("Agents")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await model.refreshVisibleAgentOverview() }
    .task { await model.beginAgentOverview() }
    .onDisappear {
      openTask?.cancel()
      model.endAgentOverview()
    }
    .onChange(of: model.agentOverviewScope) { _, _ in
      Task { await model.refreshVisibleAgentOverview() }
    }
    .onChange(of: model.timelineGeneration) { _, _ in
      guard !model.openingOverviewAgent else { return }
      Task { await model.refreshVisibleAgentOverview() }
    }
  }

  private var overviewSummary: some View {
    Section {
      if model.savedInstances.count > 1 {
        Picker("Server scope", selection: $model.agentOverviewScope) {
          ForEach(AgentOverviewScope.allCases) { scope in Text(scope.title).tag(scope) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("agent-overview-scope")
      }
      Picker("Agent filter", selection: $filter) {
        ForEach(AgentOverviewFilter.allCases) { option in Text(option.title).tag(option) }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("agent-overview-filter")

      let errorLabel = counts.errors == 1 ? "error" : "errors"
      Text(
        "\(counts.running) running · \(counts.attention) need attention · \(counts.errors) \(errorLabel)"
      )
      .font(.subheadline.weight(.medium))
      .accessibilityIdentifier("agent-overview-summary")
      Text(
        isLoading ? "Counts include results loaded so far." : "Snapshot status · pull to refresh"
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      if model.openingOverviewAgent {
        ProgressView("Opening agent…")
      }
    }
  }

  private func open(_ entry: RemoteAgentOverviewEntry, on host: RemoteAgentOverviewHost) async {
    let opened: Bool
    if host.id == "current-host" {
      opened = model.openAgent(projectID: entry.project.id, threadID: entry.thread.id)
    } else {
      opened = await model.openOverviewAgent(
        instanceID: host.id, projectID: entry.project.id, threadID: entry.thread.id)
    }
    if opened && !Task.isCancelled { onOpenThread(entry.thread.id) }
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
  let projectName: String

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
          projectLabel
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
            projectLabel
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

  private var projectLabel: some View {
    Text(verbatim: projectName)
      .font(.subheadline)
      .foregroundStyle(.secondary)
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
