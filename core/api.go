package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"

	"github.com/metacubex/mihomo/hub/route"

	"github.com/metacubex/chi"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

func init() {
	// 关掉 mihomo 给独立进程用的接口：PUT/PATCH /configs 会绕过 applyOverrides，
	// /restart 会 exec 宿主进程，/upgrade 会下载替换内核（ADR-0009）。
	route.SetEmbedMode(true)
	route.Register(func(r chi.Router) {
		r.Route("/arkclash", func(r chi.Router) {
			r.Get("/status", getStatus)
			r.Get("/proxies", getProxySnapshot)
			r.Post("/proxies/definition", postProxyDefinition)
			r.Post("/proxies/tailscale-login", postTailscaleLogin)
			r.Get("/providers", getRuntimeProviders)
			r.Get("/providers/events", getRuntimeProviderEvents)
			r.Post("/providers/update", postRuntimeProviderUpdate)
			r.Post("/providers/replace", postRuntimeProviderReplace)
			r.Get("/selections", getSelections)
			r.Post("/selection", portableMutation(postSelection))
			r.Get("/delay", getDelay)
			r.Post("/probe", postProbe)
			r.Post("/backup/dav", postBackupDAV)
			r.Post("/backup/apply", withPortableMutation(postBackupApply, true))
			r.Patch("/configs", patchRuntimeOptions)
			r.Post("/reload", postReload)
			r.Post("/prefetch", postPrefetch)
			r.Get("/events", getEvents)
			r.Get("/geo", getGeo)
			r.Post("/geo/settings", postGeoSettings)
			r.Post("/dns/settings", portableMutation(postDNSOverrides))
			r.Post("/general/settings", portableMutation(postGeneralSettings))
			r.Post("/rules/settings", portableMutation(postAddedRules))
			r.Post("/rule-sets", postRuleSet)
			r.Post("/scripts/apply", postProfileScript)
			r.Get("/scripts/outbounds", getScriptOutbounds)
			r.Get("/profiles/preview", getProfilePreview)
			r.Post("/local-proxies/{operation}", postLocalProxies)
			r.Post("/proxy-filters/validate", postProxyFilterValidation)
			r.Post("/geo/update", postGeoUpdate)
			r.Get("/geo/events", getGeoEvents)
			r.Get("/diagnostics/capture", getDiagnosticCapture)
			r.Get("/diagnostics/stats", getDiagnosticStats)
			r.Get("/diagnostics/connections", getDiagnosticConnections)
			r.Get("/diagnostics/dns", getDiagnosticDns)
			r.Get("/diagnostics/logs", getDiagnosticLogs)
			r.Post("/diagnostics/logs/clear", postDiagnosticLogsClear)
			r.Post("/diagnostics/connections/close", postDiagnosticConnectionsClose)
			r.Post("/diagnostics/dns/clear-cache", postDiagnosticDnsClearCache)
			r.Post("/profiles/{name}", forwardCommand)
			r.Post("/vpn/connect", forwardCommand)
			r.Post("/vpn/disconnect", forwardCommand)
		})
	})
}

type apiError struct {
	Message string `json:"message"`
}

func writeError(w http.ResponseWriter, r *http.Request, status int, err error) {
	render.Status(r, status)
	render.JSON(w, r, apiError{Message: err.Error()})
}

func getStatus(w http.ResponseWriter, r *http.Request) {
	status := runtimeSnapshot.Load()
	if status == nil {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("core_initializing"))
		return
	}
	render.JSON(w, r, status)
}

type runtimeOptionsBody struct {
	Mode     *string `json:"mode"`
	AllowLan *bool   `json:"allow-lan"`
}

func patchRuntimeOptions(w http.ResponseWriter, r *http.Request) {
	var body runtimeOptionsBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := setRuntimeOptions(body.Mode, body.AllowLan); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	render.NoContent(w, r)
}

type reloadBody struct {
	Profile         string  `json:"profile"`
	Path            string  `json:"path"`
	ExpectedProfile *string `json:"expectedProfile,omitempty"`
}

func postReload(w http.ResponseWriter, r *http.Request) {
	var body reloadBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := reload(body.Path, body.Profile, body.ExpectedProfile); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	render.NoContent(w, r)
}

type prefetchBody struct {
	Path string `json:"path"`
}

type prefetchResult struct {
	Downloaded int    `json:"downloaded"`
	Error      string `json:"error,omitempty"`
}

func postPrefetch(w http.ResponseWriter, r *http.Request) {
	var body prefetchBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	n, err := prefetch(body.Path)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	render.JSON(w, r, prefetchResult{Downloaded: n})
}

// upgradeWebSocket 完成服务端握手（RFC 6455 第 4.2 节），mihomo 自己的实现没有导出。
// 调用前先检查请求头；接管连接之后出错，只能直接关掉连接。
func upgradeWebSocket(w http.ResponseWriter, r *http.Request) (net.Conn, *bufio.ReadWriter, error) {
	key := r.Header.Get("Sec-WebSocket-Key")
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("connection cannot be hijacked")
	}
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return nil, nil, err
	}
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	_, err = rw.WriteString("HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + base64.StdEncoding.EncodeToString(sum[:]) + "\r\n\r\n")
	if err == nil {
		err = rw.Flush()
	}
	if err != nil {
		conn.Close()
		return nil, nil, err
	}
	return conn, rw, nil
}

// 服务端发出的帧不加掩码，一条消息一帧。
func writeTextFrame(w io.Writer, p []byte) error {
	header := []byte{0x81, 0}
	switch n := len(p); {
	case n < 126:
		header[1] = byte(n)
	case n <= 0xFFFF:
		header[1] = 126
		header = binary.BigEndian.AppendUint16(header, uint16(n))
	default:
		header[1] = 127
		header = binary.BigEndian.AppendUint64(header, uint64(n))
	}
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err := w.Write(p)
	return err
}
