package engine

import (
	"fmt"
	"sync"

	"sslcon/auth"
	"sslcon/base"
	"sslcon/rpc"
	"sslcon/session"
)

type VPNConfig struct {
	Server   string
	Username string
	Password string
}

type VPNInfo struct {
	VPNAddress string
	VPNMask    string
	DNS        []string
	MTU        int
	ServerAddr string
}

type VPNClient struct {
	mu   sync.Mutex
	info *VPNInfo
}

func NewVPNClient() *VPNClient {
	return &VPNClient{}
}

func (c *VPNClient) Connect(cfg VPNConfig) (*VPNInfo, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	base.Cfg.NoTUN = true
	base.Cfg.InsecureSkipVerify = true
	base.Cfg.CiscoCompat = true
	base.Cfg.LogLevel = "Info"
	base.InitLog()

	auth.Prof.Host = cfg.Server
	auth.Prof.Username = cfg.Username
	auth.Prof.Password = cfg.Password

	if err := rpc.Connect(); err != nil {
		return nil, fmt.Errorf("vpn connect: %w", err)
	}

	cSess := session.Sess.CSess
	if cSess == nil {
		return nil, fmt.Errorf("no session after connect")
	}

	c.info = &VPNInfo{
		VPNAddress: cSess.VPNAddress,
		VPNMask:    cSess.VPNMask,
		DNS:        cSess.DNS,
		MTU:        cSess.MTU,
		ServerAddr: cSess.ServerAddress,
	}

	return c.info, nil
}

func (c *VPNClient) Session() *session.ConnSession {
	return session.Sess.CSess
}

func (c *VPNClient) Disconnect() {
	c.mu.Lock()
	defer c.mu.Unlock()
	session.Sess.ActiveClose = true
	if cSess := session.Sess.CSess; cSess != nil {
		cSess.Close()
	}
	c.info = nil
}
