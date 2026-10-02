import SwiftUI

struct AgentSettingsSheet: View {
  @Bindable var model: OesapModel
  let threadID: String

  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var settings: RemoteAgentSettings? { model.sessionSettings }

  private var selectedModel: RemoteAgentModel? {
    guard let settings else { return nil }
    if let selected = model.sessionDraftModelID {
      return settings.models.first { $0.id == selected }
    }
    return settings.models.first(where: \.isDefault)
  }

  private var selectedMode: RemoteAgentMode? {
    settings?.availableModes.first { $0.id == model.sessionDraftModeID }
  }

  var body: some View {
    NavigationStack {
      List {
        settingsSection
      }
      .refreshable { await model.refreshSessionDetails(threadID: threadID) }
      .navigationTitle("Agent settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
            .disabled(model.sessionDetailsApplying)
            .accessibilityIdentifier("agent-settings-done")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task {
              if await model.applySessionSettings(threadID: threadID) { dismiss() }
            }
          } label: {
            if model.sessionDetailsApplying {
              ProgressView()
                .accessibilityLabel("Applying settings")
            } else {
              Text("Apply")
            }
          }
          .disabled(!model.canApplySessionSettings)
          .accessibilityIdentifier("apply-session-settings")
        }
      }
    }
    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium])
    .presentationDragIndicator(.hidden)
    .interactiveDismissDisabled(model.sessionDetailsApplying)
    .task(id: threadID) { await model.openSessionDetails(threadID: threadID) }
  }

  @ViewBuilder
  private var settingsSection: some View {
    Section {
      if model.connectionState != .connected {
        Label("Reconnect to load session settings.", systemImage: "wifi.exclamationmark")
      } else if model.sessionDetailsLoading && settings == nil {
        HStack(spacing: 12) {
          ProgressView()
          Text("Loading settings…")
        }
      } else if let settings {
        if settings.canApply && !settings.models.isEmpty {
          modelPicker(settings)
          if settings.supportsThinking {
            effortPicker(settings)
          } else if settings.thinkingOptionID != nil
            || settings.effectiveThinkingOptionID != nil
          {
            LabeledContent("Effort", value: effortLabel(settings.thinkingOptionID, in: settings))
          }
        } else {
          LabeledContent("Model", value: modelLabel(settings.modelID, in: settings))
          if settings.thinkingOptionID != nil || settings.effectiveThinkingOptionID != nil {
            LabeledContent("Effort", value: effortLabel(settings.thinkingOptionID, in: settings))
          }
          if settings.effectiveThinkingOptionID != settings.thinkingOptionID,
            let effective = settings.effectiveThinkingOptionID
          {
            LabeledContent("Effective effort", value: effortLabel(effective, in: settings))
          }
        }

        if settings.canApply && !settings.availableModes.isEmpty {
          modePicker(settings)
        } else {
          LabeledContent("Permissions", value: modeLabel(settings.currentModeID, in: settings))
        }

        if settings.canApply && model.sessionSettingsHaveChanges
          && model.sessionDetailsError != nil
        {
          VStack(alignment: .leading, spacing: 3) {
            Text("Current on host")
              .font(.subheadline.weight(.semibold))
            Text("Model: \(modelLabel(settings.modelID, in: settings))")
            if settings.supportsThinking {
              Text("Effort: \(effortLabel(settings.thinkingOptionID, in: settings))")
            }
            if settings.currentModeID != model.sessionDraftModeID {
              Text("Permissions: \(modeLabel(settings.currentModeID, in: settings))")
            }
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("current-host-session-settings")
        }
      }

      if let error = model.sessionDetailsError {
        Label {
          Text(verbatim: error)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        .accessibilityIdentifier("session-settings-error")
        if settings == nil && model.connectionState == .connected {
          Text("Pull down to refresh to try again.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if let notice = model.sessionDetailsNotice {
        Text(verbatim: notice)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("session-settings-notice")
      }
    } header: {
      Text("Session settings")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        if let description = selectedMode?.description, !description.isEmpty {
          Text(verbatim: description)
        }
        if let settings, !settings.canApply {
          Text("This host does not allow changing settings for this session.")
        } else if let settings, settings.canApply && settings.models.isEmpty {
          Text("This host has not provided model choices for this session.")
        }
        if model.sessionSettingsMutationPendingElsewhere {
          Text("Finishing a change in another session…")
        }
        if model.sessionDetailsNotice == nil {
          Text("Model and effort changes may take effect on the next turn.")
        }
      }
    }
  }

  private func modePicker(_ settings: RemoteAgentSettings) -> some View {
    Picker(
      "Permissions",
      selection: Binding(
        get: { model.sessionDraftModeID },
        set: { model.chooseSessionMode($0) }
      )
    ) {
      if settings.currentModeID == nil {
        Text("Not reported").tag(nil as String?)
      } else if let current = settings.currentModeID,
        !settings.availableModes.contains(where: { $0.id == current })
      {
        Text("Current: \(current)").tag(current as String?)
      }
      ForEach(settings.availableModes) { option in
        Text(verbatim: option.label).tag(option.id as String?)
      }
    }
    .disabled(model.sessionDetailsApplying)
    .accessibilityIdentifier("session-permissions-picker")
  }

  private func modelPicker(_ settings: RemoteAgentSettings) -> some View {
    Picker(
      "Model",
      selection: Binding(
        get: { model.sessionDraftModelID },
        set: { model.chooseSessionModel($0) }
      )
    ) {
      Text("Provider default").tag(nil as String?)
      if let current = settings.modelID,
        !settings.models.contains(where: { $0.id == current })
      {
        Text("Current: \(current)").tag(current as String?)
      }
      ForEach(settings.models) { option in
        Text(verbatim: option.label).tag(option.id as String?)
      }
    }
    .disabled(model.sessionDetailsApplying)
    .accessibilityIdentifier("session-model-picker")
  }

  private func effortPicker(_ settings: RemoteAgentSettings) -> some View {
    Picker(
      "Effort",
      selection: Binding(
        get: { model.sessionDraftThinkingOptionID },
        set: { model.chooseSessionThinkingOption($0) }
      )
    ) {
      Text("Provider default").tag(nil as String?)
      if let current = settings.thinkingOptionID,
        let selectedModel,
        !selectedModel.thinkingOptions.contains(where: { $0.id == current })
      {
        Text("Current: \(current)").tag(current as String?)
      }
      if let selectedModel {
        ForEach(selectedModel.thinkingOptions) { option in
          Text(verbatim: option.label).tag(option.id as String?)
        }
      }
    }
    .disabled(
      model.sessionDetailsApplying || selectedModel == nil
        || selectedModel?.thinkingOptions.isEmpty == true
    )
    .accessibilityIdentifier("session-effort-picker")
  }

  private func modelLabel(_ id: String?, in settings: RemoteAgentSettings) -> String {
    guard let id else { return "Provider default" }
    return settings.models.first(where: { $0.id == id })?.label ?? id
  }

  private func effortLabel(_ id: String?, in settings: RemoteAgentSettings) -> String {
    guard let id else { return "Provider default" }
    return settings.models.lazy.flatMap(\.thinkingOptions).first(where: { $0.id == id })?.label
      ?? id
  }

  private func modeLabel(_ id: String?, in settings: RemoteAgentSettings) -> String {
    guard let id else { return "Not reported" }
    return settings.availableModes.first(where: { $0.id == id })?.label ?? id
  }

}
