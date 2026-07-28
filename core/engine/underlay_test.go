package engine

import "testing"

func TestParseDefaultRouteInterface(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		output string
		want   string
	}{
		{
			name: "physical",
			output: `   route to: default
destination: default
  interface: en0
      flags: <UP,DONE,CLONING,STATIC,PRCLONING>
`,
			want: "en0",
		},
		{
			name: "virtual_without_gateway",
			output: `   route to: default
destination: default
  interface: utun13
      flags: <UP,DONE,STATIC>
`,
			want: "utun13",
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseDefaultRouteInterface(test.output)
			if err != nil {
				t.Fatalf("parseDefaultRouteInterface: %v", err)
			}
			if got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
}

func TestParseDefaultRouteInterfaceRejectsMissingOrInvalid(t *testing.T) {
	t.Parallel()

	for _, output := range []string{
		"route to: default\n",
		"interface:\n",
		"interface: utun13 extra\n",
	} {
		if got, err := parseDefaultRouteInterface(output); err == nil {
			t.Fatalf("accepted %q as %q", output, got)
		}
	}
}
