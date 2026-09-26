import SwiftUI

@main
struct OesapApp: App {
  @State private var model: OesapModel

  init() {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      let factory: any OesapConnectionFactory
      if arguments.contains("--demo-tools") {
        factory = DemoToolCallConnectionFactory()
      } else if arguments.contains("--demo-failure") {
        factory = DemoConnectionFactory(mode: .failure)
      } else if arguments.contains("--demo-empty") {
        factory = DemoConnectionFactory(mode: .empty)
      } else if arguments.contains("--demo-send-failure") {
        factory = DemoConnectionFactory(mode: .sendFailure)
      } else if arguments.contains("--demo-creation-unsupported") {
        factory = DemoConnectionFactory(mode: .creationUnsupported)
      } else if arguments.contains("--demo-overview-empty") {
        factory = DemoConnectionFactory(mode: .overviewEmpty)
      } else if arguments.contains("--demo-overview-failure") {
        factory = DemoConnectionFactory(mode: .overviewFailure)
      } else if arguments.contains("--demo-usage-unsupported") {
        factory = DemoConnectionFactory(mode: .usageUnsupported)
      } else if arguments.contains("--demo-usage-unavailable") {
        factory = DemoConnectionFactory(mode: .usageUnavailable)
      } else if arguments.contains("--demo-usage-failure") {
        factory = DemoConnectionFactory(mode: .usageFailure)
      } else if arguments.contains("--demo") {
        factory = DemoConnectionFactory()
      } else {
        factory = PaseoConnectionFactory()
      }
    #else
      let factory: any OesapConnectionFactory = PaseoConnectionFactory()
    #endif
    _model = State(initialValue: OesapModel(connectionFactory: factory))
  }

  var body: some Scene {
    WindowGroup {
      WorkspaceRootView(model: model)
    }
  }
}
