// Package config reads and validates environment-only sidecar settings.
package config

import (
	"errors"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/paseo"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Paseo                           struct{ URL, PairingLink, ExpectedServerID, ServerName string }
	Pushover                        struct{ Device string }
	DeliveryMode, Content, StateDir string
	MaxPending, EventTTLSeconds     int
}
type Secrets struct{ Password, Token, User string }

var keyPattern = regexp.MustCompile(`^[A-Za-z0-9]{30}$`)
var devicePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,25}$`)

func Load() (Config, Secrets, error) { return LoadFrom(os.Getenv) }

// LoadFrom provides an environment seam for offline tests without reading files.
func LoadFrom(getenv func(string) string) (Config, Secrets, error) {
	var c Config
	c.Paseo.URL = getenv("PASEO_URL")
	c.Paseo.PairingLink = getenv("PASEO_PAIRING_LINK")
	if c.Paseo.URL == "" && c.Paseo.PairingLink == "" {
		c.Paseo.URL = "ws://127.0.0.1:6767/ws"
	}
	c.Paseo.ExpectedServerID = getenv("PASEO_SERVER_ID")
	c.Paseo.ServerName = getenv("PASEO_SERVER_NAME")
	c.Pushover.Device = getenv("PUSHOVER_DEVICE")
	c.DeliveryMode = getenv("NOTIFY_DELIVERY_MODE")
	c.Content = getenv("NOTIFY_CONTENT")
	if c.Content == "" {
		c.Content = "paseo-preview"
	}
	c.StateDir = getenv("NOTIFY_STATE_DIR")
	var err error
	c.MaxPending, err = integer(getenv("NOTIFY_MAX_PENDING"), 256)
	if err != nil {
		return c, Secrets{}, errors.New("NOTIFY_MAX_PENDING must be an integer")
	}
	c.EventTTLSeconds, err = integer(getenv("NOTIFY_EVENT_TTL_SECONDS"), 86400)
	if err != nil {
		return c, Secrets{}, errors.New("NOTIFY_EVENT_TTL_SECONDS must be an integer")
	}
	if err := c.Validate(); err != nil {
		return c, Secrets{}, err
	}
	if !filepath.IsAbs(c.StateDir) {
		c.StateDir, err = filepath.Abs(c.StateDir)
		if err != nil {
			return c, Secrets{}, errors.New("cannot resolve NOTIFY_STATE_DIR")
		}
	}
	s := Secrets{Password: getenv("PASEO_PASSWORD"), Token: getenv("PUSHOVER_APP_TOKEN"), User: getenv("PUSHOVER_USER_KEY")}
	if len(s.Password) > 4096 {
		return c, Secrets{}, errors.New("PASEO_PASSWORD exceeds credential bound")
	}
	if !keyPattern.MatchString(s.Token) {
		return c, Secrets{}, errors.New("PUSHOVER_APP_TOKEN must contain a valid Pushover application token")
	}
	if !keyPattern.MatchString(s.User) {
		return c, Secrets{}, errors.New("PUSHOVER_USER_KEY must contain a valid Pushover user or group key")
	}
	return c, s, nil
}
func integer(value string, fallback int) (int, error) {
	if value == "" {
		return fallback, nil
	}
	return strconv.Atoi(value)
}
func (c Config) Validate() error {
	if c.DeliveryMode == "paseo-parity" {
		return errors.New("paseo-parity is unavailable: pinned Paseo exposes no external remote-delivery decision; explicitly select all-attention to accept presence-policy differences")
	}
	if c.DeliveryMode != "all-attention" {
		return errors.New("NOTIFY_DELIVERY_MODE must explicitly be all-attention")
	}
	if c.Content != "generic" && c.Content != "paseo-preview" {
		return errors.New("NOTIFY_CONTENT must be generic or paseo-preview")
	}

	if c.Paseo.PairingLink != "" {
		if c.Paseo.URL != "" {
			return errors.New("PASEO_PAIRING_LINK and explicitly set PASEO_URL are mutually exclusive")
		}
		offer, err := paseo.ParseRelayOffer(c.Paseo.PairingLink)
		if err != nil {
			return errors.New("PASEO_PAIRING_LINK must be a valid supported relay v2 pairing link")
		}
		if c.Paseo.ExpectedServerID != "" && c.Paseo.ExpectedServerID != offer.ServerID {
			return errors.New("PASEO_SERVER_ID differs from relay pairing identity")
		}
	} else {
		u, err := url.Parse(c.Paseo.URL)
		if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "/ws" || u.RawPath != "" {
			return errors.New("PASEO_URL must be a direct ws/wss endpoint ending in /ws, without credentials, query or fragment")
		}
		if u.Scheme != "wss" && u.Scheme != "ws" {
			return errors.New("PASEO_URL must use ws or wss")
		}
		if u.Scheme == "ws" {
			ip := net.ParseIP(u.Hostname())
			if ip == nil || !ip.IsLoopback() {
				return errors.New("unencrypted WebSocket requires a numeric loopback address; remote connections require verified wss")
			}
		}

	}
	if c.Paseo.ExpectedServerID != "" && (strings.TrimSpace(c.Paseo.ExpectedServerID) == "" || len(c.Paseo.ExpectedServerID) > 512) {
		return errors.New("PASEO_SERVER_ID must be a nonempty bounded identity when supplied")
	}
	if len(c.Paseo.ServerName) > 4096 {
		return errors.New("PASEO_SERVER_NAME exceeds display label bound")
	}
	if c.StateDir == "" {
		return errors.New("NOTIFY_STATE_DIR is required")
	}
	if c.MaxPending < 1 || c.MaxPending > 10000 {
		return errors.New("NOTIFY_MAX_PENDING must be between 1 and 10000")
	}
	if c.EventTTLSeconds < 5 || c.EventTTLSeconds > int((7*24*time.Hour).Seconds()) {
		return errors.New("NOTIFY_EVENT_TTL_SECONDS must be between 5 and 604800")
	}
	if c.Pushover.Device != "" && !devicePattern.MatchString(c.Pushover.Device) {
		return errors.New("PUSHOVER_DEVICE must be one name of at most 25 ASCII letters, digits, underscores or hyphens")
	}
	return nil
}
