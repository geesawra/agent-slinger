// Package notify separates the passive delivery policy from event and HTTP transport.
package notify

import (
	"context"
	"errors"
	"html"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/geesawra/oesap/Tools/agent-slinger-notify/deeplink"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/pushover"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/state"
)

type Data struct {
	ServerID    string `json:"serverId"`
	WorkspaceID string `json:"workspaceId"`
	AgentID     string `json:"agentId"`
	Reason      string `json:"reason"`
}
type Payload struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	Data  Data   `json:"data"`
}
type Event struct {
	AgentTitle     string   `json:"-"`
	SubscriptionID string   `json:"subscriptionId"`
	AgentID        string   `json:"agentId"`
	Reason         string   `json:"reason"`
	Timestamp      string   `json:"timestamp"`
	ShouldNotify   bool     `json:"shouldNotify"`
	Notification   *Payload `json:"notification"`
}
type Policy struct {
	Mode, Content, ServerID, ServerName string
	TTL                                 time.Duration
}

// Prepare does not consume shouldNotify: all-attention explicitly bypasses UI presence selection.
// The pinned attention wire payload has no authoritative anchor, so links target the session.
func (p Policy) Prepare(e Event, now time.Time) (*state.Item, error) {
	if p.Mode != "all-attention" {
		return nil, errors.New("delivery decision integration unavailable")
	}
	if e.Reason != "finished" && e.Reason != "permission" {
		return nil, nil
	}
	if !deeplink.ValidID(e.AgentID) || e.Notification == nil {
		return nil, errors.New("attention event lacks a valid target payload")
	}
	d := e.Notification.Data
	if d.ServerID != p.ServerID || d.AgentID != e.AgentID || d.Reason != e.Reason {
		return nil, errors.New("attention target differs from authenticated event")
	}
	ts, err := time.Parse(time.RFC3339Nano, e.Timestamp)
	if err != nil || ts.After(now.Add(5*time.Minute)) {
		return nil, errors.New("invalid attention timestamp")
	}
	expires := ts.Add(p.TTL)
	if !now.Before(expires) {
		return nil, nil
	}
	action, err := deeplink.Build(deeplink.Target{ServerID: d.ServerID, WorkspaceID: d.WorkspaceID, AgentID: d.AgentID})
	if err != nil {
		return nil, err
	}

	status := "turn finished"
	fallbackBody := "The agent finished its turn."
	if e.Reason == "permission" {
		status = "needs permission"
		fallbackBody = "The agent needs your permission."
	}
	title := DisplayTitle(e.AgentTitle, e.AgentID, status)
	body := fallbackBody
	if p.Content == "paseo-preview" {
		if preview := NormalizeText(e.Notification.Body); preview != "" {
			body = LimitText(preview, 1024)
		}
	} else if p.Content != "generic" {
		return nil, errors.New("invalid content policy")
	}
	message := pushover.Message{Title: title, Body: DisplayBody(p.ServerName, p.ServerID, body), HTML: true, URL: action, URLTitle: "Open Agent Slinger"}
	if message.Validate() != nil {
		return nil, errors.New("notification exceeds provider limits")
	}
	return &state.Item{ID: state.Key(d.ServerID, e.AgentID, e.Reason, ts.UTC().Format(time.RFC3339Nano)), AgentKey: state.Key(d.ServerID, e.AgentID), Reason: e.Reason, Timestamp: ts, Expires: expires, NextAttempt: now, Message: message}, nil
}

// NormalizeText keeps notification text plain and collapses whitespace/control characters.
func NormalizeText(value string) string {
	value = strings.ToValidUTF8(value, " ")
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.IsSpace(r) || bidiControl(r) {
			return ' '
		}
		return r
	}, value)
	return strings.Join(strings.Fields(value), " ")
}

// Remove directional format controls while preserving emoji/script joining characters.
func bidiControl(r rune) bool {
	switch r {
	case '\u061c', '\u200e', '\u200f', '\u202a', '\u202b', '\u202c', '\u202d', '\u202e', '\u2066', '\u2067', '\u2068', '\u2069':
		return true
	}
	return false
}

