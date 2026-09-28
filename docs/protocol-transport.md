# Paseo transport used by the remote MVP

Source of truth: Paseo commit `8cd989529e2d86bb6d1c8a775bf695fa5970c997` (Apache-2.0), particularly `packages/protocol/src/{connection-offer,daemon-endpoints}.ts`, `packages/client/src/{daemon-client,daemon-client-relay-e2ee-transport}.ts`, `packages/relay/src/{crypto,encrypted-channel}.ts`, and `packages/server/src/server/{websocket-server,pairing-offer}.ts`. The compatibility rules are in Paseo `docs/protocol-compatibility.md`.

The MVP accepts two connection forms:

* **Direct:** a host and explicit port. `useTLS` selects `wss://` or `ws://`, and the path is `/ws`. When a password is supplied, it is sent in the `paseo.bearer.<password>` WebSocket subprotocol. The daemon WebSocket server authenticates this protocol and closes with code `4401` for a bad password. A direct `ws://` connection carries its traffic without TLS; the setup UI must make that clear. Certificate checks for `wss://` use URLSession defaults.
* **Relay:** a pasted pairing URL whose fragment is `#offer=<base64url JSON>`. The v2 offer contains an opaque `serverId`, a base64 daemon X25519 public key, and a relay host:port plus optional `useTls`. The relay socket is `/ws?serverId=<opaque>&role=client&v=2`; no client `connectionId` is sent, because the relay assigns one. Existing offers without `useTls` select TLS for port 443, matching the current upstream app compatibility behavior. The relay host may see routing metadata and encrypted frame sizes; agent content is encrypted end to end with the daemon's paired key.

After a relay WebSocket opens, Oesap generates an ephemeral X25519 keypair and sends plaintext `{"type":"e2ee_hello","key":"<base64 public key>","capabilities":{"binaryCiphertext":true}}`. It waits for `e2ee_ready`, then exchanges only NaCl `box.after` ciphertext derived with `box.before`: X25519, HSalsa20, XSalsa20-Poly1305. The wire bundle is `24-byte nonce || ciphertext`; text frames carry standard base64. Received binary ciphertext is accepted when the daemon advertised `binaryCiphertext`. Older base64 text frames continue to work. Unexpected plaintext after readiness and invalid authentication tags close the socket. A low-order or all-zero public key is rejected before deriving the shared key.

The NaCl implementation is the unmodified public-domain [TweetNaCl C reference, 20140427](https://tweetnacl.cr.yp.to/20140427/), vendored as `Sources/Oesap/Transport/Crypto/tweetnacl.c` and `tweetnacl.h`, with a small Oesap wrapper for secure random bytes, input lengths, zero padding, and key validation. SHA-256 of the upstream files:

* `tweetnacl.c`: `02e65bc3013ff2168983365e55906bc783c4c7e0a60d8100f17bb303a17175c4`
* `tweetnacl.h`: `43f29ad721d9927b747b0100ab4160c119e7bb180c7c98a66e4bf79d31244287`

The offline test vector was generated with `tweetnacl@1.0.3`, the version range used by the inspected Paseo relay package (`^1.0.3`). It checks the public key, `box.before` shared key, `box.after` ciphertext, decryption, malformed bundles, and tag tampering. A fake socket test covers relay readiness, encrypted app frames, plaintext rejection, direct authentication failure, reconnect, cancellation, and timeouts. No real host, pairing link, prompt, or credential appears in fixtures.

`PaseoTransport` handles one physical socket. The protocol service owns the receive pump, request correlation, capabilities, and subscriptions. Oesap reconnects with bounded retries after a user action or when the app returns from the background. Reconnect creates a fresh socket, and the service requests needed subscriptions and workspace state again. The transport does not start observation on connect. The sole saved connection record, including direct password and relay key, is stored in an after-first-unlock, this-device-only Keychain item and removed on explicit clear.

Supported surface: current Paseo v2 relay pairing offers and direct `/ws` sockets. These connection forms do not require a `server_info.features` flag. The protocol adapter gates app RPCs and stream behavior against advertised server capabilities. The MVP does not support legacy pairing offer formats or SSH tunneling in the connection layer.
