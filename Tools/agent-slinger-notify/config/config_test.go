package config

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func environment() map[string]string {
	return map[string]string{"PASEO_SERVER_ID": "s", "NOTIFY_DELIVERY_MODE": "all-attention", "NOTIFY_STATE_DIR": "./state", "PUSHOVER_APP_TOKEN": strings.Repeat("a", 30), "PUSHOVER_USER_KEY": strings.Repeat("b", 30)}
}
func load(values map[string]string) (Config, Secrets, error) {
	return LoadFrom(func(key string) string { return values[key] })
}
func TestEnvironmentOnlyDefaultsAndOptionalPassword(t *testing.T) {
	values := environment()
	c, s, err := load(values)
	if err != nil {
		t.Fatal(err)
	}
	if c.Paseo.URL != "ws://127.0.0.1:6767/ws" || c.Content != "paseo-preview" || c.MaxPending != 256 || c.EventTTLSeconds != 86400 || s.Password != "" {
		t.Fatal(c, "unexpected defaults")
	}
	values["PASEO_URL"] = "wss://daemon.example/ws"
	values["PASEO_PASSWORD"] = ""
	if _, s, err := load(values); err != nil || s.Password != "" {
		t.Fatal("remote password required", err)
	}
	values["PASEO_PASSWORD"] = "with spaces"
	if _, s, err := load(values); err != nil || s.Password != "with spaces" {
		t.Fatal("optional credential changed", err)
	}
}
func TestTransportAndModeValidation(t *testing.T) {
	for _, u := range []string{"ws://example.com/ws", "ws://localhost/ws", "wss://user:password@example.com/ws", "wss://example.com/ws?token=hidden", "wss://example.com/other"} {
		v := environment()
		v["PASEO_URL"] = u
		if _, _, err := load(v); err == nil {
			t.Fatal(u)
		}
	}
	for _, u := range []string{"ws://127.0.0.1/ws", "ws://[::1]/ws", "wss://example.com/ws"} {
		v := environment()
		v["PASEO_URL"] = u
		if _, _, err := load(v); err != nil {
			t.Fatal(err)
		}
	}
	v := environment()
	v["NOTIFY_DELIVERY_MODE"] = "paseo-parity"
	if _, _, err := load(v); err == nil || !strings.Contains(err.Error(), "no external remote-delivery decision") {
		t.Fatal(err)
	}
	delete(v, "NOTIFY_DELIVERY_MODE")
	if _, _, err := load(v); err == nil {
		t.Fatal("silent mode default")
	}
}
func TestRequiredBoundsAndNoValuesInErrors(t *testing.T) {
	for _, key := range []string{"NOTIFY_STATE_DIR", "PUSHOVER_APP_TOKEN", "PUSHOVER_USER_KEY"} {
		v := environment()
		delete(v, key)
		if _, _, err := load(v); err == nil {
			t.Fatal("missing required", key)
		}
	}
	for _, tc := range []struct{ key, value string }{{"NOTIFY_MAX_PENDING", "private-invalid-value"}, {"NOTIFY_EVENT_TTL_SECONDS", "private-invalid-value"}, {"NOTIFY_MAX_PENDING", "0"}, {"NOTIFY_MAX_PENDING", "10001"}, {"NOTIFY_EVENT_TTL_SECONDS", "4"}, {"NOTIFY_EVENT_TTL_SECONDS", "604801"}, {"PUSHOVER_DEVICE", "invalid private value"}, {"PUSHOVER_APP_TOKEN", "private-invalid-value"}, {"PUSHOVER_USER_KEY", "private-invalid-value"}} {
		v := environment()
		v[tc.key] = tc.value
		_, _, err := load(v)
		if err == nil || strings.Contains(err.Error(), "private") {
			t.Fatal("invalid setting accepted or leaked", tc.key, err)
		}
	}
}

func TestServerIdentityPinIsOptional(t *testing.T) {
	v := environment()
	delete(v, "PASEO_SERVER_ID")
	c, _, err := load(v)
	if err != nil || c.Paseo.ExpectedServerID != "" {
		t.Fatal("identity pin required", err)
	}
	v["PASEO_SERVER_ID"] = " "
	if _, _, err := load(v); err == nil {
		t.Fatal("blank supplied pin accepted")
	}
}

func relayLink(serverID string) string {
	key := [32]byte{9}
	payload, _ := json.Marshal(map[string]any{"v": 2, "serverId": serverID, "daemonPublicKeyB64": base64.StdEncoding.EncodeToString(key[:]), "relay": map[string]any{"endpoint": "relay.example:443", "useTls": true}})
	return "https://app.paseo.sh/#offer=" + base64.RawURLEncoding.EncodeToString(payload)
}
func TestRelaySelectionAndExpectedIdentity(t *testing.T) {
	v := environment()
	v["PASEO_PAIRING_LINK"] = relayLink("s")
	c, _, err := load(v)
	if err != nil || c.Paseo.URL != "" || c.Paseo.PairingLink != v["PASEO_PAIRING_LINK"] {
		t.Fatal("relay collided with direct default", err)
	}
	v["PASEO_URL"] = "ws://127.0.0.1/ws"
	if _, _, err := load(v); err == nil {
		t.Fatal("two transports accepted")
	}
	delete(v, "PASEO_URL")
	v["PASEO_SERVER_ID"] = "other"
	if _, _, err := load(v); err == nil {
		t.Fatal("relay identity pin ignored")
	}
	delete(v, "PASEO_SERVER_ID")
	if _, _, err := load(v); err != nil {
		t.Fatal("optional relay pin required", err)
	}
	v["PASEO_PAIRING_LINK"] = "private-invalid-offer"
	if _, _, err := load(v); err == nil || strings.Contains(err.Error(), "private") {
		t.Fatal("invalid offer accepted or leaked", err)
	}
}

func TestServerNameDisplayOverrideAndExplicitGeneric(t *testing.T) {
	v := environment()
	v["PASEO_SERVER_NAME"] = "Friendly workstation"
	v["NOTIFY_CONTENT"] = "generic"
	c, _, err := load(v)
	if err != nil || c.Paseo.ServerName != v["PASEO_SERVER_NAME"] || c.Content != "generic" {
		t.Fatal(c, err)
	}
	v["PASEO_SERVER_NAME"] = strings.Repeat("s", 4097)
	if _, _, err := load(v); err == nil {
		t.Fatal("unbounded server label accepted")
	}
}
