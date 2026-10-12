// Package state maintains a bounded, atomically replaced outbox with a process lock.
// The journal records enqueue watermarks and accepted removals in the same snapshot.
package state

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"syscall"
	"time"

	"github.com/geesawra/oesap/Tools/agent-slinger-notify/pushover"
)

const maxWatermarks = 4096
const maxStateBytes = 64 << 20

var ErrLocked = errors.New("state directory already has a writer")

type Item struct {
	ID          string           `json:"id"`
	AgentKey    string           `json:"agent_key"`
	Reason      string           `json:"reason"`
	Timestamp   time.Time        `json:"timestamp"`
	Expires     time.Time        `json:"expires"`
	NextAttempt time.Time        `json:"next_attempt"`
	Attempts    int              `json:"attempts"`
	Message     pushover.Message `json:"message"`
}
type Snapshot struct {
	Version    int                  `json:"version"`
	Scope      string               `json:"scope"`
	Pending    []Item               `json:"pending"`
	Watermarks map[string]time.Time `json:"watermarks"`
}
type Store struct {
	mu   sync.Mutex
	dir  string
	lock *os.File
	max  int
	data Snapshot
}

func Key(parts ...string) string {
	b, _ := json.Marshal(parts)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// Open may migrate one explicitly accepted legacy scope, preserving its entire journal.
func Open(dir, scope string, max int, acceptedLegacyScope ...string) (*Store, error) {
	if max < 1 || max > 10000 || scope == "" || len(acceptedLegacyScope) > 1 {
		return nil, errors.New("invalid state bounds or scope")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, errors.New("cannot create state directory")
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("state directory must be private and not a symlink")
	}
	lock, err := os.OpenFile(filepath.Join(dir, "writer.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, errors.New("cannot open state lock")
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, ErrLocked
	}
	s := &Store{dir: dir, lock: lock, max: max, data: Snapshot{Version: 1, Scope: scope, Watermarks: map[string]time.Time{}}}
	p := filepath.Join(dir, "outbox.json")
	f, err := os.Open(p)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		s.Close()
		return nil, errors.New("cannot read persisted outbox")
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxStateBytes+1))
	if err != nil || len(b) > maxStateBytes || json.Unmarshal(b, &s.data) != nil {
		s.Close()
		return nil, errors.New("invalid persisted outbox")
	}
	scopeMatches := s.data.Scope == scope
	if !scopeMatches && len(acceptedLegacyScope) == 1 && acceptedLegacyScope[0] != "" {
		scopeMatches = s.data.Scope == acceptedLegacyScope[0]
	}
	if s.data.Version != 1 || !scopeMatches || s.data.Watermarks == nil || len(s.data.Pending) > max || len(s.data.Watermarks) > maxWatermarks {
		s.Close()
		return nil, errors.New("state scope or bounds changed; use a separate state directory")
	}
	seen := map[string]bool{}
	for _, i := range s.data.Pending {
		if i.ID == "" || seen[i.ID] || i.AgentKey == "" || (i.Reason != "finished" && i.Reason != "permission") || i.Attempts < 0 || i.Expires.IsZero() || i.Timestamp.IsZero() || i.Message.Validate() != nil {
			s.Close()
			return nil, errors.New("invalid persisted pending item")
		}
		seen[i.ID] = true
	}
	if s.data.Scope != scope {
		d := s.copy()
		d.Scope = scope
		if err := s.save(d); err != nil {
			s.Close()
			return nil, err
		}
	}
	return s, nil
}
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lock == nil {
		return nil
	}
	err := s.lock.Close()
	s.lock = nil
	return err
}
func (s *Store) copy() Snapshot {
	d := s.data
	d.Pending = append([]Item(nil), d.Pending...)
	d.Watermarks = make(map[string]time.Time, len(s.data.Watermarks))
	for k, v := range s.data.Watermarks {
		d.Watermarks[k] = v
	}
	return d
}
func prune(d *Snapshot, now time.Time) int {
	n := 0
	kept := d.Pending[:0]
	for _, i := range d.Pending {
		if !now.Before(i.Expires) {
			n++
			continue
		}
		kept = append(kept, i)
	}
	d.Pending = kept
	for k, t := range d.Watermarks {
		if now.Sub(t) > 30*24*time.Hour {
			delete(d.Watermarks, k)
		}
	}
	return n
}

