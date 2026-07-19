//go:build !darwin && !windows

package libbox

// Other Unix implementations can still obtain the interface name from the
// created tun.Tun. Returning an empty name selects that fallback path.
func tunnelNameFromFileDescriptor(_ int) (string, error) {
	return "", nil
}
