package pushover

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func fake(t *testing.T, h http.HandlerFunc) *Client {
	t.Helper()
	s := httptest.NewServer(h)
	t.Cleanup(s.Close)
	c := New(strings.Repeat("a", 30), strings.Repeat("b", 30), "")
	c.base = s.URL + "/"
	return c
}
func msg() Message {
	return Message{Title: "日本語", Body: "🙂 completion", URL: "agentslinger://open?v=1&serverId=s&workspaceId=w&agentId=a", URLTitle: "Open Agent Slinger"}
}
func TestSendEncodingNormalPriorityAndAcceptance(t *testing.T) {
	c := fake(t, func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		if r.Method != "POST" || r.Form.Get("priority") != "0" || r.Form.Get("message") != msg().Body || r.Form.Get("url") != msg().URL || r.Form.Get("token") != strings.Repeat("a", 30) {
			t.Error("incorrect form")
		}
		fmt.Fprint(w, `{"status":1}`)
	})
	if o := c.Send(context.Background(), msg()); !o.Accepted {
		t.Fatal(o)
	}
}
func TestResponseClassificationAndFloor(t *testing.T) {
	cases := []struct {
		status       int
		body         string
		retry, fatal bool
		code         string
	}{{200, `{"status":1}`, false, false, "accepted"}, {200, `broken`, true, false, "response_ambiguous"}, {500, `{"errors":["secret remote text"]}`, true, false, "provider_temporary"}, {429, `{"status":0}`, true, false, "provider_temporary"}, {401, `{"status":0}`, false, true, "recipient_or_token_rejected"}, {400, `{"status":0,"token":"invalid","errors":["private"]}`, false, true, "recipient_or_token_rejected"}, {400, `{"status":0,"errors":["private"]}`, false, false, "request_rejected"}, {200, `{"status":0}`, false, false, "request_rejected"}}
	for _, tc := range cases {
		t.Run(tc.code+fmt.Sprint(tc.status), func(t *testing.T) {
			c := fake(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Retry-After", "1")
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			})
			o := c.Send(context.Background(), msg())
			if o.Code != tc.code || o.Retry != tc.retry || o.Fatal != tc.fatal {
				t.Fatal(o)
			}
			if o.Retry && o.Delay < 5*time.Second {
				t.Fatal("retry floor", o)
			}
			if strings.Contains(o.Code, "private") {
				t.Fatal("remote error leaked")
			}
		})
	}
}
func TestQuotaAndTimeoutAmbiguity(t *testing.T) {
	c := fake(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Limit-App-Remaining", "0")
		w.Header().Set("X-Limit-App-Reset", fmt.Sprint(time.Now().Add(time.Hour).Unix()))
		w.WriteHeader(429)
		fmt.Fprint(w, `{"status":0}`)
	})
	if o := c.Send(context.Background(), msg()); !o.Retry || o.Code != "quota_exhausted" || o.Delay < 59*time.Minute {
		t.Fatal(o)
	}
	c = fake(t, func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(100 * time.Millisecond)
		fmt.Fprint(w, `{"status":1}`)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if o := c.Send(ctx, msg()); !o.Retry || o.Code != "transport_ambiguous" {
		t.Fatal(o)
	}
}
func TestRecipientCheckNeverPostsMessagesAndRejectsMissingDevice(t *testing.T) {
	for _, body := range []string{`{"status":1,"devices":["phone"]}`, `{"status":1,"devices":[]}`, `{"status":1,"devices":["other"]}`} {
		c := fake(t, func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/users/validate.json" {
				t.Error("pushed during check")
			}
			fmt.Fprint(w, body)
		})
		c.device = "phone"
		o := c.ValidateRecipient(context.Background())
		if (body == `{"status":1,"devices":["phone"]}`) != o.Accepted {
			t.Fatal(o)
		}
	}
}
func TestUnicodeLimitsAndSerializedCalls(t *testing.T) {
	m := msg()
	m.Body = strings.Repeat("🙂", 1024)
	if m.Validate() != nil {
		t.Fatal("UTF-8 counted as bytes")
	}
	m.Body += "🙂"
	if m.Validate() == nil {
		t.Fatal("oversize accepted")
	}
	var concurrent atomic.Int32
	c := fake(t, func(w http.ResponseWriter, r *http.Request) {
		if concurrent.Add(1) != 1 {
			t.Error("parallel requests")
		}
		time.Sleep(time.Millisecond)
		concurrent.Add(-1)
		fmt.Fprint(w, `{"status":1}`)
	})
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); c.Send(context.Background(), msg()) }()
	}
	wg.Wait()
}
func TestProductionHTTPSRejectsRedirect(t *testing.T) {
	c := New("token", "user", "")
	if c.base != "https://api.pushover.net/1/" || c.http.CheckRedirect(&http.Request{}, nil) != http.ErrUseLastResponse {
		t.Fatal("unsafe production endpoint")
	}
	if transport, ok := c.http.Transport.(*http.Transport); ok && transport.TLSClientConfig != nil && transport.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("TLS verification disabled")
	}
}

func TestHTMLFlagOnlyForFormattedMessages(t *testing.T) {
	for _, formatted := range []bool{false, true} {
		c := fake(t, func(w http.ResponseWriter, r *http.Request) {
			r.ParseForm()
			if formatted {
				if r.Form.Get("html") != "1" {
					t.Error("formatted message did not opt into HTML")
				}
			} else if _, exists := r.Form["html"]; exists {
				t.Error("legacy plain message altered")
			}
			fmt.Fprint(w, `{"status":1}`)
		})
		m := msg()
		m.HTML = formatted
		if !c.Send(context.Background(), m).Accepted {
			t.Fatal("send failed")
		}
	}
}
