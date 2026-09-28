import SwiftUI
import UIKit

struct NewChatView: View {
  @Bindable var model: OesapModel
  let projectID: String
  var onOpenAgent: () -> Void
  var onCreated: (String) -> Void

  @State private var composerFocused = false
  @State private var hasInitiallyFocusedComposer = false
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  private var draftKey: String { model.newThreadDraftKey(for: projectID) }
  private var configuration: RemoteAgentConfiguration? {
    model.agentConfiguration(for: projectID)
  }
  private var configuredProviderLabel: String {
    guard let configuration else { return "" }
    return model.agentProviders.first(where: { $0.id == configuration.provider })?.label
      ?? configuration.provider
  }
  private var configuredModelLabel: String? {
    guard let configuration, let modelID = configuration.model else { return nil }
    return model.agentModels(for: configuration.provider).first(where: { $0.id == modelID })?
      .label ?? modelID
  }
  private var configuredModeLabel: String {
    guard let configuration else { return "Default permissions" }
    guard let provider = model.agentProviders.first(where: { $0.id == configuration.provider })
    else { return configuration.modeID ?? "Default permissions" }
    guard let modeID = configuration.modeID else {
      return provider.modes.first(where: { $0.id == provider.defaultModeID })?.label
        ?? "Default permissions"
    }
    return provider.modes.first(where: { $0.id == modeID })?.label ?? modeID
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          projectAgentCard

          ContentUnavailableView(
            "New thread",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Write a message below to start an agent on this project.")
          )
          .frame(maxWidth: .infinity, minHeight: 200)
        }
        .padding()
      }

      ChatComposerBar(
        draft: Binding(
          get: { model.draft(for: draftKey) },
          set: { model.setDraft($0, for: draftKey) }
        ),
        images: Binding(
          get: { model.draftImages(for: draftKey) },
          set: { _ = model.setDraftImages($0, for: draftKey) }
        ),
        isSending: model.sendingMessage,
        isConnected: canStartThread,
        error: model.messageError,
        focus: $composerFocused,
        send: sendFirstMessage,
        clearError: model.clearMessageError,
        onShowContextUsage: {
          composerFocused = false
          openAgentSettings()
        },
        imageImportIdentity: "\(draftKey)-\(model.timelineGeneration)"
      )
    }
    .navigationTitle("New thread")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: projectID) {
      await model.refreshAgentOptions(projectID: projectID)
    }
    .onAppear {
      guard !hasInitiallyFocusedComposer else { return }
      hasInitiallyFocusedComposer = true
      Task { @MainActor in
        await Task.yield()
        composerFocused = true
      }
    }
  }

  @ViewBuilder
  private var projectAgentCard: some View {
    if model.connectionState != .connected {
      connectionStatusCard
    } else if !model.canCreateThreads {
      Label {
        VStack(alignment: .leading, spacing: 4) {
          Text("This host can’t start threads from Oesap yet.")
            .font(.subheadline.weight(.semibold))
          Text(
            "Update Paseo on the host to enable new threads. Your draft stays here while the app is open."
          )
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
        }
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
      .accessibilityIdentifier("new-thread-unsupported")
    } else if configuration != nil {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 8) {
            configuredAgentDetails
            editAgentButton(expanded: true)
          }
        } else {
          HStack(alignment: .top, spacing: 12) {
            configuredAgentDetails
            Spacer(minLength: 8)
            editAgentButton(expanded: false)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    } else {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 8) {
            setupAgentDetails
            setupAgentButton(expanded: true)
          }
        } else {
          HStack(alignment: .top, spacing: 12) {
            setupAgentDetails
            Spacer(minLength: 8)
            setupAgentButton(expanded: false)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
  }

  private var connectionStatusCard: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          connectionStatusDetails
          if !model.connectionState.isBusy { reconnectButton(expanded: true) }
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          connectionStatusDetails
          Spacer(minLength: 8)
          if !model.connectionState.isBusy { reconnectButton(expanded: false) }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
  }

  private var configuredAgentDetails: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "cpu")
        .foregroundStyle(.tint)
        .padding(.top, 2)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Project Agent")
          .font(.subheadline.weight(.semibold))
        Text(
          verbatim: configuredModelLabel.map { "\(configuredProviderLabel) · \($0)" }
            ?? "\(configuredProviderLabel) · Provider default"
        )
        .font(.subheadline)
        Text(configuredModeLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("Saved on this device")
          .font(.caption)
          .foregroundStyle(Color.primary.opacity(0.75))
      }
    }
  }

  private var setupAgentDetails: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "person.crop.circle.badge.questionmark")
        .foregroundStyle(.orange)
        .padding(.top, 2)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Set up this project’s Agent")
          .font(.subheadline.weight(.semibold))
        Text("Choose a provider in Project Agent settings before starting a thread.")
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
      }
    }
  }

  private var connectionStatusDetails: some View {
    HStack(alignment: .top, spacing: 12) {
      if model.connectionState.isBusy {
        ProgressView()
          .padding(.top, 2)
          .accessibilityHidden(true)
      } else {
        Image(systemName: "wifi.slash")
          .foregroundStyle(.orange)
          .padding(.top, 2)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(connectionStatusTitle)
          .font(.subheadline.weight(.semibold))
          .accessibilityIdentifier("new-thread-connection-title")
        Text("Your draft stays here while the app is open. Reconnect to start a thread.")
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
      }
    }
  }

  private func editAgentButton(expanded: Bool) -> some View {
    Button(action: openAgentSettings) {
      Text("Edit")
        .frame(minWidth: 44, maxWidth: expanded ? .infinity : nil, minHeight: 44)
        .contentShape(Rectangle())
    }
    .font(.subheadline.weight(.medium))
    .accessibilityIdentifier("new-thread-edit-agent")
  }

  private func setupAgentButton(expanded: Bool) -> some View {
    Button(action: openAgentSettings) {
      Text("Set up")
        .frame(minWidth: 44, maxWidth: expanded ? .infinity : nil, minHeight: 44)
        .contentShape(Rectangle())
    }
    .font(.subheadline.weight(.medium))
    .accessibilityIdentifier("new-thread-setup-agent")
  }

  private func reconnectButton(expanded: Bool) -> some View {
    Button {
      Task { await model.reconnect() }
    } label: {
      Text("Reconnect")
        .frame(minWidth: 44, maxWidth: expanded ? .infinity : nil, minHeight: 44)
        .contentShape(Rectangle())
    }
    .font(.subheadline.weight(.medium))
    .disabled(!model.hasSavedConnection)
    .accessibilityIdentifier("new-thread-reconnect")
  }

  private var connectionStatusTitle: String {
    switch model.connectionState {
    case .connecting:
      "Connecting to host…"
    case .reconnecting:
      "Reconnecting to host…"
    case .connected:
      "Connected to host"
    case .disconnected:
      "Host disconnected"
    }
  }

  private var canStartThread: Bool {
    model.connectionState == .connected && model.canCreateThreads && configuration != nil
  }

  private func sendFirstMessage(_ text: String, images: [RemoteDraftImage]) {
    guard model.setDraftImages(images, for: draftKey) else { return }
    Task {
      guard let threadID = await model.sendFirstMessage(projectID: projectID, text: text) else {
        return
      }
      onCreated(threadID)
    }
  }

  private func openAgentSettings() {
    composerFocused = false
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    onOpenAgent()
  }
}

