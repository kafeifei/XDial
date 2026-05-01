package config

import (
	"encoding/json"
	"testing"
)

func TestGenerateSingBox(t *testing.T) {
	profile := NewDefaultProfile()

	vpn := profile.FindLine(LineIDCompanyVPN)
	vpn.VPNServer = "vpn.example.com"
	vpn.VPNUsername = "user"

	company := profile.FindDiverter(DiverterIDCompany)
	company.Domains = []string{"example.com", "internal.corp"}

	profile.ActivePresetID = PresetIDOverseas

	data, err := GenerateSingBox(profile, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	if len(cfg.Outbounds) < 2 {
		t.Fatal("expected at least 2 outbounds")
	}
	if cfg.Outbounds[0]["tag"] != "direct" {
		t.Errorf("first outbound should be direct, got %v", cfg.Outbounds[0]["tag"])
	}
	if cfg.Outbounds[1]["tag"] != "vpn" {
		t.Errorf("second outbound should be vpn, got %v", cfg.Outbounds[1]["tag"])
	}
	socksPort := cfg.Outbounds[1]["server_port"]
	if socksPort != float64(10800) {
		t.Errorf("socks port should be 10800, got %v", socksPort)
	}

	tun := cfg.Inbounds[0]
	excludeAddrs, ok := tun["route_exclude_address"]
	if !ok {
		t.Fatal("TUN inbound missing route_exclude_address")
	}
	addrs, ok := excludeAddrs.([]interface{})
	if !ok || len(addrs) == 0 {
		t.Fatal("route_exclude_address should be non-empty array")
	}
	if addrs[0] != "1.2.3.4/32" {
		t.Errorf("expected VPN server IP in exclude list, got %v", addrs[0])
	}

	t.Log(string(data))
}

func TestGenerateDomesticAirport(t *testing.T) {
	profile := NewDefaultProfile()

	vpn := profile.FindLine(LineIDCompanyVPN)
	vpn.VPNServer = "vpn.example.com"

	company := profile.FindDiverter(DiverterIDCompany)
	company.Domains = []string{"example.com"}

	airport := profile.FindLine(LineIDAirport)
	airport.Enabled = true
	airport.Type = LineTypeTrojan
	airport.TrojanServer = "proxy.airport.com"
	airport.TrojanPort = 443
	airport.TrojanPassword = "pass123"
	airport.TrojanSNI = "proxy.airport.com"

	profile.ActivePresetID = PresetIDDomesticAirport

	data, err := GenerateSingBox(profile, 10800, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}

	var cfg SingBoxConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}

	if len(cfg.Outbounds) < 3 {
		t.Fatalf("expected 3+ outbounds for domestic+airport, got %d", len(cfg.Outbounds))
	}

	t.Log(string(data))
}
