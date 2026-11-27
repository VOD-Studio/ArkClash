package main

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"

	"github.com/metacubex/http"
)

var (
	subscribersMu sync.Mutex
	subscribers   = map[chan []byte]struct{}{}
)

// subscribeEvents 登记一条运行时事件订阅；调用方必须调用返回的取消函数释放通道。
func subscribeEvents(buffer int) (<-chan []byte, func()) {
	ch := make(chan []byte, buffer)
	subscribersMu.Lock()
	subscribers[ch] = struct{}{}
	subscribersMu.Unlock()
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			subscribersMu.Lock()
			delete(subscribers, ch)
			subscribersMu.Unlock()
		})
	}
}

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

	ch, unsubscribe := subscribeEvents(16)
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
			if err := writeTextFrame(conn, data); err != nil {
				return
			}
		case <-closed:
			return
		}
	}
}