struct AgentConfigurationView: View {
  @Bindable var model: OesapModel
  let projectID: String

  @Environment(\.dismiss) private var dismiss
  @State private var selectedProviderID: String?
  @State private var selectedModelID: String?
  @State private var selectedModeID: String?
  @State private var saveError: String?

  private var project: RemoteProject? { model.projects.first { $0.id == projectID } }

  var body: some View {
    Form {
      Section {
        Text(project?.name ?? "This project")
          .font(.headline)
        LabeledContent("Storage", value: "Saved on this device")
        Text(
          "These provider, model, and permission settings apply to new threads for this project."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      if model.loadingAgentOptions {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading available providers…").foregroundStyle(.secondary)
          }
        }
      }

      if !model.loadingAgentOptions, model.agentProviders.isEmpty,
        model.agentConfigurationError == nil
      {
        Section {
          ContentUnavailableView(
            "No providers available",
            systemImage: "cpu",
            description: Text("No agent providers are currently available on this host.")
          )
          .listRowSeparator(.hidden)
        }
      }

      if let error = model.agentConfigurationError {
        Section {
          Label {
            Text(error).foregroundStyle(.primary)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
          }
          Button("Try again") { Task { await model.refreshAgentOptions(projectID: projectID) } }
            .disabled(model.loadingAgentOptions)
        }
      }

      Section("Provider") {
        Picker("Provider", selection: providerSelection) {
          Text("Choose a provider").tag(Optional<String>.none)
          if let saved = model.agentConfiguration(for: projectID),
            !model.agentProviders.contains(where: { $0.id == saved.provider })
          {
            Text("\(saved.provider) (Unavailable)")
              .tag(Optional(saved.provider))
              .disabled(true)
          }
          ForEach(model.agentProviders, id: \.id) { provider in
            let label = provider.label ?? provider.id
            Text(verbatim: provider.available ? label : "\(label) (Unavailable)")
              .tag(Optional(provider.id))
              .disabled(!provider.available)
          }
        }
        .accessibilityIdentifier("agent-provider-picker")

        if let selectedProvider, !selectedProvider.available, let error = selectedProvider.error {
          Text(error)
            .font(.footnote)
            .foregroundStyle(Color.primary.opacity(0.75))
        }
      }

      if let selectedProviderID,
        let selectedProvider = model.agentProviders.first(where: { $0.id == selectedProviderID }),
        selectedProvider.available
      {
        Section("Model") {
          Picker("Model", selection: $selectedModelID) {
            Text(providerDefaultLabel(for: selectedProviderID))
              .tag(Optional<String>.none)
            ForEach(model.agentModels(for: selectedProviderID), id: \.id) { agentModel in
              Text(
                verbatim: agentModel.isDefault ? "\(agentModel.label) (Default)" : agentModel.label
              )
              .tag(Optional(agentModel.id))
            }
          }
          .accessibilityIdentifier("agent-model-picker")

          Text("Choose Provider default to let the host select its default model.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if !selectedProvider.modes.isEmpty || selectedModeID != nil {
          Section("Permissions") {
            Picker("Permissions", selection: $selectedModeID) {
              Text(defaultModeLabel(for: selectedProvider)).tag(Optional<String>.none)
              if let selectedModeID,
                !selectedProvider.modes.contains(where: { $0.id == selectedModeID })
              {
                Text("\(selectedModeID) (Unavailable)")
                  .tag(Optional(selectedModeID))
                  .disabled(true)
              }
              ForEach(selectedProvider.modes, id: \.id) { mode in
                Text(verbatim: mode.label).tag(Optional(mode.id))
              }
            }
            .accessibilityIdentifier("agent-permissions-picker")
            if let selectedModeID,
              let description = selectedProvider.modes.first(where: { $0.id == selectedModeID })?
                .description
            {
              Text(description).font(.footnote).foregroundStyle(.secondary)
            }
          }
        }
      }

      if let saveError {
        Section {
          Label {
            Text(saveError).foregroundStyle(.primary)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
          }
        }
      }

      Section {
        Button("Save Agent") { saveConfiguration() }
          .frame(maxWidth: .infinity, alignment: .center)
          .font(.headline)
          .disabled(!canSave)
          .accessibilityIdentifier("save-agent-configuration")
      }
    }
    .navigationTitle("Project Agent")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: projectID) {
      await model.refreshAgentOptions(projectID: projectID)
      loadSavedSelection()
    }
    .onChange(of: model.agentProviders.map(\.id)) { _, _ in
      if selectedProviderID == nil { loadSavedSelection() }
    }
  }

