import SwiftUI
import UIKit

struct ConnectionSetupView: View {
  @Bindable var model: OesapModel
  var title = "Oesap"
  var showsReconnectAction = true
  var onOpenSettings: (() -> Void)?
  var onConnected: (() -> Void)?
  @State private var connection = RemoteConnection.empty
  @State private var connectingTask: Task<Void, Never>?
  @FocusState private var focusedField: Field?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private enum Field: Hashable {
    case endpoint
    case password
    case pairingLink
  }

  var body: some View {
    Form {
      Section {
        if dynamicTypeSize.isAccessibilitySize {
          connectionMethodPicker.pickerStyle(.menu)
        } else {
          connectionMethodPicker.pickerStyle(.segmented)
        }
      } header: {
        Text("Connect to Paseo").foregroundStyle(Color.primary.opacity(0.75))
      } footer: {
        Text("Connect to a Paseo instance to browse its projects and agent threads.")
          .foregroundStyle(Color.primary.opacity(0.75))
      }

      if connection.method == .direct {
        Section {
          TextField("Name (optional)", text: $connection.name)
            .textContentType(.organizationName)
            .textInputAutocapitalization(.words)
            .accessibilityIdentifier("connection-name")

          TextField("host:port (e.g. mac.local:6767)", text: $connection.endpoint)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .focused($focusedField, equals: .endpoint)
            .accessibilityLabel("Host and port")
            .accessibilityIdentifier("direct-endpoint")

          Toggle("Use TLS", isOn: $connection.usesTLS)

          SecureField("Password (if required)", text: $connection.password)
            .textContentType(.password)
            .focused($focusedField, equals: .password)
            .accessibilityIdentifier("direct-password")
        } header: {
          Text("Direct connection").foregroundStyle(Color.primary.opacity(0.75))
        } footer: {
          VStack(alignment: .leading, spacing: 6) {
            Text("Give this connection a name such as Mac Studio.")
            if connection.usesTLS {
              Text(
                "Enter host:port without ws:// or wss://. TLS is on by default. For a private VPN host, use its IP address if needed."
              )
            } else {
              Text(
                "Without TLS, messages and the password are sent unencrypted. Use only on a private LAN or VPN host without TLS; use its IP address for a private VPN connection."
              )
            }
          }
          .foregroundStyle(Color.primary.opacity(0.75))
        }
      } else {
        Section {
          TextField("Name (optional)", text: $connection.name)
            .textContentType(.organizationName)
            .textInputAutocapitalization(.words)
            .accessibilityIdentifier("connection-name")

          TextField("Paste pairing link", text: $connection.pairingLink, axis: .vertical)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(2...5)
            .focused($focusedField, equals: .pairingLink)
            .accessibilityIdentifier("pairing-link")
          Text("Create a relay pairing link in Paseo, then paste it here.")
            .font(.footnote)
            .foregroundStyle(Color.primary.opacity(0.75))
          Text("Give this connection a name such as Home Studio.")
            .font(.footnote)
            .foregroundStyle(Color.primary.opacity(0.75))
        } header: {
          Text("Relay pairing").foregroundStyle(Color.primary.opacity(0.75))
        } footer: {
          Text("Traffic is relayed and encrypted end-to-end to the paired host.")
            .foregroundStyle(Color.primary.opacity(0.75))
        }
      }

      if showsReconnectAction, let activeInstanceID = model.activeInstanceID {
        Section {
          Button {
            connectingTask = Task { await model.reconnect() }
          } label: {
            HStack {
              Label(reconnectTitle(for: activeInstanceID), systemImage: "arrow.clockwise")
              Spacer()
              if model.connectionState.isBusy { ProgressView() }
            }
          }
          .disabled(model.connectionState.isBusy)
          .accessibilityIdentifier("reconnect-saved")
        }
      }

      if let error = model.connectError {
        Section {
          ConnectionErrorNotice(message: error, identifier: "connection-error")
        }
      }

      Section {
        Button {
          focusedField = nil
          connectingTask = Task {
            await model.connect(connection)
            if model.connectionState == .connected { onConnected?() }
          }
        } label: {
          HStack {
            Spacer()
            if model.connectionState.isBusy {
              ProgressView().padding(.trailing, 8)
              Text("Connecting…")
            } else {
              Text("Connect")
            }
            Spacer()
          }
          .fontWeight(.semibold)
        }
        .disabled(model.connectionState.isBusy || !hasConnectionInput)
        .tint(Color.primary)
        .accessibilityIdentifier("connect-button")

        if model.connectionState.isBusy {
          Button("Cancel connection", role: .cancel) {
            connectingTask?.cancel()
            connectingTask = nil
          }
          .accessibilityIdentifier("cancel-connection")
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { focusedField = nil }
          .accessibilityIdentifier("connection-keyboard-done")
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      if let onOpenSettings, !model.savedInstances.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: onOpenSettings) {
            Label("Settings", systemImage: "gearshape")
          }
          .accessibilityIdentifier("setup-settings-button")
        }
      }
    }
    .task { await model.refreshSavedInstances() }
  }

  private var connectionMethodPicker: some View {
    Picker("Connection method", selection: $connection.method) {
      ForEach(RemoteConnection.Method.allCases) { method in
        Text(method.rawValue).tag(method)
      }
    }
    .accessibilityIdentifier("connection-method")
  }

  private var hasConnectionInput: Bool {
    switch connection.method {
    case .direct: !connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .relay: !connection.pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func reconnectTitle(for activeInstanceID: String) -> String {
    guard let name = model.savedInstances.first(where: { $0.id == activeInstanceID })?.name else {
      return "Reconnect selected instance"
    }
    return "Reconnect \(name)"
  }

}

/// Connection diagnostics are sanitized at the transport boundary before display.
/// Copying is an explicit action; no clipboard contents are read.
struct ConnectionErrorNotice: View {
  let message: String
  let identifier: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text(message)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
      }
      .accessibilityIdentifier(identifier)

      Button("Copy details", systemImage: "doc.on.doc") {
        UIPasteboard.general.string = message
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier("\(identifier)-copy")
    }
  }
}
