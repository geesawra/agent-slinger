package paseo

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/geesawra/oesap/Tools/agent-slinger-notify/deeplink"
	"github.com/gorilla/websocket"
	"golang.org/x/crypto/nacl/box"
)

const relayPlaintextLimit = 1 << 20

// RelayOffer contains validated v2 routing and pinned peer key material. Never log
// an offer: it is supplied by the user through a secret environment value.
type RelayOffer struct {
	ServerID  string
	endpoint  string
	daemonKey [32]byte
}

func ParseRelayOffer(link string) (RelayOffer, error) {
	invalid := func() (RelayOffer, error) { return RelayOffer{}, fail("invalid_relay_offer", true) }
	if len(link) == 0 || len(link) > 16*1024 || strings.TrimSpace(link) != link {
		return invalid()
	}
	u, err := url.Parse(link)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil || u.RawQuery != "" || !strings.HasPrefix(u.Fragment, "offer=") {
		return invalid()
	}
	encoded := strings.TrimPrefix(u.Fragment, "offer=")
	payload, err := decodeRelayBase64(encoded)
	if err != nil || !utf8.Valid(payload) {
		return invalid()
	}
	var offer struct {
		Version  int    `json:"v"`
		ServerID string `json:"serverId"`
		Key      string `json:"daemonPublicKeyB64"`
		Relay    struct {
			Endpoint string `json:"endpoint"`
			UseTLS   *bool  `json:"useTls"`
		} `json:"relay"`
	}
	if !uniqueJSONKeys(payload) {
		return invalid()
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&offer) != nil || decoder.Decode(new(any)) != io.EOF || offer.Version != 2 || !deeplink.ValidID(offer.ServerID) {
		return invalid()
	}
	var raw struct {
		Relay map[string]json.RawMessage `json:"relay"`
	}
	_ = json.Unmarshal(payload, &raw)
	if useTLS, exists := raw.Relay["useTls"]; exists && bytes.Equal(bytes.TrimSpace(useTLS), []byte("null")) {
		return invalid()
	}
	key, err := base64.StdEncoding.Strict().DecodeString(offer.Key)
	if err != nil || len(key) != 32 || base64.StdEncoding.EncodeToString(key) != offer.Key {
		return invalid()
	}
	// ECDH checks the all-zero result and rejects low-order Curve25519 inputs.
	privateBytes := [32]byte{1}
	private, _ := ecdh.X25519().NewPrivateKey(privateBytes[:])
	public, err := ecdh.X25519().NewPublicKey(key)
	if err != nil {
		return invalid()
	}
	if _, err = private.ECDH(public); err != nil {
		return invalid()
	}
	host, portText, err := net.SplitHostPort(offer.Relay.Endpoint)
	port, portErr := strconv.Atoi(portText)
	if err != nil || portErr != nil || port < 1 || port > 65535 || host == "" || strings.ContainsAny(host, "/\\?#@% \t\r\n") {
		return invalid()
	}
	if strings.Contains(host, ":") && net.ParseIP(host) == nil {
		return invalid()
	}
	for _, c := range portText {
		if c < '0' || c > '9' {
			return invalid()
		}
	}
	useTLS := port == 443 // Pinned upstream's compatibility default for old offers.
	if offer.Relay.UseTLS != nil {
		useTLS = *offer.Relay.UseTLS
	}
	scheme := "wss"
	if !useTLS {
		scheme = "ws"
	}
	endpoint := url.URL{Scheme: scheme, Host: net.JoinHostPort(host, portText), Path: "/ws"}
	endpoint.RawQuery = url.Values{"serverId": {offer.ServerID}, "role": {"client"}, "v": {"2"}}.Encode()
	result := RelayOffer{ServerID: offer.ServerID, endpoint: endpoint.String()}
	copy(result.daemonKey[:], key)
	return result, nil
}

// JSON's last-key-wins convention must not change a pairing offer's pinned peer.
func uniqueJSONKeys(payload []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	var value func() bool
	value = func() bool {
		token, err := decoder.Token()
		if err != nil {
			return false
		}
		delimiter, ok := token.(json.Delim)
		if !ok {
			return true
		}
		switch delimiter {
		case '{':
			seen := map[string]bool{}
			for decoder.More() {
				key, err := decoder.Token()
				name, ok := key.(string)
				if err != nil || !ok || seen[name] {
					return false
				}
				seen[name] = true
				if !value() {
					return false
				}
			}
			end, err := decoder.Token()
			return err == nil && end == json.Delim('}')
		case '[':
			for decoder.More() {
				if !value() {
					return false
				}
			}
			end, err := decoder.Token()
			return err == nil && end == json.Delim(']')
		default:
			return false
		}
	}
	if !value() {
		return false
	}
	_, err := decoder.Token()
	return err == io.EOF
}

func decodeRelayBase64(encoded string) ([]byte, error) {
	// Accept standard and URL-safe padded/unpadded forms used by Paseo, but no whitespace.
	if strings.ContainsAny(encoded, " \t\r\n") {
		return nil, fail("relay_invalid_base64", true)
	}
	for _, encoding := range []*base64.Encoding{base64.StdEncoding.Strict(), base64.RawStdEncoding.Strict(), base64.URLEncoding.Strict(), base64.RawURLEncoding.Strict()} {
		if value, err := encoding.DecodeString(encoded); err == nil {
			return value, nil
		}
	}
	return nil, fail("relay_invalid_base64", true)
}

