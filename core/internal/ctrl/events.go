package ctrl

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"

	"github.com/metacubex/http"
)

// EventBus 广播运行时事件给所有 WebSocket 订阅者；慢连接满队列时丢弃，不阻塞发送方。
type EventBus struct {
	mu          sync.Mutex
	subscribers map[chan []byte]struct{}
}

func NewEventBus() *EventBus {
	return &EventBus{subscribers: make(map[chan []byte]struct{})}
}

// Subscribe 登记一条运行时事件订阅；调用方必须调用返回的取消函数释放通道。
func (b *EventBus) Subscribe(buffer int) (<-chan []byte, func()) {
	ch := make(chan []byte, buffer)
	b.mu.Lock()
	b.subscribers[ch] = struct{}{}
	b.mu.Unlock()
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			b.mu.Lock()
			delete(b.subscribers, ch)
			b.mu.Unlock()
		})
	}
}

func (b *EventBus) Emit(event any) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	b.EmitRaw(data)
}

func (b *EventBus) EmitRaw(data []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subscribers {
		select {
		case ch <- data:
		default:
		}
	}
}

func (b *EventBus) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") ||
		r.Header.Get("Sec-WebSocket-Key") == "" {
		WriteError(w, r, http.StatusBadRequest, errors.New("websocket handshake required"))
		return
	}
	conn, rw, err := UpgradeWebSocket(w, r)
	if err != nil {
		return
	}
	defer conn.Close()

	ch, unsubscribe := b.Subscribe(16)
	defer unsubscribe()

	// 客户端发来的帧都不需要处理，读到出错就说明连接关了。
	closed := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, rw)
		close(closed)
	}()
	for {
		select {
		case data := <-ch:
			if err := WriteTextFrame(conn, data); err != nil {
				return
			}
		case <-closed:
			return
		}
	}
}

// Events 是默认运行时事件总线。
var Events = NewEventBus()

func SubscribeEvents(buffer int) (<-chan []byte, func()) { return Events.Subscribe(buffer) }
func Emit(event any)                                     { Events.Emit(event) }
func EmitRaw(data []byte)                                { Events.EmitRaw(data) }
func GetEvents(w http.ResponseWriter, r *http.Request)   { Events.ServeHTTP(w, r) }
