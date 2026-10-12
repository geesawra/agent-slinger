# ADR 0008: Push notifications for agent attention

## Status

Proposed. A host-run bridge can observe attention events from an unchanged
Paseo daemon. Native Oesap alerts still require an APNs provider path; its
operator and privacy model need a product decision before implementation.

The [Go notification sidecar draft](../notification-sidecar.md) develops the
user-operated Pushover alternative, using Paseo's mobile and web behavior as
the reference. It also identifies a delivery-policy limitation: a passive
attention subscription cannot reproduce the daemon's remote-push selection
from `shouldNotify` alone. Exact selection parity needs a daemon integration.

## Context and findings

Oesap is an iPhone-only SwiftUI client. It currently has one saved Paseo
connection, a foreground WebSocket, per-thread timeline subscriptions, and a
refreshable Agents overview. It has no notification entitlement, APNs
registration, token persistence, or notification-tap route. Its connection
adapter handles thread events, but does not consume Paseo's connection-wide
`agent_attention_required` event. The app's `serverId` is available after the
handshake and can identify the connected host when opening a notification.
See [the app entry point](../../Sources/Oesap/OesapApp.swift),
[project configuration](../../project.yml),
[protocol client](../../Sources/Oesap/Protocol/PaseoProtocolClient.swift), and
[navigation](../../Sources/Oesap/Features/WorkspaceViews.swift).

