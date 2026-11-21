package main

import (
	"strings"

	"github.com/dlclark/regexp2"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

type proxyFilterRequest struct {
	Expression string `json:"expression"`
}

type proxyFilterResult struct {
	InvalidPart int `json:"invalidPart"`
}

func invalidProxyFilterPart(expression string) int {
	// mihomo 为每个反引号分隔的片段分别编译正则。
	for index, part := range strings.Split(expression, "`") {
		if _, err := regexp2.Compile(part, regexp2.None); err != nil {
			return index + 1
		}
	}
	return 0
}

func postProxyFilterValidation(w http.ResponseWriter, r *http.Request) {
	var body proxyFilterRequest
	if err := decodeProfileSettings(http.MaxBytesReader(w, r.Body, 8<<10), &body); err != nil ||
		strings.TrimSpace(body.Expression) == "" || len(body.Expression) > 4096 ||
		strings.ContainsAny(body.Expression, "\x00\r\n") {
		writeError(w, r, http.StatusBadRequest, errProfileSettingsInvalid)
		return
	}
	render.JSON(w, r, proxyFilterResult{InvalidPart: invalidProxyFilterPart(body.Expression)})
}
