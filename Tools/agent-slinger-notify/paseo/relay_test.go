package paseo

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/crypto/nacl/box"
)

const fixtureDaemonKey = "VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY="

func relayLink(t *testing.T, serverID, key, endpoint string, useTLS *bool) string {
	t.Helper()
	relay := map[string]any{"endpoint": endpoint}
	if useTLS != nil {
		relay["useTls"] = *useTLS
	}
	payload, err := json.Marshal(map[string]any{"v": 2, "serverId": serverID, "daemonPublicKeyB64": key, "relay": relay})
	if err != nil {
		t.Fatal(err)
	}
	return "https://app.paseo.sh/#offer=" + base64.RawURLEncoding.EncodeToString(payload)
}
func boolPointer(v bool) *bool { return &v }

func TestRelayOfferPinsIdentityEndpointAndCanonicalKey(t *testing.T) {
	for _, tt := range []struct {
		endpoint string
		tls      *bool
		scheme   string
	}{
		{"relay.example:443", nil, "wss"}, {"relay.example:7443", boolPointer(true), "wss"},
		{"relay.example:7443", boolPointer(false), "ws"}, {"[::1]:1234", boolPointer(false), "ws"},
		{"relay.example:80", nil, "ws"},
	} {
		offer, err := ParseRelayOffer(relayLink(t, "server /+", fixtureDaemonKey, tt.endpoint, tt.tls))
		if err != nil {
			t.Fatal(err)
		}
		parsed, _ := url.Parse(offer.endpoint)
		if offer.ServerID != "server /+" || parsed.Scheme != tt.scheme || parsed.Path != "/ws" || parsed.Query().Get("serverId") != "server /+" || parsed.Query().Get("role") != "client" || parsed.Query().Get("v") != "2" || len(parsed.Query()) != 3 {
			t.Fatal("wrong relay routing")
		}
	}
	badEndpoints := []string{"relay.example", "relay.example:0", "relay.example:65536", "user:pass@relay.example:443", "relay.example:443/path", "wss://relay.example:443", "relay.example:443?password=secret", "[bad:ipv6]:443"}
	for _, endpoint := range badEndpoints {
		if _, err := ParseRelayOffer(relayLink(t, "s", fixtureDaemonKey, endpoint, boolPointer(true))); err == nil {
			t.Fatalf("accepted invalid endpoint %q", endpoint)
		}
	}
	for _, key := range []string{"", "not-a-key", strings.TrimSuffix(fixtureDaemonKey, "="), base64.StdEncoding.EncodeToString(make([]byte, 32)), base64.StdEncoding.EncodeToString(append([]byte{1}, make([]byte, 31)...))} {
		if _, err := ParseRelayOffer(relayLink(t, "s", key, "relay.example:443", nil)); err == nil {
			t.Fatal("accepted invalid/low-order key")
		}
	}
	for _, payload := range []string{
		`{"v":2,"v":2,"serverId":"s","daemonPublicKeyB64":"` + fixtureDaemonKey + `","relay":{"endpoint":"relay.example:443"}}`,
		`{"v":2,"serverId":"s","daemonPublicKeyB64":"` + fixtureDaemonKey + `","relay":{"endpoint":"relay.example:443","useTls":true,"useTls":false}}`,
		`{"v":1,"serverId":"s","daemonPublicKeyB64":"` + fixtureDaemonKey + `","relay":{"endpoint":"relay.example:443"}}`,
		`{"v":2,"serverId":"s","daemonPublicKeyB64":"` + fixtureDaemonKey + `","relay":{"endpoint":"relay.example:443"},"password":"private"}`,
	} {
		if _, err := ParseRelayOffer("https://app.paseo.sh/#offer=" + base64.RawURLEncoding.EncodeToString([]byte(payload))); err == nil {
			t.Fatal("accepted ambiguous/malformed offer")
		}
	}
}

