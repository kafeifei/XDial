package rpc

import (
	"testing"

	"sslcon/auth"
)

func TestConnectionIdentity(t *testing.T) {
	tests := []struct {
		name         string
		server       string
		hostWithPort string
		serverName   string
	}{
		{"hostname", "gateway.example.com", "gateway.example.com:443", "gateway.example.com"},
		{"custom port", "gateway.example.com:8443", "gateway.example.com:8443", "gateway.example.com"},
		{"URL", "https://gateway.example.com:9443/path", "gateway.example.com:9443", "gateway.example.com"},
		{"IPv4", "198.51.100.8", "198.51.100.8:443", "198.51.100.8"},
		{"IPv6", "[2001:db8::8]:443", "[2001:db8::8]:443", "2001:db8::8"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			hostWithPort, serverName, err := connectionIdentity(tt.server)
			if err != nil {
				t.Fatalf("connectionIdentity: %v", err)
			}
			if hostWithPort != tt.hostWithPort || serverName != tt.serverName {
				t.Fatalf("got (%q, %q), want (%q, %q)", hostWithPort, serverName, tt.hostWithPort, tt.serverName)
			}
		})
	}
}

func TestConnectionIdentityRejectsMalformedEndpoint(t *testing.T) {
	for _, server := range []string{"", "gateway.example.com/path", "gateway.example.com:"} {
		if _, _, err := connectionIdentity(server); err == nil {
			t.Fatalf("connectionIdentity(%q) unexpectedly succeeded", server)
		}
	}
}

func TestConfigureConnectionProfileSeparatesDialTargetFromTLSIdentity(t *testing.T) {
	profile := &auth.Profile{
		Host:        "gateway.example.com:8443",
		DialAddress: "203.0.113.12",
	}
	if err := configureConnectionProfile(profile); err != nil {
		t.Fatalf("configureConnectionProfile: %v", err)
	}
	if profile.HostWithPort != "gateway.example.com:8443" {
		t.Fatalf("HostWithPort = %q", profile.HostWithPort)
	}
	if profile.DialHostWithPort != "203.0.113.12:8443" {
		t.Fatalf("DialHostWithPort = %q", profile.DialHostWithPort)
	}
	if profile.TLSServerName != "gateway.example.com" {
		t.Fatalf("TLSServerName = %q", profile.TLSServerName)
	}
}

func TestConfigureConnectionProfileRejectsNonNumericDialTarget(t *testing.T) {
	profile := &auth.Profile{
		Host:        "gateway.example.com",
		DialAddress: "another.example.com",
	}
	if err := configureConnectionProfile(profile); err == nil {
		t.Fatal("expected non-numeric dial address to fail")
	}
}
