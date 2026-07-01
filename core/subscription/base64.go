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

func parseBase64(content string) ([]config.Line, error) {
	decoded := tryBase64Decode(strings.TrimSpace(content))
	textLines := strings.Split(decoded, "\n")

	var results []config.Line
	for _, line := range textLines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		ln, ok := uriToLine(line)
		if ok {
			results = append(results, ln)
		}
	}
	if len(results) == 0 {
		return nil, fmt.Errorf("no supported URIs found")
	}
	return results, nil
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

func uriToLine(uri string) (config.Line, bool) {
	switch {
	case strings.HasPrefix(uri, "ss://"):
		return parseSS(uri)
	case strings.HasPrefix(uri, "vmess://"):
		return parseVMess(uri)
	case strings.HasPrefix(uri, "trojan://"):
		return parseTrojan(uri)
	default:
		return config.Line{}, false
	}
}

// ss://base64(method:password)@server:port#name
// or ss://base64(method:password@server:port)#name
func parseSS(uri string) (config.Line, bool) {
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
			return config.Line{}, false
		}
		method = parts[0]
		password = parts[1]
		server, port = parseHostPort(hostPort)
	} else {
		decoded := tryBase64Decode(uri)
		if i := strings.Index(decoded, "@"); i >= 0 {
			parts := strings.SplitN(decoded[:i], ":", 2)
			if len(parts) != 2 {
				return config.Line{}, false
			}
			method = parts[0]
			password = parts[1]
			server, port = parseHostPort(decoded[i+1:])
		} else {
			return config.Line{}, false
		}
	}

	if server == "" || port == 0 {
		return config.Line{}, false
	}
	if name == "" {
		name = server
	}

	return config.Line{
		ID:       shortID(),
		Name:     name,
		Type:     config.LineTypeShadowsocks,
		Enabled:  true,
		SSServer: server,
		SSPort:   port,
		SSMethod: method,
		SSPass:   password,
	}, true
}

// vmess://base64(json)
// v2rayN format: {"v":"2","ps":"name","add":"server","port":"443","id":"uuid","aid":"0",...}
func parseVMess(uri string) (config.Line, bool) {
	encoded := strings.TrimPrefix(uri, "vmess://")
	decoded := tryBase64Decode(encoded)

	var obj map[string]interface{}
	if err := json.Unmarshal([]byte(decoded), &obj); err != nil {
		return config.Line{}, false
	}

	server := getString(obj, "add")
	portStr := getString(obj, "port")
	uuid := getString(obj, "id")
	name := getString(obj, "ps")

	port, _ := strconv.Atoi(portStr)
	if server == "" || port == 0 || uuid == "" {
		return config.Line{}, false
	}
	if name == "" {
		name = server
	}

	aid, _ := strconv.Atoi(getString(obj, "aid"))

	return config.Line{
		ID:          shortID(),
		Name:        name,
		Type:        config.LineTypeVMess,
		Enabled:     true,
		VMessServer: server,
		VMessPort:   port,
		VMessUUID:   uuid,
		VMessAltID:  aid,
	}, true
}

// trojan://password@server:port?sni=xxx#name
func parseTrojan(uri string) (config.Line, bool) {
	u, err := url.Parse(uri)
	if err != nil {
		return config.Line{}, false
	}

	password := u.User.Username()
	server := u.Hostname()
	port, _ := strconv.Atoi(u.Port())
	name, _ := url.QueryUnescape(u.Fragment)
	sni := u.Query().Get("sni")

	if server == "" || port == 0 || password == "" {
		return config.Line{}, false
	}
	if sni == "" {
		sni = server
	}
	if name == "" {
		name = server
	}

	return config.Line{
		ID:             shortID(),
		Name:           name,
		Type:           config.LineTypeTrojan,
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