func TestRelayCryptoMatchesSwiftAndTweetNaClVector(t *testing.T) {
	decode := func(s string) []byte {
		v, err := hex.DecodeString(s)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	var private, public, shared [32]byte
	copy(private[:], decode("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"))
	copy(public[:], decode("5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36"))
	secret, _ := ecdh.X25519().NewPrivateKey(private[:])
	if hex.EncodeToString(secret.PublicKey().Bytes()) != "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c" {
		t.Fatal("public key mismatch")
	}
	box.Precompute(&shared, &public, &private)
	var nonce [24]byte
	copy(nonce[:], decode("c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0"))
	plain := []byte(`{"type":"ping"}`)
	got := box.SealAfterPrecomputation(nonce[:], plain, &nonce, &shared)
	expected := decode("c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe07e89308e4f560a28812d0318cab768a9eeb9f2a8fcd365c9cddc3ae9e6ffe1")
	if !bytes.Equal(got, expected) {
		t.Fatal("ciphertext differs from Swift/TweetNaCl vector")
	}
	got[len(got)-1] ^= 1
	if _, ok := box.OpenAfterPrecomputation(nil, got[24:], &nonce, &shared); ok {
		t.Fatal("tampering accepted")
	}
}

type relayFixture struct {
	link string
	seen chan map[string]any
	keys chan string
}

// This fake is a daemon behind a relay: only handshake public keys are plaintext.
func fakeRelay(t *testing.T, mode, identity string, requireRetry bool) relayFixture {
	t.Helper()
	public, private, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	fixture := relayFixture{seen: make(chan map[string]any, 32), keys: make(chan string, 8)}
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("Sec-WebSocket-Protocol") != "" || r.URL.Query().Get("role") != "client" || r.URL.Query().Get("serverId") != "relay-server" || r.URL.Query().Get("v") != "2" || len(r.URL.Query()) != 3 {
			t.Error("unsafe or incorrect websocket upgrade")
			return
		}
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		ws.SetReadDeadline(time.Now().Add(5 * time.Second))
		var handshake struct {
			Type         string          `json:"type"`
			Key          string          `json:"key"`
			Capabilities map[string]bool `json:"capabilities"`
		}
		if ws.ReadJSON(&handshake) != nil {
			return
		}
		if handshake.Type != "e2ee_hello" || !handshake.Capabilities["binaryCiphertext"] {
			t.Error("invalid encrypted hello")
			return
		}
		fixture.keys <- handshake.Key
		if requireRetry {
			var retry map[string]any
			if ws.ReadJSON(&retry) != nil || retry["key"] != handshake.Key || retry["type"] != "e2ee_hello" {
				t.Error("retry rotated key or absent")
				return
			}
		}
		key, err := base64.StdEncoding.DecodeString(handshake.Key)
		if err != nil || len(key) != 32 {
			t.Error("invalid client public key")
			return
		}
		var clientKey, shared [32]byte
		copy(clientKey[:], key)
		box.Precompute(&shared, &clientKey, private)
		ready := map[string]any{"type": "e2ee_ready"}
		if mode != "legacy" && mode != "legacy-binary" {
			ready["capabilities"] = map[string]bool{"binaryCiphertext": true}
		}
		if mode == "noise" {
			_ = ws.WriteMessage(websocket.TextMessage, []byte("relay control noise"))
			_ = ws.WriteMessage(websocket.BinaryMessage, []byte{1, 2, 3})
		}
		if ws.WriteJSON(ready) != nil {
			return
		}
		read := func() map[string]any {
			kind, wire, err := ws.ReadMessage()
			if err != nil {
				return nil
			}
			if kind != websocket.TextMessage || bytes.Contains(wire, []byte("private password")) || bytes.HasPrefix(wire, []byte("{")) {
				t.Error("application frame was plaintext or incorrect opcode")
				return nil
			}
			bundle, err := decodeRelayBase64(string(wire))
			if err != nil || len(bundle) < 40 {
				return nil
			}
			var nonce [24]byte
			copy(nonce[:], bundle[:24])
			plain, ok := box.OpenAfterPrecomputation(nil, bundle[24:], &nonce, &shared)
			if !ok {
				return nil
			}
			var message map[string]any
			if json.Unmarshal(plain, &message) != nil {
				return nil
			}
			return message
		}
		send := func(value any) bool {
			plain, _ := json.Marshal(value)
			if mode == "plaintext" {
				return ws.WriteMessage(websocket.TextMessage, plain) == nil
			}
			var nonce [24]byte
			_, _ = rand.Read(nonce[:])
			encryptionKey := shared
			if mode == "wrong-key" {
				encryptionKey[0] ^= 1
			}
			bundle := box.SealAfterPrecomputation(nonce[:], plain, &nonce, &encryptionKey)
			if mode == "tampered" {
				bundle[len(bundle)-1] ^= 1
			}
			if mode == "truncated" {
				bundle = bundle[:30]
			}
			if mode == "oversized" {
				bundle = make([]byte, 2<<20)
			}
			kind := websocket.TextMessage
			wire := []byte(base64.StdEncoding.EncodeToString(bundle))
			if mode == "binary" || mode == "tampered" || mode == "truncated" || mode == "oversized" {
				kind = websocket.BinaryMessage
				wire = bundle
			}
			if mode == "legacy-binary" {
				kind = websocket.BinaryMessage
			}
			return ws.WriteMessage(kind, wire) == nil
		}
		hello := read()
		if hello == nil {
			return
		}
		fixture.seen <- hello
		if !send(map[string]any{"type": "session", "message": map[string]any{"type": "status", "payload": map[string]any{"status": "server_info", "serverId": identity, "protocolVersion": 1, "features": map[string]bool{"explicitEventSubscriptions": true, "ownedSubscriptions": true}}}}) {
			return
		}
		for {
			frame := read()
			if frame == nil {
				return
			}
			if frame["type"] == "ping" {
				if !send(map[string]string{"type": "pong"}) {
					return
				}
				continue
			}
			message, ok := frame["message"].(map[string]any)
			if !ok {
				return
			}
			fixture.seen <- message
			kind := message["type"]
			response := ""
			payload := map[string]any{"requestId": message["requestId"]}
			switch kind {
			case "session.events.set_subscription.request":
				response = "session.events.set_subscription.response"
				payload["subscriptionId"] = "relay-sub"
			case "subscription.release.request":
				response = "subscription.release.response"
				payload["subscriptionId"] = "relay-sub"
			case "fetch_agent_request":
				response = "fetch_agent_response"
				payload["agent"] = map[string]string{"id": "agent-1", "workspaceId": "workspace-1"}
			default:
				t.Error("unexpected protocol request")
				return
			}
			if !send(map[string]any{"type": "session", "message": map[string]any{"type": response, "payload": payload}}) {
				return
			}
			if kind == "session.events.set_subscription.request" {
				if !send(map[string]any{"type": "session", "message": map[string]any{"type": "agent_attention_required", "payload": map[string]any{"subscriptionId": "relay-sub", "agentId": "agent-1", "reason": "completion", "timestamp": time.Now().UTC().Format(time.RFC3339Nano), "shouldNotify": false}}}) {
					return
				}
			}
		}
	}))
	t.Cleanup(server.Close)
	endpoint := strings.TrimPrefix(server.URL, "http://")
	fixture.link = relayLink(t, "relay-server", base64.StdEncoding.EncodeToString(public[:]), endpoint, boolPointer(false))
	return fixture
}

