package main

/*
#include <stdlib.h>

// 必须和 arkclash.h 里的声明一致。
typedef void (*ArkClashCommandHandler)(long long id, const char *name, const char *body);

static void arkclashCallCommandHandler(ArkClashCommandHandler h, long long id, const char *name, const char *body) {
	h(id, name, body);
}
*/
import "C"

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	mihomoHttp "github.com/metacubex/mihomo/component/http"
	"github.com/metacubex/mihomo/hub/route"

	"github.com/metacubex/chi"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

// 订阅类命令转给 VPN 进程的 ArkTS 后最多等这么久：下载（连接 15s + 读取 30s）、
// 先走内核再直连各一次，再加上解析和热切换。
const commandTimeout = 150 * time.Second

// 经内核下载的订阅最大字节数，超过就算失败，防止异常响应占满内存。
const fetchLimit = 64 << 20

func init() {
	// 关掉 mihomo 给独立进程用的接口：PUT/PATCH /configs 会绕过 applyOverrides，
	// /restart 会 exec 宿主进程，/upgrade 会下载替换内核（ADR-0009）。
	route.SetEmbedMode(true)
	route.Register(func(r chi.Router) {
		r.Route("/arkclash", func(r chi.Router) {
			r.Get("/status", getStatus)
			r.Patch("/configs", patchRuntimeOptions)
			r.Post("/reload", postReload)
			r.Post("/prefetch", postPrefetch)
			r.Get("/events", getEvents)
			r.Post("/profiles/{name}", forwardCommand)
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

type statusResponse struct {
	Profile string `json:"profile"`
}

func getStatus(w http.ResponseWriter, r *http.Request) {
	profile, _ := runningProfile()
	render.JSON(w, r, statusResponse{Profile: profile})
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
	Profile string `json:"profile"`
	Path    string `json:"path"`
}

func postReload(w http.ResponseWriter, r *http.Request) {
	var body reloadBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := reload(body.Path, body.Profile); err != nil {
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

// ArkClashPrefetch 预先下载 path 里还没下载过的 rule-provider（见 prefetch）。返回 JSON
// {"downloaded":n} 或 {"error":"..."}，用 ArkClashFree 释放。会阻塞到下载结束，只能在工作线程上调用。
//
//export ArkClashPrefetch
func ArkClashPrefetch(path *C.char) *C.char {
	n, err := prefetch(C.GoString(path))
	result := prefetchResult{Downloaded: n}
	if err != nil {
		result.Error = err.Error()
	}
	data, _ := json.Marshal(result)
	return C.CString(string(data))
}

// ---- 转给 ArkTS 的命令 ----

type commandReply struct {
	status int
	body   []byte
}

var (
	commandHandler atomic.Pointer[C.ArkClashCommandHandler]
	commandSeq     atomic.Int64
	pendingMu      sync.Mutex
	pending        = map[int64]chan commandReply{}
)

// forwardCommand 把 POST /arkclash/profiles/{name} 原样交给 VPN 进程的 ArkTS，等它用
// ArkClashReply 回复。请求方中途断开时不再等，但 ArkTS 照样把命令做完（ADR-0009）。
func forwardCommand(w http.ResponseWriter, r *http.Request) {
	handler := commandHandler.Load()
	if handler == nil {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("command handler is not ready"))
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}

	id := commandSeq.Add(1)
	ch := make(chan commandReply, 1)
	pendingMu.Lock()
	pending[id] = ch
	pendingMu.Unlock()
	defer func() {
		pendingMu.Lock()
		delete(pending, id)
		pendingMu.Unlock()
	}()

	cName := C.CString(chi.URLParam(r, "name"))
	cBody := C.CString(string(body))
	C.arkclashCallCommandHandler(*handler, C.longlong(id), cName, cBody)
	C.free(unsafe.Pointer(cName))
	C.free(unsafe.Pointer(cBody))

	timer := time.NewTimer(commandTimeout)
	defer timer.Stop()
	select {
	case reply := <-ch:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(reply.status)
		_, _ = w.Write(reply.body)
	case <-timer.C:
		writeError(w, r, http.StatusGatewayTimeout, errors.New("command timed out"))
	case <-r.Context().Done():
	}
}

// ArkClashSetCommandHandler 登记处理订阅类命令的回调。回调在 Go 的线程上调用，name 和 body
// 只在回调期间有效；处理完后用 ArkClashReply 回复同一个 id。
//
//export ArkClashSetCommandHandler
func ArkClashSetCommandHandler(handler C.ArkClashCommandHandler) {
	if handler == nil {
		commandHandler.Store(nil)
		return
	}
	commandHandler.Store(&handler)
}

// ArkClashReply 回复一条命令；请求已超时或断开时直接丢弃。body 由调用方保留所有权。
//
//export ArkClashReply
func ArkClashReply(id C.longlong, status C.int, body *C.char) {
	pendingMu.Lock()
	ch, ok := pending[int64(id)]
	pendingMu.Unlock()
	if !ok {
		return
	}
	select {
	case ch <- commandReply{status: int(status), body: []byte(C.GoString(body))}:
	default:
	}
}

// ---- 事件推送 ----

var (
	subscribersMu sync.Mutex
	subscribers   = map[chan []byte]struct{}{}
)

// emit 推给所有订阅 /arkclash/events 的连接；某个连接积压太多时丢掉这条，不阻塞发送方。
func emit(event any) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	emitRaw(data)
}

func emitRaw(data []byte) {
	subscribersMu.Lock()
	defer subscribersMu.Unlock()
	for ch := range subscribers {
		select {
		case ch <- data:
		default:
		}
	}
}

// ArkClashEmit 由 VPN 进程的 ArkTS 推送一条事件（JSON 对象），body 由调用方保留所有权。
//
//export ArkClashEmit
func ArkClashEmit(event *C.char) {
	emitRaw([]byte(C.GoString(event)))
}

func getEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") ||
		r.Header.Get("Sec-WebSocket-Key") == "" {
		writeError(w, r, http.StatusBadRequest, errors.New("websocket handshake required"))
		return
	}
	conn, rw, err := upgradeWebSocket(w, r)
	if err != nil {
		return
	}
	defer conn.Close()

	ch := make(chan []byte, 16)
	subscribersMu.Lock()
	subscribers[ch] = struct{}{}
	subscribersMu.Unlock()
	defer func() {
		subscribersMu.Lock()
		delete(subscribers, ch)
		subscribersMu.Unlock()
	}()

	// 客户端发来的帧都不需要处理，读到出错就说明连接关了。
	closed := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, rw)
		close(closed)
	}()
	for {
		select {
		case data := <-ch:
			if err := writeTextFrame(conn, data); err != nil {
				return
			}
		case <-closed:
			return
		}
	}
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

// ---- 经内核下载 ----

type fetchRequest struct {
	URL       string            `json:"url"`
	Header    map[string]string `json:"header"`
	Path      string            `json:"path"`      // 响应体写到这里，必须在配置目录下
	TimeoutMs int               `json:"timeoutMs"` // 整个请求的上限
}

type fetchResult struct {
	Status int               `json:"status"`
	Header map[string]string `json:"header,omitempty"` // 键为小写，只保留第一个值
	Error  string            `json:"error,omitempty"`
}

// fetch 按规则经内核发出请求（mihomo 下载 provider 的同一条路径），内核连不上时
// component/http 自己会退回直连。响应体直接写文件，不经过 NAPI 传大字符串。
func fetch(req fetchRequest) fetchResult {
	if _, ok := runningProfile(); !ok {
		return fetchResult{Error: "core is not running"}
	}
	if err := checkProfilePath(req.Path); err != nil {
		return fetchResult{Error: err.Error()}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(req.TimeoutMs)*time.Millisecond)
	defer cancel()

	header := map[string][]string{}
	for k, v := range req.Header {
		header[k] = []string{v}
	}
	resp, err := mihomoHttp.HttpRequest(ctx, req.URL, http.MethodGet, header, nil)
	if err != nil {
		// url.Error 会带上完整链接，订阅链接不能出现在错误信息里（AGENTS.md「安全」）。
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err
		}
		return fetchResult{Error: err.Error()}
	}
	defer resp.Body.Close()

	result := fetchResult{Status: resp.StatusCode, Header: map[string]string{}}
	for k, v := range resp.Header {
		if len(v) > 0 {
			result.Header[strings.ToLower(k)] = v[0]
		}
	}
	if resp.StatusCode != http.StatusOK {
		return result
	}
	if err := writeBody(req.Path, resp.Body); err != nil {
		return fetchResult{Error: err.Error()}
	}
	return result
}

func writeBody(path string, body io.Reader) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	n, err := io.Copy(f, io.LimitReader(body, fetchLimit+1))
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err == nil && n > fetchLimit {
		err = errors.New("response too large")
	}
	if err != nil {
		_ = os.Remove(path)
	}
	return err
}

// ArkClashFetch 经内核下载，参数和结果都是 JSON（见 fetchRequest、fetchResult）。
// 返回值由调用方用 ArkClashFree 释放。会阻塞到请求结束，只能在工作线程上调用。
//
//export ArkClashFetch
func ArkClashFetch(requestJSON *C.char) *C.char {
	var req fetchRequest
	result := fetchResult{}
	if err := json.Unmarshal([]byte(C.GoString(requestJSON)), &req); err != nil {
		result.Error = err.Error()
	} else {
		result = fetch(req)
	}
	data, _ := json.Marshal(result)
	return C.CString(string(data))
}
