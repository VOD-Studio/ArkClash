package main

import (
	"bufio"
	"bytes"
	"io"
	"net"
	"testing"
	"time"

	"github.com/gobwas/ws"
)

type diagnosticPartialControl struct {
	entered chan struct{}
	release chan struct{}
}

func (r *diagnosticPartialControl) Read(p []byte) (int, error) {
	close(r.entered)
	<-r.release
	return 0, io.EOF
}

func TestDiagnosticsPartialControlDoesNotBlockText(t *testing.T) {
	server, peer := net.Pipe()
	body := &diagnosticPartialControl{entered: make(chan struct{}), release: make(chan struct{})}
	var header bytes.Buffer
	if err := ws.WriteHeader(&header, ws.Header{Fin: true, OpCode: ws.OpPing, Masked: true,
		Mask: [4]byte{1, 2, 3, 4}, Length: 4}); err != nil {
		t.Fatal(err)
	}
	writer := &diagnosticSocketWriter{conn: server}
	done := make(chan struct{})
	go func() {
		defer close(done)
		readDiagnosticControls(bufio.NewReader(io.MultiReader(&header, body)), writer)
	}()
	defer func() { close(body.release); server.Close(); peer.Close(); <-done }()
	select {
	case <-body.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("control reader never requested payload")
	}
	written := make(chan error, 1)
	go func() { written <- writer.text([]byte("continues")) }()
	if err := peer.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	frame, err := ws.ReadFrame(peer)
	if err != nil {
		t.Fatalf("partial control frame blocked text: %v", err)
	}
	if frame.Header.OpCode != ws.OpText || string(frame.Payload) != "continues" {
		t.Fatal("corrupt text frame")
	}
	if err := <-written; err != nil {
		t.Fatal(err)
	}
}
