# ADR 0003: Native tool-call viewer

## Status

Accepted

## Context

Paseo timelines can include shell, file-read, edit, and provider-specific tool
activity. A plain message bubble hides the status and structure needed to
review those operations, while rendering one unbounded detail string can make
large output slow to inspect on a phone.

## Decision

Render structured tool calls as native SwiftUI `DisclosureGroup` cards. Keep
the timeline row identity stable across live snapshots so an expanded card
stays open when its status or output changes. Show the command and working
directory as inert, selectable text; render file previews and diffs from
typed sections; use plain selectable text for generic provider details.

Long sections show a bounded preview and open a sheet that reveals content in
small pages. The viewer never executes commands, fetches remote files, or opens
URLs from tool data. Live updates do not force-scroll the timeline while a tool
card is expanded.

## Consequences

- Tool status, exit code, errors, output, file previews, and diffs can be
  reviewed in place with Dynamic Type and native disclosure behavior.
- Large output is materialized incrementally, keeping initial timeline layout
  bounded.
- Provider-specific data without a recognized section shape remains visible
  as inert text instead of being interpreted by the view.
