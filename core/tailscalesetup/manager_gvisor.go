//go:build darwin && with_gvisor

package tailscalesetup

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/kafeifei/xdial/core/engine"
	"github.com/kafeifei/xdial/core/libbox"
)

const (
	defaultIdleTimeout    = 2 * time.Minute
	defaultStartupTimeout = 12 * time.Second
	defaultStatusInterval = 100 * time.Millisecond
)

// Manager owns the explicit, bounded Tailscale configuration session defined by D33.
// It never creates a TUN or changes system DNS/routes; the only persisted state is the
// Tailscale identity written by the upstream endpoint into basePath/tailscale.
type Manager struct {
	operationMu sync.Mutex
	basePath    string
	idleTimeout time.Duration

	runtime     *libbox.Libbox
	lineID      string
	endpointTag string
	idleTimer   *time.Timer
	timerGen    uint64
}

func New(basePath string) *Manager {
	return &Manager{
		basePath:    basePath,
		idleTimeout: defaultIdleTimeout,
	}
}

// Prepare replaces any previous setup session and returns the current structured
// LocalAPI status. authKey is used only while building this in-memory setup config.
func (m *Manager) Prepare(profileJSON, lineID, authKey string) (string, error) {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()

	lineID = strings.TrimSpace(lineID)
	configJSON, err := libbox.GenerateTailscaleSetupConfigWithAuthKey(
		profileJSON,
		lineID,
		m.basePath,
		authKey,
	)
	if err != nil {
		return "", err
	}
	interfaceName, err := engine.DetectUnderlayInterface(context.Background())
	if err != nil {
		return "", err
	}
	networkInterface, err := net.InterfaceByName(interfaceName)
	if err != nil {
		return "", fmt.Errorf("系统默认接口 %q 已消失: %w", interfaceName, err)
	}

	if err := m.stopLocked(); err != nil {
		return "", err
	}

	runtime := libbox.New(nil)
	runtime.SetDefaultInterface(interfaceName, networkInterface.Index)
	if err := runtime.StartStandalone(configJSON); err != nil {
		return "", fmt.Errorf("Tailscale setup could not start: %w", err)
	}

	endpointTag := "tailscale-" + lineID
	status, err := waitForSettledStatus(
		func() (string, error) {
			return runtime.TailscaleStatus(endpointTag)
		},
		defaultStartupTimeout,
		defaultStatusInterval,
	)
	if err != nil {
		_ = runtime.Stop()
		return "", err
	}
	m.runtime = runtime
	m.lineID = lineID
	m.endpointTag = endpointTag
	m.touchLocked()
	return status, nil
}

func (m *Manager) Status(lineID string) (string, error) {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()

	runtime, err := m.runtimeForLineLocked(lineID)
	if err != nil {
		return "", err
	}
	status, err := runtime.TailscaleStatus(m.endpointTag)
	if err == nil {
		m.touchLocked()
	}
	return status, err
}

func (m *Manager) BeginLogin(lineID string) (string, error) {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()

	runtime, err := m.runtimeForLineLocked(lineID)
	if err != nil {
		return "", err
	}
	status, err := runtime.BeginTailscaleLogin(m.endpointTag)
	if err == nil {
		m.touchLocked()
	}
	return status, err
}

func (m *Manager) Logout(lineID string) (string, error) {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()

	runtime, err := m.runtimeForLineLocked(lineID)
	if err != nil {
		return "", err
	}
	if err := runtime.TailscaleLogout(m.endpointTag); err != nil {
		return "", err
	}
	status, err := runtime.TailscaleStatus(m.endpointTag)
	if err == nil {
		m.touchLocked()
	}
	return status, err
}

func (m *Manager) Stop() error {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()
	return m.stopLocked()
}

// StopLine closes the setup session only when it still belongs to the requesting UI
// card. A stale card collapsing must not tear down a newer card's session.
func (m *Manager) StopLine(lineID string) error {
	m.operationMu.Lock()
	defer m.operationMu.Unlock()
	if m.runtime == nil || strings.TrimSpace(lineID) != m.lineID {
		return nil
	}
	return m.stopLocked()
}

func (m *Manager) runtimeForLineLocked(lineID string) (*libbox.Libbox, error) {
	if m.runtime == nil || strings.TrimSpace(lineID) != m.lineID {
		return nil, fmt.Errorf("Tailscale setup session is unavailable")
	}
	return m.runtime, nil
}

// tsnet 会在恢复持久身份时短暂经过 NoState / Starting / NeedsLogin。
// 只有恢复到 Running、取得真正的登录 URL，或进入其他终态后，状态才可交给 UI 和预检。
func waitForSettledStatus(
	readStatus func() (string, error),
	timeout time.Duration,
	interval time.Duration,
) (string, error) {
	deadline := time.Now().Add(timeout)
	var lastState string
	for {
		statusJSON, err := readStatus()
		if err != nil {
			return "", err
		}
		settled, state, err := tailscaleStatusSettled(statusJSON)
		if err != nil {
			return "", err
		}
		if settled {
			return statusJSON, nil
		}
		lastState = state
		if !time.Now().Before(deadline) {
			return "", fmt.Errorf("Tailscale startup did not settle (last state %s)", lastState)
		}
		time.Sleep(interval)
	}
}

func tailscaleStatusSettled(statusJSON string) (bool, string, error) {
	var status struct {
		BackendState string `json:"backend_state"`
		AuthURL      string `json:"auth_url"`
	}
	if err := json.Unmarshal([]byte(statusJSON), &status); err != nil {
		return false, "", fmt.Errorf("Tailscale status is invalid")
	}
	if strings.TrimSpace(status.AuthURL) != "" || status.BackendState == "Running" {
		return true, status.BackendState, nil
	}
	switch status.BackendState {
	case "NoState", "Starting", "NeedsLogin":
		return false, status.BackendState, nil
	default:
		return true, status.BackendState, nil
	}
}

func (m *Manager) touchLocked() {
	if m.idleTimer != nil {
		m.idleTimer.Stop()
	}
	m.timerGen++
	generation := m.timerGen
	m.idleTimer = time.AfterFunc(m.idleTimeout, func() {
		m.operationMu.Lock()
		defer m.operationMu.Unlock()
		if generation != m.timerGen {
			return
		}
		_ = m.stopLocked()
	})
}

func (m *Manager) stopLocked() error {
	m.timerGen++
	if m.idleTimer != nil {
		m.idleTimer.Stop()
		m.idleTimer = nil
	}
	runtime := m.runtime
	m.runtime = nil
	m.lineID = ""
	m.endpointTag = ""
	if runtime == nil {
		return nil
	}
	return runtime.Stop()
}
