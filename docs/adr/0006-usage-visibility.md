# ADR 0006: Context and provider usage visibility

## Status

Accepted

## Context

Paseo reports context-window token counts on agent snapshots and turn completion
events, and exposes a separate host-level provider quota report. These values
have different meanings: context use belongs to one agent thread, while provider
quotas describe credentials and plans available to the host. Context reports
have no timestamp and may describe an earlier turn. Provider quota responses
can be cached by the daemon.

The protocol behavior was checked against Paseo commit
`8cd989529e2d86bb6d1c8a775bf695fa5970c997`. Context percentages use only the
reported context-window used and maximum token counts. The cumulative input,
cached-input, output, and cost totals are not substitutes for context use.
Provider quota listing is gated by the host's `providerUsageList` capability.
Its response is host-wide and can contain multiple windows, signed balances,
unavailable or failed provider reports, and optional reset metadata.

## Decision

- Put a compact context gauge in the chat agent-status card. Tapping it opens a
  native usage sheet with reported token counts and the matching provider quota
  only when the agent provider ID exactly matches a host report ID.
- Label context data as last reported. Show a percentage only when both token
  counts are finite and the context-window size is positive. A partial report
  remains visible without a percentage; missing usage is not shown as zero.
- Add **Usage** to the Projects connection menu. This screen lists every
  host-reported provider, status, plan/source, usage window, balance, details,
  reset/run-out time, and provider error.
- Keep percentage points distinct from fractions. Display the reported finite
  number, including values below zero or above 100; clamp only the visual gauge
  fill. Preserve signed finite balance values and their reported units.
- Treat both surfaces as snapshots with explicit loading, unsupported,
  unavailable, partial, error, and offline states. Show host-provided report
  time when present and explain that Paseo may return cached quota data.
  Refresh asks the daemon again but does not promise to bypass its cache.

## Consequences

The UI does not infer provider limits, remaining balances, percentages, or
context use from unrelated fields. Context may remain unchanged while an agent
is idle, and a quota refresh may return a cached host report. Users can inspect
those semantics alongside the values instead of seeing invented precision or
zeros for missing data.
