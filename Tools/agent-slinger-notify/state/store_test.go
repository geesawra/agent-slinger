package state

import (
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/pushover"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func item(agent, reason string, ts time.Time) Item {
	return Item{ID: Key(agent, reason, ts.String()), AgentKey: Key(agent), Reason: reason, Timestamp: ts, Expires: ts.Add(time.Hour), NextAttempt: ts, Message: pushover.Message{Title: "Agent", Body: "finished", URL: "agentslinger://open?v=1&serverId=s&workspaceId=w&agentId=a", URLTitle: "Open"}}
}
func TestAtomicRecoveryWatermarkAndSingleWriter(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	now := time.Now().UTC()
	s, err := Open(dir, "scope", 2)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Open(dir, "scope", 2); err != ErrLocked {
		t.Fatal(err)
	}
	a := item("a", "finished", now)
	if queued, _, err := s.Enqueue(a, now); !queued || err != nil {
		t.Fatal(queued, err)
	}
	s.Close()
	s, err = Open(dir, "scope", 2)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if s.Count() != 1 {
		t.Fatal("lost pending")
	}
	if err := s.Finish(a.ID, false, 0, now); err != nil {
		t.Fatal(err)
	}
	if queued, _, err := s.Enqueue(a, now); queued || err != nil {
		t.Fatal("accepted duplicate", err)
	}
	if info, _ := os.Stat(filepath.Join(dir, "outbox.json")); info.Mode().Perm() != 0600 {
		t.Fatal("unprotected state")
	}
	if _, err := Open(filepath.Join(t.TempDir(), "new"), "scope", 0); err == nil {
		t.Fatal("invalid bounds")
	}
}
func TestBoundsExpiryPermissionPriorityAndBackoff(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state"), "s", 2)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now().UTC()
	a := item("a", "finished", now.Add(-time.Minute))
	b := item("b", "permission", now.Add(-time.Second))
	s.Enqueue(a, now)
	s.Enqueue(b, now)
	next, _, _ := s.Next(now)
	if next.ID != b.ID {
		t.Fatal("completion blocked permission")
	}
	s.Finish(b.ID, true, time.Second, now)
	next, _, _ = s.Next(now.Add(4 * time.Second))
	if next.ID != a.ID {
		t.Fatal("retry before 5 second floor")
	}
	c := item("c", "permission", now)
	if queued, dropped, err := s.Enqueue(c, now); !queued || dropped != 1 || err != nil || s.Count() != 2 {
		t.Fatal(queued, dropped, err)
	}
	next, _, _ = s.Next(now)
	if next.ID != c.ID {
		t.Fatal("backoff blocked ready permission")
	}
	next, expired, err := s.Next(now.Add(2 * time.Hour))
	if next != nil || expired != 2 || err != nil {
		t.Fatal(next, expired, err)
	}
}
func TestScopeChangeCorruptionAndConcurrentDedup(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	s, _ := Open(dir, "s", 256)
	now := time.Now().UTC()
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); s.Enqueue(item("a", "finished", now), now) }()
	}
	wg.Wait()
	if s.Count() != 1 {
		t.Fatal("race duplicate")
	}
	s.Close()
	if _, err := Open(dir, "other", 256); err == nil {
		t.Fatal("scope reuse accepted")
	}
	os.WriteFile(filepath.Join(dir, "outbox.json"), []byte(`{"version":1,"scope":"s","pending":`), 0600)
	if _, err := Open(dir, "s", 256); err == nil {
		t.Fatal("corruption ignored")
	}
}

func TestForwardContentMigrationPreservesJournalAndRejectsForeignOrReverseScope(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	now := time.Now().UTC()
	genericScope := Key("server", "recipient", "device", "generic", "all-attention")
	previewScope := Key("server", "recipient", "device", "paseo-preview", "all-attention")
	s, err := Open(dir, genericScope, 10)
	if err != nil {
		t.Fatal(err)
	}
	pending := item("pending", "permission", now)
	pending.Message.Body = "Original generic message"
	accepted := item("accepted", "finished", now)
	s.Enqueue(pending, now)
	s.Enqueue(accepted, now)
	s.Finish(accepted.ID, false, 0, now)
	s.Finish(pending.ID, true, 30*time.Second, now)
	s.Close()
	// A different host/recipient cannot be accepted by this exact content-only migration.
	if _, err := Open(dir, Key("foreign", "recipient", "device", "paseo-preview", "all-attention"), 10, Key("foreign", "recipient", "device", "generic", "all-attention")); err == nil {
		t.Fatal("foreign scope migrated")
	}
	s, err = Open(dir, previewScope, 10, genericScope)
	if err != nil {
		t.Fatal(err)
	}
	if s.Count() != 1 {
		t.Fatal("pending work lost")
	}
	got, _, err := s.Next(now.Add(time.Minute))
	if err != nil || got == nil || got.Message != pending.Message || got.Attempts != 1 || !got.NextAttempt.Equal(now.Add(30*time.Second)) {
		t.Fatal("pending content or backoff changed", got, err)
	}
	if queued, _, err := s.Enqueue(accepted, now); queued || err != nil {
		t.Fatal("accepted watermark lost", err)
	}
	if queued, _, err := s.Enqueue(pending, now); queued || err != nil {
		t.Fatal("pending watermark lost", err)
	}
	s.Close()
	reopened, err := Open(dir, previewScope, 10)
	if err != nil {
		t.Fatal("atomic migrated scope not retained", err)
	}
	reopened.Close()
	if _, err := Open(dir, genericScope, 10); err == nil {
		t.Fatal("reverse migration enabled queued previews in generic mode")
	}
}

func TestHTMLFormatPersistsAndLegacyPlainMessagesRemainPlain(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	now := time.Now().UTC()
	s, err := Open(dir, "scope", 10)
	if err != nil {
		t.Fatal(err)
	}
	plain := item("plain", "finished", now)
	formatted := item("formatted", "permission", now)
	formatted.Message.HTML = true
	formatted.Message.Body = "<b>Server:</b> workstation\n\nEscaped &amp; preview"
	s.Enqueue(plain, now)
	s.Enqueue(formatted, now)
	s.Close()
	s, err = Open(dir, "scope", 10)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	next, _, _ := s.Next(now)
	if next == nil || !next.Message.HTML || next.Message.Body != formatted.Message.Body {
		t.Fatal("format flag lost", next)
	}
	s.Finish(formatted.ID, false, 0, now)
	next, _, _ = s.Next(now)
	if next == nil || next.Message.HTML || next.Message.Body != plain.Message.Body {
		t.Fatal("legacy message switched to HTML", next)
	}
}
