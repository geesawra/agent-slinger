package paseo

import (
	"context"
	"encoding/json"
	"github.com/gorilla/websocket"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func server(t *testing.T, serverID, agentID string) (string, <-chan map[string]any) {
	return serverHostname(t, serverID, agentID, "workstation")
}
func serverHostname(t *testing.T, serverID, agentID string, hostname any) (string, <-chan map[string]any) {
	t.Helper()
	seen := make(chan map[string]any, 8)
	upgrader := websocket.Upgrader{}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		var hello map[string]any
		if ws.ReadJSON(&hello) != nil {
			return
		}
		seen <- hello
		ws.WriteJSON(map[string]any{"type": "session", "message": map[string]any{"type": "status", "payload": map[string]any{"status": "server_info", "serverId": serverID, "hostname": hostname, "protocolVersion": 1, "features": map[string]bool{"explicitEventSubscriptions": true, "ownedSubscriptions": true}}}})
		for {
			var frame struct {
				Type    string         `json:"type"`
				Message map[string]any `json:"message"`
			}
			if ws.ReadJSON(&frame) != nil {
				return
			}
			if frame.Type == "ping" {
				ws.WriteJSON(map[string]string{"type": "pong"})
				continue
			}
			seen <- frame.Message
			id := frame.Message["requestId"]
			kind := frame.Message["type"]
			payload := map[string]any{"requestId": id}
			var responseType string
			switch kind {
			case "session.events.set_subscription.request":
				responseType = "session.events.set_subscription.response"
				payload["subscriptionId"] = "sub-1"
			case "subscription.release.request":
				responseType = "subscription.release.response"
				payload["subscriptionId"] = "sub-1"
			case "fetch_agent_request":
				responseType = "fetch_agent_response"
				payload["agent"] = map[string]string{"id": agentID, "workspaceId": "workspace /+", "title": "Fix login", "lastAssistantMessage": "Newer transcript text must not become the preview"}
				payload["error"] = nil
			default:
				return
			}
			ws.WriteJSON(map[string]any{"type": "session", "message": map[string]any{"type": responseType, "payload": payload}})
			if kind == "session.events.set_subscription.request" {
				ws.WriteJSON(map[string]any{"type": "session", "message": map[string]any{"type": "agent_attention_required", "payload": map[string]any{"subscriptionId": "sub-1", "agentId": "agent-1", "reason": "permission", "timestamp": time.Now().UTC().Format(time.RFC3339Nano), "shouldNotify": false, "notification": map[string]any{"title": "Paseo", "body": "permission preview", "data": map[string]string{"serverId": serverID, "agentId": "agent-1", "reason": "permission", "workspaceId": "workspace /+"}}}}})
			}
		}
	}))
	t.Cleanup(s.Close)
	return "ws" + strings.TrimPrefix(s.URL, "http") + "/ws", seen
}
func TestPinnedHelloPassiveSubscriptionCorrelatedLookupAndRelease(t *testing.T) {
	url, seen := server(t, "s", "agent-1")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	c, err := Connect(ctx, Options{URL: url, Password: "private password", ExpectedServerID: "s"})
	if err != nil {
		t.Fatal(err)
	}
	hello := <-seen
	auth := hello["auth"].(map[string]any)
	caps := hello["capabilities"].(map[string]any)
	if hello["clientType"] != "cli" || hello["protocolVersion"] != float64(1) || auth["kind"] != "password" || auth["password"] != "private password" || caps["explicit_event_subscriptions"] != true || caps["owned_subscriptions"] != true {
		t.Fatal("wrong hello")
	}
	sub := <-seen
	if sub["notifications"] != false || sub["requestId"] == "" {
		t.Fatal(sub)
	}
	events, _ := json.Marshal(sub["events"])
	if string(events) != `["agent_attention_required"]` {
		t.Fatal(string(events))
	}
	select {
	case e := <-c.Events():
		if e.AgentID != "agent-1" || e.ShouldNotify {
			t.Fatal(e)
		}
	case <-ctx.Done():
		t.Fatal("missing event")
	}
	agent, err := c.FetchAgent(ctx, "agent-1")
	if err != nil || agent.WorkspaceID != "workspace /+" || agent.Title != "Fix login" {
		t.Fatal(agent, err)
	}
	<-seen
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	release := <-seen
	if release["type"] != "subscription.release.request" || release["subscriptionId"] != "sub-1" {
		t.Fatal(release)
	}
}
func TestWrongServerNeverSubscribesAndLookupRejectsAlias(t *testing.T) {
	url, seen := server(t, "other", "agent-1")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := Connect(ctx, Options{URL: url, ExpectedServerID: "s"})
	if err == nil || !Permanent(err) {
		t.Fatal(err)
	}
	<-seen
	select {
	case m := <-seen:
		t.Fatal("subscribed to wrong host", m)
	default:
	}
	url, seen = server(t, "s", "agent-1")
	c, err := Connect(ctx, Options{URL: url, ExpectedServerID: "s"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	<-seen
	<-seen
	if _, err := c.FetchAgent(ctx, "agent"); err == nil {
		t.Fatal("accepted alias pointing at another opaque target")
	}
}
func TestHelloRejectionIsPermanentAndRedacted(t *testing.T) {
	up := websocket.Upgrader{}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, _ := up.Upgrade(w, r, nil)
		defer ws.Close()
		var frame any
		ws.ReadJSON(&frame)
		ws.WriteJSON(map[string]any{"type": "hello.rejected", "reason": "incorrect_password", "accepts": []string{"password"}, "secret": "should not be logged"})
	}))
	defer s.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := Connect(ctx, Options{URL: "ws" + strings.TrimPrefix(s.URL, "http"), Password: "secret", ExpectedServerID: "s"})
	if !Permanent(err) || err.Error() != "Paseo: hello_rejected" {
		t.Fatal(err)
	}
}
func TestReconnectAcquiresFreshOwnedSubscription(t *testing.T) {
	url, seen := server(t, "s", "agent-1")
	for i := 0; i < 2; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		c, err := Connect(ctx, Options{URL: url, ExpectedServerID: "s"})
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		hello := <-seen
		if _, exists := hello["auth"]; exists {
			t.Fatal("authentication advertised without configured credential")
		}
		m := <-seen
		if m["notifications"] != false {
			t.Fatal("presence leaked")
		}
		c.Close()
		<-seen
	}
}

