//go:build !darwin || !with_gvisor

package tailscalesetup

import "fmt"

type Manager struct{}

func New(string) *Manager {
	return &Manager{}
}

func unavailable() error {
	return fmt.Errorf("Tailscale setup is unavailable in this build")
}

func (m *Manager) Prepare(string, string, string) (string, error) {
	return "", unavailable()
}

func (m *Manager) Status(string) (string, error) {
	return "", unavailable()
}

func (m *Manager) BeginLogin(string) (string, error) {
	return "", unavailable()
}

func (m *Manager) Logout(string) (string, error) {
	return "", unavailable()
}

func (m *Manager) Stop() error {
	return nil
}

func (m *Manager) StopLine(string) error {
	return nil
}
