//go:build darwin

package main

import "path/filepath"

// Network Extension system extensions run as root. A Team-ID-prefixed macOS
// App Group gives the root helper and the root system extension one protected
// container without requiring a registered App Group provisioning capability.
func networkExtensionStatePath(string) string {
	return networkExtensionStatePathForIdentity(currentRuntimeIdentity())
}

func networkExtensionStatePathForIdentity(identity runtimeIdentity) string {
	return filepath.Join(
		"/private/var/root/Library/Group Containers",
		identity.sharedAppGroup,
		"NetworkExtension",
	)
}
