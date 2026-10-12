package deeplink

import (
	"net/url"
	"strings"
	"testing"
)

func TestOpaqueIdentifiers(t *testing.T) {
	target := Target{ServerID: "server /+%?#", WorkspaceID: "日本語 +/ %", AgentID: "agent +%2F/", PermissionID: "request /+"}
	got, err := Build(target)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(got, "+") || !strings.Contains(got, "%20") {
		t.Fatal(got)
	}
	u, _ := url.Parse(got)
	q := u.Query()
	for k, want := range map[string]string{"serverId": target.ServerID, "workspaceId": target.WorkspaceID, "agentId": target.AgentID, "permissionId": target.PermissionID} {
		if q.Get(k) != want {
			t.Fatalf("%s: %q != %q", k, q.Get(k), want)
		}
	}
	if q.Get("v") != "1" || u.Host != "open" || u.Scheme != "agentslinger" {
		t.Fatal(got)
	}
}
func TestRejectMalformedAndOversize(t *testing.T) {
	for _, target := range []Target{{ServerID: "s", WorkspaceID: "w"}, {ServerID: "s", WorkspaceID: "w", AgentID: "a\n"}, {ServerID: "s", WorkspaceID: "w", AgentID: "a", MessageID: "m", PermissionID: "p"}, {ServerID: "s", WorkspaceID: "w", AgentID: strings.Repeat("+", 200)}} {
		if _, err := Build(target); err == nil {
			t.Fatalf("accepted %+v", target)
		}
	}
}
