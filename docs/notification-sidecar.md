# Go notification sidecar for Agent Slinger

Status: Initial implementation. An optional `agent-slinger-notify` Go binary runs
alongside their Paseo daemon. Deliver alerts through their own Pushover account,
with an action that opens Agent Slinger at the relevant agent session. Use
Paseo's mobile and web notification behavior as the compatibility reference.

The binary and Agent Slinger URL handler implement the explicit `all-attention`
mode. Exact daemon delivery parity remains a proposed integration. See the
[sidecar setup guide](../Tools/agent-slinger-notify/README.md) for executable and
Docker instructions. Pushover owns the system alert. Following its action
opens Agent Slinger, which reconnects and loads authoritative state before the
user answers a question, grants permission, or sends a message.

## Reference behavior in Paseo

Source baseline: Paseo commit
[`9246813fd2acd6afc7012c5fde79a164b8f8592e`](https://github.com/getpaseo/paseo/commit/9246813fd2acd6afc7012c5fde79a164b8f8592e),
reviewed on 2026-10-12. The mobile and web implementations share payload and
navigation semantics, with different delivery mechanisms.

| Behavior | Mobile | Web |
| --- | --- | --- |
| Delivery | Expo remote push, registered with each daemon | WebSocket attention event followed by browser `Notification`, or the desktop notification bridge |
| Foreground | Native notification handler suppresses banners, sound, list entries, and badge changes | Sends only when the daemon selects this client and the app is away from the agent |
| Reasons | Remote push includes completion and permission, excludes error | Agent alert handler excludes error |
| Tap | Live response listener and last response on startup; ignores repeated response identifiers | Dispatches a click event to the app; falls back to route navigation |
| Target | Opens and pins the host/workspace/agent | Same target and pinning behavior |

The web push registration implementation is a no-op: this path creates browser
notifications from a connected client, rather than registering browser Web Push.
Native code deliberately avoids creating local OS alerts from the WebSocket.
See [native registration](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/app/src/push-notifications/internal/subscriptions.ts),
[web registration](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/app/src/push-notifications/index.web.ts),
[OS notification delivery](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/app/src/utils/os-notifications.ts),
[attention handling](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/app/src/contexts/session-context.tsx),
and [tap handling](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/app/src/app/_layout.tsx).

The web handler deduplicates each agent's timestamps, skipping an event older
than or equal to the last notified event. Prefer the daemon's supplied title,
body, and routing metadata. Its builder provides a plain-text completion or
permission preview, capped at 220 JavaScript string units, with generic text
when no preview exists. Permission previews can contain input or metadata.
Using this payload preserves Paseo's wording without porting its Markdown
cleanup to Go. Preview mode is the default. A configurable generic-content mode
can omit previews; that is an explicit departure from content parity.
See [payload construction](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/protocol/src/agent-attention-notification.ts).

The sidecar enriches the title with the exact agent's current title, for example
`Fix login — turn finished`. The body names the generating daemon (`Server: Mac
Studio`) above the preview supplied with that event, so a later turn cannot
replace the completed turn's preview. Missing agent metadata falls back to the
agent ID. `PASEO_SERVER_NAME` overrides the displayed hostname; absent both, the
server ID is shown. Display names never change the identity in the action link.
The server label uses Pushover's supported bold HTML formatting. Server names and
preview text are escaped, and the complete encoded body stays within the provider
limit. Pushover renders this styling inside its app; operating-system notification
banners strip the tags, as described in its [HTML documentation](https://pushover.net/api#html).

## Notification selection and the parity gap

Paseo's daemon makes the delivery decision across notification-enabled clients:

1. A client with activity in the last 180 seconds is present.
2. A present, visible client focused on the target suppresses the notification.
3. Otherwise the most recently active present client receives the in-app alert.
4. With no present client, completion and permission are eligible for remote push.

Presence currently considers recent activity even when the app is hidden.
See [selection policy](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/server/src/server/agent-attention-policy.ts)
and [daemon delivery](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/server/src/server/websocket-server.ts).

The current subscription does not expose that remote-push decision. Its
`shouldNotify` flag selects a connected recipient. With `notifications: false`,
the sidecar still receives events but that flag is false. With notifications
enabled and no activity, the sidecar is not selected either. Pretending the
sidecar is an active UI would affect every other client's delivery decision.
See [subscription dispatch](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/server/src/server/session.ts).

Therefore exact delivery parity needs a daemon integration that exposes the
existing decision for external delivery. Proposed extension: publish a scoped
delivery event when the daemon chooses remote push, with a stable event ID and
the existing notification payload. The observer must not count as a present
UI. Pushover then replaces the remote transport while the daemon retains its
policy. If Expo and Pushover are both enabled, delivery to both must be an
explicit user choice. The extension is proposed, not an existing Paseo API.

For an unchanged daemon, an explicitly named `all-attention` mode can subscribe
passively and send completion/permission regardless of other clients' presence.
This is useful for prototyping transport and links, but differs from Paseo's
suppression behavior and can duplicate other alerts. Do not label it parity
mode. Default production behavior should wait for the decision integration;
do not silently fall back to `all-attention` when it is unavailable.

## Go process and configuration

Use one foreground process per daemon and recipient, with macOS/Linux binaries
and graceful SIGINT/SIGTERM shutdown. A user can supervise it with launchd,
systemd, or a container. The transport can be a direct local connection or
an encrypted relay connection from a Paseo pairing
link. Agent Slinger can independently use either transport to reach the same server.

Commands:

```sh
agent-slinger-notify run
agent-slinger-notify check
agent-slinger-notify test --agent-id agent-456
```

`check` validates configuration, daemon compatibility, server identity, and
recipient configuration without sending an alert. `test` explicitly sends a
labelled test alert. `run` reports connection, subscription, queue, and sender
health through structured logs. A daemon connection alone does not imply that
notification delivery is healthy.

All configuration comes from environment variables. For the passive observer:

```sh
export PASEO_URL=ws://127.0.0.1:6767/ws
export NOTIFY_DELIVERY_MODE=all-attention
export NOTIFY_CONTENT=paseo-preview
export NOTIFY_STATE_DIR=./notify-state
# Set PUSHOVER_APP_TOKEN and PUSHOVER_USER_KEY using your secret facilities.
# Optionally set PUSHOVER_DEVICE, PASEO_PASSWORD, or a PASEO_SERVER_ID identity pin.
# Optionally set PASEO_SERVER_NAME to a friendly display name.
```

The port is illustrative. A Paseo password is optional: omit or leave
`PASEO_PASSWORD` empty for a daemon without authentication. The binary accepts
no configuration or secret files. Exclude secrets from arguments, logs, and links.
The daemon supplies its server ID during the handshake. `PASEO_SERVER_ID` is an
optional check against an expected identity, rather than required setup. Links
and persistent queue scope always use the observed identity. A running process
pins that identity for reconnects so a replacement daemon cannot inherit its
queued sends.
The user supplies their own Pushover application token. Explain at setup that
the default preview mode sends agent text and permission details to Pushover.
`NOTIFY_CONTENT=generic` omits those previews while retaining the agent and server
names and opaque identifiers in the action URL. Existing generic queue state can
migrate to preview mode for the same server and recipient without losing pending
alerts or deduplication watermarks.

Authenticate only when credentials are configured. The current Swift
[direct socket](../Sources/Oesap/Transport/PaseoSocket.swift) uses the
`paseo.bearer.<password>` WebSocket subprotocol; newer upstream hello schemas
also support authentication fields. The Go adapter uses the pinned revision's
`hello.auth` password field, omitting it when no credential is configured.
Allow unencrypted WebSockets only on
loopback for direct connections; require verified TLS for remote direct connections.

For relay connections, set `PASEO_PAIRING_LINK` to the v2 pairing link and leave
`PASEO_URL` unset. The offer supplies the relay endpoint, routing server ID, and
daemon public key. The transport validates those fields, generates an ephemeral
keypair, performs the relay's `e2ee_hello`/`e2ee_ready` exchange, and encrypts
every subsequent Paseo message with NaCl box. It honors the offer's TLS choice,
while end-to-end encryption and the pinned daemon key remain mandatory. The
protocol handshake's server ID must also match the offer. Any configured
password travels inside that encrypted handshake, never in relay upgrade headers.

JSON remains encrypted base64 text even after binary-ciphertext negotiation.
The receiver also supports binary ciphertext and the upstream legacy framing.
Handshake retries reuse the ephemeral key for that connection; reconnects
create a new keypair. Wrong keys, tampering, plaintext application frames,
malformed messages, and timeouts fail the connection. The Go 1.27 implementation
uses the maintained [Go NaCl box package](https://pkg.go.dev/golang.org/x/crypto/nacl/box)
and the existing Swift interoperability vectors.

In Docker, `NOTIFY_DOCKER_NETWORK_MODE=bridge` provides ordinary outbound
networking for the relay. The default `host` mode remains useful for a local
direct daemon. All other notification behavior and delivery-policy limitations
are shared between the transports.

For the passive prototype, negotiate explicit event subscriptions, wait for
`server_info`, verify the configured server ID, and send a correlated
`session.events.set_subscription.request` for `agent_attention_required` with
`notifications: false`. Restore it after reconnect and release the owned
subscription on shutdown. Never advertise the process as a visible or focused
UI. Unknown reasons are ignored; malformed targets are rejected.
The current [wire schema](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/protocol/src/messages.ts)
has no message ID in the attention notification data.

Public package boundaries:

```text
Tools/agent-slinger-notify/
  cmd/agent-slinger-notify/   CLI and signal lifecycle
  config/                   validation and secret loading
  paseo/                    handshake, subscriptions, event decoding
  notify/                   reason filter, delivery gate, deduplication
  deeplink/                 versioned URL encoding
  pushover/                 HTTP sender and response classification
  state/                    bounded outbox and deduplication persistence
```

Keep policy separate from transport: a decoded event is not automatically a
send request. Inject the event source, sender, clock, and store so offline
fixtures can verify the delivery decision without making real pushes.

## Pushover delivery

POST to `https://api.pushover.net/1/messages.json` with `token`, `user`, `title`,
`message`, `url`, and `url_title`; optionally select `device`. Use normal
priority. The supplementary URL supports custom schemes; opening the alert in
Pushover exposes the link, which then launches Agent Slinger. This is a two-step
interaction, not a native Agent Slinger notification action.

Require HTTP 200 and response `status: 1` for acceptance. Reuse one HTTP client
and serialize sends. Retry temporary failures no sooner than five seconds;
do not repeat unchanged invalid requests. Surface quota/authentication failures.
Enforce the provider's limits: 1024 message characters, 250 title characters,
512 URL characters, and 100 action-title characters. Reject an oversized route
instead of truncating identifiers. See [Pushover API](https://pushover.net/api).

Use a bounded persistent outbox with an expiry and backoff per event. Deduplicate
by the proposed stable delivery ID; for passive mode use host, agent, reason,
and timestamp, with a per-agent timestamp watermark matching the web handler.
Do not let an old completion block a newer permission request in the queue.
Persist accepted sends and pending work atomically, and enforce a single writer
per state directory. Acceptance is not proof of a device displaying the alert.
An ambiguous timeout or crash after acceptance can produce a duplicate on retry;
do not promise exactly-once delivery. Disconnected attention streams have no
assumed replay guarantee; report coverage gaps rather than claiming recovery.

## Agent Slinger link contract

Implemented versioned scheme:

```text
agentslinger://open?v=1&serverId=server-123&workspaceId=workspace-789&agentId=agent-456
agentslinger://open?v=1&serverId=server-123&workspaceId=workspace-789&agentId=agent-456&messageId=message-101
agentslinger://open?v=1&serverId=server-123&workspaceId=workspace-789&agentId=agent-456&permissionId=request-202
```

Use `net/url` in Go and `URLComponents` in Swift. Treat IDs as opaque and encode
them exactly once. Include no endpoint, pairing offer, credentials, permission
decision, or agent text. `workspaceId` is a Paseo workspace identity, not a
project ID or filesystem path. Validate supplied payload host/agent identifiers
against the authenticated event before building the URL.

The base route follows Paseo's notification tap intent: open the known host,
resolve the workspace and agent, and select that conversation. Paseo's
[notification router](https://github.com/getpaseo/paseo/blob/9246813fd2acd6afc7012c5fde79a164b8f8592e/packages/app/src/utils/notification-routing.ts)
falls back to host root when the workspace target is incomplete. Its separate
`paseo://h/<server>/agent/<agent>` scheme belongs to Paseo; Agent Slinger should
register its own scheme.

Message and permission anchors extend upstream behavior. Add them only when
authoritative correlated data identifies the target. Never guess that the latest
message belongs to a completion event: the agent may already have started a new
turn. When no reliable anchor exists, link to the session. For a permission
anchor, resolve the request ID to its current permission card rather than
assuming it is a message ID. If enrichment times out, keep the session action.

App routing uses URL registration in [project.yml](../project.yml),
`.onOpenURL` in [OesapApp.swift](../Sources/Oesap/OesapApp.swift), and an open-intent
coordinator in [OesapModel.swift](../Sources/Oesap/Features/OesapModel.swift):

1. Parse an allowlisted scheme, route, version, and parameter set. Reject
   duplicate keys, conflicting anchors, empty IDs, credentials, and oversized URLs.
2. Retain the intent through cold launch, connection setup, and authentication.
   Map `serverId` to a saved instance, reconnect, and verify the handshake ID.
   An unknown host opens setup with an explanation; a URL never imports credentials.
3. Fetch the agent and resolve its current project/workspace using authoritative
   metadata. Navigate through the existing selection methods, with connection
   and selection generation checks so stale loads cannot replace a newer intent.
4. Fetch timeline state and scroll/highlight the optional anchor. Bound older-page
   lookup; if the anchor is missing or permission is already resolved, show the
   session with an explanation. A deleted agent falls back to the host overview.
5. Keep permission actions in the current app flow. Opening a link never approves
   a request. Native foreground-banner suppression remains Pushover's behavior;
   Agent Slinger cannot control another app's alert presentation.

## Implementation order and acceptance

1. Capture sanitized upstream fixtures for payload wording, reason filtering,
   presence selection, timestamp deduplication, and tap target fallbacks. Retain
   the Apache-2.0 attribution for any ported implementation.
2. Build Go configuration, URL generation, outbox, and Pushover transport with an
   offline HTTP fake. Exercise timeout ambiguity, rejected credentials, Unicode,
   long URLs, restart recovery, and queue bounds.
3. Add the app open-intent path. Validate saved host switching, cold/warm launch,
   disconnected hosts, stale links, message pagination, and permission resolution
   on iPhone, iPad, and Catalyst. Run `just regenerate`, `just mac-build`, and
   `just mac-unit-test` for those app changes. UI automation is excluded at the
   user's request.
4. Prototype the passive observer only under explicit `all-attention` mode. In
   parallel, specify and implement the daemon delivery-decision integration.
5. Enable parity mode only with a verified decision signal. Check a visible
   focused client, a visible client on another agent, hidden recent clients, no
   clients, and multiple clients against Paseo's own selection fixtures.
6. Send a real Pushover test and follow its action on signed installed apps.
   Session routing is the first acceptance gate; exact message routing requires
   a proven correlation source. Document installation and supervision once the
   executable exists.

This direction chooses a user-operated Pushover path for the sidecar described
in [the earlier push proposal](adr/0008-push-notifications.md). It does not require
an Agent Slinger APNs gateway. Exact presence parity and reliable message anchors
are the two integration requirements to resolve before calling the design complete.
