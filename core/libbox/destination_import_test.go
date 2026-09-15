//go:build !windows

package libbox

import (
	"encoding/base64"
	"github.com/kafeifei/xdial/core/config"
	"strings"
	"testing"
)

func TestClashAndSurgeCategorySelectorsImportAsScenarioBindings(t *testing.T) {
	inputs := []string{
		`[Proxy]
A = anytls, 192.0.2.1, 443, password=fixture
B = anytls, 192.0.2.2, 443, password=fixture
[Proxy Group]
Proxies = select, A, B
Local = select, DIRECT, Proxies
AI = select, Proxies, Local, A, B
Netflix = select, Proxies, Local, A, B
Apple = select, Local, Proxies, A, B
Final = select, Proxies, Local, A, B
[Rule]
DOMAIN,ai.example,AI
DOMAIN,video.example,Netflix
IP-CIDR,192.0.2.0/24,AI,no-resolve
DOMAIN,apple.example,Apple
FINAL,Final
`,
		`proxies:
  - {name: A, type: anytls, server: 192.0.2.1, port: 443, password: fixture}
  - {name: B, type: anytls, server: 192.0.2.2, port: 443, password: fixture}
proxy-groups:
  - {name: Proxies, type: select, proxies: [A, B]}
  - {name: Local, type: select, proxies: [DIRECT, Proxies]}
  - {name: AI, type: select, proxies: [Proxies, Local, A, B]}
  - {name: Netflix, type: select, proxies: [Proxies, Local, A, B]}
  - {name: Apple, type: select, proxies: [Local, Proxies, A, B]}
  - {name: Final, type: select, proxies: [Proxies, Local, A, B]}
rules:
  - DOMAIN,ai.example,AI
  - DOMAIN,video.example,Netflix
  - IP-CIDR,192.0.2.0/24,AI,no-resolve
  - DOMAIN,apple.example,Apple
  - MATCH,Final
`,
	}
	for _, input := range inputs {
		raw, err := ImportProfile(input, "auto", "source", false)
		if err != nil {
			t.Fatal(err)
		}
		p, err := config.ParseProfile([]byte(raw))
		if err != nil {
			t.Fatal(err)
		}
		if len(p.Lines) != 4 || len(p.RuleSets) != 3 || len(p.Scenarios[0].MatchOrder) != 4 {
			t.Fatal("categories, group count or order incorrect")
		}
		var names []string
		for _, rule := range p.RuleSets {
			names = append(names, rule.Name)
		}
		if strings.Join(names, ",") != "AI,Netflix,Apple" {
			t.Fatal("rules grouped by resolved exit instead of source category")
		}
		for i, binding := range p.Scenarios[0].Bindings {
			name := p.FindLine(binding.LineID).Name
			if (i < 2 && name != "Proxies") || (i == 2 && binding.LineID != "direct") {
				t.Fatal("wrong Scenario exit", i, name)
			}
		}
		copyRaw, err := ReimportProfileScenario(raw, p.Scenarios[0].ID, "new-import")
		if err != nil {
			t.Fatal(err)
		}
		copy, _ := config.ParseProfile([]byte(copyRaw))
		if len(copy.Lines) != 4 || len(copy.RuleSets) != 3 {
			t.Fatal("saved reimport changed grouping")
		}
		// A source refresh keeps the identities of existing business rules.
		updatedRaw, err := ImportProfile(strings.Replace(input, "ai.example", "new-ai.example", 1), "auto", "source", false)
		if err != nil {
			t.Fatal(err)
		}
		updated, _ := config.ParseProfile([]byte(updatedRaw))
		if updated.RuleSets[0].ID != p.RuleSets[0].ID {
			t.Fatal("content update changed rule identity")
		}
	}
}

func TestTraditionalFormatsUseSharedGroupsAndDefaultScenario(t *testing.T) {
	cases := map[string]string{
		"Clash": `proxies:
  - {name: Edge, type: anytls, server: 192.0.2.1, port: 443, password: fixture, sni: edge.example}
proxy-groups:
  - {name: Proxy, type: select, proxies: [Edge, DIRECT]}
rules:
  - DOMAIN,push.example,Proxy
  - DOMAIN-SUFFIX,example,DIRECT
  - PROCESS-NAME,Example,Proxy
  - IP-CIDR,192.0.2.0/24,Proxy,no-resolve
  - MATCH,DIRECT
`,
		"Surge": `[Proxy]
Edge = anytls, 192.0.2.1, 443, password=fixture, sni=edge.example
[Proxy Group]
Proxy = select, Edge, DIRECT
[Rule]
DOMAIN,push.example,Proxy
DOMAIN-SUFFIX,example,DIRECT
PROCESS-NAME,Example,Proxy
IP-CIDR,192.0.2.0/24,Proxy,no-resolve
FINAL,DIRECT
`,
		"Shadowrocket": base64.StdEncoding.EncodeToString([]byte("anytls://fixture@192.0.2.1:443?sni=edge.example#Edge")),
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			raw, err := ImportProfile(input, "auto", "fixture", false)
			if err != nil {
				t.Fatal(err)
			}
			p, err := config.ParseProfile([]byte(raw))
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Scenarios) != 1 {
				t.Fatal("default Scenario missing")
			}
			groups := 0
			for _, line := range p.Lines {
				if line.IsGroup() {
					groups++
				}
			}
			if groups != 1 {
				t.Fatal("selection group missing")
			}
			if name == "Shadowrocket" {
				if len(p.RuleSets) != 0 {
					t.Fatal("node list invented routing rules")
				}
			} else {
				if len(p.RuleSets) != 2 || p.RuleSets[0].Name != "Proxy" || len(p.RuleSets[0].Conditions) != 3 || len(p.Scenarios[0].MatchOrder) != 4 {
					t.Fatal("destination grouping lost source semantics")
				}
				flat, err := config.ExpandRuleSetGroups(p)
				if err != nil || !flat.FindRuleSet(flat.Scenarios[0].Bindings[3].RuleSetID).NoResolve {
					t.Fatal("DNS option or ordering lost", err)
				}
			}
			exported, err := ExportProfile(raw)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = ImportProfile(exported, "auto", "copy", false); err != nil {
				t.Fatal("redacted roundtrip failed", err)
			}
		})
	}
}
