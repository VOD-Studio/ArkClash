package main

import (
	"errors"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/chi"
	"github.com/metacubex/http"
)

// 订阅类命令允许下载、内容校验和热切换完成；下载本身受20秒总超时约束。
const commandTimeout = 150 * time.Second

type commandDispatcher func(id int64, name, body string)

type commandReply struct {
	status int
	body   []byte
}

var (
	commandHandler atomic.Pointer[commandDispatcher]
	commandSeq     atomic.Int64
	pendingMu      sync.Mutex
	pending        = map[int64]chan commandReply{}
)

func setCommandDispatcher(fn commandDispatcher) {
	if fn == nil {
		commandHandler.Store(nil)
		return
	}
	commandHandler.Store(&fn)
}

func replyCommand(id int64, status int, body []byte) {
	pendingMu.Lock()
	ch, ok := pending[id]
	pendingMu.Unlock()
	if !ok {
		return
	}
	select {
	case ch <- commandReply{status: status, body: body}:
	default:
	}
}

// HTTP 超时或断开只停止等待，不取消已交给扩展的操作。
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

	name := "profiles/" + chi.URLParam(r, "name")
	if strings.HasPrefix(r.URL.Path, "/arkclash/vpn/") {
		name = strings.TrimPrefix(r.URL.Path, "/arkclash/")
	}
	(*handler)(id, name, string(body))

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
