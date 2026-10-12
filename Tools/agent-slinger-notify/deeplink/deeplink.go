// Package deeplink implements Agent Slinger's v1 session action contract.
package deeplink

import (
	"errors"
	"net/url"
	"strings"
	"unicode"
	"unicode/utf8"
)

type Target struct{ ServerID, WorkspaceID, AgentID, MessageID, PermissionID string }

func ValidID(id string) bool {
	if id == "" || strings.TrimSpace(id) == "" || !utf8.ValidString(id) || len(id) > 512 {
		return false
	}
	for _, r := range id {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}
func Build(t Target) (string, error) {
	if !ValidID(t.ServerID) || !ValidID(t.WorkspaceID) || !ValidID(t.AgentID) {
		return "", errors.New("invalid session target")
	}
	if t.MessageID != "" && t.PermissionID != "" {
		return "", errors.New("conflicting anchors")
	}
	q := url.Values{"v": {"1"}, "serverId": {t.ServerID}, "workspaceId": {t.WorkspaceID}, "agentId": {t.AgentID}}
	for k, v := range map[string]string{"messageId": t.MessageID, "permissionId": t.PermissionID} {
		if v != "" {
			if !ValidID(v) {
				return "", errors.New("invalid anchor")
			}
			q.Set(k, v)
		}
	}
	// URLComponents does not form-decode '+'; use RFC3986 spaces in the shared contract.
	u := url.URL{Scheme: "agentslinger", Host: "open", RawQuery: strings.ReplaceAll(q.Encode(), "+", "%20")}
	result := u.String()
	if len(result) > 512 {
		return "", errors.New("action URL exceeds 512 bytes; identifiers cannot be truncated")
	}
	return result, nil
}
