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

func NewTailscaleSession(_ string, _ config.TailscaleIdentity, _ string, _ func(string), _ func(TailscaleStatus)) (*TailscaleSession, error) {
	return nil, errTailscaleUnavailable
}

func (s *TailscaleSession) LineID() string {
	return ""
}

func (s *TailscaleSession) Status(context.Context) (TailscaleStatus, error) {
	return TailscaleStatus{}, errTailscaleUnavailable
}

func (s *TailscaleSession) Close() error {
	return nil
}
