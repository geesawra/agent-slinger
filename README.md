# Oesap

Oesap is an iPhone client for following and messaging coding agents running on
a Paseo instance. The first MVP supports connecting directly to a host or
pasting a Paseo relay pairing link, browsing projects and their agent threads,
starting a project-configured agent thread, and viewing and sending timeline
messages.

## Run

Generate the Xcode project with the pinned XcodeGen version, then build or run
the `Oesap` scheme on an iPhone simulator:

```sh
just generate
just simulator-destinations
OESAP_SIMULATOR_UDID=<available-iphone-simulator-udid> just simulator
```

In Oesap, choose **Direct connection** and enter the Paseo host and port (for
example, `mac.local:6767`; leave off `ws://` or `wss://`) and password when
required, or choose **Relay pairing** and paste the link provided by Paseo.
For a private VPN host without TLS, use the VPN IP address when turning TLS
off. The app stores connection credentials in the iOS Keychain.
After connecting, open a project, select an agent thread, and send a message
from its timeline. Use **Project Agent** to choose a provider and optional
model for future threads on that host and project; those settings are saved on
this iPhone because Paseo projects do not currently contain an agent binding.
Choose **New thread** to open a blank composer. The remote thread is created
when the first message is sent, on hosts that advertise Paseo's
`creationLifecycle` capability.

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
are not treated as zero. Paseo may return a cached quota report, so Oesap shows
the host's report time when available and does not promise a forced refresh.

Use `just test` with an available iPhone simulator destination for the offline
test suite. Passing `--demo` to the app enables deterministic local UI data and
does not connect to a remote host. Pass `--demo-tools` from Xcode's launch
arguments to inspect realistic shell, read, edit, and failed-tool cards, then
send a prompt to see a running shell row update in place.