func TestCancelledHandshakeClosesPromptly(t *testing.T) {
	entered := make(chan struct{})
	finish := make(chan struct{})
	up := websocket.Upgrader{}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		var hello any
		if ws.ReadJSON(&hello) != nil {
			return
		}
		close(entered)
		<-finish
	}))
	defer s.Close()
	defer close(finish)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := Connect(ctx, Options{URL: "ws" + strings.TrimPrefix(s.URL, "http"), ExpectedServerID: "s"})
		result <- err
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("hello did not arrive")
	}
	cancel()
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("cancelled handshake accepted")
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("handshake ignored cancellation")
	}
}

func TestDiscoverActualIdentityWithoutConfiguredPin(t *testing.T) {
	url, seen := server(t, "actual-server", "agent-1")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	c, err := Connect(ctx, Options{URL: url})
	if err != nil {
		t.Fatal("pin incorrectly required", err)
	}
	defer c.Close()
	<-seen
	<-seen
	if c.ServerIdentity() != "actual-server" {
		t.Fatal("actual server identity lost")
	}
}
func TestMissingServerIdentityStillRejectedWithoutPin(t *testing.T) {
	url, seen := server(t, "", "agent-1")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := Connect(ctx, Options{URL: url}); err == nil || !Permanent(err) {
		t.Fatal("unidentified daemon accepted", err)
	}
	<-seen
}

func TestOptionalHostnamePermissiveAndUsesDaemonMetadata(t *testing.T) {
	for _, hostname := range []any{"actual daemon", nil, map[string]string{"untrusted": "object"}, 42} {
		url, seen := serverHostname(t, "s", "agent-1", hostname)
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		c, err := Connect(ctx, Options{URL: url})
		cancel()
		if err != nil {
			t.Fatal("optional hostname failed connection", err)
		}
		<-seen
		<-seen
		want, _ := hostname.(string)
		if c.ServerHostname() != want {
			t.Fatal("hostname was invented", c.ServerHostname())
		}
		c.Close()
	}
}
