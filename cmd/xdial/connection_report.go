package main

import (
	"fmt"
	"os"
	"path/filepath"
)

const providerReportHome = "/var/root"

func readProviderConnectionReport() ([]byte, error) {
	if os.Geteuid() != 0 {
		return nil, fmt.Errorf("provider report requires root helper")
	}
	return readProviderConnectionReportAt(providerReportHome)
}

func readProviderConnectionReportAt(home string) ([]byte, error) {
	return readProviderConnectionReportForIdentity(home, currentRuntimeIdentity())
}

func readProviderConnectionReportForIdentity(home string, identity runtimeIdentity) ([]byte, error) {
	path := filepath.Join(
		home,
		"Library",
		"Group Containers",
		identity.sharedAppGroup,
		"Transactions",
		"connection-report.json",
	)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("provider report unavailable: %w", err)
	}
	return data, nil
}
