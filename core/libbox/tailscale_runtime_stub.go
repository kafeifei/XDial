//go:build !windows && (!with_gvisor || mobile_no_tailscale)

package libbox

import (
	"context"
	"fmt"
)

func createTailscaleRuntimeCapability(
	context.Context,
	*tailscaleRuntimeSpec,
	*xdPlatformInterface,
) (pooledTailscaleRuntime, error) {
	return nil, fmt.Errorf("Tailscale is unavailable in this build")
}
