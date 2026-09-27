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

- Keep the chat timeline status focused on agent state and provider/model
  information. Put a compact Context disclosure and, while running, Stop in a
  fixed accessory row immediately above the shared composer. Context opens a
  native usage sheet with reported token counts and the matching provider quota
  only when the agent provider ID exactly matches a host report ID. Stop keeps
  its native confirmation.
- On iOS 26 and later, use native Liquid Glass controls for the composer and
  accessory row, grouped with `GlassEffectContainer`; use native material and
  bordered controls on the iOS 17 fallback path. Follow Apple's
  [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
  for the separation between controls and content.
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

## Validation

The simulator build and strict Swift format lint passed on 27 September 2026.
Eight functional UI flows passed in `.build/glass-accessory-verified.xcresult`,
and two focused checks passed in `.build/glass-accessory-tint.xcresult`. The
native accessibility audit still reports contrast failures for the Context
and Stop labels. In the captured light appearance, sampled black glyphs over
the glass backdrop measured 20.65:1; that single appearance does not establish
contrast across other dynamic backdrops, so the audit finding remains
unresolved and is not suppressed.
