package ctrl

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

// 订阅类命令允许下载、内容校验和热切换完成；下载本身受 20 秒总超时约束。
const DefaultCommandTimeout = 150 * time.Second

type CommandDispatcher func(id int64, name, body string)

type commandReply struct {
	status int
	body   []byte
}

// CommandBridge 将 controller 上的命令请求转发给 VPN 进程 ArkTS 并等待对应 id 回复。
type CommandBridge struct {
	handler   atomic.Pointer[CommandDispatcher]
	seq       atomic.Int64
	pendingMu sync.Mutex
	pending   map[int64]chan commandReply
	timeout   time.Duration
}

func NewCommandBridge(timeout time.Duration) *CommandBridge {
	if timeout <= 0 {
		timeout = DefaultCommandTimeout
	}
	return &CommandBridge{
		pending: make(map[int64]chan commandReply),
		timeout: timeout,
	}
}

func (b *CommandBridge) SetDispatcher(fn CommandDispatcher) {
	if fn == nil {
		b.handler.Store(nil)
		return
	}
	b.handler.Store(&fn)
}

func (b *CommandBridge) Reply(id int64, status int, body []byte) {
	b.pendingMu.Lock()
	ch, ok := b.pending[id]
	b.pendingMu.Unlock()
	if !ok {
		return
	}
	select {
	case ch <- commandReply{status: status, body: body}:
	default:
	}
}

// Forward 转发命令；HTTP 超时或断开只停止等待，不取消已交给扩展的操作。
func (b *CommandBridge) Forward(w http.ResponseWriter, r *http.Request) {
	handler := b.handler.Load()
	if handler == nil {
		WriteError(w, r, http.StatusServiceUnavailable, errors.New("command handler is not ready"))
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		WriteError(w, r, http.StatusBadRequest, err)
		return
	}

	id := b.seq.Add(1)
	ch := make(chan commandReply, 1)
	b.pendingMu.Lock()
	b.pending[id] = ch
	b.pendingMu.Unlock()
	defer func() {
		b.pendingMu.Lock()
		delete(b.pending, id)
		b.pendingMu.Unlock()
	}()

	name := "profiles/" + chi.URLParam(r, "name")
	if strings.HasPrefix(r.URL.Path, "/arkclash/vpn/") {
		name = strings.TrimPrefix(r.URL.Path, "/arkclash/")
	}
	(*handler)(id, name, string(body))

	timer := time.NewTimer(b.timeout)
	defer timer.Stop()
	select {
	case reply := <-ch:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(reply.status)
		_, _ = w.Write(reply.body)
	case <-timer.C:
		WriteError(w, r, http.StatusGatewayTimeout, errors.New("command timed out"))
	case <-r.Context().Done():
	}
}

// Commands 是默认命令转发桥。
var Commands = NewCommandBridge(DefaultCommandTimeout)

func SetCommandDispatcher(fn CommandDispatcher)             { Commands.SetDispatcher(fn) }
func ReplyCommand(id int64, status int, body []byte)        { Commands.Reply(id, status, body) }
func ForwardCommand(w http.ResponseWriter, r *http.Request) { Commands.Forward(w, r) }
