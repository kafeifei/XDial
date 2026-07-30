package main

import (
	"strings"
	"testing"

	"github.com/kafeifei/xdial/core/config"
)

func TestValidateTailscalePreflightStatus(t *testing.T) {
	tests := []struct {
		name       string
		exitNode   string
		statusJSON string
		wantError  string
	}{
		{
			name:       "running without exit node",
			statusJSON: `{"backend_state":"Running","exit_nodes":[]}`,
		},
		{
			name:       "sign-in required",
			statusJSON: `{"backend_state":"NeedsLogin","exit_nodes":[]}`,
			wantError:  "sign-in is required",
		},
		{
			name:       "selected exit node online",
			exitNode:   "100.64.0.8",
			statusJSON: `{"backend_state":"Running","exit_nodes":[{"ip":"100.64.0.8","online":true}]}`,
		},
		{
			name:       "selected exit node offline",
			exitNode:   "100.64.0.8",
			statusJSON: `{"backend_state":"Running","exit_nodes":[{"ip":"100.64.0.8","online":false}]}`,
			wantError:  "offline",
		},
		{
			name:       "selected exit node disappeared",
			exitNode:   "100.64.0.8",
			statusJSON: `{"backend_state":"Running","exit_nodes":[{"ip":"100.64.0.9","online":true}]}`,
			wantError:  "unavailable",
		},
		{
			name:       "malformed status",
			statusJSON: `{`,
			wantError:  "invalid",
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			line := &config.Line{
				ID:                "tailnet",
				Type:              config.LineTypeTailscale,
				TailscaleExitNode: testCase.exitNode,
			}
			err := validateTailscalePreflightStatus(line, testCase.statusJSON)
			if testCase.wantError == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), testCase.wantError) {
				t.Fatalf("expected %q error, got %v", testCase.wantError, err)
			}
		})
	}
}
