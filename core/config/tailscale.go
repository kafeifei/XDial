package config

import (
	"crypto/sha256"
	"fmt"
	"path/filepath"
)

func TailscaleStateDirectory(basePath, lineID string) string {
	stateID := sha256.Sum256([]byte(lineID))
	return filepath.Join(basePath, "tailscale", fmt.Sprintf("%x", stateID[:8]))
}

func buildTailscaleEndpoint(line *Line, basePath string) (map[string]interface{}, error) {
	if line == nil || line.Type != LineTypeTailscale {
		return nil, fmt.Errorf("line is not a Tailscale line")
	}
	if line.ID == "" {
		return nil, fmt.Errorf("Tailscale line ID is empty")
	}

	endpoint := map[string]interface{}{
		"type":            "tailscale",
		"tag":             tailscaleEndpointTag(line),
		"state_directory": TailscaleStateDirectory(basePath, line.ID),
		"accept_routes":   line.TailscaleAcceptRoutes,
	}
	if line.TailscaleHostname != "" {
		endpoint["hostname"] = line.TailscaleHostname
	}
	if line.TailscaleExitNode != "" {
		endpoint["exit_node"] = line.TailscaleExitNode
	}
	return endpoint, nil
}
