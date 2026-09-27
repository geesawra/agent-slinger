# ADR 0009: Native Markdown for messages and composer preview

- Status: Accepted
- Date: 2026-09-27

## Context

Agent replies and draft previews need the same readable rendering for Markdown
headings, lists, code, tables, and links. Message bodies come from remote hosts
and remain untrusted. The composer preview should show the same output users see
in the conversation.

## Decisions

- Pin `MarkdownUI` 2.4.1 through Swift Package Manager. It renders GitHub-Flavored
  Markdown with native SwiftUI views and uses `swift-cmark` for parsing. Keep
  `project.yml` as the dependency source of truth and track Xcode's resolved
  dependency graph in the root `Package.resolved`; `Scripts/generate-project`
  copies that lock into the generated project.
- Render the original message and draft strings through the shared
  `MessageMarkdownView(source:)`. Parse on a dedicated actor and check task
  cancellation before and after parsing so superseded streamed content does not
  update the view. MarkdownUI 2.4.1's `MarkdownContent` is an immutable tree of
  value types, while its public type lacks `Sendable`; the renderer uses a local
  transfer wrapper rather than adding a retroactive conformance.
- Use MarkdownUI's basic theme and the system body font so its scaled metrics,
  relative heading sizes, and monospaced code remain responsive to Dynamic Type.
  Keep text selectable.
- Replace both Markdown image providers. Block images show a local placeholder
  and inline images use a local SF Symbol; neither provider fetches host URLs.
  Render with SwiftUI rather than a web view, so received HTML is never
  executed. Route tapped links through an `openURL` policy that accepts only
  absolute HTTP and HTTPS URLs without embedded credentials.
- Keep composer input in the existing draft binding. The native compose sheet
  offers Write and Preview modes on supported device sizes; Preview uses the
  shared renderer. A requested send runs after the sheet dismisses, so existing
  running-agent and uncertain-send choices keep their sequence. This follows
  Apple's [Sheets guidance](https://developer.apple.com/design/human-interface-guidelines/sheets)
  for focused, full-height composition.

## License and constraints

`MarkdownUI` and its `NetworkImage` dependency are MIT-licensed. MarkdownUI's
resolved `swift-cmark` parser is BSD-2-Clause licensed and retains additional
component notices in its `COPYING` file. Their notices are bundled in
`Sources/Oesap/Resources/ThirdPartyNotices.txt` for distribution. Oesap supplies
image providers that do not use `NetworkImage`'s default remote loader.

The parser is pinned to a stable 2.4.1 release. Upstream now describes MarkdownUI
as in maintenance mode and points to Textual as its successor; revisit the
choice if Oesap needs features beyond this native GFM renderer.
