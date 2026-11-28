package proxylink

import (
	"bytes"
	"regexp"
	"strconv"
	"strings"

	"go.yaml.in/yaml/v3"
)

// 和 ArkTS 端 ShareProfile.ets 的 buildShareProfile、LocalProxies.ets 的命名规则保持一致。
const shareGroup = "PROXY"

var (
	schemePrefix = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9+.-]*://`)
	emptyName    = regexp.MustCompile(`^(-[0-9]+)?$`)
)

// LooksLikeShareLinks 只看开头判断是否为分享链接列表或其 Base64，供下载时决定是否要整段读入转换。
// Clash YAML 的键带冒号且不是 scheme://，不会命中。
func LooksLikeShareLinks(head []byte) bool {
	text := bytes.TrimLeft(bytes.TrimPrefix(head, []byte("\xef\xbb\xbf")), " \t\r\n")
	if len(text) == 0 {
		return false
	}
	line, _, _ := bytes.Cut(text, []byte("\n"))
	if schemePrefix.Match(line) {
		return true
	}
	for _, c := range text {
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '+', c == '/', c == '=', c == '-', c == '_', c == '\r', c == '\n', c == ' ', c == '\t':
		default:
			return false
		}
	}
	return true
}

// SubscriptionProfile 把分享链接列表（可为 Base64）转成单个选择组的 Clash 配置；没有可用节点时返回 false。
func SubscriptionProfile(data []byte) ([]byte, bool) {
	if !LooksLikeShareLinks(data) {
		return nil, false
	}
	proxies := Decode(string(data))
	if len(proxies) == 0 {
		return nil, false
	}
	reserved := []string{"DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "PASS-RULE", "GLOBAL"}
	taken := make(map[string]struct{}, len(proxies)+len(reserved)+1)
	for _, name := range reserved {
		taken[name] = struct{}{}
	}
	taken[shareGroup] = struct{}{}
	names := make([]string, len(proxies))
	for i, proxy := range proxies {
		names[i] = uniqueProxyName(importedName(proxyFields(proxy)), taken)
		proxy["name"] = names[i]
	}
	out, err := yaml.Marshal(map[string]any{
		"proxies":      proxies,
		"proxy-groups": []map[string]any{{"name": shareGroup, "type": "select", "proxies": names}},
		"rules":        []string{"MATCH," + shareGroup},
	})
	if err != nil {
		return nil, false
	}
	return out, true
}

func importedName(f proxyFields) string {
	name := strings.TrimSpace(f.str("name"))
	if emptyName.MatchString(name) {
		if name = f.str("server"); name == "" {
			name = f.str("type")
		}
	}
	name = strings.NewReplacer(",", "-", "\x00", "-", "\r", "-", "\n", "-").Replace(name)
	if runes := []rune(name); len(runes) > 255 {
		name = string(runes[:255])
	}
	return name
}

func uniqueProxyName(base string, taken map[string]struct{}) string {
	name := base
	for index := 1; ; index++ {
		if _, used := taken[name]; !used {
			break
		}
		ending := "-" + leftPad(index)
		runes := []rune(base)
		if limit := 255 - len(ending); len(runes) > limit {
			runes = runes[:limit]
		}
		name = string(runes) + ending
	}
	taken[name] = struct{}{}
	return name
}

func leftPad(index int) string {
	text := strconv.Itoa(index)
	if len(text) < 2 {
		text = "0" + text
	}
	return text
}
