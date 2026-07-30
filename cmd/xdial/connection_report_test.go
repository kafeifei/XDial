package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadProviderConnectionReportAt(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(
		home,
		"Library",
		"Group Containers",
		connectionReportGroup,
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

	got, err := readProviderConnectionReportAt(home)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}