func TestRelayEncryptedLifecycleBinaryAndLegacy(t *testing.T) {
	for _, mode := range []string{"binary", "legacy", "legacy-binary", "noise"} {
		t.Run(mode, func(t *testing.T) {
			fixture := fakeRelay(t, mode, "relay-server", false)
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			client, err := Connect(ctx, Options{PairingLink: fixture.link, Password: "private password"})
			if err != nil {
				t.Fatal(err)
			}
			hello := <-fixture.seen
			auth, ok := hello["auth"].(map[string]any)
			if !ok || auth["password"] != "private password" || hello["clientType"] != "cli" {
				t.Fatal("missing encrypted authentication")
			}
			subscription := <-fixture.seen
			if subscription["notifications"] != false {
				t.Fatal("sidecar advertised UI notification presence")
			}
			select {
			case event := <-client.Events():
				if event.AgentID != "agent-1" || event.ShouldNotify {
					t.Fatal("wrong event")
				}
			case <-ctx.Done():
				t.Fatal("missing encrypted event")
			}
			agent, err := client.FetchAgent(ctx, "agent-1")
			if err != nil || agent.WorkspaceID != "workspace-1" {
				t.Fatal("encrypted lookup failed", err)
			}
			<-fixture.seen
			if err := client.Close(); err != nil {
				t.Fatal(err)
			}
			if (<-fixture.seen)["type"] != "subscription.release.request" {
				t.Fatal("owned subscription not released")
			}
		})
	}
}

