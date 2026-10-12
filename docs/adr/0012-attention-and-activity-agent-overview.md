# ADR 0012: Agent overview ordered by attention and activity

- Status: Accepted
- Date: 2026-10-12

## Context

Project sections can hide an agent needing attention below unrelated running
agents. People need the most actionable threads at the top of the Agents home
view, with recent activity deciding the order within each category.

## Decision

- Default to all saved servers, with a list section titled by the saved server
  name. Offer a selected-server scope. Within each section, display a sorted list
  across projects, with the project name on every row. Server sections with
  attention threads come first, then sections with more recent activity.
- Put threads with `requiresAttention` or a waiting state first. A failed thread
  with the attention flag participates in this category. Preserve the existing
  independent running, attention, and error counts.
- Within each category, sort descending by the host's `updatedAt`, falling back
  to `createdAt` if the update timestamp cannot be parsed. Unknown dates sort
  last in their category; equal dates use project ID and thread ID for a stable
  order. Parse timestamps as dates so offsets and fractional seconds compare
  correctly.
- Keep project groups inside per-instance snapshots. Flatten them for display;
  the server section and project/thread row identity together distinguish rows
  even when servers have identical project and thread IDs. Opening a row selects
  its originating instance, confirms server identity, and refreshes its threads.
- Continue to display project errors with their project names and preserve stale
  rows, Active/All filtering, and explicit refresh. This change does not add
  timeline subscriptions.

## Consequences

Attention priority applies across projects within a server section. Recency reflects host record updates,
not a client-inferred timeline activity time. The optional activity timestamp
allows older fixtures or unavailable dates to remain visible without inventing
recency. Concurrent saved-host connections and their lifecycle are described in
[the all-server overview design](../all-host-agent-overview.md).
