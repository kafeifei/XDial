//go:build darwin

package main

import "path/filepath"

const networkStateGroup = "UVZM439VGU.com.kafeifei.xdial.network"

// Network Extension system extensions run as root. A Team-ID-prefixed macOS
// App Group gives the root helper and the root system extension one protected
// container without requiring a registered App Group provisioning capability.
func networkExtensionStatePath(string) string {
	return filepath.Join(
		"/private/var/root/Library/Group Containers",
		networkStateGroup,
		"NetworkExtension",
	)
}
