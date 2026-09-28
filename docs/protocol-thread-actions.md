# Paseo thread archive and read actions

Protocol behavior was checked against `getpaseo/paseo` commit
`fa93c4290eaa87ae58452ab6e2012f85ae6e0c6b` on 2026-09-28:

- `packages/protocol/src/messages.ts` defines `archive_agent_request` with
  `agentId` and `requestId`; the correlated `agent_archived` response carries
  `agentId`, `archivedAt`, and `requestId`.
- The same package defines `clear_agent_attention` and
  `clear_agent_attention_response`. The request accepts one agent ID or an
  array; Oesap sends one ID when a thread is read.
- `packages/client/src/daemon-client.ts` correlates both operations by
  `requestId`. `archiveAgent` returns the archive timestamp, and
  `clearAgentAttention` completes when its response arrives. These operations
  are not gated by a separate advertised capability in that client.
- `docs/architecture.md` identifies the protocol package as the wire-schema
  authority. `docs/protocol-compatibility.md` says capabilities gate features
  only when the daemon advertises them. The checked client exposes no
  archive/read capability flag or daemon-version floor for these existing
  operations.
- `docs/agent-lifecycle.md` defines archive as a global soft delete that sets
  `archivedAt`, closes the runtime, and removes the agent from active lists. It
  describes clearing attention as the read action when the user views a chat.

Oesap keeps these wire operations inside `PaseoProtocolClient`. The thread
list exposes archive and read actions only while connected. Marking a thread
read clears the host's agent attention, so other Paseo clients observe the same
state; archiving uses the daemon's global archive action. The active thread
list already requests `includeArchived: false`, so a successfully archived
thread is removed from it.

Oesap does not infer that every daemon version supports these calls. The
upstream client does not publish a minimum daemon version or a capability for
them, so an incompatible host response remains an operation error surfaced by
the normal thread-list error state.
