import SwiftUI

struct SettingsView: View {
  @Bindable var model: OesapModel
  var onAddInstance: () -> Void
  var onSelected: () -> Void

  @State private var isRefreshing = false
  @State private var isSelecting = false
  @State private var pendingRemoval: SavedPaseoInstance?

  var body: some View {
    Form {
      Section {
        if isRefreshing && model.savedInstances.isEmpty {
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading saved instances…").foregroundStyle(.secondary)
          }
          .listRowSeparator(.hidden)
        } else if model.savedInstances.isEmpty {
          ContentUnavailableView(
            "No saved instances",
            systemImage: "server.rack",
            description: Text("Add a Paseo instance to save it on this device.")
          )
          .listRowSeparator(.hidden)
        } else {
          ForEach(model.savedInstances) { instance in
            HStack(spacing: 12) {
              Button {
                select(instance)
              } label: {
                HStack(spacing: 12) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(instance.name)
                      .font(.body.weight(.medium))
                      .foregroundStyle(.primary)
                    if !instance.subtitle.isEmpty {
                      Text(instance.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                  }
                  Spacer(minLength: 4)
                  if isSelecting && model.activeInstanceID == instance.id {
                    ProgressView()
                      .accessibilityLabel("Connecting to \(instance.name)")
                  } else if model.activeInstanceID == instance.id {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(.tint)
                      .accessibilityLabel("Selected")
                  }
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(model.connectionState.isBusy || isSelecting)
              .accessibilityLabel(
                model.activeInstanceID == instance.id
                  ? "\(instance.name), Selected" : instance.name
              )
              .accessibilityIdentifier("saved-instance-\(instance.id)")
              .accessibilityHint("Select this Paseo instance. \(instance.subtitle)")

              Button(role: .destructive) {
                pendingRemoval = instance
              } label: {
                Image(systemName: "trash")
                  .frame(minWidth: 32, minHeight: 44)
              }
              .buttonStyle(.borderless)
              .disabled(model.connectionState.isBusy || isSelecting)
              .accessibilityLabel("Remove \(instance.name)")
              .accessibilityIdentifier("remove-instance-\(instance.id)")
            }
          }
        }

        Button(action: onAddInstance) {
          Label("Add Paseo instance", systemImage: "plus")
        }
        .disabled(model.connectionState.isBusy || isSelecting)
        .accessibilityIdentifier("add-instance-button")
      } header: {
        Text("Paseo instances").foregroundStyle(Color.primary.opacity(0.75))
      } footer: {
        Text("Choose which Paseo host to use. Each instance keeps its own saved connection.")
          .foregroundStyle(Color.primary.opacity(0.75))
      }

      if let error = model.instanceError {
        Section {
          ConnectionErrorNotice(message: error, identifier: "instance-error")

          if let activeID = model.activeInstanceID,
            let activeInstance = model.savedInstances.first(where: { $0.id == activeID })
          {
            Button {
              select(activeInstance)
            } label: {
              HStack {
                Label("Retry \(activeInstance.name)", systemImage: "arrow.clockwise")
                Spacer()
                if isSelecting { ProgressView() }
              }
            }
            .disabled(model.connectionState.isBusy || isSelecting)
            .accessibilityIdentifier("retry-active-instance")
          } else {
            Button {
              Task { await refreshInstances() }
            } label: {
              HStack {
                Label("Refresh saved instances", systemImage: "arrow.clockwise")
                Spacer()
                if isRefreshing { ProgressView() }
              }
            }
            .disabled(isRefreshing)
            .accessibilityIdentifier("refresh-saved-instances")
          }
        }
      }
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await refreshInstances() }
    .task { await refreshInstances() }
    .confirmationDialog(
      "Remove \(pendingRemoval?.name ?? "this instance")?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let pendingRemoval {
        Button("Remove Instance", role: .destructive) {
          Task {
            await model.removeSavedInstance(pendingRemoval.id)
            self.pendingRemoval = nil
          }
        }
        .accessibilityIdentifier("confirm-remove-instance")
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("Its saved connection credentials will be deleted from this device.")
    }
  }

  private func select(_ instance: SavedPaseoInstance) {
    guard !model.connectionState.isBusy, !isSelecting else { return }
    isSelecting = true
    Task {
      let connected = await model.selectSavedInstance(instance.id)
      isSelecting = false
      if connected { onSelected() }
    }
  }

  private func refreshInstances() async {
    isRefreshing = true
    await model.refreshSavedInstances()
    isRefreshing = false
  }
}
