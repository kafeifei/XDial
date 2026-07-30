//go:build !windows

package libbox

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/kafeifei/xdial/core/config"
	"github.com/sagernet/sing-box/common/srs"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestClassifyNERuleSetSourceAndBinary(t *testing.T) {
	tests := []struct {
		name   string
		source string
		want   config.RuleSetMatchKind
	}{
		{
			name:   "domain",
			source: `{"version":1,"rules":[{"domain_suffix":["example.com"]}]}`,
			want:   config.RuleSetMatchDomain,
		},
		{
			name:   "ip",
			source: `{"version":1,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}`,
			want:   config.RuleSetMatchIP,
		},
		{
			name:   "mixed",
			source: `{"version":1,"rules":[{"domain_suffix":["example.com"]},{"ip_cidr":["192.0.2.0/24"]}]}`,
			want:   config.RuleSetMatchMixed,
		},
		{
			name:   "domain with connection condition",
			source: `{"version":1,"rules":[{"domain_suffix":["example.com"],"port":[443]}]}`,
			want:   config.RuleSetMatchMixed,
		},
	}

	for _, test := range tests {
		t.Run(test.name+"/source", func(t *testing.T) {
			got, err := classifyNERuleSet([]byte(test.source), "source")
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("source classification: got %q, want %q", got, test.want)
			}
		})

		t.Run(test.name+"/binary", func(t *testing.T) {
			binary := encodeRuleSetBinary(t, []byte(test.source))
			got, err := classifyNERuleSet(binary, "binary")
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("binary classification: got %q, want %q", got, test.want)
			}
		})
	}
}

func encodeRuleSetBinary(t *testing.T, source []byte) []byte {
	t.Helper()
	var compat option.PlainRuleSetCompat
	if err := json.Unmarshal(source, &compat); err != nil {
		t.Fatal(err)
	}
	plain, err := compat.Upgrade()
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := srs.Write(&output, plain, C.RuleSetVersionCurrent); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}
