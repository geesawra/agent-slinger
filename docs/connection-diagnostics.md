# Connection diagnostics

Connection failures now retain a useful explanation, a suggested next step, and
safe technical details where the system provides them. Setup, saved-instance
errors, and disconnected project/thread lists let you select the text or choose
**Copy details**. In an open chat, expand **Connection details** in the paused
connection banner. Reconnect failures preserve the draft and the underlying
failure details.

The details can distinguish DNS or reachability problems, TLS verification,
App Transport Security blocking an unencrypted connection, authentication,
HTTP upgrade failures, and WebSocket closure. They may include
the operation phase, an allowlisted system error domain and numeric code, HTTP
status, and WebSocket close code. Missing metadata remains unknown. The prior
message “The connection closed” alone does not establish which of these caused
a particular failure; reproduce it with the updated app to obtain evidence.
HTTP 101 is the successful WebSocket protocol upgrade. A later socket failure
after that response is reported as a WebSocket closure (or by a more specific
transport cause), not as a rejected HTTP upgrade.
The status alone does not validate the upgrade headers: a rejected acceptance
header is reported as an invalid handshake even if the response status is 101.
Transport opening waits for URLSession's validated WebSocket-open delegate
callback, without requiring an extra ping/pong exchange.

## Shared connection and cached workspace

`OesapApp` creates one application-scoped observable `OesapModel` and injects it
into every screen. The model owns the active connection, cached workspace, and
selected timeline subscription. Navigating away from a chat no longer cancels
that subscription. Returning to the selected project or thread preserves its
history and draft, and reapplies the chat's latest-message anchor after layout.
Overlapping workspace and thread refreshes share their in-flight requests;
populated lists remain visible while refreshed data arrives. Switching hosts
still clears host-specific state and rejects late responses from the old host.

Foreground activation checks the existing session before reconnecting. A healthy
session keeps its subscriptions and cached data. A failed session reconnects and
restores the selected timeline. Connection progress includes retry delays and
attempt counts. Credentials, TLS, endpoint, and protocol errors stop immediately;
only transient failures use the bounded retry policy.

Transport diagnostics omit passwords, pairing links and secrets, full URLs,
query strings, workspace paths, remote message bodies, and raw system error
messages. Copying is a user action and does not read the clipboard. Share only
the copied diagnostic text needed to investigate the failed connection.

## Plain WebSockets over Tailscale IPv4

On iOS 17, iPadOS 17, and macOS 14 or later, Apple requires explicit ATS
exceptions for IP-address connections. Oesap includes
`NSExceptionDomains["100.64.0.0/10"].NSExceptionAllowsInsecureHTTPLoads = true`
so a direct `ws://` connection chosen with **Use TLS** off is permitted for that
range. This uses Apple's supported CIDR exception syntax. See
[Apple's IP-address rules](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
and [exception-domain syntax](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains).

The exception covers `100.64.0.0` through `100.127.255.255`, the shared CGNAT
range used by Tailscale; it does not cover every `100.x.x.x` address. Other
networks can also use this range, so the address alone does not establish that
traffic travels through a Tailscale tunnel. See
[Tailscale's address documentation](https://tailscale.com/docs/concepts/tailscale-ip-addresses).

The app preserves the visible TLS choice and saved connection settings. It does
not retry a failed TLS connection as plaintext, bypass certificate verification,
or enable arbitrary insecure loads. The IP exception applies when connecting
by literal IPv4 address, not to a DNS name that resolves to that address.

## Mac secure storage

The failing Mac build had a development signature but lacked a provisioned
application identifier and Keychain access group. Oesap uses the Data Protection
Keychain, whose access groups require matching signing entitlements and a
provisioning profile. See [Apple's Mac Keychain guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

The Catalyst target now declares its application identifier, development team,
and app-specific Keychain access group. The signed build contains the matching
embedded provisioning profile. Existing iOS credential identifiers are preserved.
Missing-entitlement failures now show actionable guidance and OSStatus `-34018`.

`just mac-run` selects the unique local development team and builds with automatic
provisioning before launching. Set `OESAP_DEVELOPMENT_TEAM` when an explicit team
is needed; see the [Mac development instructions](../README.md).

To verify secure storage in a signed build:

```sh
Scripts/check-mac-keychain .build/mac-catalyst/Build/Products/Debug-maccatalyst/Oesap.app
```

This opt-in probe signs a temporary helper with the app's identity, entitlements,
and profile. It adds, reads, updates, and deletes one randomly named synthetic
Data Protection Keychain item, then verifies removal. It never queries saved
Oesap credentials. The corrected build passed all five operations and cleanup.

## Mac logs

Open **Console**, select the Mac, and start streaming. Filter by subsystem
`com.oesap.app` and category `connection`, then reproduce the connection attempt.
The same safe events are available from Terminal:

```sh
log stream --level info --predicate 'subsystem == "com.oesap.app" AND category == "connection"'
```

To inspect recent events after a failure:

```sh
log show --last 15m --info --predicate 'subsystem == "com.oesap.app" AND category == "connection"'
```

## Simulator logs

Use an available simulator's UDID, as listed by `just simulator-destinations`:

```sh
xcrun simctl spawn <simulator-udid> log stream --level info --predicate 'subsystem == "com.oesap.app" AND category == "connection"'
```

`OESAP_SIMULATOR_UDID=<simulator-udid> just simulator-logs` also streams Oesap
logs, and `just simulator-logs-recent` reads the last 15 minutes for that selected
simulator. No physical-device installation is needed for these checks.

## Validation

The October 9 connection/refresh follow-up passed the signed Catalyst build and
194 Catalyst unit tests (two loopback-server tests are skipped on Catalyst, whose
app sandbox grants only network client access). All 21 transport tests passed on
iPhone Simulator, including real valid HTTP 101/no-pong and invalid-accept-header
handshakes. A simulator UI regression passed three leave-and-return chat visits
without scrolling and preserved the draft. Mac UI tests were deferred at the
user's request.

Three existing unit tests were excluded from the final Catalyst run after their
failures reproduced against the baseline model: large-timeline delta text,
snapshot/delta merging, and accessibility font line measurement. This connection
change does not resolve those baseline failures. Evidence is in
`.build/connection-refresh-unit-final.log`,
`.build/connection-refresh-baseline.log`,
`.build/connection-refresh-websocket-simulator.log`,
`.build/connection-refresh-chat-return-ui.log`, and
`.build/connection-refresh-mac-build.log`.

Earlier diagnostic work:

- The full unit suite passed 177 tests. The final focused transport run passed
  15 tests, including two additional regressions: 179 distinct unit tests across
  both runs. Eight device-selector mock tests also passed.
- The real loopback connection-failure UI test passed and safe OSLog output was
  verified. The UI suite pass is recorded in its log; its result bundle was
  still finalizing at handoff.
- Signed iPhone and Mac Catalyst builds passed. After the user subsequently
  authorized phone installation, the updated `com.oesap.app` installed and
  launched successfully. Plain `just mac-run` also completed development signing,
  provisioning, and launch.
- Follow-up checks passed 20 focused ATS/transport/storage tests, five final
  connection-store tests, and 15 script tests. The Mac signature and embedded
  profile passed verification, and the isolated real Keychain probe above passed.

Evidence: `.build/connection-diagnostics-tests.log`,
`.build/connection-transport-final.log`, and
`.build/connection-diagnostics-oslog.log`,
`.build/tailscale-keychain-mac-build.log`, and `.build/keychain-error-tests.log`.
These checks validate diagnostics, the scoped ATS configuration, secure storage,
and build/install behavior. The original generic connection message alone cannot
identify its underlying cause.