func TestRelayRejectsPlaintextTamperingTruncationOversizeAndIdentityMismatch(t *testing.T) {
	for _, mode := range []string{"plaintext", "tampered", "wrong-key", "truncated", "oversized", "wrong-identity"} {
		t.Run(mode, func(t *testing.T) {
			identity := "relay-server"
			if mode == "wrong-identity" {
				identity = "different-server"
			}
			fixture := fakeRelay(t, mode, identity, false)
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_, err := Connect(ctx, Options{PairingLink: fixture.link, Password: "private password"})
			if err == nil {
				t.Fatal("unsafe frame accepted")
			}
			if strings.Contains(err.Error(), "private") || strings.Contains(err.Error(), "offer=") || strings.Contains(err.Error(), fixture.link) {
				t.Fatal("sensitive connection data leaked")
			}
		})
	}
}

func TestRelayRetryUsesSameKeyAndReconnectUsesFreshKey(t *testing.T) {
	fixture := fakeRelay(t, "legacy", "relay-server", true)
	var keys []string
	for i := 0; i < 2; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		client, err := Connect(ctx, Options{PairingLink: fixture.link})
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, <-fixture.keys)
		if err := client.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if keys[0] == keys[1] {
		t.Fatal("ephemeral key reused across connections")
	}
}

func TestRelayHandshakeCancellationAndTLSVerification(t *testing.T) {
	finished := make(chan struct{})
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(finished)
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		for {
			if _, _, err := ws.ReadMessage(); err != nil {
				return
			}
		}
	}))
	link := relayLink(t, "relay-server", fixtureDaemonKey, strings.TrimPrefix(server.URL, "http://"), boolPointer(false))
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := Connect(ctx, Options{PairingLink: link})
	if err == nil || time.Since(start) > time.Second {
		t.Fatal("relay cancellation did not bound handshake")
	}
	server.Close()
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("cancelled relay socket not closed")
	}
	tlsServer := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("untrusted TLS was accepted") }))
	defer tlsServer.Close()
	link = relayLink(t, "relay-server", fixtureDaemonKey, strings.TrimPrefix(tlsServer.URL, "https://"), boolPointer(true))
	ctx2, cancel2 := context.WithTimeout(context.Background(), time.Second)
	defer cancel2()
	if _, err := Connect(ctx2, Options{PairingLink: link}); err == nil {
		t.Fatal("untrusted relay certificate accepted")
	}
}

func TestRelayReadyCapabilityValidation(t *testing.T) {
	for _, wire := range []string{`{"type":"e2ee_ready","capabilities":null}`, `{"type":"e2ee_ready","capabilities":{"binaryCiphertext":null}}`, `{"type":"e2ee_ready","capabilities":{"binaryCiphertext":"true"}}`, `{"type":"e2ee_ready","capabilities":[]}`, `{"type":"e2ee_ready","type":"e2ee_ready"}`} {
		if _, valid := parseRelayReady([]byte(wire)); valid {
			t.Fatal("accepted malformed ready capability")
		}
	}
	for _, wire := range []string{`{"type":"e2ee_ready"}`, `{"type":"e2ee_ready","capabilities":{}}`, `{"type":"e2ee_ready","capabilities":{"binaryCiphertext":true,"future":123}}`} {
		if _, valid := parseRelayReady([]byte(wire)); !valid {
			t.Fatal("rejected valid ready capability")
		}
	}
}