Paseo already emits attention for `finished`, `error`, and `permission` and
builds a notification with `serverId`, `workspaceId`, `agentId`, and `reason`.
Its body may include an assistant-message or permission preview, including
permission input/metadata. The daemon sends remote push only for `finished`
and `permission`; `error` is currently excluded. It offers an explicit
connection event subscription for foreground delivery and `client_heartbeat`
fields for visibility, activity, and focus. See the
[attention payload builder](https://github.com/getpaseo/paseo/blob/main/packages/protocol/src/agent-attention-notification.ts),
[wire schemas](https://github.com/getpaseo/paseo/blob/main/packages/protocol/src/messages.ts),
and [daemon routing](https://github.com/getpaseo/paseo/blob/main/packages/server/src/server/websocket-server.ts).
The [architecture](https://github.com/getpaseo/paseo/blob/main/docs/architecture.md)
places this routing in the local daemon, outside the encrypted relay.

Paseo's existing remote sender posts to Expo's push API. Its
`register_push_token` message accepts an Expo token and has no correlated
response; `push.unregister.request` has a response. The daemon keeps a global
set of tokens with a 48-hour renewable lease and sends the same alert to all
active tokens when its presence policy allows push. `server_info.features`
advertises `pushTokenRevocation`, but no native APNs registration/delivery
capability. See [the protocol](https://github.com/getpaseo/paseo/blob/main/packages/protocol/src/messages.ts),
[sender](https://github.com/getpaseo/paseo/blob/main/packages/server/src/server/push/push-service.ts),
[token store and lease](https://github.com/getpaseo/paseo/blob/main/packages/server/src/server/push/index.ts),
and [server features](https://github.com/getpaseo/paseo/blob/main/packages/server/src/server/websocket-server.ts).

An APNs token obtained by native Oesap is not an Expo push token. Expo's sender
requires an Expo token associated with an Expo project and its push
credentials; Apple requires the recipient app's own APNs token and a provider
that can authenticate to APNs. Thus sending Oesap's APNs token in Paseo's
current `register_push_token` message will not deliver notifications to Oesap.
Oesap's WebSocket also cannot be relied on once iOS suspends the app.
See [Expo's sender contract](https://docs.expo.dev/push-notifications/sending-notifications/),
[Expo token setup](https://docs.expo.dev/push-notifications/push-notifications-setup/),
and [Apple's provider architecture](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server).

Paseo currently regards any client active within 180 seconds as present, even
when `appVisible` is false. It can then suppress remote push in favor of a
WebSocket notification that a suspended iPhone cannot handle. This has been
[reported upstream](https://github.com/getpaseo/paseo/issues/2622); the
[policy source](https://github.com/getpaseo/paseo/blob/main/packages/server/src/server/agent-attention-policy.ts)
confirms the mechanism. A separate bridge can receive the attention event
without participating in Paseo's notification selection by subscribing with
`notifications: false`. It must decide delivery independently of
`shouldNotify`; otherwise this presence bug would still lose alerts. See
Paseo's [subscription implementation](https://github.com/getpaseo/paseo/blob/main/packages/server/src/server/session.ts).

Source review: Paseo `main` was inspected on 2026-09-27. The preceding Oesap
protocol review pinned Paseo commit
[`d7b7016cc98da02ce5110fb218c70cac419657f3`](https://github.com/getpaseo/paseo/commit/d7b7016cc98da02ce5110fb218c70cac419657f3),
but the environment could not resolve a fresh `main` SHA or fetch an upstream
checkout. The linked `main` files are therefore an observed source snapshot,
not a pinned compatibility guarantee. Pin and recheck a Paseo commit before
writing wire code.

## Proposed decision

Use visible remote APNs alerts for agent completion and permission requests.
Start with generic text and no agent output, permission details, workspace
paths, or credentials in the push payload. A tap opens Oesap, reconnects to
the verified host, fetches current state, and navigates only to an agent still
belonging to that host. The alert is a prompt to refresh; the daemon remains
the authority for agent state and permission actions.

Make a small, optional bridge the primary Paseo integration. Users install it
on the machine running their self-hosted Paseo daemon. It connects through the
existing authenticated WebSocket, subscribes to `agent_attention_required`
with `notifications: false`, and forwards only the opaque `serverId`,
`agentId`, reason, and a pairing handle. The gateway sees this metadata but
receives no agent text or permission details.
This needs no Paseo daemon or wire-schema change. The bridge reconnects and
restores its subscription, deduplicates events, and does not treat
`shouldNotify` as permission to deliver or suppress a phone alert.

For alerts shown by the distributed Oesap app, the bridge forwards events to
a narrow Oesap APNs gateway over authenticated TLS. That gateway holds the
app owner's provider credential, maps a paired installation to its APNs
token, and sends to APNs. The existing Paseo Expo push path is independent.
The bridge is user-operated; the gateway remains an operated service because
Apple's provider key cannot be distributed to every host.

### Distribution and secret ownership

One confirmed Oesap bundle ID and Apple Developer team sign the distributed
app. The binary contains its app identity, APNs entitlement, and the public
gateway address, but **no APNs provider signing key, gateway master secret,
or Paseo host credential**. The Oesap operator keeps the `.p8` APNs key in
the gateway's secret store. Each installed app asks iOS for its own APNs
device token and sends that token to the gateway over TLS. The gateway issues
a limited delivery credential for that app/host pairing. A short-lived,
one-time pairing code can transfer that credential to the host bridge without
adding a Paseo RPC or requiring the phone to reach a host-side HTTP port.
The phone keeps its pairing credential in Keychain and the bridge stores its
copy privately. A leaked per-pairing credential can be revoked without rotating
the app-wide APNs key. The device token is a routing address, not the APNs
provider signing key, but it still needs protected transport and storage.
Apple's [registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
and [provider authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
documentation distinguish these roles.

The self-hosted bridge fits the intended user distribution. The Oesap product
guide still requires explicit approval for a service that receives agent
data. The APNs gateway must have a documented operator, retention policy,
abuse controls, and privacy review. If that service is not approved, the
bridge can instead publish to a user-chosen
notification app such as ntfy; the alert would appear in that app, not in
Oesap. A self-built variant can use a user-operated APNs provider with the
user's own Apple key only when Oesap is separately signed under that user's
Apple Developer team and App ID.

## Implementation plan

1. **Set the distribution and trust contract.** Confirm the final bundle ID,
   Apple Developer team, APNs environment, gateway operator, and notification
   text policy. Keep generic alert text for the first release. Obtain user
   opt-in before registering a device with the gateway.
2. **Build the host bridge.** Package a small process users install alongside
   Paseo. It authenticates to the local daemon, checks the verified `serverId`,
   and owns a `session.events.set_subscription.request` for
   `agent_attention_required` with `notifications: false`. Release and restore
   the subscription on disconnect/reconnect; bound retries and deduplicate
   `(serverId, agentId, reason, timestamp)` within a short window. Filter to
   completion and permission by default. Never forward the upstream preview,
   raw prompt, permission input, or path. Make startup, status, pairing, and
   stop commands available to the person running the host. If a supported
   daemon lacks the required event subscription, show that requirement
   clearly; do not synthesize attention from polling snapshots.
3. **Pair bridge and phone.** The gateway binds one Oesap installation to its
   APNs token and issues a short-lived pairing code. The user enters that
   code into the host bridge, which receives a scoped, revocable delivery
   credential. Verify app possession of the APNs token before linking it,
   for example with a challenge sent to that token. Require authenticated,
   rate-limited sends and remove stale registrations. A host disconnect or
   token rotation revokes or renews the bridge's route. No Paseo token-store
   entry or new daemon RPC is involved.
4. **Add the native client.** In `project.yml`, add the Push Notifications
   entitlement for the confirmed App ID. Use `UNUserNotificationCenter` for
   user permission and `UIApplication` APNs registration. Handle denial,
   token changes, host replacement, and bridge unpairing. Keep the pairing
   credential in Keychain; obtain the APNs token from the system again at
   launch rather than caching it. Handle foreground display and notification
   taps through the app model and navigation, with a host-ID check and an
   authoritative refresh. Never approve a permission from notification data.
5. **Verify end to end.** Use sanitized fixtures for the event subscription,
   reconnect, malformed events, and deduplication. Test bridge installation,
   pairing, revocation, and gateway routing with fake senders. Test permission
   denial, token rotation, tap navigation, and stale host states in Oesap.
   Validate sandbox and production delivery on a signed physical iPhone with
   the app foregrounded, backgrounded, suspended, and relaunched. Treat APNs
   delivery as best effort; reconcile on every open.

## Alternatives considered

- **Only show local notifications from the foreground WebSocket.** This can
  provide an in-app alert, but cannot meet the background push goal once iOS
  suspends the app.
- **Extend the Paseo daemon with a separate delivery channel.** This removes
  the process users install beside Paseo but requires an upstream protocol
  and daemon change. The bridge uses an existing event subscription and fits
  the expected self-hosted setup. A daemon channel can follow later if bridge
  installation or maintenance proves costly; it should follow
  [Paseo's compatibility rules](https://github.com/getpaseo/paseo/blob/main/docs/protocol-compatibility.md).
- **Use a user-chosen notification app.** The bridge can publish to an
  authenticated ntfy topic and the ntfy iOS app can display the alert. This
  avoids an Oesap-operated APNs gateway but the alert belongs to ntfy, not
  Oesap. Even self-hosted ntfy needs an APNs-connected upstream for instant
  iOS delivery; see [ntfy's configuration guide](https://docs.ntfy.sh/config/).
- **Send the native APNs token through Paseo's Expo API.** Token formats and
  provider credentials do not match.
- **Embed Expo notification modules in Oesap.** This could use Paseo's
  existing Expo sender after creating an Oesap Expo project and managing its
  credentials, but would add a substantial React Native/Expo dependency to a
  small native Swift app and route notification content through Expo. It also
  inherits Paseo's shared-token and presence behavior. Reconsider only if
  operating a gateway is rejected and that dependency/privacy tradeoff is
  explicitly preferred.
- **Put the app owner's APNs key on each user's Paseo host.** Distributing a
  provider signing credential with a public client would let hosts send as
  Oesap and is unsuitable for distribution.

## Consequences and open decisions

Remote push is feasible without modifying Paseo. Users install and operate
the bridge on the host; it must stay running while they want alerts. Native
Oesap notifications still need a provider that holds the Oesap app owner's
APNs credential. The gateway is a new service and data path; even generic
alerts expose that an agent needs attention at a particular time. The scope
of notification text, retention, and the gateway operator must be settled
before accepting this ADR. APNs best-effort delivery limits the promise Oesap
can make about timeliness. A user-chosen notification app is available when
running an Oesap gateway is not desired, with a different notification UX.
