package config

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
)

// TailscaleHostnameForChannel names a local runtime without changing its state
// path, keys, or the shared Profile. Applying it repeatedly is idempotent.
func TailscaleHostnameForChannel(hostname, profileID, channel string) string {
	switch channel {
	case "debug", "next":
	default:
		channel = "stable"
	}
	base := strings.ToLower(strings.TrimSpace(hostname))
	for _, prefix := range []string{"xdial-debug-", "xdial-next-", "xdial-stable-", "xdial-"} {
		if strings.HasPrefix(base, prefix) {
			base = strings.TrimPrefix(base, prefix)
			break
		}
	}
	if base == "" {
		base = profileID
	}
	var builder strings.Builder
	for _, r := range base {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			builder.WriteRune(r)
		} else {
			builder.WriteByte('-')
		}
	}
	clean := strings.Trim(builder.String(), "-")
	// 49 bytes leaves room for the longest channel prefix, xdial-stable-.
	if clean == "" || clean != base || len(clean) > 49 {
		digest := sha256.Sum256([]byte(base))
		if len(clean) > 40 {
			clean = strings.TrimRight(clean[:40], "-")
		}
		if clean == "" {
			clean = "device"
		}
		clean += "-" + hex.EncodeToString(digest[:4])
	}
	return "xdial-" + channel + "-" + clean
}

func TailscaleIdentityProfileID(profile *Profile, line *Line) string {
	if line != nil && line.IdentityProfileID != "" {
		return line.IdentityProfileID
	}
	return profile.ID
}

// ProfileWithTailscaleChannel retains unknown JSON fields and never persists
// this projection. Both setup and data-plane compilation consume the same names.
func ProfileWithTailscaleChannel(raw, channel string) (string, error) {
	var document map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &document); err != nil {
		return "", err
	}
	if document == nil {
		return "", fmt.Errorf("invalid Tailscale profile")
	}
	var profile Profile
	if err := json.Unmarshal([]byte(raw), &profile); err != nil {
		return "", err
	}
	identity := map[string]json.RawMessage{}
	if data := document["tailscale"]; len(data) > 0 && string(data) != "null" {
		if err := json.Unmarshal(data, &identity); err != nil {
			return "", err
		}
	}
	identity["hostname"], _ = json.Marshal(TailscaleHostnameForChannel(profile.Tailscale.Hostname, profile.ID, channel))
	document["tailscale"], _ = json.Marshal(identity)
	var lines []map[string]json.RawMessage
	if err := json.Unmarshal(document["lines"], &lines); err != nil {
		return "", err
	}
	for i, line := range profile.Lines {
		if line.Type != LineTypeTailscale {
			continue
		}
		hostname := line.IdentityHostname
		if hostname == "" {
			hostname = profile.Tailscale.Hostname
		}
		lines[i]["identity_hostname"], _ = json.Marshal(TailscaleHostnameForChannel(hostname, TailscaleIdentityProfileID(&profile, &line), channel))
	}
	document["lines"], _ = json.Marshal(lines)
	data, err := json.Marshal(document)
	return string(data), err
}
