package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/metacubex/http"
)

const diagnosticWriteTimeout = 5 * time.Second

func getDiagnosticConnections(w http.ResponseWriter, r *http.Request) {
	getDiagnosticStream(w, r, "connections")
}

func getDiagnosticDns(w http.ResponseWriter, r *http.Request) {
	getDiagnosticStream(w, r, "dns")
}

func diagnosticStreamRuntime(r *http.Request) (string, uint64, error) {
	invalid := errors.New("diagnostics_invalid_request")
	if r.Method != http.MethodGet || !r.ProtoAtLeast(1, 1) ||
		!strings.EqualFold(r.Header.Get("Upgrade"), "websocket") ||
		r.Header.Get("Sec-WebSocket-Version") != "13" {
		return "", 0, invalid
	}
	connectionUpgrade := false
	for _, value := range r.Header.Values("Connection") {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), "upgrade") {
				connectionUpgrade = true
			}
		}
	}
	key, err := base64.StdEncoding.DecodeString(r.Header.Get("Sec-WebSocket-Key"))
	if !connectionUpgrade || err != nil || len(key) != 16 {
		return "", 0, invalid
	}
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return "", 0, invalid
	}
	boot, revision := query["expectedBootId"], query["expectedConfigRevision"]
	if len(boot) != 1 || strings.TrimSpace(boot[0]) == "" || len(revision) != 1 || revision[0] == "" {
		return "", 0, invalid
	}
	for _, digit := range revision[0] {
		if digit < '0' || digit > '9' {
			return "", 0, invalid
		}
	}
	parsed, err := strconv.ParseUint(revision[0], 10, 64)
	if err != nil || parsed == 0 {
		return "", 0, invalid
	}
	return boot[0], parsed, nil
}

func getDiagnosticStream(w http.ResponseWriter, r *http.Request, feed string) {
	bootID, revision, err := diagnosticStreamRuntime(r)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	session, status, err := subscribeDiagnostics(feed, bootID, revision)
	if err != nil {
		writeError(w, r, status, err)
		return
	}
	// 握手失败也必须完成 worker；运行代次退休会等待这个通道。
	defer close(session.workerDone)
	defer session.close()
	conn, rw, err := upgradeWebSocket(w, r)
	if err != nil {
		return
	}
	defer conn.Close()
	if !session.attach(conn) {
		return
	}
	writer := diagnosticSocketWriter{conn: conn}
	readerDone, watcherDone := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(readerDone)
		readDiagnosticControls(rw.Reader, &writer)
	}()
	go func() {
		defer close(watcherDone)
		select {
		case <-r.Context().Done():
		case <-session.done:
		case <-readerDone:
		}
		// 写入可能正被慢读端阻塞，取消不能等待主循环再次进入 select。
		session.close()
		_ = conn.Close()
	}()
	defer func() {
		session.close()
		_ = conn.Close()
		<-readerDone
		<-watcherDone
	}()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-session.done:
			return
		case <-readerDone:
			return
		case <-session.wake:
			select {
			case <-session.done:
				return
			default:
			}
			frame := session.nextFrame()
			if frame == nil {
				continue
			}
			data, err := json.Marshal(frame)
			if err != nil || writer.text(data) != nil {
				return
			}
		}
	}
}

type diagnosticSocketWriter struct {
	conn net.Conn
	mu   sync.Mutex
}

func (writer *diagnosticSocketWriter) lockFrame() error {
	writer.mu.Lock()
	if err := writer.conn.SetWriteDeadline(time.Now().Add(diagnosticWriteTimeout)); err != nil {
		writer.mu.Unlock()
		return err
	}
	return nil
}

func (writer *diagnosticSocketWriter) text(data []byte) error {
	if err := writer.lockFrame(); err != nil {
		return err
	}
	defer writer.mu.Unlock()
	return writeTextFrame(writer.conn, data)
}

func (writer *diagnosticSocketWriter) protocolError() {
	if writer.lockFrame() != nil {
		return
	}
	defer writer.mu.Unlock()
	_ = ws.WriteFrame(writer.conn, ws.NewCloseFrame(ws.NewCloseFrameBody(ws.StatusProtocolError, "")))
}

func readDiagnosticControls(reader *bufio.Reader, writer *diagnosticSocketWriter) {
	for {
		header, err := ws.ReadHeader(reader)
		if err != nil {
			if errors.Is(err, ws.ErrHeaderLengthMSB) || errors.Is(err, ws.ErrHeaderLengthUnexpected) {
				writer.protocolError()
			}
			return
		}
		if ws.CheckHeader(header, ws.StateServerSide) != nil || !header.OpCode.IsControl() {
			writer.protocolError()
			return
		}
		// 控制载荷最多125字节；先读完再取写锁，半帧不能阻塞正常数据写出。
		var payload [125]byte
		if _, err := io.ReadFull(reader, payload[:int(header.Length)]); err != nil {
			return
		}
		if writer.lockFrame() != nil {
			return
		}
		// 控制回复直接写入连接；缓冲 Writer 未 Flush 时不能视为已经回复。
		handler := wsutil.ControlHandler{
			Src: bytes.NewReader(payload[:int(header.Length)]), Dst: writer.conn, State: ws.StateServerSide,
		}
		err = handler.Handle(header)
		writer.mu.Unlock()
		if err != nil || header.OpCode == ws.OpClose {
			return
		}
	}
}
