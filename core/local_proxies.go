package main

import (
	"encoding/json"
	"errors"
	"maps"
	"strconv"
	"sync"
	"sync/atomic"

	"github.com/metacubex/chi"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter"
)

const localProxyLimit = 8 << 20
const localProxyCount = 5000

var (
	localProxyValidation sync.Mutex
	localProxySequence   atomic.Uint64
)

type localProxyBody struct {
	Definitions []map[string]any `json:"definitions"`
	Lines       []string         `json:"lines"`
}

func postLocalProxies(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, localProxyLimit)
	var body localProxyBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil ||
		len(body.Definitions) > localProxyCount || len(body.Lines) > localProxyCount {
		writeError(w, r, http.StatusBadRequest, errors.New("local_proxy_input"))
		return
	}
	switch chi.URLParam(r, "operation") {
	case "validate":
		render.JSON(w, r, validateLocalProxies(body.Definitions))
	case "encode":
		render.JSON(w, r, encodeLocalProxyLinks(body.Definitions))
	case "decode":
		results := make([][]map[string]any, len(body.Lines))
		count := 0
		for i, line := range body.Lines {
			results[i] = decodeLocalProxyLink(line)
			count += len(results[i])
			if count > localProxyCount {
				writeError(w, r, http.StatusBadRequest, errors.New("local_proxy_input"))
				return
			}
		}
		render.JSON(w, r, results)
	default:
		http.NotFound(w, r)
	}
}

func validateLocalProxies(definitions []map[string]any) []string {
	results := make([]string, len(definitions))
	localProxyValidation.Lock()
	defer localProxyValidation.Unlock()
	for i, definition := range definitions {
		results[i] = validateLocalProxy(definition)
	}
	return results
}

func validateLocalProxy(definition map[string]any) (result string) {
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
