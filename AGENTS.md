# Notes for agents

## Mac Catalyst

- The Mac app is the shared `Oesap` target. Edit `project.yml` for target or
  signing configuration; `Scripts/generate-project` skips an existing
  `Oesap.xcodeproj`. Use `just regenerate` after changing the project spec.
  The architecture decision is in `docs/adr/0011-mac-catalyst-ipad-and-chat-performance.md`.
- Platform-specific SwiftUI code uses `#if targetEnvironment(macCatalyst)`.
  `WorkspaceRootView` in `Sources/Oesap/Features/WorkspaceViews.swift` owns the
  Catalyst `NavigationSplitView`. Connection setup, the workspace, and the
  loading state all affect the window toolbar during launch.
- Keep connection progress in `.status` on Catalyst and `.principal` on iPhone
  and iPad through `PlatformToolbarPlacements.connectionProgress`. On Catalyst,
  `ProjectListView` puts Agents and Add project in the sidebar list; the mobile
  toolbar keeps its buttons. Do not move the Mac actions back into toolbar
  button groups without validating both startup paths. On macOS 27, AppKit
  threw `NSGenericException` while laying out those buttons:
  `NSToolbarButton.leading == NSToolbarItemGroupLayoutWrapper.leading` referred
  to a button outside the wrapper's view subtree. The debugger identified the
  Agents button as “CPU chip” and the Add project button as “add”. The window
  could appear briefly before the exception.
- Run `just mac-build` and `just mac-test` for Catalyst changes. These require
  Apple Development signing; see `README.md`. The UI tests in
  `Tests/OesapPlatformUITests/WorkspacePlatformUITests.swift` cover cold launch
  with no saved host and automatic connection to a saved demo host.
  `--demo-saved-connection` seeds that offline host in `DemoConnectionFactory`.
  Mac UI tests take control of keyboard focus, so run them when the Mac is not
  being used interactively.
- A `.ips` crash report may omit the Objective-C exception reason. For a
  toolbar-layout crash, inspect the matching process in macOS's unified log
  with `/usr/bin/log show`; zsh's `log` builtin is a different command.
