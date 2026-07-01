package subscription

import (
	"os"
	"testing"
)

func TestParseRealSurge(t *testing.T) {
	data, err := os.ReadFile("/tmp/sub_test.txt")
	if err != nil {
		t.Skip("no test data at /tmp/sub_test.txt")
	}
	format := detect(string(data))
	t.Logf("detected format: %s", format)

	r, err := Parse("", string(data), "auto")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	t.Logf("parsed %d lines, %d groups, %d rules", len(r.Lines), len(r.ProxyGroups), len(r.Rules))
	for i, g := range r.ProxyGroups {
		if i > 5 {
			break
		}
		t.Logf("  group: %s [%s] %d members", g.Name, g.Type, len(g.Proxies))
	}
	for i, rule := range r.Rules {
		if i > 5 {
			break
		}
		t.Logf("  rule: %s %s -> %s", rule.Type, rule.Value, rule.Group)
	}
}
