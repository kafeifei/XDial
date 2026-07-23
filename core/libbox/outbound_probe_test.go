//go:build !windows

package libbox

import "testing"

func TestParsePublicProbeAddress(t *testing.T) {
	address, err := parsePublicProbeAddress("fl=123\nip=8.8.8.8\nts=1\n")
	if err != nil {
		t.Fatal(err)
	}
	if address != "8.8.8.8" {
		t.Fatalf("address = %q", address)
	}
}

func TestParsePublicProbeAddressRejectsPrivateAndMissingValues(t *testing.T) {
	for _, body := range []string{"ip=192.168.1.10\n", "ip=not-an-address\n", "fl=123\n"} {
		if _, err := parsePublicProbeAddress(body); err == nil {
			t.Fatalf("accepted invalid probe response %q", body)
		}
	}
}
