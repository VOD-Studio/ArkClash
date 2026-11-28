package ctrl

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
)

func TestCtrlWriteError(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/arkclash/test", nil)
	WriteError(rec, req, http.StatusConflict, errors.New("stale_runtime"))
	if rec.Code != http.StatusConflict {
		t.Fatalf("status=%d, want 409", rec.Code)
	}
	var body APIError
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body.Message != "stale_runtime" {
		t.Fatalf("unexpected error body: %s err=%v", rec.Body.String(), err)
	}
}

type fakeHijacker struct {
	http.ResponseWriter
	conn net.Conn
	rw   *bufio.ReadWriter
}

func (f *fakeHijacker) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return f.conn, f.rw, nil
}

func TestCtrlUpgradeWebSocketAndWriteTextFrame(t *testing.T) {
	// 非 Hijacker 必须返回错误。
	req := httptest.NewRequest(http.MethodGet, "/arkclash/events", nil)
	req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	if _, _, err := UpgradeWebSocket(httptest.NewRecorder(), req); err == nil {
		t.Fatal("non-hijacker writer unexpectedly upgraded")
	}

	// 验证 RFC 6455 标准示例密钥的 Accept 响应。
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	rw := bufio.NewReadWriter(bufio.NewReader(server), bufio.NewWriter(server))
	readDone := make(chan string, 1)
	go func() {
		buf := make([]byte, 512)
		n, _ := client.Read(buf)
		readDone <- string(buf[:n])
	}()
	conn, _, err := UpgradeWebSocket(&fakeHijacker{ResponseWriter: httptest.NewRecorder(), conn: server, rw: rw}, req)
	if err != nil || conn != server {
		t.Fatalf("upgrade failed: conn=%v err=%v", conn, err)
	}
	handshake := <-readDone
	if !strings.Contains(handshake, "HTTP/1.1 101 Switching Protocols") ||
		!strings.Contains(handshake, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") {
		t.Fatalf("unexpected handshake: %q", handshake)
	}

	// 验证三档长度的文本帧头编码（<126、16-bit、64-bit）。
	for _, size := range []int{5, 300, 70000} {
		payload := bytes.Repeat([]byte("a"), size)
		var out bytes.Buffer
		if err := WriteTextFrame(&out, payload); err != nil {
			t.Fatalf("WriteTextFrame(%d): %v", size, err)
		}
		raw := out.Bytes()
		if raw[0] != 0x81 {
			t.Fatalf("size=%d opcode=0x%x", size, raw[0])
		}
		switch {
		case size < 126:
			if int(raw[1]) != size || !bytes.Equal(raw[2:], payload) {
				t.Fatalf("short frame mismatch for size=%d", size)
			}
		case size <= 0xFFFF:
			if raw[1] != 126 || int(binary.BigEndian.Uint16(raw[2:4])) != size || !bytes.Equal(raw[4:], payload) {
				t.Fatalf("medium frame mismatch for size=%d", size)
			}
		default:
			if raw[1] != 127 || int(binary.BigEndian.Uint64(raw[2:10])) != size || !bytes.Equal(raw[10:], payload) {
				t.Fatalf("long frame mismatch for size=%d", size)
			}
		}
	}
}

func TestCtrlEventBusAndCommandBridge(t *testing.T) {
	bus := NewEventBus()
	ch, unsubscribe := bus.Subscribe(1)
	bus.Emit(map[string]string{"type": "first"})
	// 满队列时非阻塞丢弃，不能卡住广播方。
	bus.Emit(map[string]string{"type": "dropped"})
	if got := string(<-ch); !strings.Contains(got, `"first"`) {
		t.Fatalf("unexpected event payload: %q", got)
	}
	unsubscribe()
	unsubscribe() // 幂等取消

	bridge := NewCommandBridge(50 * time.Millisecond)
	rec := httptest.NewRecorder()
	bridge.Forward(rec, httptest.NewRequest(http.MethodPost, "/arkclash/vpn/connect", strings.NewReader(`{}`)))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("unready bridge status=%d, want 503", rec.Code)
	}

	bridge.SetDispatcher(func(id int64, name, body string) {
		if name != "vpn/connect" || body != `{"ok":true}` {
			t.Errorf("unexpected command: name=%q body=%q", name, body)
		}
		go bridge.Reply(id, http.StatusAccepted, []byte(`{"done":true}`))
	})
	rec = httptest.NewRecorder()
	bridge.Forward(rec, httptest.NewRequest(http.MethodPost, "/arkclash/vpn/connect", strings.NewReader(`{"ok":true}`)))
	if rec.Code != http.StatusAccepted || rec.Body.String() != `{"done":true}` {
		t.Fatalf("reply mismatch: code=%d body=%q", rec.Code, rec.Body.String())
	}

	bridge.SetDispatcher(func(id int64, name, body string) {})
	rec = httptest.NewRecorder()
	bridge.Forward(rec, httptest.NewRequest(http.MethodPost, "/arkclash/vpn/disconnect", nil))
	if rec.Code != http.StatusGatewayTimeout {
		t.Fatalf("timeout status=%d, want 504", rec.Code)
	}
}
