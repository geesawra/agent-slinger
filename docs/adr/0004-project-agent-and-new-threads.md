# ADR 0004: Project Agent settings and new threads

- Status: Accepted
- Date: 2026-09-25

## Context

People need a direct way to start an agent for the current project without
choosing an agent separately for every conversation. Current Paseo project
descriptors do not provide provider or model configuration, and its legacy
thread-creation operation cannot safely combine an idempotency key with the
initial prompt.

## Decisions

- Add a project-scoped **Project Agent** screen for the host's available
  providers and models. The selected provider and optional model are Oesap
  settings saved on this iPhone, scoped by verified Paseo server ID and
  project ID. An omitted model leaves the provider's host default in effect.
- Do not infer project defaults from recent threads or expose a per-thread
  provider/model picker. The project screen is the only place to configure
  future agents.
- **New thread** opens a blank chat composer and focuses it immediately. It
  creates the remote thread only after the user sends the first nonempty
  prompt. The creation request includes that prompt and an idempotency key in
  one operation.
- Gate creation on the host's advertised `creationLifecycle` capability. If
  the host lacks it, explain the limitation and keep the draft available; do
  not fall back to an unkeyed create-then-send sequence.
- On confirmed thread creation, replace the blank-chat route with the new
  thread's timeline. If thread creation succeeds but initial prompt delivery
  is uncertain, move the draft to the new thread and prompt the person to
  inspect its timeline before retrying.

## Consequences

Project Agent settings are local to one iPhone and one verified Paseo server;
they are not written into the remote project. Existing threads continue to
work on hosts that do not support new thread creation. A missing stable server
identity prevents saving project configuration rather than risking applying
it to a different host.
