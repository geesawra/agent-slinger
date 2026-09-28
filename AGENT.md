# Oesap agent guide

## Product intent

Oesap is a native Apple-platform client for the [Paseo](https://github.com/getpaseo/paseo)
protocol. It lets people securely monitor and control coding agents running on
their Paseo hosts from a fast, polished iPhone, iPad, and Mac app.

The product direction is:

- Swift and SwiftUI, with native Apple frameworks and system UI as the default.
- A clear separation between SwiftUI, app/domain state, Paseo protocol
  transport, and persistence.
- A small, testable protocol layer and a real end-to-end vertical slice rather
  than broad placeholder screens.
- A fluid, responsive interface that remains useful across loading, offline,
  reconnecting, and agent-attention states.

This app is a client of a Paseo daemon; it does not run coding agents on the
device or replace the daemon. Oesap targets iPhone and iPad on iOS/iPadOS 17
and later, with Mac support through Mac Catalyst on macOS 14 and later. The
shared iOS target reuses SwiftUI views, UIKit text/image services, domain and
protocol code, and persistence across all three devices. Do not add standalone
AppKit, other Apple-platform, Android, or backend targets without explicit
product approval. Generate the Xcode project from the checked-in
`project.yml` using XcodeGen 2.46.0 and `Scripts/generate-project`; do not edit
the generated `.xcodeproj` directly. The initial iOS deployment target is
17.0, carried over from Hydraulophone. `com.oesap.app` is a provisional
development bundle identifier and must be confirmed before distribution.
Record changes to these project decisions in an ADR.

## Apple platform and UX principles

Use Apple's current Human Interface Guidelines and native platform behavior as
the baseline. In particular:

- Prefer standard SwiftUI controls and containers: `NavigationStack`,
  `TabView`, `List`, `Form`, toolbars, menus, sheets, alerts, confirmation
  dialogs, text fields, and native keyboard/focus behavior where they fit.
- Do not replace a standard system control with a custom-drawn imitation.
  Custom views are appropriate for product-specific content, not for avoiding
  native accessibility, interaction, or platform conventions. Record the
  reason when a custom control is necessary.
- Use familiar navigation, clear information hierarchy, concise labels, and
  predictable back, dismiss, and swipe behavior. Confirm destructive or
  consequential agent actions; do not interrupt routine actions with needless
  confirmation.
- Make agent state and required user attention easy to distinguish. Keep the
  primary task visible and do not hide important status behind decoration.
- Support Dynamic Type, VoiceOver, sufficient color contrast, Reduce Motion,
  keyboard and focus use, safe areas, and usable touch targets from the first
  real screen. Never communicate state using color alone.
- Use SF Symbols and system materials intentionally. Motion should clarify
  state changes, remain lightweight, and honor Reduce Motion.
- Design loading, empty, partial, error, offline, reconnecting, and permission
  waiting states alongside the success state. Preserve user-entered drafts
  across transient connection failures where appropriate.
- Keep the interface responsive: do not perform networking, large decoding,
  disk work, or long-running stream processing on the main actor. Avoid
  unnecessary polling and animations that obscure live agent output.
- Adapt layouts to the supported device sizes and orientations; do not hard-code
  a single simulator's dimensions.

Do not claim conformance to every Apple guideline as a substitute for reviewing
the actual screens and interactions. Validate real flows with accessibility
tools and on-device testing when available.

## Paseo protocol boundary

Paseo's daemon owns agent processes, workspaces, and their underlying machine
resources. Oesap connects to that daemon and presents its capabilities. The
protocol evolves, and the daemon and mobile app can be updated independently.
Treat upstream sources as the protocol authority, not assumptions from UI
behavior or old examples.

Before implementing or changing protocol behavior:

1. Inspect the current upstream
   [`packages/protocol`](https://github.com/getpaseo/paseo/tree/main/packages/protocol)
   wire schemas and relevant
   [`packages/client`](https://github.com/getpaseo/paseo/tree/main/packages/client)
   behavior. Consult
   [`docs/architecture.md`](https://github.com/getpaseo/paseo/blob/main/docs/architecture.md)
   and
   [`docs/protocol-compatibility.md`](https://github.com/getpaseo/paseo/blob/main/docs/protocol-compatibility.md)
   for the current system and compatibility rules.
2. Record the Paseo commit consulted, observed wire behavior, supported daemon
   versions/capabilities, and any intentional Oesap behavior in a protocol
   note or ADR.
3. Keep protocol types and serialization behind a small Swift adapter. Keep
   wire DTOs separate from stable app/domain models; do not let SwiftUI decode
   or construct WebSocket messages.
4. Add sanitized fixtures and tests for supported request and response shapes.
   Never commit host credentials, agent prompts/output containing personal
   data, or captured private workspace information.

The upstream TypeScript client is a behavioral reference, not a Swift runtime
dependency. Do not port it wholesale or copy source without first checking its
license and preserving required notices. Do not invent message names, fields,
defaults, or capability semantics. Treat IDs, cursors, tokens, and other
opaque protocol values as opaque and pass them through unchanged.

Preserve the upstream compatibility contract:

- Parse additive messages and unknown fields defensively. Missing optional
  fields should produce a typed absence or documented default, never a crash.
- Use daemon-advertised capabilities to gate features that require them. Put
  compatibility decisions at the protocol boundary rather than spreading
  legacy fallbacks through screens.
- Do not require a new app feature from an old daemon unless the daemon
  advertises the needed capability. Do not fake unavailable functionality by
  composing unrelated RPCs.
- Respect request/response correlation, connection lifecycle, protocol framing,
  and explicit subscription ownership. Connecting alone must not silently
  create unbounded stream demand. Release subscriptions when their consumers
  leave and restore the required subscriptions after reconnect.
- Treat live timeline events as updates for responsiveness and use the
  protocol's authoritative history/snapshot operations for initial state and
  recovery from gaps, when those semantics apply.
- Keep reconnects cancellation-aware, bounded, and backoff-based. Do not retry
  authentication, malformed-message, or user-cancelled operations forever.
- Use Paseo-supported direct and/or relay connection flows. Do not invent a
  relay handshake or cryptographic scheme. Relay encryption, pairing, and
  credential flows must follow upstream implementations and test vectors; if
  that cannot be verified, stop and document the blocker rather than weakening
  security.

The exact first-release feature set is a product decision. Favor a thin,
end-to-end flow that proves host connection, agent/workspace discovery, live
agent state, timeline viewing, sending a prompt, and handling a permission or
other user-attention request before adding broad secondary protocol surfaces.
Do not leave placeholder screens presented as completed functionality.

## Architecture and Swift implementation

Keep these boundaries explicit:

```text
SwiftUI views
    -> feature state / view models
        -> domain services
            -> Paseo protocol client / transport
            -> Keychain-backed credentials and app persistence
```

- Views render state and send user intents. They do not create
  `URLRequest`s/WebSocket frames, decode protocol payloads, or own unbounded
  connection tasks.
- Keep UI-facing state on the main actor. Use Swift structured concurrency,
  cancellation, and `Sendable` value types; use actors for shared mutable
  connection, subscription, and cache state where helpful. Do not mark the
  whole application `@MainActor` to avoid designing isolation.
- Keep connection lifetime and per-host state explicit. A screen's lifetime
  must not accidentally own or tear down an app-wide host connection.
- Prefer Observation and simple dependency injection when supported by the
  chosen deployment target. Avoid introducing a large architecture or
  networking dependency without a concrete, documented benefit.
- Prefer `URLSession` WebSocket support, `Codable`, Keychain Services, and
  other system APIs when they meet protocol requirements.
- Use typed errors that distinguish authentication, unsupported capability,
  transport loss, malformed data, and user cancellation. Do not turn failures
  into empty agent lists or silently suppress them.
- Avoid force unwraps, `try!`, unstructured long-lived tasks, and
  `Task.detached` without a documented isolation and cancellation reason.
- Keep previews and sample data deterministic and offline. Do not include
  real host data or secrets in previews, screenshots, or tests.

## Security and privacy

Paseo can expose access to development hosts, agent conversations, and
workspace operations. Treat connection material and all data received from a
host as sensitive.

- Store passwords, pairing secrets, relay keys, and other credentials in the
  Keychain, never in `UserDefaults`, source, fixtures, analytics, or ordinary
  logs. Clear associated secrets on explicit disconnect/removal where expected.
- Redact credentials, authorization headers, pairing material, raw prompts,
  private agent output, and workspace paths from logs and diagnostics unless a
  reviewed user-initiated diagnostic explicitly needs them.
- Do not add telemetry, tracking, or a service that receives agent data without
  explicit product approval and a privacy review. Make any relay or other
  third-party data path visible and accurately describe its security model.
- Treat remote agent text and file names as untrusted content. Render safely;
  do not execute received commands, scripts, links, or markup as a side effect
  of displaying them.
- Use secure transport and authentication exactly as supported by Paseo. Never
  silently downgrade encryption or bypass certificate validation to make a
  connection succeed.

## Tests, builds, and completion

Test protocol and stateful behavior at the lowest practical layer:

- Unit-test message encoding/decoding, handshake and capability negotiation,
  correlation, frame handling, error mapping, reconnect cancellation, and
  subscription cleanup/restoration.
- Use sanitized fixtures for supported messages, including unknown/additive
  fields, missing optional data, stale/gapped timeline state, and daemon
  capability differences.
- Test feature state with injected fake services and controllable tasks/clocks.
  Test view behavior for loading, empty, failure, offline, and attention
  states.
- Keep the default test suite offline and credential-free. Live daemon tests
  must be explicit opt-ins against a disposable/test host.
- Build and test the configured `Oesap` iOS scheme with `xcodebuild` and
  installed iPhone and iPad simulator destinations, plus the `Oesap` scheme
  with the Mac Catalyst destination on macOS. Do not guess simulator names;
  discover available destinations. Validate security-sensitive connection flows and key platform
  behavior on a physical device when available, and state clearly when that
  validation was not possible.

Before a change, read this guide and any more-specific `AGENT.md` or
`AGENTS.md`, inspect the current project structure, and identify the smallest
vertical slice and its acceptance check. After a change, run focused tests,
formatting/linting checks that exist, and the relevant simulator build/test;
review the diff and generated files for accidental secrets or unrelated
changes.

A change is complete when the requested flow works through the intended native
UI, protocol and UI concerns remain in their layers, failure and cancellation
are handled, tests cover the behavior without live credentials, and relevant
protocol notes or ADRs are updated. Handoffs state what changed, what was
tested, what could not be tested, and remaining risks.

## Agent delegation and model guidance

Agents are free to use as many subagents as are useful for the task. Delegate
independent research, implementation, and review work in parallel when doing so
reduces risk or elapsed time. Give each agent a bounded assignment, avoid
conflicting edits to the same files, and integrate and verify all delegated
changes before calling the task complete.

- Use **`gpt-6-luna-xhigh`** for most, and preferably all, implementation
  work. It is the default implementation model; use another implementation
  model only when the task's needs call for it.
- Use **`gpt-6-sol-xhigh`** for hard implementation or reasoning tasks that
  benefit from its strengths.
- **`gpt-6-astra` is a manager, never an implementor.** It may plan, coordinate,
  delegate, and review. It can also review especially complex work when Sol is
  not well suited to that review, but must not implement code or make direct
  project edits.
- Keep a human-readable summary of delegated work, integration decisions, and
  validation results in the handoff.
