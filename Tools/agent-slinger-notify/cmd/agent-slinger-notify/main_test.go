package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/config"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/notify"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/paseo"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/pushover"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/state"
	"html"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakeConnection struct {
	serverID  string
	hostname  string
	lookupErr error
	events    chan notify.Event
	lookups   int
	closed    bool
	agent     paseo.Agent
}

func (f *fakeConnection) ServerIdentity() string {
	if f.serverID != "" {
		return f.serverID
	}
	return "s"
}
func (f *fakeConnection) ServerHostname() string      { return f.hostname }
func (f *fakeConnection) Events() <-chan notify.Event { return f.events }
func (f *fakeConnection) Err() error                  { return nil }
func (f *fakeConnection) FetchAgent(context.Context, string) (paseo.Agent, error) {
	f.lookups++
	return f.agent, f.lookupErr
}
func (f *fakeConnection) Close() error { f.closed = true; return nil }

type fakeProvider struct {
	checks, sends int
	message       pushover.Message
}

func (f *fakeProvider) ValidateRecipient(context.Context) pushover.Outcome {
	f.checks++
	return pushover.Outcome{Accepted: true}
}
func (f *fakeProvider) Send(_ context.Context, m pushover.Message) pushover.Outcome {
	f.sends++
	f.message = m
	return pushover.Outcome{Accepted: true}
}
func setup(t *testing.T) (dependencies, *fakeConnection, *fakeProvider) {
	t.Helper()
	t.Setenv("PASEO_URL", "ws://127.0.0.1/ws")
	t.Setenv("PASEO_PAIRING_LINK", "")
	t.Setenv("PASEO_SERVER_ID", "s")
	t.Setenv("PASEO_PASSWORD", "")
	t.Setenv("PASEO_SERVER_NAME", "")
	t.Setenv("PUSHOVER_APP_TOKEN", strings.Repeat("a", 30))
	t.Setenv("PUSHOVER_USER_KEY", strings.Repeat("b", 30))
	t.Setenv("PUSHOVER_DEVICE", "")
	t.Setenv("NOTIFY_DELIVERY_MODE", "all-attention")
	t.Setenv("NOTIFY_CONTENT", "generic")
	t.Setenv("NOTIFY_STATE_DIR", filepath.Join(t.TempDir(), "state"))
	t.Setenv("NOTIFY_MAX_PENDING", "")
	t.Setenv("NOTIFY_EVENT_TTL_SECONDS", "")
	f := &fakeConnection{events: make(chan notify.Event, 1), hostname: "workstation", agent: paseo.Agent{ID: "a", WorkspaceID: "w /+", Title: "Fix login"}}
	p := &fakeProvider{}
	deps := dependencies{connect: func(context.Context, paseo.Options) (connection, error) { return f, nil }, provider: func(config.Secrets, string) providerClient { return p }}
	return deps, f, p
}

func logger() *slog.Logger { return slog.New(slog.NewJSONHandler(io.Discard, nil)) }
func TestCheckDoesNotPushAndTestUsesAuthoritativeSession(t *testing.T) {
	deps, connection, provider := setup(t)
	if err := executeWith(context.Background(), []string{"check"}, logger(), deps); err != nil {
		t.Fatal(err)
	}
	if provider.sends != 0 || provider.checks != 1 || !connection.closed {
		t.Fatal("check pushed or leaked subscription")
	}
	if err := executeWith(context.Background(), []string{"test", "--agent-id", "a"}, logger(), deps); err != nil {
		t.Fatal(err)
	}
	if provider.sends != 1 || connection.lookups != 1 || !strings.Contains(provider.message.URL, "workspaceId=w%20%2F%2B") || provider.message.Title != "Fix login — test alert" || !strings.HasPrefix(provider.message.Body, "<b>Server:</b> workstation\n\n") {
		t.Fatal(provider, connection)
	}
	if strings.Contains(provider.message.URL, "messageId") {
		t.Fatal("guessed message anchor")
	}
}
func TestTestRejectsWorkspaceMismatchWithoutPush(t *testing.T) {
	deps, _, p := setup(t)
	err := executeWith(context.Background(), []string{"test", "--agent-id", "a", "--workspace-id", "wrong"}, logger(), deps)
	if err == nil || p.sends != 0 {
		t.Fatal("mismatched target sent")
	}
}
func TestRunnerEnrichesMissingWorkspaceAndPersistsOnlyResolvedTarget(t *testing.T) {
	_, f, _ := setup(t)
	store, err := state.Open(filepath.Join(t.TempDir(), "state"), "scope", 2)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now().UTC()
	f.events <- notify.Event{AgentID: "a", Reason: "permission", Timestamp: now.Format(time.RFC3339Nano), Notification: &notify.Payload{Title: "upstream", Body: "preview", Data: notify.Data{ServerID: "s", AgentID: "a", Reason: "permission"}}}
	close(f.events)
	policy := notify.Policy{Mode: "all-attention", Content: "generic", ServerID: "s", TTL: time.Hour}
	if err := observe(context.Background(), f, store, policy, &notify.Worker{}, make(chan time.Time), logger()); err != nil {
		t.Fatal(err)
	}
	if f.lookups != 1 || store.Count() != 1 {
		t.Fatal("unresolved target dropped")
	}
	i, _, _ := store.Next(now.Add(time.Second))
	var fields map[string]any
	b, _ := json.Marshal(i)
	json.Unmarshal(b, &fields)
	if !strings.Contains(i.Message.URL, "workspaceId=w%20%2F%2B") {
		t.Fatal(i)
	}
}

