import SwiftUI

struct ConnectionSetupView: View {
  @Bindable var model: OesapModel
  @State private var connection = RemoteConnection.empty
  @State private var connectingTask: Task<Void, Never>?
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case endpoint
    case password
    case pairingLink
  }

  var body: some View {
    Form {
      Section {
        Picker("Connection method", selection: $connection.method) {
          ForEach(RemoteConnection.Method.allCases) { method in
            Text(method.rawValue).tag(method)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("connection-method")
      } header: {
        Text("Connect to Paseo")
      } footer: {
        Text("Connect to a Paseo instance to browse its projects and agent threads.")
      }

      if connection.method == .direct {
        Section {
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
          Text("Direct connection")
        } footer: {
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
      } else {
        Section {
          TextField("Paste pairing link", text: $connection.pairingLink, axis: .vertical)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(2...5)
            .focused($focusedField, equals: .pairingLink)
            .accessibilityIdentifier("pairing-link")
          Text("Create a relay pairing link in Paseo, then paste it here.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
          Text("Relay pairing")
        } footer: {
          Text("Traffic is relayed and encrypted end-to-end to the paired host.")
        }
      }

      if model.hasSavedConnection {
        Section {
          Button {
            connectingTask = Task { await model.reconnect() }
          } label: {
            HStack {
              Label("Reconnect previous host", systemImage: "arrow.clockwise")
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
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .accessibilityIdentifier("connection-error")
        }
      }

      Section {
        Button {
          focusedField = nil
          connectingTask = Task { await model.connect(connection) }
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
    .navigationTitle("Oesap")
    .navigationBarTitleDisplayMode(.large)
    .task { await model.refreshSavedConnectionState() }
  }

  private var hasConnectionInput: Bool {
    switch connection.method {
    case .direct: !connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .relay: !connection.pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

}
