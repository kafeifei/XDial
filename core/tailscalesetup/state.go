package tailscalesetup

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const migrationMarker = ".xdial-tailscale-state-v1"

// PreparePersistentState moves the legacy helper-owned Tailscale identity into
// the Network Extension's shared root App Group exactly once. The setup runtime
// and the full data plane then use the same state directory; no node key is
// copied through Profile, start options, logs, or the GUI process.
func PreparePersistentState(legacyBasePath, activeBasePath string) error {
	legacyBasePath = filepath.Clean(legacyBasePath)
	activeBasePath = filepath.Clean(activeBasePath)
	if !filepath.IsAbs(legacyBasePath) || !filepath.IsAbs(activeBasePath) {
		return fmt.Errorf("Tailscale state directories must be absolute")
	}
	if legacyBasePath == activeBasePath {
		return os.MkdirAll(activeBasePath, 0o700)
	}
	if err := os.MkdirAll(activeBasePath, 0o700); err != nil {
		return fmt.Errorf("create Tailscale state container: %w", err)
	}
	if err := os.Chmod(activeBasePath, 0o700); err != nil {
		return fmt.Errorf("protect Tailscale state container: %w", err)
	}

	markerPath := filepath.Join(activeBasePath, migrationMarker)
	if _, err := os.Stat(markerPath); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect Tailscale migration marker: %w", err)
	}

	legacyState := filepath.Join(legacyBasePath, "tailscale")
	activeState := filepath.Join(activeBasePath, "tailscale")
	legacyInfo, err := os.Lstat(legacyState)
	if errors.Is(err, os.ErrNotExist) {
		if _, activeErr := os.Lstat(activeState); activeErr == nil {
			return writeMigrationMarker(markerPath)
		} else if !errors.Is(activeErr, os.ErrNotExist) {
			return fmt.Errorf("inspect active Tailscale state: %w", activeErr)
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect legacy Tailscale state: %w", err)
	}
	if !legacyInfo.IsDir() || legacyInfo.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("legacy Tailscale state is not a directory")
	}

	var backupPath string
	if activeInfo, activeErr := os.Lstat(activeState); activeErr == nil {
		if !activeInfo.IsDir() || activeInfo.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("active Tailscale state is not a directory")
		}
		backupPath, err = availableBackupPath(activeBasePath)
		if err != nil {
			return err
		}
		if err := os.Rename(activeState, backupPath); err != nil {
			return fmt.Errorf("preserve pre-migration Tailscale state: %w", err)
		}
	} else if !errors.Is(activeErr, os.ErrNotExist) {
		return fmt.Errorf("inspect active Tailscale state: %w", activeErr)
	}

	if err := os.Rename(legacyState, activeState); err != nil {
		if backupPath != "" {
			_ = os.Rename(backupPath, activeState)
		}
		return fmt.Errorf("move Tailscale identity into shared container: %w", err)
	}
	if err := writeMigrationMarker(markerPath); err != nil {
		return err
	}
	return nil
}

func availableBackupPath(basePath string) (string, error) {
	for index := 0; index < 100; index++ {
		name := "tailscale.pre-migration"
		if index > 0 {
			name = fmt.Sprintf("%s.%d", name, index)
		}
		candidate := filepath.Join(basePath, name)
		if _, err := os.Lstat(candidate); errors.Is(err, os.ErrNotExist) {
			return candidate, nil
		} else if err != nil {
			return "", fmt.Errorf("inspect Tailscale migration backup: %w", err)
		}
	}
	return "", fmt.Errorf("too many Tailscale migration backups")
}

func writeMigrationMarker(path string) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".tailscale-marker-*")
	if err != nil {
		return fmt.Errorf("create Tailscale migration marker: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("protect Tailscale migration marker: %w", err)
	}
	if _, err := temporary.WriteString("v1\n"); err != nil {
		temporary.Close()
		return fmt.Errorf("write Tailscale migration marker: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close Tailscale migration marker: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("install Tailscale migration marker: %w", err)
	}
	return nil
}
