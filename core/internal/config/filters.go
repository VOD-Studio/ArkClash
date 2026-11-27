package config

import (
	"errors"
	"maps"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/VOD-Studio/ArkClash/core/internal/proxylink"
	"github.com/dlclark/regexp2"
	"github.com/metacubex/mihomo/adapter"
)

const (
	LocalProxyLimit = 8 << 20
	LocalProxyCount = 5000
)

var (
	ErrLocalProxyInput = errors.New("local_proxy_input")

	localProxyValidation sync.Mutex
	localProxySequence   atomic.Uint64
)

type ProxyFilterRequest struct {
	Expression string `json:"expression"`
}

type ProxyFilterResult struct {
	InvalidPart int `json:"invalidPart"`
}

type LocalProxyBody struct {
	Definitions []map[string]any `json:"definitions"`
	Lines       []string         `json:"lines"`
}

func ValidProxyFilterExpression(expression string) bool {
	return strings.TrimSpace(expression) != "" && len(expression) <= 4096 && !strings.ContainsAny(expression, "\x00\r\n")
}

func InvalidProxyFilterPart(expression string) int {
	// mihomo 为每个反引号分隔的片段分别编译正则。
	for index, part := range strings.Split(expression, "`") {
		if _, err := regexp2.Compile(part, regexp2.None); err != nil {
			return index + 1
		}
	}
	return 0
}

func ValidateLocalProxies(definitions []map[string]any) []string {
	results := make([]string, len(definitions))
	localProxyValidation.Lock()
	defer localProxyValidation.Unlock()
	for i, definition := range definitions {
		results[i] = ValidateLocalProxy(definition)
	}
	return results
}

func ValidateLocalProxy(definition map[string]any) (result string) {
	// 试建适配器借用 mihomo 的参数检查，不发起连接。临时名称隔离 DNS 注册。
	defer func() {
		if recover() != nil {
			result = "local_proxy_rejected"
		}
	}()
	probe := maps.Clone(definition)
	if probe == nil {
		return "local_proxy_rejected"
	}
	switch probe["type"] {
	case "tailscale", "easytier":
		probe["name"] = "\x00arkclash-validation-" + strconv.FormatUint(localProxySequence.Add(1), 10)
	}
	outbound, err := adapter.ParseProxy(probe)
	if err != nil {
		// 内核的错误可能带凭据或服务器地址。
		return "local_proxy_rejected"
	}
	_ = outbound.Close()
	return ""
}

func EncodeLocalProxies(definitions []map[string]any) []string {
	return proxylink.Encode(definitions)
}

func DecodeLocalProxies(lines []string) ([][]map[string]any, error) {
	results := make([][]map[string]any, len(lines))
	count := 0
	for i, line := range lines {
		results[i] = proxylink.Decode(line)
		count += len(results[i])
		if count > LocalProxyCount {
			return nil, ErrLocalProxyInput
		}
	}
	return results, nil
}
