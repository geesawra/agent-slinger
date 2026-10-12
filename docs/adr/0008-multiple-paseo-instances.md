# ADR 0008: Multiple Paseo Instances

- Status: Accepted
- Date: 2026-09-27

Amended 2026-10-12: the selected chat workspace remains single-instance, while
the [Projects and Agents views](../all-host-agent-overview.md) may maintain concurrent
connections to other saved instances while visible. Both group content into
server-named sections and restore the originating server when opening a row.
Settings now manages saved servers without choosing a default or active server.
Opening a project or agent chooses its workspace; connection errors appear in
that server's section and pull-to-refresh retries all catalogs independently.
The selection and Settings retry behavior below records the original decision
and is superseded by this amendment.
Drafts and uncertain sends
are kept in memory per saved instance and restored after matching authenticated
server identity. Explicit removal or disconnect discards that instance's state.

## Context

People may use Oesap with more than one Paseo host, such as a home machine and
a work machine. The app needs a clear way to save connection details, choose
the current host, and recover when that host cannot be reached. Saved
credentials must remain local to the device.

## Decisions

- Settings lists saved instances and marks the currently selected instance.
  Settings is reachable from the connected Projects menu and from the
  disconnected connection setup screen.
- The existing direct and relay setup form is reused to add an instance. Each
  instance may have a user-facing name; the host or relay details remain its
  identifying subtitle. Removing an instance requires confirmation.
- Each instance's complete connection record, including direct passwords and
  relay pairing material, is stored in the Keychain. The collection and its
  `activeInstanceID` are stored together in the Keychain-backed connection
  store. No connection secret is stored in UserDefaults.
- On upgrade, the app migrates the legacy `current-host` Keychain item into a
  one-instance collection. It writes the new collection before deleting the
  legacy item, so a failed write leaves the old saved connection available.
- Choosing an instance persists that instance as active and clears the prior
  host's workspace before connecting. A successful connection returns to the
  Projects root. The selected instance stays selected after a failed
  connection; Settings remains open and displays an error with a retry action
  so the user can retry it or choose another instance. Oesap does not silently
  fall back to another host.
- Removing the active instance clears its saved credentials. The Settings
  list remains open with no active selection, so another instance can be
  selected or added. Oesap does not choose a different host implicitly.

## Consequences

People can keep several local Paseo connections and switch hosts without
re-entering their credentials. A host switch starts at that host's Projects
screen instead of retaining project, thread, or chat routes from the previous
host. Availability and workspace data remain per active connection, and
connection failures are visible at the point where users manage their
instances.
