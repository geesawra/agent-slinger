# ADR 0011: Mac Catalyst and iPad support with shared chat UI

- Status: Accepted
- Date: 2026-09-28

## Context

The product owner explicitly expanded support from iPhone to Mac and iPad and
requested a performance pass, particularly for chat. Preserve existing code and
use native Apple cross-platform APIs. No physical phone installation is part of
this change. This supersedes the iPhone-only scope in ADR 0001.

## Decision

Keep the existing iOS target and enable both iPhone and iPad on iOS/iPadOS 17+.
Enable Mac Catalyst for the same `Oesap` target and scheme, generated from
`project.yml`, with macOS 14+ support. Catalyst keeps the SwiftUI feature views,
UIKit text editor, image import and clipboard handling, Observation model,
domain services, Paseo protocol and transport, and Keychain persistence shared.
This avoids a separate editor and platform target while retaining native Mac
windowing, menus, pointer input, and keyboard support.

Use `NavigationSplitView` for the project, thread, and conversation columns on
Mac and iPad, with native list selection, column resizing, sidebar visibility,
and iPad's automatic compact collapse. Programmatic thread creation and opening
an overview result explicitly reveal the detail column when collapsed. Keep the
existing `NavigationStack` flow on iPhone. Shared rows and feature destinations
keep behavior and accessibility consistent. Connection settings, usage, agent
overview, and project configuration use sheets on the split-view platforms.

The shared app uses `WindowGroup` with multiple scenes disabled on every device.
The model owns one active selected thread and subscription; independent
multi-window sessions need a separate state/lifetime design and are outside
this change.
Focused scene commands expose New Thread (Command-N), Refresh Workspace
(Command-R), Settings (Command-comma), and native sidebar commands. Project or
instance switches discard stale navigation destinations but retain the model's
existing per-thread draft behavior.

Chat performance changes preserve native SwiftUI scrolling and text rendering.
The model still ingests every timeline event immediately, using a constant-time
message-ID lookup and a structural revision that changes only for insertion or
snapshot replacement. Equatable rows avoid invalidating unrelated message views.
A latest-source buffer coalesces Markdown rendering with at least 50 milliseconds
between parses; a bounded cache retains up to 64 Markdown trees and 512 KiB of
source text. A newly visible message renders its initial Markdown tree in the
first frame, so a lazy row does not change height when its background renderer
starts. Subsequent streaming updates remain coalesced off the main actor. No
protocol messages are dropped or coalesced. Initial history and the explicit
Latest button are the only programmatic jumps; live tokens and status changes
do not repeatedly call `scrollTo`. On iOS 18 and later (including its Catalyst
availability), native scroll phase tracks user interaction and the size-change
anchor follows the bottom only while the reader is idle and already near it.
The iOS 17 baseline uses whole-content geometry and a simultaneous drag gesture
to preserve reading position through deceleration; it reads the current
`GeometryReader` viewport size directly on the first layout. Both paths keep
the top anchored while reading earlier messages or expanding a tool call.
A deterministic offline `--demo-performance` fixture supplies 1,000 Markdown
messages and 5,000 streaming chunks over 50 seconds for repeatable validation.
These changes do not alter Paseo's wire protocol or add a rendering dependency.

## Consequences

- The same product functionality now has touch, pointer, and hardware-keyboard
  entry points through a single target and existing UIKit/SwiftUI code.
- Mac and iPad builds and smoke tests become part of platform validation.
- Existing Keychain records remain local to their device; this does not introduce
  cross-device account or draft sync.
- Physical-device and Instruments validation should be reported separately from
  compile, offline behavior tests, and simulator UI checks. No frame-rate or
  latency claim follows from a successful build alone.

## Validation

Verified during integration:

- iPhone 18 Pro simulator, iOS 27: the initial offline unit run passed 152 tests;
  seven selected UI regressions passed, covering chat, native Markdown input,
  image handling, new-thread flow, and accessibility. Evidence is in
  `.build/multiplatform-iphone-ui.log`.
- Mac Catalyst Debug and final Release builds passed. `lipo` verified both
  arm64 and x86_64 in the final Release binary; the Mac-optimized device family (`UIDeviceFamily = [6]`)
  and sandbox, outbound-network, and user-selected-file entitlements were
  verified. Build evidence is in `.build/catalyst-release-final.log`.
- Manual offline Mac Catalyst checks passed for connection setup, project and
  thread navigation, Markdown display, opening the new-thread composer, and
  saving Project Agent configuration then returning to the draft. Automated computer
  input could not exercise typing; the shared UIKit unit suite covers hardware
  keyboard and IME behavior. The final Mac dark-mode screenshot also verifies
  visible context and Stop controls. No Catalyst XCTest UI pass is claimed.
- iPhone 17 simulator, iOS 27: the large-chat UI regression passed with one test
  and zero failures. It verifies ongoing stream progress after scrolling away
  in a 1,000-message conversation, typing and retaining an unsent draft, and
  returning to live output with Latest. The test exposed and verified the fix
  for a bottom anchor incorrectly applying to content-size changes. Its
  interaction assertions completed in about 29 seconds; XCTest reported 151
  seconds including runner teardown. This is a functional load regression,
  not a frame-rate or latency benchmark. Evidence is in
  `.build/performance-ui-run2.log`. The suite reported one pass and zero
  failures, but overall xcodebuild finalization later stalled for over ten
  minutes and was stopped; the incomplete result bundle is not cited.
- Formatting and diff checks passed for the navigation, scene, and shared
  platform UI test files.
- Final iPad simulator run: 162 unit tests passed, including hardware-keyboard
  and IME coverage for the shared UIKit editor. Both split-workspace UI tests
  passed, covering new-thread detail navigation, thread/project switching,
  stale detail clearing, and draft restoration. The run finalized with
  `TEST EXECUTE SUCCEEDED`; evidence is in `.build/catalyst-ipad-final.log`.
  Exported iPad screenshots in `.build/ipad-final-attachments` were visually
  reviewed. Actual narrow-window resizing and collapse have not been exercised
  by automation.
- The final focused `MessageMarkdownTests` run passed all 16 tests, including
  two additional regressions for the iOS 17 scroll-follow fallback. Together
  with the full 162-test run, this covers 164 distinct unit tests. Evidence is
  in `.build/final-markdown-tests.log`.

## Scroll redraw correction

The initial performance pass still let a lazy row show raw Markdown before its
asynchronous parse completed, and two independent paths issued `scrollTo` on
stream growth. This caused visible row reflow and jumps while scrolling. The
follow-up keeps the first row layout stable and lets the native anchor manage
content growth according to scroll intent. The iPhone simulator and Mac Catalyst
builds passed, as did 19 focused unit tests. The live 1,000-message iPhone UI
regression reported one pass and zero failures: it held an earlier message in
place while the offline fixture advanced by more than 100 bytes, then returned
to live output with Latest. After the agent-output buffering change on `main`,
the debug fixture reports incoming buffered bytes to keep this check meaningful.
These checks do not measure frame rate on physical devices.

The iOS 26 bottom `safeAreaBar` and soft scroll edge effect also drew a
full-width boundary through an agent message while that message passed behind
the composer. The composer now uses a native bottom `safeAreaInset` with a
system-background backing. This keeps the timeline above the controls and
removes the apparent divider under “Agent.” A simulator screenshot of the
1,000-message fixture was reviewed after the change, and its UI regression
passed with a finalized result bundle.

No on-device frame-rate measurement, real-host credential access, or Instruments
measurement was performed. Simulator and compile checks establish
behavior and compatibility within their tested scope, not an on-device frame
rate guarantee.
