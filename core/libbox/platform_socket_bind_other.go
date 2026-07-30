//go:build !darwin && !ios

package libbox

import "fmt"

func bindSocketToInterface(_ int, _ int) error {
	return fmt.Errorf("platform: Underlay socket binding is unavailable")
}