// Enqueue returns queued, number evicted, and error. Stale/equal timestamps are suppressed.
func (s *Store) Enqueue(item Item, now time.Time) (bool, int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lock == nil {
		return false, 0, errors.New("state closed")
	}
	if !now.Before(item.Expires) || item.Timestamp.IsZero() || item.AgentKey == "" || item.ID == "" || item.Message.Validate() != nil {
		return false, 0, errors.New("invalid or expired outbox item")
	}
	if t, ok := s.data.Watermarks[item.AgentKey]; ok && !item.Timestamp.After(t) {
		return false, 0, nil
	}
	d := s.copy()
	dropped := prune(&d, now)
	if len(d.Pending) >= s.max {
		victim := 0
		for i, p := range d.Pending {
			if p.Reason == "finished" {
				victim = i
				break
			}
		}
		d.Pending = append(d.Pending[:victim], d.Pending[victim+1:]...)
		dropped++
	}
	if len(d.Watermarks) >= maxWatermarks {
		oldest := ""
		var t time.Time
		for k, v := range d.Watermarks {
			if oldest == "" || v.Before(t) {
				oldest = k
				t = v
			}
		}
		delete(d.Watermarks, oldest)
	}
	d.Watermarks[item.AgentKey] = item.Timestamp
	d.Pending = append(d.Pending, item)
	if err := s.save(d); err != nil {
		return false, 0, err
	}
	return true, dropped, nil
}

// Next selects ready permissions first, so a deferred completion cannot block them.
func (s *Store) Next(now time.Time) (*Item, int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.copy()
	expired := prune(&d, now)
	if expired > 0 || len(d.Watermarks) != len(s.data.Watermarks) {
		if err := s.save(d); err != nil {
			return nil, 0, err
		}
	}
	var best *Item
	for _, i := range s.data.Pending {
		if i.NextAttempt.After(now) {
			continue
		}
		if best == nil || (i.Reason == "permission" && best.Reason != "permission") || (i.Reason == best.Reason && i.Timestamp.Before(best.Timestamp)) {
			copy := i
			best = &copy
		}
	}
	return best, expired, nil
}
func (s *Store) Finish(id string, retry bool, delay time.Duration, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.copy()
	for idx, i := range d.Pending {
		if i.ID != id {
			continue
		}
		if retry {
			if delay < 5*time.Second {
				delay = 5 * time.Second
			}
			i.Attempts++
			i.NextAttempt = now.Add(delay)
			d.Pending[idx] = i
		} else {
			d.Pending = append(d.Pending[:idx], d.Pending[idx+1:]...)
		}
		return s.save(d)
	}
	return nil
}
func (s *Store) Count() int { s.mu.Lock(); defer s.mu.Unlock(); return len(s.data.Pending) }
func (s *Store) save(d Snapshot) error {
	if s.lock == nil {
		return errors.New("state closed")
	}
	// Stable snapshots aid diagnosis without exposing their contents in logs.
	sort.SliceStable(d.Pending, func(i, j int) bool { return d.Pending[i].Timestamp.Before(d.Pending[j].Timestamp) })
	b, err := json.Marshal(d)
	if err != nil || len(b) > maxStateBytes {
		return errors.New("outbox exceeds persistent bound")
	}
	f, err := os.CreateTemp(s.dir, ".outbox-*")
	if err != nil {
		return errors.New("cannot create atomic outbox")
	}
	name := f.Name()
	defer os.Remove(name)
	if f.Chmod(0600) != nil {
		f.Close()
		return errors.New("cannot protect atomic outbox")
	}
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil || closeErr != nil {
		return errors.New("cannot flush atomic outbox")
	}
	if os.Rename(name, filepath.Join(s.dir, "outbox.json")) != nil {
		return errors.New("cannot replace atomic outbox")
	}
	dir, err := os.Open(s.dir)
	if err != nil {
		return errors.New("cannot sync outbox directory")
	}
	err = dir.Sync()
	dir.Close()
	if err != nil {
		return errors.New("cannot sync outbox directory")
	}
	s.data = d
	return nil
}
