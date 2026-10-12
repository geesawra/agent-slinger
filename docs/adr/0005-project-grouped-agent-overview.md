# ADR 0005: Project-grouped agent overview

## Status

Accepted

The project grouping is superseded by
[ADR 0012](0012-attention-and-activity-agent-overview.md). The snapshot,
filtering, freshness, and navigation decisions below still apply.

## Context

People need a cross-project view of running agents and work that needs
attention without opening and subscribing to every timeline. Paseo exposes
project-scoped agent listings, while Oesap already has a separate project
thread list and per-thread timeline.

## Decision

- Add a top-level **Agents** entry on the Projects screen. Group agent rows by
  project and open a selected thread with its project context restored.
- Default the overview to **Active**: include starting, running, waiting for
  attention, and failed agents. **All** also includes idle and closed agents.
- Show running, attention, and failure counts independently; a thread may
  contribute to more than one count when its state and attention flag overlap.
- Treat the overview as a snapshot. Fetch agent lists on entry, return,
  foreground, reconnect, and explicit refresh. Do not create timeline
  subscriptions or poll individual agents from this screen.
- Keep stale rows visible after connection or per-project refresh failures.
  Mark them as last known, show project/global errors, and explain that counts
  describe only loaded rows. A partial failure must never look like an empty
  overview.
- Provide pull-to-refresh and an explicit refresh action.

## Consequences

The overview stays lightweight as project and agent counts grow, and opening a
row reuses the existing chat timeline flow. Status may be out of date until a
refresh succeeds; the UI labels snapshot freshness and stale data instead of
implying a live view.
