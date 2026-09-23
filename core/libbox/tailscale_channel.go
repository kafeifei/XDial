package libbox

import "github.com/kafeifei/xdial/core/config"

// ProfileWithTailscaleChannel projects the local installation channel into a
// runtime snapshot; it never changes the shared configuration or node keys.
func ProfileWithTailscaleChannel(profileJSON, channel string) (string, error) {
	return config.ProfileWithTailscaleChannel(profileJSON, channel)
}
