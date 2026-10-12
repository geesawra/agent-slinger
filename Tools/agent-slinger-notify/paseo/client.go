// Package paseo adapts the direct and encrypted relay protocol at Paseo commit
// 9246813fd2acd6afc7012c5fde79a164b8f8592e. It never advertises UI presence.
package paseo

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/geesawra/oesap/Tools/agent-slinger-notify/deeplink"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/notify"
)

const SourceRevision = "9246813fd2acd6afc7012c5fde79a164b8f8592e"

type Failure struct {
	Code      string
	Permanent bool
}

func (e *Failure) Error() string             { return "Paseo: " + e.Code }
func fail(code string, permanent bool) error { return &Failure{code, permanent} }
func Permanent(err error) bool               { var f *Failure; return errors.As(err, &f) && f.Permanent }

type Options struct{ URL, Password, ExpectedServerID, PairingLink string }
type envelope struct {
	Type    string `json:"type"`
	Message struct {
		Type    string          `json:"type"`
		Payload json.RawMessage `json:"payload"`
	} `json:"message"`
}
type response struct {
	RequestID      string `json:"requestId"`
	SubscriptionID string `json:"subscriptionId"`
}
type reply struct {
	kind    string
	payload json.RawMessage
}
type Agent struct {
	Title       string `json:"title"`
	ID          string `json:"id"`
	WorkspaceID string `json:"workspaceId"`
}
type Client struct {
	conn         jsonTransport
	ServerID     string
	hostname     string
	subscription string
	events       chan notify.Event
	done         chan struct{}
	writeMu      sync.Mutex
	mu           sync.Mutex
	pending      map[string]chan reply
	failure      error
	closeOnce    sync.Once
}

