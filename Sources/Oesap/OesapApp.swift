import SwiftUI

@main
struct OesapApp: App {
  @State private var model: OesapModel

  init() {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      let factory: any OesapConnectionFactory
      if arguments.contains("--demo-performance") {
        factory = DemoConnectionFactory(mode: .performance)
      } else if arguments.contains("--demo-images") {
        factory = DemoConnectionFactory(mode: .images)
      } else if arguments.contains("--demo-tools") {
        factory = DemoToolCallConnectionFactory()
      } else if arguments.contains("--demo-agent-control") {
        factory = DemoConnectionFactory(mode: .agentControl)
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
    // Multiple scenes stay disabled: the shared model owns one selected thread
    // and its timeline subscription on iPhone, iPad, and Mac Catalyst.
    WindowGroup {
      workspace
    }
    .commands { WorkspaceCommands() }
  }

  private var workspace: some View {
    WorkspaceRootView(model: model)
      .tint(Color.accentColor)
      .onOpenURL { url in Task { await model.openNotificationURL(url) } }
      #if DEBUG
        .preferredColorScheme(uiTestDarkMode ? .dark : nil)
      #endif
  }

  #if DEBUG
    private var uiTestDarkMode: Bool {
      ProcessInfo.processInfo.arguments.contains("--ui-test-dark-mode")
    }
  #endif
}