// LimitText counts Unicode code points, as Pushover's UTF-8 character limits require.
func LimitText(value string, max int) string {
	r := []rune(value)
	if max < 1 {
		return ""
	}
	if len(r) <= max {
		return value
	}
	if max == 1 {
		return "…"
	}
	return string(r[:max-1]) + "…"
}

// ServerLabel uses daemon metadata, never an endpoint or relay hostname.
func ServerLabel(override, hostname, serverID string) string {
	for _, value := range []string{override, hostname, serverID} {
		if label := NormalizeText(value); label != "" {
			return LimitText(label, 100)
		}
	}
	return "Server"
}

// DisplayTitle identifies the authoritative agent and event. Server context belongs in the body.
func DisplayTitle(agentTitle, agentID, status string) string {
	agent := NormalizeText(agentTitle)
	if agent == "" {
		agent = "Agent " + NormalizeText(agentID)
	}
	return LimitText(agent, 100) + " — " + LimitText(NormalizeText(status), 30)
}

// DisplayBody formats only trusted metadata markup and escapes all remote text.
// The encoded payload, including tags and entities, stays within 1024 characters.
func DisplayBody(serverName, serverID, text string) string {
	prefix := "<b>Server:</b> " + html.EscapeString(ServerLabel(serverName, "", serverID)) + "\n\n"
	return prefix + escapeLimited(NormalizeText(text), 1024-utf8.RuneCountInString(prefix))
}

// Truncation chooses whole raw runes before escaping; it never cuts an entity.
func escapeLimited(text string, max int) string {
	if max < 1 {
		return ""
	}
	parts := make([]string, 0, max)
	used := 0
	for _, r := range text {
		part := html.EscapeString(string(r))
		n := utf8.RuneCountInString(part)
		if used+n > max {
			if used+1 > max && len(parts) > 0 {
				last := len(parts) - 1
				used -= utf8.RuneCountInString(parts[last])
				parts = parts[:last]
			}
			return strings.Join(parts, "") + "…"
		}
		parts = append(parts, part)
		used += n
	}
	return strings.Join(parts, "")
}

type Sender interface {
	Send(context.Context, pushover.Message) pushover.Outcome
}
type Outbox interface {
	Next(time.Time) (*state.Item, int, error)
	Finish(string, bool, time.Duration, time.Time) error
}
type Worker struct {
	Store     Outbox
	Sender    Sender
	Now       func() time.Time
	Report    func(string, int)
	notBefore time.Time
}

// Step sends at most one ready item. Callers provide a serial tick loop and cancellation.
func (w *Worker) Step(ctx context.Context) error {
	now := w.Now()
	item, expired, err := w.Store.Next(now)
	if err != nil {
		return err
	}
	if expired > 0 && w.Report != nil {
		w.Report("outbox_expired", expired)
	}
	if item == nil || now.Before(w.notBefore) {
		return nil
	}
	outcome := w.Sender.Send(ctx, item.Message)
	if w.Report != nil {
		w.Report(outcome.Code, 1)
	}
	if ctx.Err() != nil {
		return ctx.Err()
	} // ambiguous interrupted send stays pending for restart.
	if outcome.Fatal {
		return errors.New("Pushover sender unhealthy: " + outcome.Code)
	}
	delay := outcome.Delay
	if outcome.Retry {
		cooldown := outcome.Delay
		if cooldown < 5*time.Second {
			cooldown = 5 * time.Second
		}
		w.notBefore = w.Now().Add(cooldown)
		backoff := 5 * time.Second
		for n := 0; n < item.Attempts && backoff < 5*time.Minute; n++ {
			backoff *= 2
		}
		if backoff > 5*time.Minute {
			backoff = 5 * time.Minute
		}
		if delay < backoff {
			delay = backoff
		}
	}
	return w.Store.Finish(item.ID, outcome.Retry, delay, w.Now())
}