  private var selectedProvider: RemoteAgentProvider? {
    model.agentProviders.first { $0.id == selectedProviderID }
  }

  private var providerSelection: Binding<String?> {
    Binding(
      get: { selectedProviderID },
      set: { providerID in
        guard selectedProviderID != providerID else { return }
        selectedProviderID = providerID
        selectedModelID = nil
        selectedModeID = nil
        saveError = nil
      }
    )
  }

  private var canSave: Bool {
    guard !model.loadingAgentOptions, let selectedProvider else { return false }
    return selectedProvider.available
      && (selectedModeID == nil || selectedProvider.modes.contains { $0.id == selectedModeID })
  }

  private func defaultModeLabel(for provider: RemoteAgentProvider) -> String {
    if let defaultModeID = provider.defaultModeID,
      let mode = provider.modes.first(where: { $0.id == defaultModeID })
    {
      return "Provider default (\(mode.label))"
    }
    return "Provider default"
  }

  private func providerDefaultLabel(for providerID: String) -> String {
    if let model = model.agentModels(for: providerID).first(where: \.isDefault) {
      return "Provider default (\(model.label))"
    }
    return "Provider default"
  }

  private func loadSavedSelection() {
    if let configuration = model.agentConfiguration(for: projectID) {
      selectedProviderID = configuration.provider
      selectedModelID = configuration.model
      selectedModeID = configuration.modeID
    } else if selectedProviderID == nil {
      selectedProviderID = model.agentProviders.first(where: \.available)?.id
    }
  }

  private func saveConfiguration() {
    guard let selectedProviderID else { return }
    let configuration = RemoteAgentConfiguration(
      provider: selectedProviderID, model: selectedModelID, modeID: selectedModeID)
    guard model.saveAgentConfiguration(configuration, for: projectID) else {
      saveError = "Couldn’t save this project’s Agent settings on this device."
      return
    }
    dismiss()
  }
}
