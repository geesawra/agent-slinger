# ADR 0009: Native Markdown for messages and live composer editing

- Status: Accepted
- Date: 2026-09-27

## Context

Agent replies and the composer should present Markdown clearly while preserving
the original text. Message bodies come from remote hosts and remain untrusted.
The composer should show formatting as people type, without making them switch
between writing and previewing.

## Decisions

- Pin `MarkdownUI` 2.4.1 through Swift Package Manager. It renders GitHub-Flavored
  Markdown with native SwiftUI views and uses `swift-cmark` for parsing. Keep
  `project.yml` as the dependency source of truth and track Xcode's resolved
  dependency graph in the root `Package.resolved`; `Scripts/generate-project`
  copies that lock into the generated project.
- Render remote message bodies through the shared
  `MessageMarkdownView(source:)`. Parse on a dedicated actor and check task
  cancellation before and after parsing so superseded streamed content does not
  update the view. MarkdownUI 2.4.1's `MarkdownContent` is an immutable tree of
  value types, while its public type lacks `Sendable`; the renderer uses a local
  transfer wrapper rather than adding a retroactive conformance.
- Keep composer text in `NativeImagePasteTextView` as editable Markdown source
  and style it live with the pinned cmark-gfm parser. The same editor
  implementation is used in the compact composer and expanded sheet. Markdown
  syntax remains in the text storage and accessibility value while inactive
  delimiters are visually collapsed; delimiters in the active caret block are
  exposed for editing.
- Parse composer edits off the main actor. A newer edit cancels the previous
  parse task, and source and generation checks discard stale results. Style
  headings, emphasis, code, links, quotes, and lists. Tables remain editable
  Markdown source and are not laid out as a rendered grid. For drafts longer
  than 100,000 UTF-16 code units, keep the editable source in plain text without
  Markdown styling.
- Use MarkdownUI's basic theme and the system body font so its scaled metrics,
  relative heading sizes, and monospaced code remain responsive to Dynamic Type.
  Keep text selectable.
- Replace both Markdown image providers. Block images show a local placeholder
  and inline images use a local SF Symbol; neither provider fetches host URLs.
  Render with SwiftUI rather than a web view, so received HTML is never
  executed. Route tapped links through an `openURL` policy that accepts only
  absolute HTTP and HTTPS URLs without embedded credentials.
- Keep compact and expanded composer input in the same draft binding, retaining
  Markdown source while formatting it live. Place Send inside the trailing edge
  of both composer surfaces with a 44-point touch target. In compact mode, show
  Expand above Send only after the text exceeds two visual lines, also with a
  44-point target. The expanded native sheet sends after dismissal, preserving
  existing running-agent and uncertain-send choices. This follows Apple's
  [Sheets guidance](https://developer.apple.com/design/human-interface-guidelines/sheets)
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
