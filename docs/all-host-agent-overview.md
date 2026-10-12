# Cross-server Projects and Agents

Status: Implemented, 2026-10-12.

## Display and ordering

Projects loads catalogs from all saved servers into sections named after their
saved connections. Project rows carry both instance and project identity, so
matching project IDs on different hosts remain separate destinations. Catalogs
load independently without fetching agent threads. Add project offers a server
chooser when multiple connections are saved, so a server with an empty catalog
is still usable. Selecting a project checks the originating server and refreshes
its catalog before opening the thread list.
Initial project loading uses a small spinner beside the server's section title.
Failed servers keep their error without a loading indicator, including during a
retry. Pull-to-refresh loads all server catalogs directly, without first loading
the selected workspace or its threads. Overlapping refreshes share one batch;
saved-server changes can request a follow-up batch. Connection-loss notices and diagnostics
appear only inside the affected server section; healthy sections remain usable.
Connection diagnostics offer Copy details through a long-press/right-click
context menu and an accessibility action, without a permanent copy button.
Each error's title and message occupy one list row. Project, agent, and saved
server rows animate insertion/removal over 0.2 seconds, with motion disabled
when Reduce Motion is enabled.
Settings manages saved servers without a default-server selector or selected
checkmarks. Opening a project or agent determines the workspace server.
Removing a saved server uses a trailing swipe action on mobile or the row's
context menu on Mac, followed by the existing confirmation dialog.
The swipe action opens confirmation without removing the row; the destructive
action and removal animation run only after confirmation.

Agents opens in **All servers** scope. Each saved server has a list section whose
header is its saved connection name. **This server** limits the view to the
selected workspace. **Active / All** filters threads independently of scope.

Within a server section, attention threads sort first, followed by most recent
host update in each category, across all projects. Rows show project names.
Sections with attention threads sort first, then sections with more recent
activity, with server name and instance ID breaking ties. The server section and
project/thread row IDs distinguish colliding IDs on different hosts.

After authentication, alternate saved connections to the same nonempty server ID
contribute one section and one set of counts. Fresh results take precedence over
stale results, then the selected connection takes precedence. Identical names
and unknown server identities never trigger deduplication.

## Connections and freshness

`PaseoConnectionFactory` keeps independent overview sessions keyed by saved
instance ID, coalesces overlapping connection attempts, and reuses the selected
workspace service. Catalog and overview requests never change the active Keychain
selection. Opening a secondary server promotes its connected service into the
selected workspace without another handshake.

Each catalog or overview batch starts at most four server operations concurrently.
Each overview host's project loading also has at most four requests in flight.
Connection attempts have a 30-second limit;
project catalogs and project thread requests have 15-second limits. Healthy host
results are published as soon as that host finishes, without waiting for other
hosts. All pages of each thread listing are loaded through the existing adapter.

Every host retains its own update time, error, stale state, and project results.
Failed catalogs keep that host's last snapshot; partial project failures keep the
last rows for those projects. A changed authenticated server identity clears its
prior rows before loading new ones. Counts explicitly describe partial or stale
results. Missing data is never presented as an empty, healthy server.

Agent refreshes coalesce, with a final refresh when another request arrives during a
batch. Removal, leaving the overview, and backgrounding invalidate outstanding
batches so late results cannot repopulate sections. Leaving or backgrounding
closes auxiliary services once neither Projects nor Agents is visible, and
preserves the selected chat service. The iPad/Mac project sidebar can keep these
services available alongside the selected chat. Backgrounding always closes
auxiliary services. Returning,
foregrounding, and pull-to-refresh reload snapshots. This is a snapshot view,
without polling or subscriptions to each agent timeline.

## Opening threads and drafts

A row carries its originating instance, project, and thread identities. Opening
it selects that instance, checks authenticated server identity, and reloads the
project's thread list before selecting the exact thread. A failed connection,
changed server identity, missing thread, cancellation, or another connection
change prevents navigation. The overview stays mounted during the switch to
show navigation errors. Opening requests are cancelled when the view disappears.

Text/image drafts, accepted attachment state, new-thread intents, and uncertain
send state are held in memory per saved instance when switching. In-flight sends
become uncertain before caching, and are not automatically resent. State is
restored only after the same authenticated server identity is confirmed. Explicit
removal/disconnect discards that instance's cache. State is not persisted across
app restarts.

## Validation and limits

Unit coverage exercises healthy results arriving before a slow host, colliding
project/thread IDs and send routing, authenticated duplicate-server suppression,
matching display names, partial failures and retry, background/foreground
cleanup, removal during refresh/handshake, connection coalescing, service
promotion, and draft isolation. Tests also cover project catalogs arriving
independently, colliding project IDs, removal during catalog loading, shared
connection lifetime between Projects and Agents, and uncertain sends surviving
a server switch without being resent. The multi-server offline demo and UI
regression exercise named server headers, scope changes, unavailable servers, and opening
an originating server. UI automation is deferred while the user's Mac is in use.

Host clock skew may affect recency across sections. Ordering uses host record
updates, falling back to creation time, without inventing activity from fetch
time. Real-time aggregate updates and longer-lived background connections are
outside this implementation; transport and relay costs need device measurement
before expanding that lifecycle.
