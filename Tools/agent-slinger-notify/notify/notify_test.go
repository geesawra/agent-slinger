package notify

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/pushover"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/state"
	"html"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func fixture(now time.Time, reason string) Event {
	return Event{AgentID: "a", Reason: reason, Timestamp: now.Format(time.RFC3339Nano), ShouldNotify: false, Notification: &Payload{Title: "Paseo title", Body: "Upstream preview 🙂", Data: Data{ServerID: "s", WorkspaceID: "w", AgentID: "a", Reason: reason}}}
}
func TestExplicitPassivePolicyFiltersAndNeverInventsAnchors(t *testing.T) {
	now := time.Now().UTC()
	p := Policy{Mode: "all-attention", Content: "paseo-preview", ServerID: "s", TTL: time.Hour}
	e := fixture(now, "permission")
	i, err := p.Prepare(e, now)
	if err != nil || i == nil || i.Message.Body != DisplayBody(p.ServerName, p.ServerID, e.Notification.Body) {
		t.Fatal(i, err)
	}
	if i.Message.URL != "agentslinger://open?agentId=a&serverId=s&v=1&workspaceId=w" {
		t.Fatal("guessed anchor or incorrect session URL", i.Message.URL)
	}
	for _, reason := range []string{"error", "unknown"} {
		if i, err := p.Prepare(fixture(now, reason), now); i != nil || err != nil {
			t.Fatal("unsupported reason sent")
		}
	}
	p.Mode = "paseo-parity"
	if _, err := p.Prepare(e, now); err == nil {
		t.Fatal("invented parity")
	}
	p.Mode = "all-attention"
	p.Content = "generic"
	i, _ = p.Prepare(e, now)
	if strings.Contains(i.Message.Body, e.Notification.Body) {
		t.Fatal("preview disclosure in generic mode")
	}
}
func TestRejectTargetsTimestampExpiryAndLongRoutes(t *testing.T) {
	now := time.Now().UTC()
	p := Policy{Mode: "all-attention", Content: "generic", ServerID: "s", TTL: time.Hour}
	for _, change := range []func(*Event){func(e *Event) { e.Notification.Data.ServerID = "other" }, func(e *Event) { e.Notification.Data.AgentID = "other" }, func(e *Event) { e.Notification.Data.Reason = "finished" }, func(e *Event) { e.Timestamp = "not a timestamp" }, func(e *Event) { e.Timestamp = now.Add(time.Hour).Format(time.RFC3339) }, func(e *Event) { e.Notification.Data.WorkspaceID = "" }} {
		e := fixture(now, "permission")
		change(&e)
		if _, err := p.Prepare(e, now); err == nil {
			t.Fatal("accepted untrusted target")
		}
	}
	i, err := p.Prepare(fixture(now.Add(-2*time.Hour), "finished"), now)
	if i != nil || err != nil {
		t.Fatal("expired event", err)
	}
}

type fakeSender struct {
	out  pushover.Outcome
	sent int
}

func (s *fakeSender) Send(context.Context, pushover.Message) pushover.Outcome { s.sent++; return s.out }
func TestWorkerRetriesWithClockAndPreservesFatalPending(t *testing.T) {
	now := time.Now().UTC()
	s, _ := state.Open(filepath.Join(t.TempDir(), "state"), "s", 10)
	defer s.Close()
	p := Policy{Mode: "all-attention", Content: "generic", ServerID: "s", TTL: time.Hour}
	i, _ := p.Prepare(fixture(now, "finished"), now)
	s.Enqueue(*i, now)
	sender := &fakeSender{out: pushover.Outcome{Retry: true, Delay: time.Second, Code: "temporary"}}
	w := Worker{Store: s, Sender: sender, Now: func() time.Time { return now }}
	if err := w.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	now = now.Add(4 * time.Second)
	w.Step(context.Background())
	if sender.sent != 1 {
		t.Fatal("retried too early")
	}
	now = now.Add(time.Second)
	sender.out = pushover.Outcome{Fatal: true, Code: "recipient_rejected"}
	if err := w.Step(context.Background()); err == nil || s.Count() != 1 {
		t.Fatal("fatal lost pending")
	}
	sender.out = pushover.Outcome{Accepted: true, Code: "accepted"}
	if err := w.Step(context.Background()); err != nil || s.Count() != 0 {
		t.Fatal(err)
	}
}
func TestInterruptedAmbiguousSendStaysPending(t *testing.T) {
	now := time.Now().UTC()
	s, _ := state.Open(filepath.Join(t.TempDir(), "state"), "s", 10)
	defer s.Close()
	p := Policy{Mode: "all-attention", Content: "generic", ServerID: "s", TTL: time.Hour}
	i, _ := p.Prepare(fixture(now, "finished"), now)
	s.Enqueue(*i, now)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	w := Worker{Store: s, Sender: &fakeSender{out: pushover.Outcome{Retry: true}}, Now: func() time.Time { return now }}
	if err := w.Step(ctx); !errors.Is(err, context.Canceled) || s.Count() != 1 {
		t.Fatal(err)
	}
}

func TestPinnedSanitizedFixturesPreserveUpstreamWording(t *testing.T) {
	now, _ := time.Parse(time.RFC3339, "2026-10-12T08:00:01Z")
	p := Policy{Mode: "all-attention", Content: "paseo-preview", ServerID: "server-fixture", TTL: time.Hour}
	for _, path := range []string{"testdata/attention_permission.json", "testdata/attention_finished.json"} {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var e Event
		if json.Unmarshal(b, &e) != nil {
			t.Fatal("invalid fixture")
		}
		i, err := p.Prepare(e, now)
		if err != nil || i == nil || i.Message.Body != DisplayBody(p.ServerName, p.ServerID, e.Notification.Body) {
			t.Fatal(i, err)
		}
	}
}

