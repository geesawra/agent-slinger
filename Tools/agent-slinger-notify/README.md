# Agent Slinger notification sidecar

`agent-slinger-notify` observes one Paseo daemon and sends normal-priority
Pushover alerts using your application token and recipient key. It is a separate
foreground process. It never sends UI presence, focus, or permission decisions.

The adapter is pinned to Paseo commit
[`9246813fd2acd6afc7012c5fde79a164b8f8592e`](https://github.com/getpaseo/paseo/tree/9246813fd2acd6afc7012c5fde79a164b8f8592e).
It supports a direct WebSocket or a v2 encrypted relay pairing link and
negotiates protocol v1 with explicit and owned subscriptions, verifies
`server_info.serverId`, and subscribes to `agent_attention_required` with
`notifications:false`. When an optional password is supplied, the direct
WebSocket hello includes `auth:{kind:"password",password:...}`; otherwise it
omits authentication. Reconnection acquires a fresh owned subscription.
Graceful shutdown releases it with a correlated acknowledgement when connected.

Only explicitly configured `all-attention` delivery is available. Completion
(`finished`) and permission events are eligible regardless of other clients'
presence or `shouldNotify`; errors and unknown reasons are excluded. This can
duplicate Paseo's own alerts and notify while you are already viewing the agent.
`paseo-parity` is rejected: this revision exposes no external remote-delivery
decision. The sidecar cannot infer that decision from `shouldNotify`.

## Build and environment

Go 1.27 or later is required. From the repository root:

```sh
just sidecar-build
just sidecar-test
```

All settings come from environment variables. There are no configuration files,
secret-file options, or credential command-line arguments.

| Environment variable | Requirement / default |
| --- | --- |
| `PASEO_URL` | Direct endpoint; default `ws://127.0.0.1:6767/ws` when no pairing link is set |
| `PASEO_PAIRING_LINK` | Optional v2 encrypted relay pairing link; mutually exclusive with explicitly set `PASEO_URL` |
| `PASEO_SERVER_ID` | Optional expected identity pin; otherwise discovered from `server_info` |
| `PASEO_SERVER_NAME` | Optional display name; otherwise daemon hostname, then actual server ID |
| `PASEO_PASSWORD` | Optional; absent or empty omits authentication |
| `PUSHOVER_APP_TOKEN` | Required personal Pushover application token |
| `PUSHOVER_USER_KEY` | Required Pushover user/group key |
| `PUSHOVER_DEVICE` | Optional single device name; empty targets all active devices |
| `NOTIFY_DELIVERY_MODE` | Must explicitly be `all-attention` |
| `NOTIFY_CONTENT` | `paseo-preview` (default) or explicit `generic` preview opt-out |
| `NOTIFY_STATE_DIR` | Required private state directory; relative to process working directory |
| `NOTIFY_MAX_PENDING` | Default 256; range 1–10000 |
| `NOTIFY_EVENT_TTL_SECONDS` | Default 86400; range 5–604800 |

Set secrets using your shell or supervisor's environment facilities. For a
protected daemon set `PASEO_PASSWORD`; a password is never required for an
unauthenticated daemon. The port in the default endpoint is illustrative.
Direct remote WebSockets require verified `wss`; direct unencrypted `ws` is
allowed only for numeric loopback addresses. Relay transport honors the pairing
offer's TLS setting and always enforces an encrypted channel pinned to the
supplied daemon public key, including a self-hosted relay using `ws`.
Authentication and session messages travel
inside that encrypted channel; the pairing link never enters action URLs or logs.
Keep it private. The returned server identity must match the relay offer and any
optional explicit identity pin. Pushover always uses verified HTTPS.

The daemon supplies its stable server identity during the handshake. The sidecar
uses that actual identity in action links even when you omit `PASEO_SERVER_ID`.
Setting the variable adds a check that you connected to the expected daemon.
Your saved Agent Slinger host must refer to the same server identity; the app
may independently reach it through a relay. Notifications identify the agent
and generating daemon. The title is **Fix login — turn finished**; the body
starts with a bold **Server:** label and the server name, followed by the event
preview. Pushover renders this HTML styling inside its app; system notification
banners strip the markup. See [Pushover's HTML documentation](https://pushover.net/api#html).
The agent title comes from an exact authoritative agent lookup. If that lookup
fails or the title is empty, the alert identifies **Agent <id>** and keeps its
existing valid action and event preview. Server display uses `PASEO_SERVER_NAME`
when supplied, otherwise the daemon's handshake hostname, otherwise its actual
ID. Relay endpoint names are never used as daemon labels. Display names do not
change identity verification, links, or persistence scope.

`NOTIFY_CONTENT=paseo-preview` is the default and forwards the finished turn or
permission preview supplied with that event. It may disclose agent text or
permission details to Pushover. The sidecar never reads a newer transcript to
guess which message completed the turn. Set `NOTIFY_CONTENT=generic` to omit
previews; the title still identifies the agent and the body identifies the server.
Labels and bodies collapse whitespace, remove controls including directional overrides, and
truncate by Unicode characters within provider limits, reserving space for the
server line, separator, HTML tags, and escaped entities in the 1024-character
body limit. Server names and previews are always HTML-escaped, so text supplied
by the daemon never becomes markup. Existing queued plain-text messages keep
their original format; only newly formatted messages request `html=1`. Both modes
send opaque session IDs in the action URL and retain queued message content privately.

```sh
# Optional extra identity check: export PASEO_SERVER_ID='your-daemon-server-id'
export NOTIFY_DELIVERY_MODE=all-attention
export NOTIFY_STATE_DIR="$PWD/notify-state"
# Set PUSHOVER_APP_TOKEN and PUSHOVER_USER_KEY through your secret facilities.
# Optionally set PUSHOVER_DEVICE, PASEO_URL, PASEO_PASSWORD, or PASEO_SERVER_NAME.
# Preview opt-out: export NOTIFY_CONTENT=generic
# For relay: unset PASEO_URL and set PASEO_PAIRING_LINK instead.
.build/agent-slinger-notify check
.build/agent-slinger-notify run
# Explicitly sends a real labelled test alert:
.build/agent-slinger-notify test --agent-id FULL_AGENT_ID
```

## Commands and actions

`check` validates settings, recipient/device through Pushover's validation
endpoint, and daemon identity/protocol/subscription support. It **never posts
a message**. `test` resolves the exact full agent ID and current workspace
through the daemon and sends one labelled session action. An optional
`--workspace-id ID` asserts the resolved workspace. Prefixes and titles are
not accepted as exact identities. Test sends are not automatically retried;
an ambiguous response may already have been accepted.

`run` emits JSON health logs on stderr: connection/subscription status, coverage
gaps, pending counts, deduplicated events, dropped targets, expiry, and sender
outcomes. Logs omit credentials, URLs, agent identifiers, arbitrary server error
text, and agent previews. SIGINT/SIGTERM cancels delivery and releases the owned
subscription when connected. A sender credential rejection stops the process
with pending work retained; correct the environment and restart. Missing agent
label enrichment is reported without dropping an otherwise valid alert. Quota/rate-limit
and transient failures delay sends, respecting `Retry-After` and quota reset
headers, with a minimum five-second cooldown and per-event exponential backoff.

Action links use `agentslinger://open?v=1&serverId=...&workspaceId=...&agentId=...`.
Opaque IDs are encoded once, including spaces, plus signs and Unicode. Pushover
requires you to open the alert and then tap **Open Agent Slinger**; it is a
two-step action. The attention wire payload has no correlated message/permission
anchor, so the sidecar opens the session. It does not guess the latest message.
Missing workspace metadata is resolved with a bounded authoritative lookup.
Unresolvable or mismatched targets are dropped and reported. Supplied host and
agent metadata must match the authenticated event. Routes over 512 bytes are
rejected without truncating identifiers.

## Docker

Compose passes the environment into the container and sets `NOTIFY_STATE_DIR`
to its persistent volume's absolute path. Set the required settings first:

```sh
# Optional extra identity check: export PASEO_SERVER_ID='your-daemon-server-id'
export NOTIFY_DELIVERY_MODE=all-attention
# Set PUSHOVER_APP_TOKEN and PUSHOVER_USER_KEY through your secret facilities.
# PASEO_PASSWORD remains optional.
cd Tools/agent-slinger-notify
docker compose build
docker compose run --rm agent-slinger-notify check
docker compose up -d
docker compose logs -f
# Explicitly send a real labelled test only when you want one:
docker compose run --rm agent-slinger-notify test --agent-id FULL_AGENT_ID
```

For an encrypted relay connection, set `PASEO_PAIRING_LINK`, leave `PASEO_URL`
unset, and use ordinary Docker networking with
`NOTIFY_DOCKER_NETWORK_MODE=bridge`. Compose passes the pairing link through the
environment. The sidecar validates relay v2 compatibility and authenticates
inside the encrypted session.

Compose defaults to host networking so the loopback URL reaches the host daemon.
Host networking works on Linux and [OrbStack](https://docs.orbstack.dev/docker/network).
[Docker Desktop 4.34+](https://docs.docker.com/engine/network/drivers/host/)
requires enabling its host-networking feature. If your environment does not
support host networking, supply a reachable trusted `wss://.../ws` endpoint;
`ws://host.docker.internal` is deliberately rejected as non-loopback.

The image runs as UID/GID 65532, includes CA roots, and stores its private outbox
in the `notify-state` named volume at `/var/lib/agent-slinger-notify`. Initial
volume creation copies the image's private directory with the correct ownership.
The root filesystem is read-only. `docker compose down` retains pending work;
removing the named volume discards it. Do not run two `run` processes against
the same volume. `check` and `test` can be used while `run` is active because
they do not acquire or modify the outbox.

## Persistence and coverage

The outbox is bounded by `NOTIFY_MAX_PENDING`. Events expire at their source
timestamp plus `NOTIFY_EVENT_TTL_SECONDS`. Ready permissions take precedence
over completions. On overflow the oldest queued completion is evicted first;
otherwise the oldest pending item is evicted. Dropped/expired counts appear in
health logs.

The initial daemon connection establishes the actual server identity before the
outbox is opened. Until that first connection succeeds, pending work is not
loaded or delivered. Reconnection stays pinned to that identity for the life of
the process; a different server identity stops it. Persistence scope always uses
the discovered server identity, so adding or removing an optional pin does not
change compatible state.

A private state directory has exactly one writer, enforced by a process file
lock automatically released on exit. Atomic, fsynced snapshots contain both
pending work and per-agent timestamp watermarks, including accepted-send
removals. Duplicate/equal/older event timestamps are suppressed across restart.
Watermarks are bounded to 4096 agents and expire after 30 days; deduplication is
limited to that retained horizon. State is scoped to server identity, recipient,
device, content and delivery mode. Upgrading from the old generic default to
preview mode atomically accepts only the exact same server/recipient/device/mode
generic scope and preserves queued generic messages, retries, and watermarks.
Those previously queued messages keep their original generic wording. Explicit
generic mode retains its existing scope. Switching an existing preview outbox
back to generic still requires a separate state directory, preventing queued
previews from leaking through an opt-out. A different server, recipient, or device
also requires a separate state directory.

Acceptance requires HTTP 200 and JSON `status:1`; it does not prove the device
displayed an alert. A timeout or crash after acceptance can cause a repeat on
retry. Exactly-once delivery is not promised. The stream has no assumed replay
guarantee; alerts during disconnection may be missed. JSON health logs report
coverage gaps rather than claiming catch-up recovery.

Public packages `config`, `paseo`, `notify`, `deeplink`, `pushover`, and `state`
can be reused independently. Offline tests inject environment getters, clocks,
senders, outboxes and event sources; HTTP/WebSocket fixtures stay on loopback.
Run `go test -race ./...`, `go vet ./...`, and `go build ./cmd/agent-slinger-notify`
from this module. Its external dependencies are pinned Gorilla WebSocket
v1.5.3 (BSD-2-Clause), golang.org/x/crypto v0.58.0, and x/sys v0.49.0
(BSD-3-Clause). The adapter follows upstream wire schemas and forwards
preview text; it does not port Paseo's Markdown builder or presence policy.
Source protocol attribution: Paseo contributors, Apache-2.0. Provider constraints
follow the [Pushover API](https://pushover.net/api).
