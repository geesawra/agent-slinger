// Package pushover sends normal-priority messages through the verified HTTPS API.
package pushover

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const endpoint = "https://api.pushover.net/1/"

type Message struct {
	HTML     bool   `json:"html,omitempty"`
	Title    string `json:"title"`
	Body     string `json:"body"`
	URL      string `json:"url"`
	URLTitle string `json:"url_title"`
}

func (m Message) Validate() error {
	for _, f := range []struct {
		s   string
		max int
	}{{m.Title, 250}, {m.Body, 1024}, {m.URL, 512}, {m.URLTitle, 100}} {
		if !utf8.ValidString(f.s) || utf8.RuneCountInString(f.s) > f.max {
			return errors.New("Pushover field exceeds provider character limit")
		}
	}
	if strings.TrimSpace(m.Body) == "" || m.URL == "" {
		return errors.New("Pushover message and action URL are required")
	}
	return nil
}

type Outcome struct {
	Accepted bool
	Retry    bool
	Fatal    bool
	Delay    time.Duration
	Code     string
}

// Client serializes requests. Endpoint and transport are deliberately fixed in production.
type Client struct {
	token, user, device string
	http                *http.Client
	base                string
	mu                  sync.Mutex
}

func New(token, user, device string) *Client {
	return &Client{token: token, user: user, device: device, base: endpoint, http: &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}
func (c *Client) ValidateRecipient(ctx context.Context) Outcome {
	return c.post(ctx, "users/validate.json", url.Values{})
}
func (c *Client) Send(ctx context.Context, m Message) Outcome {
	if m.Validate() != nil {
		return Outcome{Code: "invalid_message"}
	}
	values := url.Values{"title": {m.Title}, "message": {m.Body}, "url": {m.URL}, "url_title": {m.URLTitle}, "priority": {"0"}}
	if m.HTML {
		values.Set("html", "1")
	}
	return c.post(ctx, "messages.json", values)
}
func (c *Client) post(ctx context.Context, path string, values url.Values) Outcome {
	c.mu.Lock()
	defer c.mu.Unlock()
	values.Set("token", c.token)
	values.Set("user", c.user)
	if c.device != "" {
		values.Set("device", c.device)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+path, strings.NewReader(values.Encode()))
	if err != nil {
		return Outcome{Fatal: true, Code: "request_configuration"}
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := c.http.Do(req)
	if err != nil {
		return Outcome{Retry: true, Delay: 5 * time.Second, Code: "transport_ambiguous"}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 65537))
	if err != nil || len(data) > 65536 {
		return Outcome{Retry: true, Delay: 5 * time.Second, Code: "response_ambiguous"}
	}
	var body struct {
		Status  int             `json:"status"`
		Devices []string        `json:"devices"`
		Token   json.RawMessage `json:"token"`
		User    json.RawMessage `json:"user"`
	}
	decoded := json.Unmarshal(data, &body) == nil
	if res.StatusCode == http.StatusOK && decoded && body.Status == 1 {
		if path == "users/validate.json" && c.device != "" {
			found := false
			for _, d := range body.Devices {
				if d == c.device {
					found = true
				}
			}
			if !found {
				return Outcome{Fatal: true, Code: "device_unavailable"}
			}
		}
		return Outcome{Accepted: true, Code: "accepted"}
	}
	delay := 5 * time.Second
	if v, err := strconv.Atoi(res.Header.Get("Retry-After")); err == nil && v > 0 {
		delay = time.Duration(v) * time.Second
	} else if t, err := http.ParseTime(res.Header.Get("Retry-After")); err == nil && time.Until(t) > delay {
		delay = time.Until(t)
	}
	if delay < 5*time.Second {
		delay = 5 * time.Second
	}
	if res.Header.Get("X-Limit-App-Remaining") == "0" {
		if reset, err := strconv.ParseInt(res.Header.Get("X-Limit-App-Reset"), 10, 64); err == nil && time.Until(time.Unix(reset, 0)) > delay {
			delay = time.Until(time.Unix(reset, 0))
		} else {
			delay = time.Hour
		}
		return Outcome{Retry: true, Delay: delay, Code: "quota_exhausted"}
	}
	if res.StatusCode == 429 || res.StatusCode == 408 || res.StatusCode >= 500 {
		return Outcome{Retry: true, Delay: delay, Code: "provider_temporary"}
	}
	if res.StatusCode == 401 || res.StatusCode == 403 || (decoded && (len(body.Token) > 0 || len(body.User) > 0)) {
		return Outcome{Fatal: true, Code: "recipient_or_token_rejected"}
	}
	if res.StatusCode >= 400 && res.StatusCode < 500 || res.StatusCode == 200 && decoded && body.Status != 1 {
		return Outcome{Code: "request_rejected"}
	}
	// Invalid HTTP-200 JSON may follow successful acceptance; retry is explicitly ambiguous.
	if res.StatusCode == 200 {
		return Outcome{Retry: true, Delay: delay, Code: "response_ambiguous"}
	}
	return Outcome{Fatal: true, Code: "unexpected_http_status"}
}
