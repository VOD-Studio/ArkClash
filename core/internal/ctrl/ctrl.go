// Package ctrl 提供控制面共用的 JSON 错误响应与 RFC 6455 WebSocket 握手/帧编码辅助，不依赖 mihomo。
package ctrl

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

type APIError struct {
	Message string `json:"message"`
}

func WriteError(w http.ResponseWriter, r *http.Request, status int, err error) {
	render.Status(r, status)
	render.JSON(w, r, APIError{Message: err.Error()})
}

// UpgradeWebSocket 完成服务端握手（RFC 6455 第 4.2 节），mihomo 自己的实现没有导出。
// 调用前先检查请求头；接管连接之后出错，只能直接关掉连接。
func UpgradeWebSocket(w http.ResponseWriter, r *http.Request) (net.Conn, *bufio.ReadWriter, error) {
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

// WriteTextFrame 发送服务端未加掩码的文本帧，一条消息一帧。
func WriteTextFrame(w io.Writer, p []byte) error {
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
