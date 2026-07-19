package rpc

import (
	"fmt"
	"net"
	"net/url"
	"strings"

	"sslcon/auth"
	"sslcon/session"
	"sslcon/utils/vpnc"
	"sslcon/vpn"
)

// Connect 调用之前必须由前端填充 auth.Prof，建议填充 base.Interface
func Connect() error {
	if err := configureConnectionProfile(auth.Prof); err != nil {
		return err
	}
	if !auth.Prof.Initialized {
		err := vpnc.GetLocalInterface()
		if err != nil {
			return err
		}
	}
	err := auth.InitAuth()
	if err != nil {
		return err
	}
	err = auth.PasswordAuth()
	if err != nil {
		return err
	}

	return SetupTunnel(false)
}

func configureConnectionProfile(profile *auth.Profile) error {
	hostWithPort, serverName, err := connectionIdentity(profile.Host)
	if err != nil {
		return err
	}
	profile.HostWithPort = hostWithPort
	profile.TLSServerName = serverName
	profile.DialHostWithPort = hostWithPort
	if profile.DialAddress != "" {
		if ip := net.ParseIP(profile.DialAddress); ip == nil || ip.To4() == nil {
			return fmt.Errorf("dial address is not IPv4")
		}
		_, port, splitErr := net.SplitHostPort(hostWithPort)
		if splitErr != nil {
			return fmt.Errorf("invalid server endpoint")
		}
		profile.DialHostWithPort = net.JoinHostPort(profile.DialAddress, port)
	}
	return nil
}

func connectionIdentity(server string) (hostWithPort, serverName string, err error) {
	raw := strings.TrimSpace(server)
	if raw == "" {
		return "", "", fmt.Errorf("server endpoint is empty")
	}

	if strings.Contains(raw, "://") {
		parsed, parseErr := url.Parse(raw)
		if parseErr != nil || parsed.Hostname() == "" {
			return "", "", fmt.Errorf("invalid server endpoint")
		}
		port := parsed.Port()
		if port == "" {
			port = "443"
		}
		return net.JoinHostPort(parsed.Hostname(), port), parsed.Hostname(), nil
	}

	if host, port, splitErr := net.SplitHostPort(raw); splitErr == nil {
		host = strings.Trim(host, "[]")
		if host == "" || port == "" {
			return "", "", fmt.Errorf("invalid server endpoint")
		}
		return net.JoinHostPort(host, port), host, nil
	}

	trimmed := strings.Trim(raw, "[]")
	if net.ParseIP(trimmed) != nil {
		return net.JoinHostPort(trimmed, "443"), trimmed, nil
	}
	if strings.ContainsAny(raw, "/?#:") {
		return "", "", fmt.Errorf("invalid server endpoint")
	}
	return net.JoinHostPort(raw, "443"), raw, nil
}

// SetupTunnel 操作系统长时间睡眠后再自动连接会失败，仅用于短时间断线自动重连
func SetupTunnel(reconnect bool) error {
	// 为适应复杂网络环境，必须能够感知网卡变化，建议由前端获取当前网络信息发送过来，而不是登陆前由 Go 处理
	// 断网重连时网卡信息可能已经变化，所以建立隧道时重新获取网卡信息
	if reconnect && !auth.Prof.Initialized {
		err := vpnc.GetLocalInterface()
		if err != nil {
			return err
		}
	}
	return vpn.SetupTunnel()
}

// DisConnect 主动断开或者 ctrl+c，不包括网络或tun异常退出
func DisConnect() {
	session.Sess.ActiveClose = true
	if session.Sess.CSess != nil {
		vpnc.ResetRoutes(session.Sess.CSess) // 蛋疼的循环引用
		session.Sess.CSess.Close()
	}
}