func requestID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("secure randomness unavailable")
	}
	return hex.EncodeToString(b[:])
}
func Connect(ctx context.Context, o Options) (*Client, error) {
	ws, expectedServerID, err := dialProtocolTransport(ctx, o)
	if err != nil {
		return nil, err
	}
	stopOnCancel := context.AfterFunc(ctx, func() { _ = ws.Close() })
	defer stopOnCancel()
	good := false
	defer func() {
		if !good {
			ws.Close()
		}
	}()
	ws.SetReadLimit(1 << 20)
	deadline := time.Now().Add(10 * time.Second)
	if t, ok := ctx.Deadline(); ok && t.Before(deadline) {
		deadline = t
	}
	ws.SetReadDeadline(deadline)
	ws.SetWriteDeadline(deadline)
	hello := map[string]any{"type": "hello", "clientId": "agent-slinger-notify-" + requestID(), "clientType": "cli", "protocolVersion": 1, "capabilities": map[string]bool{"hello_rejection": true, "explicit_event_subscriptions": true, "owned_subscriptions": true}}
	if o.Password != "" {
		hello["auth"] = map[string]string{"kind": "password", "password": o.Password}
	}
	if ws.WriteJSON(hello) != nil {
		return nil, fail("hello_send_failed", false)
	}
	serverID := ""
	hostname := ""
	for n := 0; n < 128; n++ {
		var frame envelope
		if err := ws.ReadJSON(&frame); err != nil {
			return nil, transportError(err, "hello_receive_failed")
		}
		if frame.Type == "hello.rejected" {
			return nil, fail("hello_rejected", true)
		}
		if frame.Type != "session" || frame.Message.Type != "status" {
			continue
		}
		var info struct {
			Status          string          `json:"status"`
			ServerID        string          `json:"serverId"`
			Hostname        json.RawMessage `json:"hostname"`
			ProtocolVersion int             `json:"protocolVersion"`
			Features        struct {
				Explicit bool `json:"explicitEventSubscriptions"`
				Owned    bool `json:"ownedSubscriptions"`
			} `json:"features"`
		}
		if json.Unmarshal(frame.Message.Payload, &info) != nil {
			return nil, fail("invalid_server_info", true)
		}
		if info.Status != "server_info" {
			continue
		}
		if info.ProtocolVersion != 1 || !info.Features.Explicit || !info.Features.Owned {
			return nil, fail("unsupported_protocol_or_subscriptions", true)
		}
		if !deeplink.ValidID(info.ServerID) || (expectedServerID != "" && info.ServerID != expectedServerID) {
			return nil, fail("server_identity_mismatch", true)
		}
		serverID = info.ServerID
		_ = json.Unmarshal(info.Hostname, &hostname)
		break
	}
	if serverID == "" {
		return nil, fail("server_info_missing", true)
	}
	id := requestID()
	if ws.WriteJSON(map[string]any{"type": "session", "message": map[string]any{"type": "session.events.set_subscription.request", "requestId": id, "events": []string{"agent_attention_required"}, "notifications": false}}) != nil {
		return nil, fail("subscription_send_failed", false)
	}
	subscription := ""
	buffered := []notify.Event{}
	for n := 0; n < 128; n++ {
		var frame envelope
		if err := ws.ReadJSON(&frame); err != nil {
			return nil, transportError(err, "subscription_receive_failed")
		}
		if frame.Type != "session" {
			continue
		}
		if frame.Message.Type == "agent_attention_required" {
			var event notify.Event
			if json.Unmarshal(frame.Message.Payload, &event) == nil {
				buffered = append(buffered, event)
			}
			continue
		}
		if frame.Message.Type != "session.events.set_subscription.response" {
			continue
		}
		var r response
		if json.Unmarshal(frame.Message.Payload, &r) != nil || r.RequestID != id {
			continue
		}
		if !deeplink.ValidID(r.SubscriptionID) {
			return nil, fail("owned_subscription_missing", true)
		}
		subscription = r.SubscriptionID
		break
	}
	if subscription == "" {
		return nil, fail("subscription_response_missing", true)
	}
	c := &Client{conn: ws, ServerID: serverID, hostname: hostname, subscription: subscription, events: make(chan notify.Event, 256), done: make(chan struct{}), pending: map[string]chan reply{}}
	for _, e := range buffered {
		if e.SubscriptionID == subscription {
			c.events <- e
		}
	}
	ws.SetWriteDeadline(time.Time{})
	good = true
	go c.read()
	go c.heartbeat()
	return c, nil
}
func (c *Client) ServerIdentity() string      { return c.ServerID }
func (c *Client) ServerHostname() string      { return c.hostname }
func (c *Client) Events() <-chan notify.Event { return c.events }
func (c *Client) Err() error                  { c.mu.Lock(); defer c.mu.Unlock(); return c.failure }
func (c *Client) read() {
	defer close(c.events)
	for {
		c.conn.SetReadDeadline(time.Now().Add(75 * time.Second))
		var frame envelope
		if err := c.conn.ReadJSON(&frame); err != nil {
			c.stop(transportError(err, "attention_stream_disconnected"))
			return
		}
		if frame.Type == "hello.rejected" {
			c.stop(fail("hello_rejected", true))
			return
		}
		if frame.Type != "session" {
			continue
		}
		if frame.Message.Type == "agent_attention_required" {
			var e notify.Event
			if json.Unmarshal(frame.Message.Payload, &e) != nil {
				c.stop(fail("invalid_attention_frame", false))
				return
			}
			if e.SubscriptionID != c.subscription {
				continue
			}
			select {
			case c.events <- e:
			case <-c.done:
				return
			default:
				c.stop(fail("attention_buffer_overflow", false))
				return
			}
			continue
		}
		var r response
		if json.Unmarshal(frame.Message.Payload, &r) != nil || r.RequestID == "" {
			continue
		}
		c.mu.Lock()
		ch := c.pending[r.RequestID]
		c.mu.Unlock()
		if ch != nil {
			select {
			case ch <- reply{frame.Message.Type, frame.Message.Payload}:
			default:
			}
		}
	}
}
func (c *Client) heartbeat() {
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-ticker.C:
			if c.write(map[string]any{"type": "ping"}) != nil {
				c.stop(fail("heartbeat_failed", false))
				return
			}
		}
	}
}
func (c *Client) write(v any) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if c.conn.WriteJSON(v) != nil {
		return fail("send_failed", false)
	}
	return nil
}
func (c *Client) stop(err error) {
	c.closeOnce.Do(func() { c.mu.Lock(); c.failure = err; c.mu.Unlock(); close(c.done); c.conn.Close() })
}
func (c *Client) request(ctx context.Context, kind string, fields map[string]any) (reply, error) {
	id := requestID()
	ch := make(chan reply, 1)
	c.mu.Lock()
	c.pending[id] = ch
	c.mu.Unlock()
	defer func() { c.mu.Lock(); delete(c.pending, id); c.mu.Unlock() }()
	fields["type"] = kind
	fields["requestId"] = id
	if err := c.write(map[string]any{"type": "session", "message": fields}); err != nil {
		return reply{}, err
	}
	select {
	case r := <-ch:
		return r, nil
	case <-ctx.Done():
		return reply{}, fail("request_timeout_or_cancelled", false)
	case <-c.done:
		return reply{}, c.Err()
	}
}
func (c *Client) FetchAgent(ctx context.Context, id string) (Agent, error) {
	if !deeplink.ValidID(id) {
		return Agent{}, fail("invalid_agent_target", true)
	}
	r, err := c.request(ctx, "fetch_agent_request", map[string]any{"agentId": id})
	if err != nil {
		return Agent{}, err
	}
	if r.kind != "fetch_agent_response" {
		return Agent{}, fail("agent_lookup_rejected", true)
	}
	var payload struct {
		Agent *Agent  `json:"agent"`
		Error *string `json:"error"`
	}
	if json.Unmarshal(r.payload, &payload) != nil || payload.Agent == nil || payload.Error != nil {
		return Agent{}, fail("agent_unavailable", true)
	}
	if payload.Agent.ID != id || !deeplink.ValidID(payload.Agent.ID) || !deeplink.ValidID(payload.Agent.WorkspaceID) {
		return Agent{}, fail("agent_workspace_unavailable", true)
	}
	return *payload.Agent, nil
}

// Close releases the owned subscription with a correlated acknowledgement when connected.
func (c *Client) Close() error {
	select {
	case <-c.done:
		return c.Err()
	default:
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	r, err := c.request(ctx, "subscription.release.request", map[string]any{"subscriptionId": c.subscription})
	if err == nil {
		var p response
		if r.kind != "subscription.release.response" || json.Unmarshal(r.payload, &p) != nil || p.SubscriptionID != c.subscription {
			err = fail("subscription_release_unconfirmed", false)
		}
	}
	c.stop(nil)
	return err
}
