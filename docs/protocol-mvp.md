# Paseo protocol MVP

The Swift adapter was checked against Paseo protocol/client **v0.9.2**, commit
[`8cd989529e2d86bb6d1c8a775bf695fa5970c997`](https://github.com/getpaseo/paseo/commit/8cd989529e2d86bb6d1c8a775bf695fa5970c997), including
`packages/protocol/src/messages.ts`, `client-capabilities.ts`, the owned timeline
subscription client, the timeline client facade, and the compatibility and architecture
docs. The upstream repository is Apache-2.0. Oesap uses the documented wire shapes and
behavior as a protocol reference. Tool-call merge behavior follows
`packages/app/src/types/stream.ts` at the same commit; the Swift app has no
TypeScript runtime dependency.

The adapter sends an initial WebSocket `hello` with `clientType: "mobile"`, protocol
version `1`, `all_providers: true` so threads from non-default providers remain visible,
`timeline_notifications: true` for notification rows rendered by the MVP, and the client
capabilities needed for owned, selective timeline delivery.
It waits for the daemon's `session/status` message whose payload status is
`server_info` before exposing the service as connected. Session RPCs use the upstream
`{"type":"session","message":{...}}` envelope. Every request has an opaque request ID,
and only a response with the matching ID and expected response type completes it.
Unknown JSON fields are retained where the UI may need to inspect provider timeline
items; unknown connection feature values are ignored.

Project listing uses `project.list.request` and is available when the daemon advertises
`server_info.features.projectList`. Agent threads come from paged
`fetch_agents_request` calls, filtered by the selected project's stable ID. The optional
project-list `projectKey` is a separate compatibility field: upstream builds agent
placement with `projectKey: project.projectId`, so the thread filter uses the stable
project ID and does not infer a match from the working directory. Each page is bounded
to 200 entries and carries the daemon's opaque next cursor.

The Agents overview refreshes a fresh project catalog, then requests each project's
entire paged agent directory with at most four projects in flight. It records
per-project failures separately and retains the last available rows as stale data
instead of treating a failed page as an empty project. It does not change the
currently selected project, thread, or timeline while loading. A row selection
installs that project's known thread snapshot before opening its authoritative
Chat timeline. The overview is explicitly a last-refreshed snapshot, updated on
entry/foreground or pull to refresh; it does not claim to be a live subscription.
Paseo's owned `agent_update` directory stream exists, but a correct bootstrap,
pagination, generation-gap recovery, and scoped release are separate work. The
overview never opens per-agent timeline subscriptions or polls the host.

Timeline history always comes from `fetch_agent_timeline_request`. Oesap preserves the
daemon epoch and sequence cursors, pagination flags, reset/stale-cursor markers, and
gap marker. Live updates come from a selective `agent.timeline.set_subscription`
request. The adapter requires both `ownedSubscriptions` and `selectiveAgentTimeline`
server features, keeps each observation's stream bounded, and releases its server
subscription when the consumer cancels or the stream ends. A sequence discontinuity,
epoch replacement, or local buffer overflow emits a reload-required event; consumers
must read authoritative history again before merging more live rows. The response
currently uses a projected timeline even when canonical entries were requested.
Ordinary entries use the epoch and sequence range to identify a row.

Tool-call lifecycle entries use the upstream `callId`, qualified by `turnId` when
present, because a call ID can recur in another turn. Their running, completed,
failed, and canceled snapshots update one row in place. A history window can
contain multiple revisions of the same call; the adapter keeps the latest
sequence and merges later sparse details using Paseo's same-kind merge and
terminal-status precedence. An older page cannot replace a newer loaded revision.
Every tail refresh buffers incoming live events until its authoritative snapshot
has seeded the tool state and cursor, then replays newer events. Epoch changes,
gaps, and buffer overflow still require a fresh history read.

The feature boundary converts tool details into `RemoteToolCall` and typed display
sections before SwiftUI sees them. Shell, read, edit, write, search, fetch,
worktree setup, sub-agent, plain-text, and plan details expose the fields the
daemon supplies, including read offset/limit, shell exit/output, diffs, and
search/worktree truncation. Missing optional values remain absent; unknown
detail kinds get a generic text representation. The UI does not decode wire JSON
or concatenate tool snapshots as chat text. Displayed remote content is data
only and is never executed by the viewer.

Message sends use `send_agent_message_request` and fail when the daemon rejects the
message. Pending permissions are read from the paged agent snapshots. Answering sends
the upstream `agent_permission_response` shape and waits for the matching
`agent_permission_resolved` message before reporting success.

New threads use the host's `creationLifecycle` feature and `agent.create.request` with
one `initialPrompt`, a stable `idempotencyKey`, and a stable `clientMessageId`. The
request includes `config.provider` and `config.cwd` set to the selected project's
`projectRootPath`; `config.model` and `config.modeId` are included only when the
user selected a model or permission mode.
It omits `workspaceId`, allowing the daemon to create a new directory workspace
under that project. The app never sends an older `create_agent_request` with a
prompt, because upstream legacy creation cannot safely key that combination.
If a response is lost, the app retains the original key, config, and prompt for
replay after reconnect. A changed draft or setting does not change an uncertain
intent. A returned agent snapshot establishes a real thread; a reserved `agentId`
alone does not. If the agent exists but the prompt failed or its outcome is unknown,
the app opens that thread with the draft intact. A definitive pre-agent failure can
start a new intent after the user corrects the setting.

Paseo project descriptors do not carry a project agent binding. Oesap therefore
saves a **device-local** provider, optional model, and optional permission mode per stable `serverId` and
`projectId`, and refuses to save under a missing or unknown server ID. The Agent
screen discovers providers and models for the project's root directory through
`get_providers_snapshot_request`, gated by `providersSnapshot` and
`providersSnapshotCwd`. A missing model choice means the provider's default; the
app does not infer a provider from the latest thread or write an undocumented
field to `paseo.json`. Opening a blank New chat does not create a remote resource;
the first send does.

The current direct and relay transports both deliver decrypted text JSON to the
protocol actor. The relay transport owns Paseo's end-to-end encryption handshake;
the protocol actor does not downgrade it or parse encrypted frames. After a transport
failure, the actor fails pending requests and closes its live streams. The feature
store reconnects, reloads history, and calls `events(agentID:after:)` again to restore
live demand. No directory or timeline data is converted into an empty success when a
request fails.

The first supported feature floor for this slice is therefore daemons advertising
`projectList` for the project directory, `stableProjectIdentity` for thread filtering,
and `ownedSubscriptions` plus `selectiveAgentTimeline` for live updates. Oesap surfaces
a typed unsupported-capability error when a required feature is absent. It does not
emulate modern per-consumer ownership over an older daemon's broadcast subscription
behavior. The new-thread flow additionally requires `creationLifecycle`; the Agent
catalog requires `providersSnapshot` and `providersSnapshotCwd` so its options reflect
the selected project's directory.

## Context window and provider usage

This slice was checked against Paseo main at
`8cd989529e2d86bb6d1c8a775bf695fa5970c997` on 2026-09-26. Agent snapshots
contain optional `lastUsage.contextWindowUsedTokens` and
`lastUsage.contextWindowMaxTokens`. Oesap seeds the selected thread from the full
agent snapshots in `fetch_agents_response`, then requests a fresh
`fetch_agent_request` snapshot when the chat opens or the user refreshes usage.
`lastUsage` has no measurement timestamp and may describe an earlier turn, so the
UI labels it last reported. Used and maximum are independent optional fields;
the gauge fills only when both are finite, used is nonnegative, and maximum is
positive. Cumulative `inputTokens` and `outputTokens` are never used as a proxy
for occupied context, and Oesap supplies no model limit of its own.

The wire `agent_stream` union includes `turn_completed.usage`, but not the
provider-internal `usage_updated` event. A complete terminal context report can
update the displayed values immediately. Sparse terminal reports merge with the
previous last-reported fields, matching the daemon's terminal merge, then a fresh
agent snapshot resolves absent fields; a terminal event without context fields
also triggers that fetch. An authoritative snapshot replaces the earlier context
report, even if it is partial. Selection and connection generations prevent old
requests from changing another thread or host. Context fetch failures preserve
the last reported value and surface a local refresh error without treating a
healthy host as disconnected.

Provider allowance data is a separate, host-scoped RPC. Oesap sends exactly
`provider.usage.list.request {requestId}` only when
`server_info.features.providerUsageList` is true (upstream added it in v0.1.98). The response has one
server `fetchedAt` and provider rows with status, optional plan/source/refresh
metadata and error, all reported windows, balances, and details. Window
percentages are optional percentage-point values; balances are optional signed
amounts in their reported units. Finite values are preserved without inferring
an absent value as zero, a quota from a balance, or a universal percentage.
Unknown status/tone/unit strings do not crash parsing. The daemon's usage
service caches results for about five minutes; the wire request has no force
refresh field, so a manual request may return the same server `fetchedAt`.
Oesap keeps prior host values marked stale when a refresh fails or the
connection drops, and clears them on explicit disconnect or a different host
identity. It refreshes on entry, reconnect, and user request without polling.
