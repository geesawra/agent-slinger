import SwiftUI

@main
struct OesapApp: App {
  var body: some Scene {
    WindowGroup {
      NavigationStack {
        ContentUnavailableView(
          "Connect a Paseo host",
          systemImage: "server.rack",
          description: Text("Oesap will show your workspaces and agents after host setup.")
        )
        .navigationTitle("Oesap")
      }
    }
  }
}