func TestAgentAndServerContextBothContentModes(t *testing.T) {
	now := time.Now().UTC()
	p := Policy{Mode: "all-attention", Content: "paseo-preview", ServerID: "s", ServerName: "workstation", TTL: time.Hour}
	e := fixture(now, "finished")
	e.AgentTitle = "Fix login"
	e.Notification.Body = "Event correlated completed turn preview"
	i, err := p.Prepare(e, now)
	if err != nil || i.Message.Title != "Fix login — turn finished" || i.Message.Body != DisplayBody(p.ServerName, p.ServerID, e.Notification.Body) {
		t.Fatal(i, err)
	}
	p.Content = "generic"
	i, err = p.Prepare(e, now)
	if err != nil || i.Message.Title != "Fix login — turn finished" || strings.Contains(i.Message.Body, "correlated") || !strings.HasPrefix(i.Message.Body, "<b>Server:</b> workstation\n\n") {
		t.Fatal("generic lost context or leaked preview", i, err)
	}
	e.Reason = "permission"
	e.Notification.Data.Reason = "permission"
	i, err = p.Prepare(e, now)
	if err != nil || !strings.Contains(i.Message.Title, "needs permission") {
		t.Fatal(i, err)
	}
}
func TestDisplayNormalizationFallbackAndUnicodeLimits(t *testing.T) {
	now := time.Now().UTC()
	p := Policy{Mode: "all-attention", Content: "paseo-preview", ServerID: "s", ServerName: "  workstation\n\t desk\x00  ", TTL: time.Hour}
	e := fixture(now, "finished")
	e.AgentTitle = "  Fix\n login\t\x00 "
	e.Notification.Body = "Line one\nline\t two\x00"
	i, err := p.Prepare(e, now)
	if err != nil || i.Message.Title != "Fix login — turn finished" || i.Message.Body != "<b>Server:</b> workstation desk\n\nLine one line two" {
		t.Fatal(i, err)
	}
	e.AgentTitle = strings.Repeat("🙂", 300)
	p.ServerName = strings.Repeat("日本語", 200)
	e.Notification.Body = strings.Repeat("🙂", 2000)
	i, err = p.Prepare(e, now)
	if err != nil || utf8.RuneCountInString(i.Message.Title) > 250 || utf8.RuneCountInString(i.Message.Body) != 1024 || !utf8.ValidString(i.Message.Title) || !strings.HasSuffix(i.Message.Body, "…") {
		t.Fatal("Unicode provider limits", err)
	}
	e.AgentTitle = ""
	p.ServerName = ""
	i, _ = p.Prepare(e, now)
	if i.Message.Title != "Agent a — turn finished" {
		t.Fatal("opaque fallback missing", i.Message.Title)
	}
	if ServerLabel(" ", " daemon\n desktop ", "s") != "daemon desktop" || ServerLabel("Custom", "hostname", "s") != "Custom" {
		t.Fatal("server display priority")
	}
}

func TestBidiControlsRemovedWithoutBreakingEmojiJoiners(t *testing.T) {
	if got := NormalizeText("Fix\u202elogin\u202c\u2066workstation\u2069"); got != "Fix login workstation" {
		t.Fatal("directional controls retained", got)
	}
	emoji := "👨‍👩‍👧‍👦"
	if NormalizeText(emoji) != emoji {
		t.Fatal("emoji joiners removed")
	}
}

func TestHTMLMetadataEscapingAndEncodedBodyLimit(t *testing.T) {
	body := DisplayBody(`workstation <& "quoted">`, "s", `Preview <b>untrusted</b> & "text"`)
	want := "<b>Server:</b> workstation &lt;&amp; &#34;quoted&#34;&gt;\n\nPreview &lt;b&gt;untrusted&lt;/b&gt; &amp; &#34;text&#34;"
	if body != want {
		t.Fatal("remote markup unescaped", body)
	}
	for _, text := range []string{strings.Repeat("&", 2000), strings.Repeat(`<>&"'🙂`, 1000)} {
		body = DisplayBody(strings.Repeat("&", 100), "s", text)
		if utf8.RuneCountInString(body) > 1024 || !strings.HasSuffix(body, "…") {
			t.Fatal("encoded limit violated", utf8.RuneCountInString(body))
		}
		preview := strings.SplitN(body, "\n\n", 2)[1]
		if strings.Contains(html.UnescapeString(preview), "&amp;") || strings.Contains(preview, "<") {
			t.Fatal("entity truncated or markup injected", preview)
		}
		// Every encoded ampersand must complete one of Go's escaped entities before the ellipsis.
		for _, part := range strings.Split(preview, "&")[1:] {
			if !strings.Contains(part, ";") {
				t.Fatal("partial entity", preview)
			}
		}
	}
	now := time.Now().UTC()
	p := Policy{Mode: "all-attention", Content: "generic", ServerID: "s", TTL: time.Hour}
	i, err := p.Prepare(fixture(now, "finished"), now)
	if err != nil || !i.Message.HTML || !strings.HasPrefix(i.Message.Body, "<b>Server:</b> s\n\n") {
		t.Fatal("generic lost styled metadata", i, err)
	}
}
