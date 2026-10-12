package paseo

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

// jsonTransport keeps the protocol unaware of the direct or encrypted relay wire.
// Like gorilla/websocket, it permits one reader and one serialized writer.
type jsonTransport interface {
	ReadJSON(any) error
	WriteJSON(any) error
	SetReadDeadline(time.Time) error
	SetWriteDeadline(time.Time) error
	SetReadLimit(int64)
	Close() error
}

type directTransport struct{ *websocket.Conn }

func dialProtocolTransport(ctx context.Context, o Options) (jsonTransport, string, error) {
	if o.PairingLink != "" {
		if o.URL != "" {
			return nil, "", fail("ambiguous_transport", true)
		}
		offer, err := ParseRelayOffer(o.PairingLink)
		if err != nil {
			return nil, "", err
		}
		if o.ExpectedServerID != "" && o.ExpectedServerID != offer.ServerID {
			return nil, "", fail("relay_offer_identity_mismatch", true)
		}
		transport, err := connectRelay(ctx, offer)
		return transport, offer.ServerID, err
	}
	ws, err := dialWebSocket(ctx, o.URL)
	if err != nil {
		return nil, "", err
	}
	return &directTransport{ws}, o.ExpectedServerID, nil
}

func dialWebSocket(ctx context.Context, endpoint string) (*websocket.Conn, error) {
	// No password headers, bearer subprotocols or pairing offer cross this boundary.
	dial := websocket.Dialer{HandshakeTimeout: 10 * time.Second, Proxy: http.ProxyFromEnvironment}
	ws, response, err := dial.DialContext(ctx, endpoint, nil)
	if err != nil {
		if response != nil && response.Body != nil {
			_ = response.Body.Close()
		}
		if response != nil && (response.StatusCode == 401 || response.StatusCode == 403) {
			return nil, fail("authentication_or_host_rejected", true)
		}
		return nil, fail("connect_failed", false)
	}
	return ws, nil
}

func transportError(err error, fallback string) error {
	var safe *Failure
	if errors.As(err, &safe) {
		return safe
	}
	return fail(fallback, false)
}