func TestConfigFileOptionIsRejected(t *testing.T) {
	deps, _, p := setup(t)
	if err := executeWith(context.Background(), []string{"check", "--config", "anything.json"}, logger(), deps); err == nil || p.checks != 0 || p.sends != 0 {
		t.Fatal("configuration file option accepted")
	}
}

func TestCheckAndTestDiscoverIdentityWithoutEnvironmentPin(t *testing.T) {
	deps, f, p := setup(t)
	t.Setenv("PASEO_SERVER_ID", "")
	if err := executeWith(context.Background(), []string{"check"}, logger(), deps); err != nil {
		t.Fatal(err)
	}
	if err := executeWith(context.Background(), []string{"test", "--agent-id", "a"}, logger(), deps); err != nil {
		t.Fatal(err)
	}
	if p.sends != 1 || !strings.Contains(p.message.URL, "serverId=s") || f.lookups != 1 {
		t.Fatal("action lost actual daemon identity")
	}
}
func TestRunScopesDiscoveredIdentityAndPinsReconnect(t *testing.T) {
	_, f, p := setup(t)
	t.Setenv("PASEO_SERVER_ID", "")
	c, secrets, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	actualScope := state.Key("s", secrets.User, c.Pushover.Device, c.Content, c.DeliveryMode)
	// Existing work belongs to the actual daemon, independent of an environment pin.
	existing, err := state.Open(c.StateDir, actualScope, c.MaxPending)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	_, _, err = existing.Enqueue(state.Item{ID: "pending", AgentKey: state.Key("s", "a"), Reason: "permission", Timestamp: now, Expires: now.Add(24 * time.Hour), NextAttempt: now.Add(time.Hour), Message: pushover.Message{Title: "Agent", Body: "Permission", URL: "agentslinger://open?v=1&serverId=s&workspaceId=w&agentId=a", URLTitle: "Open"}}, now)
	if err != nil {
		t.Fatal(err)
	}
	existing.Close()
	close(f.events)
	other := &fakeConnection{serverID: "other", events: make(chan notify.Event)}
	calls := 0
	connect := func(_ context.Context, o paseo.Options) (connection, error) {
		calls++
		if calls == 1 {
			if o.ExpectedServerID != "" {
				t.Error("initial discovery pre-pinned")
			}
			return f, nil
		}
		if o.ExpectedServerID != "s" {
			t.Error("reconnection not pinned to discovered identity")
		}
		return other, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	err = run(ctx, c, secrets, p, logger(), connect)
	if err == nil || !strings.Contains(err.Error(), "identity changed") || calls != 2 || p.sends != 0 || !other.closed {
		t.Fatal("server change not rejected", err, calls, p.sends)
	}
	recovered, err := state.Open(c.StateDir, actualScope, c.MaxPending)
	if err != nil {
		t.Fatal("state scope changed with absent pin", err)
	}
	defer recovered.Close()
	if recovered.Count() != 1 {
		t.Fatal("old server pending work lost")
	}
}

func TestRelayEnvironmentReachesConnectionWithoutDirectDefault(t *testing.T) {
	deps, f, _ := setup(t)
	key := [32]byte{9}
	payload, _ := json.Marshal(map[string]any{"v": 2, "serverId": "s", "daemonPublicKeyB64": base64.StdEncoding.EncodeToString(key[:]), "relay": map[string]any{"endpoint": "relay.example:443", "useTls": true}})
	link := "https://app.paseo.sh/#offer=" + base64.RawURLEncoding.EncodeToString(payload)
	t.Setenv("PASEO_URL", "")
	t.Setenv("PASEO_PAIRING_LINK", link)
	t.Setenv("PASEO_SERVER_ID", "")
	t.Setenv("PASEO_PASSWORD", "optional private credential")
	calls := 0
	deps.connect = func(_ context.Context, o paseo.Options) (connection, error) {
		calls++
		if o.URL != "" || o.PairingLink != link || o.Password != "optional private credential" || o.ExpectedServerID != "" {
			t.Error("relay environment not routed to adapter")
		}
		return f, nil
	}
	if err := executeWith(context.Background(), []string{"check"}, logger(), deps); err != nil || calls != 1 {
		t.Fatal(err, calls)
	}
}

func TestRunDoesNotLoadOutboxBeforeInitialIdentity(t *testing.T) {
	_, _, p := setup(t)
	t.Setenv("PASEO_SERVER_ID", "")
	c, secrets, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	connect := func(context.Context, paseo.Options) (connection, error) { cancel(); return nil, errors.New("offline") }
	err = run(ctx, c, secrets, p, logger(), connect)
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := os.Stat(c.StateDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("outbox opened before authoritative discovery", err)
	}
	if p.sends != 0 {
		t.Fatal("delivered without identity")
	}
}

func TestAgentLabelLookupFailureRetainsValidEventPreviewAndRoute(t *testing.T) {
	_, f, _ := setup(t)
	f.lookupErr = errors.New("unavailable private remote details")
	now := time.Now().UTC()
	preview := "Preview belonging to the finished turn"
	f.events <- notify.Event{AgentID: "a", Reason: "finished", Timestamp: now.Format(time.RFC3339Nano), Notification: &notify.Payload{Body: preview, Data: notify.Data{ServerID: "s", WorkspaceID: "w", AgentID: "a", Reason: "finished"}}}
	close(f.events)
	store, err := state.Open(filepath.Join(t.TempDir(), "state"), "scope", 10)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	var logs strings.Builder
	log := slog.New(slog.NewJSONHandler(&logs, nil))
	policy := notify.Policy{Mode: "all-attention", Content: "paseo-preview", ServerID: "s", ServerName: "workstation", TTL: time.Hour}
	if err := observe(context.Background(), f, store, policy, &notify.Worker{}, make(chan time.Time), log); err != nil {
		t.Fatal(err)
	}
	i, _, _ := store.Next(now.Add(time.Second))
	if i == nil || i.Message.Body != "<b>Server:</b> workstation\n\n"+html.EscapeString(preview) || i.Message.Title != "Agent a — turn finished" || f.lookups != 1 {
		t.Fatal("valid alert lost on label failure", i)
	}
	if strings.Contains(logs.String(), preview) || strings.Contains(logs.String(), "private remote") || strings.Contains(logs.String(), "workstation") {
		t.Fatal("private event/context logged")
	}
}
func TestAgentLabelEnrichmentNeverReplacesEventPreviewWithNewerMetadata(t *testing.T) {
	_, f, _ := setup(t)
	f.agent.Title = "New turn title"
	now := time.Now().UTC()
	preview := "Earlier completed turn's correlated preview"
	f.events <- notify.Event{AgentID: "a", Reason: "finished", Timestamp: now.Format(time.RFC3339Nano), Notification: &notify.Payload{Body: preview, Data: notify.Data{ServerID: "s", WorkspaceID: "w", AgentID: "a", Reason: "finished"}}}
	close(f.events)
	store, err := state.Open(filepath.Join(t.TempDir(), "state"), "scope", 10)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := notify.Policy{Mode: "all-attention", Content: "paseo-preview", ServerID: "s", ServerName: "workstation", TTL: time.Hour}
	if err := observe(context.Background(), f, store, policy, &notify.Worker{}, make(chan time.Time), logger()); err != nil {
		t.Fatal(err)
	}
	i, _, _ := store.Next(now.Add(time.Second))
	if i == nil || i.Message.Body != "<b>Server:</b> workstation\n\n"+html.EscapeString(preview) || i.Message.Title != "New turn title — turn finished" {
		t.Fatal("event preview replaced by fetched metadata", i)
	}
}
func TestTestAlertUsesConfiguredServerDisplayWithoutChangingIdentity(t *testing.T) {
	deps, _, p := setup(t)
	t.Setenv("PASEO_SERVER_NAME", "Friendly desktop")
	if err := executeWith(context.Background(), []string{"test", "--agent-id", "a"}, logger(), deps); err != nil {
		t.Fatal(err)
	}
	if p.message.Title != "Fix login — test alert" || !strings.HasPrefix(p.message.Body, "<b>Server:</b> Friendly desktop\n\n") || !strings.Contains(p.message.URL, "serverId=s") {
		t.Fatal("display override changed route identity", p.message.Title, p.message.URL)
	}
}