// Match upstream's optional capability schema while ignoring future capabilities.
func parseRelayReady(frame []byte) (bool, bool) {
	if !uniqueJSONKeys(frame) {
		return false, false
	}
	var ready map[string]json.RawMessage
	if json.Unmarshal(frame, &ready) != nil {
		return false, false
	}
	var kind string
	if json.Unmarshal(ready["type"], &kind) != nil || kind != "e2ee_ready" {
		return false, false
	}
	caps, exists := ready["capabilities"]
	if !exists {
		return false, true
	}
	var capabilities map[string]json.RawMessage
	if json.Unmarshal(caps, &capabilities) != nil || capabilities == nil {
		return false, false
	}
	binary, exists := capabilities["binaryCiphertext"]
	if !exists {
		return false, true
	}
	switch string(bytes.TrimSpace(binary)) {
	case "true":
		return true, true
	case "false":
		return false, true
	default:
		return false, false
	}
}

type relayTransport struct {
	*websocket.Conn
	shared     [32]byte
	binary     bool
	plainLimit int64
}

func connectRelay(ctx context.Context, offer RelayOffer) (*relayTransport, error) {
	// Fresh ephemeral keypair for every dial/reconnect; secret is never serialized.
	public, private, err := box.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fail("relay_randomness_failed", true)
	}
	ws, err := dialWebSocket(ctx, offer.endpoint)
	if err != nil {
		return nil, err
	}
	good := false
	defer func() {
		if !good {
			_ = ws.Close()
		}
	}()
	stopOnCancel := context.AfterFunc(ctx, func() { _ = ws.Close() })
	defer stopOnCancel()
	deadline := time.Now().Add(10 * time.Second)
	if t, ok := ctx.Deadline(); ok && t.Before(deadline) {
		deadline = t
	}
	_ = ws.SetReadDeadline(deadline)
	_ = ws.SetWriteDeadline(deadline)
	ws.SetReadLimit(4096)
	hello := map[string]any{"type": "e2ee_hello", "key": base64.StdEncoding.EncodeToString(public[:]), "capabilities": map[string]bool{"binaryCiphertext": true}}
	if ws.WriteJSON(hello) != nil {
		return nil, fail("relay_handshake_send_failed", false)
	}
	// A daemon data socket can attach after the client; repeat the same public key
	// until ready. Join the writer before protocol messages start (gorilla's rule).
	stop, stopped := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(stopped)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ctx.Done():
				return
			case <-ticker.C:
				if ws.WriteJSON(hello) != nil {
					_ = ws.Close()
					return
				}
			}
		}
	}()
	defer func() { close(stop); <-stopped }()
	for frames := 0; frames < 32; frames++ {
		kind, frame, err := ws.ReadMessage()
		if err != nil {
			return nil, fail("relay_handshake_failed", false)
		}
		binary, valid := parseRelayReady(frame)
		if kind != websocket.TextMessage || !valid {
			continue
		}
		result := &relayTransport{Conn: ws, binary: binary}
		box.Precompute(&result.shared, &offer.daemonKey, private)
		result.SetReadLimit(relayPlaintextLimit)
		good = true
		return result, nil
	}
	return nil, fail("relay_handshake_invalid", true)
}

func (r *relayTransport) SetReadLimit(limit int64) {
	r.plainLimit = limit
	r.Conn.SetReadLimit(((limit + 40 + 2) / 3) * 4)
}

func (r *relayTransport) WriteJSON(value any) error {
	plain, err := json.Marshal(value)
	if err != nil || len(plain) > relayPlaintextLimit {
		return fail("relay_plaintext_invalid", true)
	}
	var nonce [24]byte
	if _, err = rand.Read(nonce[:]); err != nil {
		return fail("relay_randomness_failed", true)
	}
	bundle := box.SealAfterPrecomputation(nonce[:], plain, &nonce, &r.shared)
	// Preserve Paseo's string opcode semantics even when binary is negotiated.
	return r.Conn.WriteMessage(websocket.TextMessage, []byte(base64.StdEncoding.EncodeToString(bundle)))
}

func (r *relayTransport) ReadJSON(value any) error {
	for skipped := 0; skipped < 32; skipped++ {
		kind, frame, err := r.Conn.ReadMessage()
		if err != nil {
			return fail("relay_receive_failed", false)
		}
		var bundle []byte
		if kind == websocket.TextMessage {
			if bytes.HasPrefix(bytes.TrimSpace(frame), []byte("{")) {
				if _, valid := parseRelayReady(frame); valid {
					continue
				}
				return fail("relay_plaintext_rejected", true)
			}
			bundle, err = decodeRelayBase64(string(frame))
			if err != nil {
				return err
			}
		} else if kind == websocket.BinaryMessage {
			bundle = frame
			if !r.binary {
				// Old adapters sometimes lost the opcode; mirror upstream's base64-first compatibility.
				if decoded, decodeErr := decodeRelayBase64(string(frame)); decodeErr == nil {
					bundle = decoded
				}
			}
		} else {
			return fail("relay_frame_invalid", true)
		}
		if len(bundle) < 40 || int64(len(bundle)) > r.plainLimit+40 {
			return fail("relay_frame_invalid", true)
		}
		var nonce [24]byte
		copy(nonce[:], bundle[:24])
		plain, ok := box.OpenAfterPrecomputation(nil, bundle[24:], &nonce, &r.shared)
		if !ok {
			return fail("relay_ciphertext_rejected", true)
		}
		if !utf8.Valid(plain) || json.Unmarshal(plain, value) != nil {
			return fail("relay_plaintext_invalid", true)
		}
		return nil
	}
	return fail("relay_handshake_flood", true)
}
