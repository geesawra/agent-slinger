# ADR 0002: Remote Paseo MVP

- Status: Accepted for the first vertical slice
- Date: 2026-09-25

## Context

Oesap needs one complete native flow that connects to a Paseo instance and
lets a person follow and message an existing agent. Both direct host
connections and Paseo relay pairing are part of the requested setup flow. The
UI must expose agent attention and connection failures without treating a
failure as an empty workspace.

## Decisions

- The first release flow is setup, project list, project threads, timeline
  history with live updates, and sending a chat message.
- Setup offers a direct endpoint with an optional password and TLS setting, or
  a pasted Paseo relay pairing link. Connection material is persisted through
  the Keychain-backed connection store.
- SwiftUI depends on feature state and a service boundary. Wire decoding,
  connection lifecycle, and Keychain operations remain below that boundary.
- The app displays loading, empty, offline, error, and agent-attention states.
  A failed send keeps the user's draft for retry.
- Reconnection is explicit and bounded. It reloads the visible workspace and
  restores the selected project/thread timeline when those resources remain
  available.
- A deterministic launch-argument demo service supports offline UI coverage;
  it is not a production connection option.

## Consequences

The initial client stays narrow while proving the full remote interaction. It
can show current daemon data and send prompts without owning agent processes.
Relay setup depends on the pairing behavior and cryptographic implementation
documented by the protocol/transport layers; Oesap must report unsupported or
failed pairing clearly rather than silently lowering transport security.
