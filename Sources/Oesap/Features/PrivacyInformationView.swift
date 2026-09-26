import SwiftUI

/// Explains how Oesap handles information exchanged with a Paseo host.
struct PrivacyInformationView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "Prompts and other messages you send, plus agent output and tool results, are exchanged with your selected Paseo host. Tool results may include file contents. Providers configured on the host may also receive data, depending on its setup."
          )
          .foregroundStyle(Color.primary.opacity(0.75))
        } header: {
          Text("Data sent to your host").foregroundStyle(Color.primary.opacity(0.75))
        }

        Section {
          Text(
            "A direct connection uses TLS when TLS is enabled in its connection settings. Without TLS, messages and the password are sent unencrypted over that connection."
          )
          .foregroundStyle(Color.primary.opacity(0.75))

          Text(
            "With a relay connection, Paseo encrypts message contents end to end between this app and your host. The relay carries the connection."
          )
          .foregroundStyle(Color.primary.opacity(0.75))
        } header: {
          Text("Connection security").foregroundStyle(Color.primary.opacity(0.75))
        }

        Section {
          Text("Connection details and credentials are stored in Keychain.")
            .foregroundStyle(Color.primary.opacity(0.75))

          Text(
            "Project agent provider and model preferences are saved on this iPhone. Recent project and thread selections may also be saved here while you use the app."
          )
          .foregroundStyle(Color.primary.opacity(0.75))

          Text(
            "Unsent message drafts are held in memory. They may be lost if the app is terminated."
          )
          .foregroundStyle(Color.primary.opacity(0.75))
        } header: {
          Text("Stored on this device").foregroundStyle(Color.primary.opacity(0.75))
        }

        Section {
          Text(
            "Disconnect closes the current session, clears saved connection credentials, and removes unsent drafts. It does not stop agents running on your Paseo host or delete remote conversations or this iPhone’s project agent preferences."
          )
          .foregroundStyle(Color.primary.opacity(0.75))
        } header: {
          Text("Disconnecting").foregroundStyle(Color.primary.opacity(0.75))
        }

        Section {
          Text("Oesap does not add analytics or tracking.")
            .foregroundStyle(Color.primary.opacity(0.75))
        } header: {
          Text("App activity").foregroundStyle(Color.primary.opacity(0.75))
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Privacy & Host Data")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("privacy-information-done")
        }
      }
    }
  }
}
