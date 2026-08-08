package subscription

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
)

func shortID() string {
	b := make([]byte, 4)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func parseExactInt(value interface{}) (int, bool) {
	text := strings.TrimSpace(fmt.Sprint(value))
	if text == "" {
		return 0, false
	}
	number, err := strconv.ParseInt(text, 10, strconv.IntSize)
	if err != nil {
		return 0, false
	}
	return int(number), true
}

func parseAnyTLSSessionSeconds(value interface{}) (int, bool) {
	seconds, ok := parseExactInt(value)
	// sing-anytls 会把 <=5s 静默改成 30s。订阅里出现该字段时必须至少为
	// 6s；未出现时才由 Line 的零值表达“使用默认值”。上界继续由
	// config.LineHasUsableOutbound 的同源校验维护。
	return seconds, ok && seconds >= 6
}

func parseAnyTLSMinIdleSession(value interface{}) (int, bool) {
	return parseExactInt(value)
}

func parseOptionalBool(value interface{}) (bool, bool) {
	switch typed := value.(type) {
	case bool:
		return typed, true
	case string:
		switch strings.ToLower(strings.TrimSpace(typed)) {
		case "1", "true", "yes":
			return true, true
		case "0", "false", "no":
			return false, true
		default:
			return false, false
		}
	default:
		number, ok := parseExactInt(value)
		if !ok || (number != 0 && number != 1) {
			return false, false
		}
		return number == 1, true
	}
}

func normalizeAnyTLSFingerprint(value string) string {
	// 只去掉配置分隔产生的普通空格；保留换行、制表符等控制字符，让
	// config.LineHasUsableOutbound 明确拒绝，而不是先清洗成另一个合法值。
	fingerprint := strings.ToLower(strings.Trim(value, " "))
	// 支持集合由 config.LineHasUsableOutbound 的 sing-box 同源校验维护。
	return fingerprint
}

func normalizeAnyTLSALPN(protocols []string) []string {
	normalized := make([]string, 0, len(protocols))
	for _, rawProtocol := range protocols {
		normalized = append(normalized, strings.Trim(rawProtocol, " "))
	}
	// 长度、控制字符、重复项与条目数由 config.LineHasUsableOutbound 统一校验。
	return normalized
}

func splitAnyTLSALPN(value string) ([]string, bool) {
	value = strings.Trim(value, " ")
	if strings.HasPrefix(value, "[") != strings.HasSuffix(value, "]") {
		return nil, false
	}
	if strings.HasPrefix(value, "[") {
		value = value[1 : len(value)-1]
	}
	if value == "" {
		return nil, true
	}
	protocols := strings.Split(value, ",")
	for _, protocol := range protocols {
		if strings.Trim(protocol, " ") == "" {
			return nil, false
		}
	}
	return protocols, true
}
