# ADR 0010: Agent model and reasoning settings

Date: 27 September 2026

## Context

Oesap showed an agent's model in thread lists but offered no way to change its
model or reasoning level. The host owns provider catalogs and agent sessions,
so the controls must use its advertised choices and mutation semantics.

Protocol authority: Paseo commit
[`30178c4f58b67f8472901356e1484022bd835de0`](https://github.com/getpaseo/paseo/tree/30178c4f58b67f8472901356e1484022bd835de0),
verified as upstream `HEAD` on 27 September 2026. Sources consulted:
`packages/protocol/src/messages.ts`, `packages/client/src/daemon-client.ts`,
`packages/server/src/server/session/agent-config/agent-config-session.ts`,
`packages/server/src/server/agent/agent-manager.ts`, provider implementations,
`docs/architecture.md`, and `docs/protocol-compatibility.md`.

## Decision

The agent settings surface reads `fetch_agent_request` / `fetch_agent_response`
for the agent's current `model`, optional `thinkingOptionId`, optional
`effectiveThinkingOptionId`, `currentModeId`, and advertised `availableModes`.
Mode entries carry opaque IDs, labels, and optional descriptions. It reads the workspace-specific
`get_providers_snapshot_request` catalog, including each selectable model's
`thinkingOptions` and `defaultThinkingOptionId`. A compact provider snapshot is
expanded at the protocol boundary when present. Oesap keeps these wire fields
in protocol models and maps them into UI-facing settings models.

The explicit Apply action sends one `agent.config.apply.request` for the selected
agent when `server_info.features.agentConfigApply` is true. Its `config` carries
`modelId` as a model ID or `null` for the provider default. It carries
`thinkingOptionId` as an option ID or `null` for default only when
`server_info.features.agentThinkingUpdate` is true. When a permission mode is
selected, optional `modeId` carries its ID; omitting the field leaves the mode
unchanged. A mode-only Apply carries only `modeId`, leaving model and reasoning
untouched. An effort-only Apply carries `thinkingOptionId` (including `null` for
the provider default) and optional changed `modeId`, omitting `modelId`. This
avoids reapplying an unchanged model before changing effort. The response is
`agent.config.apply.response` with `payload.requestId`, `agentId`, `accepted`,
`error`, and optional provider `notice`. A missing `agentConfigApply` capability
keeps the details readable and the controls unavailable. The existing provider
snapshot capability gates model discovery; an older host without it can still
show the agent's reported settings IDs. Provider availability and at least one
selectable model or advertised mode also gate Apply. The agent's
`supportsDynamicModes` flag is not a mode-picker gate: Codex advertises it as
false while exposing modes and accepting mode changes.

The combined request prevents another client from interleaving between its
settings steps, but it is **not a transaction**. Paseo applies model first,
then mode, then reasoning; a later rejection leaves earlier changes in place. Oesap
surfaces the host's rejection and refreshes the agent snapshot after success or
failure. It never retries the mutation automatically. Responses and snapshots
are correlated by request and agent ID; an unmatched agent snapshot is rejected.

For Codex, Paseo reads model and effort into each turn's start parameters.
Its thinking setter reports "Thinking level applies next turn" during an active
turn. Claude reports the same timing for thinking while active. Other provider
behavior may differ, so the UI presents a returned provider notice rather than
claiming an immediate change to a running turn. Applying settings does not
cancel an active turn.

## Compatibility and validation

Paseo's `agentConfigApply` feature was added in v0.3.2 and
`agentThinkingUpdate` in v0.2.4. Both flags are optional on the wire. Oesap
requires their advertised `true` values as described above and does not
compose legacy setters as a fallback. The catalog parser tolerates additive
fields and absent optional reasoning metadata. Sanitized protocol fixtures
cover null/default encoding, feature gates, compact thinking sets, request
correlation, mismatched agent identity, mode-only and effort-only omission of
unrelated fields, notices, and rejected mutations.

The upstream TypeScript client informed wire behavior only; Oesap does not
include its code or add it as a runtime dependency.
