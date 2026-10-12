import SwiftUI

struct SettingsView: View {
  @Bindable var model: OesapModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var onAddInstance: () -> Void

  @State private var isRefreshing = false
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
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("saved-instance-\(instance.id)")
            .transition(.opacity)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              removeAction(for: instance)
            }
            #if targetEnvironment(macCatalyst)
              .contextMenu { removeAction(for: instance) }
            #endif
          }
        }

        Button(action: onAddInstance) {
          Label("Add Paseo instance", systemImage: "plus")
        }
        .accessibilityIdentifier("add-instance-button")
      } header: {
        Text("Paseo instances").foregroundStyle(Color.primary.opacity(0.75))
      } footer: {
        Text(
          "Projects and agents include all saved servers. Open a project or agent to use its server."
        )
        .foregroundStyle(Color.primary.opacity(0.75))
      }

      if let error = model.instanceError {
        Section {
          ConnectionErrorNotice(message: error, identifier: "instance-error")
        } footer: {
          Text("Pull down to refresh saved instances.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .animation(
      reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.savedInstances.map(\.id)
    )
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

  private func removeAction(for instance: SavedPaseoInstance) -> some View {
    // This action only asks for confirmation. A destructive swipe action
    // optimistically removes the row before the user has confirmed.
    Button {
      pendingRemoval = instance
    } label: {
      Label("Remove", systemImage: "trash")
    }
    .tint(.red)
    .accessibilityLabel("Remove \(instance.name)")
    .accessibilityIdentifier("remove-instance-\(instance.id)")
  }

  private func refreshInstances() async {
    isRefreshing = true
    await model.refreshSavedInstances()
    isRefreshing = false
  }
}
