package subscription

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/kafeifei/xdial/core/config"
)

func parseBase64(content string) ([]config.Port, error) {
	decoded := tryBase64Decode(strings.TrimSpace(content))
	lines := strings.Split(decoded, "\n")

	var ports []config.Port
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		port, ok := uriToPort(line)
		if ok {
			ports = append(ports, port)
		}
	}
	if len(ports) == 0 {
		return nil, fmt.Errorf("no supported URIs found")
	}
	return ports, nil
}

func tryBase64Decode(s string) string {
	// try standard base64
	if decoded, err := base64.StdEncoding.DecodeString(s); err == nil {
		return string(decoded)
	}
	// try URL-safe base64
	if decoded, err := base64.URLEncoding.DecodeString(s); err == nil {
		return string(decoded)
	}
	// try without padding
	if decoded, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return string(decoded)
	}
	if decoded, err := base64.RawURLEncoding.DecodeString(s); err == nil {
		return string(decoded)
	}
	return s
}

func uriToPort(uri string) (config.Port, bool) {
	switch {
	case strings.HasPrefix(uri, "ss://"):
		return parseSS(uri)
	case strings.HasPrefix(uri, "vmess://"):
		return parseVMess(uri)
	case strings.HasPrefix(uri, "trojan://"):
		return parseTrojan(uri)
	default:
		return config.Port{}, false
	}
}

// ss://base64(method:password)@server:port#name
// or ss://base64(method:password@server:port)#name
func parseSS(uri string) (config.Port, bool) {
	uri = strings.TrimPrefix(uri, "ss://")

	name := ""
	if i := strings.LastIndex(uri, "#"); i >= 0 {
		name, _ = url.QueryUnescape(uri[i+1:])
		uri = uri[:i]
	}

	var method, password, server string
	var port int

	if i := strings.Index(uri, "@"); i >= 0 {
		userInfo := tryBase64Decode(uri[:i])
		hostPort := uri[i+1:]
		parts := strings.SplitN(userInfo, ":", 2)
		if len(parts) != 2 {
			return config.Port{}, false
		}
		method = parts[0]
		password = parts[1]
		server, port = parseHostPort(hostPort)
	} else {
		decoded := tryBase64Decode(uri)
		if i := strings.Index(decoded, "@"); i >= 0 {
			parts := strings.SplitN(decoded[:i], ":", 2)
			if len(parts) != 2 {
				return config.Port{}, false
			}
			method = parts[0]
			password = parts[1]
			server, port = parseHostPort(decoded[i+1:])
		} else {
			return config.Port{}, false
		}
	}

	if server == "" || port == 0 {
		return config.Port{}, false
	}
	if name == "" {
		name = server
	}

	return config.Port{
		ID:       shortID(),
		Name:     name,
		Type:     config.PortTypeShadowsocks,
		Enabled:  true,
		SSServer: server,
		SSPort:   port,
		SSMethod: method,
		SSPass:   password,
	}, true
}

// vmess://base64(json)
// v2rayN format: {"v":"2","ps":"name","add":"server","port":"443","id":"uuid","aid":"0",...}
func parseVMess(uri string) (config.Port, bool) {
	encoded := strings.TrimPrefix(uri, "vmess://")
	decoded := tryBase64Decode(encoded)

	var obj map[string]interface{}
	if err := json.Unmarshal([]byte(decoded), &obj); err != nil {
		return config.Port{}, false
	}

	server := getString(obj, "add")
	portStr := getString(obj, "port")
	uuid := getString(obj, "id")
	name := getString(obj, "ps")

	port, _ := strconv.Atoi(portStr)
	if server == "" || port == 0 || uuid == "" {
		return config.Port{}, false
	}
	if name == "" {
		name = server
	}

	aid, _ := strconv.Atoi(getString(obj, "aid"))

	return config.Port{
		ID:          shortID(),
		Name:        name,
		Type:        config.PortTypeVMess,
		Enabled:     true,
		VMessServer: server,
		VMessPort:   port,
		VMessUUID:   uuid,
		VMessAltID:  aid,
	}, true
}

// trojan://password@server:port?sni=xxx#name
func parseTrojan(uri string) (config.Port, bool) {
	u, err := url.Parse(uri)
	if err != nil {
		return config.Port{}, false
	}

	password := u.User.Username()
	server := u.Hostname()
	port, _ := strconv.Atoi(u.Port())
	name, _ := url.QueryUnescape(u.Fragment)
	sni := u.Query().Get("sni")

	if server == "" || port == 0 || password == "" {
		return config.Port{}, false
	}
	if sni == "" {
		sni = server
	}
	if name == "" {
		name = server
	}

	return config.Port{
		ID:             shortID(),
		Name:           name,
		Type:           config.PortTypeTrojan,
		Enabled:        true,
		TrojanServer:   server,
		TrojanPort:     port,
		TrojanPassword: password,
		TrojanSNI:      sni,
	}, true
}

func parseHostPort(s string) (string, int) {
	if i := strings.LastIndex(s, ":"); i >= 0 {
		host := s[:i]
		port, _ := strconv.Atoi(s[i+1:])
		return host, port
	}
	return s, 0
}
