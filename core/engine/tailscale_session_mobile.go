//go:build mobile_no_tailscale

package engine

import (
	"context"
	"errors"

	"github.com/kafeifei/xdial/core/config"
)

var errTailscaleUnavailable = errors.New("当前构建不支持 Tailscale")

// TailscaleSession 保留 Engine 的桌面接口形状，但移动构建始终拒绝启动。
type TailscaleSession struct{}

func NewTailscaleSession(_ string, _ *config.Line, _ func(string), _ func([]TailscaleExitNode)) (*TailscaleSession, error) {
	return nil, errTailscaleUnavailable
}

func (s *TailscaleSession) LineID() string {
	return ""
}

func (s *TailscaleSession) ExitNodes(context.Context) ([]TailscaleExitNode, error) {
	return nil, errTailscaleUnavailable
}

func (s *TailscaleSession) Close() error {
	return nil
}
