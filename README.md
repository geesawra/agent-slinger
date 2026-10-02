# Agent Slinger

Agent Slinger is an iPhone, iPad, and Mac client for following and messaging coding agents
running on a Paseo instance. The first MVP supports connecting directly to a host or
pasting a Paseo relay pairing link, browsing host folders to add projects,
browsing projects and their agent threads, starting a project-configured agent
thread, and viewing and sending timeline messages.

## Run

Ensure the Xcode project exists with the pinned XcodeGen version, then build or
run the `Oesap` scheme on an iPhone or iPad simulator (iOS/iPadOS 17+):

```sh
just generate
just simulator-destinations
OESAP_SIMULATOR_UDID=<available-simulator-udid> just simulator
```

Build commands skip project generation when `Oesap.xcodeproj` already exists.
After changing `project.yml`, run `just regenerate` to replace it.

For a Mac build (macOS 14+), use the same `Oesap` scheme with **My Mac (Mac
Catalyst)**. Catalyst reuses the iPad app’s SwiftUI interface, UIKit text editor,
and image handling:

```sh
just mac-build
just mac-run   # Build, then open a fresh instance of the Mac app
```

Mac builds use Apple Development signing and automatic provisioning so the app
can access its protected Keychain group. The signing helper uses
`OESAP_DEVELOPMENT_TEAM` when set; otherwise it selects the unique team in local
Apple Development certificate metadata. It reads public certificates, never
private keys. Missing or ambiguous teams stop with instructions to configure
signing, rather than producing an app with unusable credential storage. To
choose a team explicitly:

```sh
OESAP_DEVELOPMENT_TEAM=<team-id> just mac-run
```

`mac-build`, `mac-run`, and `mac-test` allow Xcode to update the selected team's
development provisioning profile. They require that team's development
certificate and Xcode signing account to be configured.

For an explicitly requested physical-device installation, run:

```sh
just device-install
```

`device-install` selects the unique team in local Apple Development
certificate metadata. If multiple teams are configured, choose one explicitly
with `OESAP_DEVELOPMENT_TEAM=<team-id>`. Xcode provisioning updates are enabled
by default; set `OESAP_ALLOW_PROVISIONING_UPDATES=0` to disable them. The
selected team's Apple Development certificate and Xcode signing account must
be configured.

The `device-*` commands use the paired-device selector from Hydraulophone,
adapted for iPhone and iPad. A single device is selected automatically; multiple
devices require the terminal picker or an explicit selection. Set
`OESAP_DEVICE_ID=<udid-or-CoreDevice-id>` to override selection, or use
`OESAP_DEVICE='Exact device name'`. `OESAP_DEVICE_ID` takes precedence. Ambiguous
non-interactive invocations stop without choosing a device. The selector opens
the chosen device's connection before building; `device-install` builds,
installs, and launches, while `device-console` relaunches the installed app and
streams its console. Signing uses `OESAP_DEVELOPMENT_TEAM` when set; otherwise
it resolves the unique local Apple Development team as described above.

Mac builds use `.build/mac-catalyst`; `mac-run` opens that exact build and never
selects or installs on a mobile device. The standalone device selector retains
its [GPLv3 license](Scripts/LICENSE.device-selector), shared by the adapted
signing-team helper. Their offline mock tests run with `just test-scripts`.

For connection failures, see the [diagnostic guide](docs/connection-diagnostics.md).

On iPad and Mac, projects, threads, and the selected conversation use a native
three-column split view. iPad adapts to narrow windows with system navigation;
Mac columns resize and the sidebar can be hidden. The Mac app uses one workspace
window because one model owns the active thread subscription. Hardware keyboards
support **⌘N** for a new thread in the selected project, **⌘R** to refresh the
workspace, and **⌘,** for Settings. The compact iPhone navigation is preserved.

In Agent Slinger, choose **Direct connection** and enter the Paseo host and port (for
example, `mac.local:6767`; leave off `ws://` or `wss://`) and password when
required, or choose **Relay pairing** and paste the link provided by Paseo.
For a private VPN host without TLS, use the VPN IP address when turning TLS
off. Give each connection an optional name, then use **Settings** to add and
switch between saved Paseo instances. Settings is available from both the
disconnected setup screen and the connected Projects menu. The app stores
connection credentials and the active instance choice in the system Keychain. On
upgrade, an existing single saved connection is migrated into the instance
list automatically.
After connecting, open a project, select an agent thread, and send a message
from its timeline. Use **Project Agent** to choose a provider and optional
model for future threads on that host and project; those settings are saved on
this device because Paseo projects do not currently contain an agent binding.
Choose **New thread** to open a blank composer. The remote thread is created
when the first message is sent, on hosts that advertise Paseo's
`creationLifecycle` capability.

In a running thread, **Stop** requests cancellation. Sending while the agent
is active offers **Steer** (ask it to use the follow-up in the current turn)
or **Interrupt** (replace that turn). A host or provider may fall back from
Steer to interrupting, so check the resulting timeline. If delivery cannot
be confirmed, Agent Slinger keeps the draft and original message identity for review.
Manual retry of that exact message is available only when the connected host
advertises `agentRequestReceipts`; an unresolved in-flight receipt can still
leave delivery uncertain.

Choose **Agents** on the Projects screen for an overview grouped by project.
It opens with active agents (starting, running, waiting for attention, or
failed); switch to **All** to include idle and closed agents. This is a status
snapshot rather than a live subscription. Pull down or use Refresh to fetch
current states. Offline and partial project failures keep the last available
rows visible with an explicit stale/error indication.

The chat status card also shows the last context-window report when the host
provides both the used token count and context-window size. Tap it for token
details and the matching provider quota when the host reports that exact
provider ID. **Usage** in the Projects connection menu shows quotas for host
provider credentials, which are separate from a particular agent's usage.
Quota values preserve the host's units and reporting states; missing values
are not treated as zero. Paseo may return a cached quota report, so Agent Slinger shows
the host's report time when available and does not promise a forced refresh.

Use `just test` with an available iPhone simulator destination for the existing
offline unit and phone UI test suite. The shared split-workspace smoke tests run
on iPad and Mac:

```sh
xcodebuild test -project Oesap.xcodeproj -scheme Oesap -destination 'platform=iOS Simulator,id=<ipad-udid>' -only-testing:OesapUITests/WorkspacePlatformUITests
xcodebuild test -project Oesap.xcodeproj -scheme Oesap -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:OesapTests -only-testing:OesapUITests/WorkspacePlatformUITests
```

Passing `--demo` to the app enables deterministic local UI data and
does not connect to a remote host. Pass `--demo-tools` from Xcode's launch
arguments to inspect realistic shell, read, edit, and failed-tool cards, then
send a prompt to see a running shell row update in place.
`--demo-performance` opens an offline fixture with 1,000 Markdown messages and
5,000 stream chunks over 50 seconds in the running demo thread for repeatable
scrolling and streaming checks. See [the cross-platform ADR](docs/adr/0011-mac-catalyst-ipad-and-chat-performance.md)
for platform boundaries and validation scope.

## MVP review

The [Apple UI/UX review](docs/apple-ui-ux-review.md) records accessibility
findings, validation, and outstanding release requirements. It is a HIG and
release-readiness review, not submission certification. The
[Paseo mobile comparison](docs/paseo-mobile-gap-review.md) prioritizes possible
next features; notifications are excluded from this review and roadmap.
