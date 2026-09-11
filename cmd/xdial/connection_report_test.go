package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadProviderConnectionReportAt(t *testing.T) {
	for _, flavor := range []string{"", "debug"} {
		t.Run(flavor, func(t *testing.T) {
			identity := runtimeIdentityForFlavor(flavor)
			home := t.TempDir()
			path := filepath.Join(
				home,
				"Library",
				"Group Containers",
				identity.sharedAppGroup,
				"Transactions",
				"connection-report.json",
			)
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			want := []byte(`{"transaction_id":"test"}`)
			if err := os.WriteFile(path, want, 0o600); err != nil {
				t.Fatal(err)
			}

			got, err := readProviderConnectionReportForIdentity(home, identity)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != string(want) {
				t.Fatalf("got %q, want %q", got, want)
			}
		})
	}
}
