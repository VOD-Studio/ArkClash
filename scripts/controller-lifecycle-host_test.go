package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestLifecycleControllerRetiresBeforeNextBoot(t *testing.T) {
	options := lifecycleOptions(t)
	client := &http.Client{Timeout: time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	defer client.CloseIdleConnections()
	defer stop()
	previous := ""
	for i := range 20 {
		options.Secret = fmt.Sprintf("isolated-controller-%d", i)
		if err := start(options); err != nil {
			t.Fatal(err)
		}
		for _, secret := range []string{options.Secret, previous} {
			if secret == "" {
				continue
			}
			request, err := http.NewRequest(http.MethodGet, "http://"+options.Controller+"/version", nil)
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Authorization", "Bearer "+secret)
			response, err := client.Do(request)
			if err != nil {
				t.Fatalf("boot %d controller unavailable: %v", i, err)
			}
			_, _ = io.Copy(io.Discard, response.Body)
			_ = response.Body.Close()
			want := http.StatusOK
			if secret == previous {
				want = http.StatusUnauthorized
			}
			if response.StatusCode != want {
				t.Fatalf("boot %d accepted wrong controller generation: %d", i, response.StatusCode)
			}
		}
		stop()
		connection, err := net.DialTimeout("tcp", options.Controller, 100*time.Millisecond)
		if connection != nil {
			_ = connection.Close()
		}
		if err == nil {
			t.Fatalf("boot %d stop returned before controller closed", i)
		}
		previous = options.Secret
	}
}

func TestLifecycleFullStopClosesHijackedControllerStreams(t *testing.T) {
	options := lifecycleOptions(t)
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	defer stop()
	stream, err := net.DialTimeout("tcp", options.Controller, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if err := stream.SetDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	_, err = fmt.Fprintf(stream, "GET /traffic HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: Zml4dHVyZS1zdHJlYW0xNg==\r\n\r\n", options.Controller)
	if err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(stream)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
	if err != nil || response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("stream did not upgrade: response=%v err=%v", response, err)
	}
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	// 升级后的 HTTP 连接已不归 http.Server.Close 管，必须由嵌入宿主显式退休。
	if _, err := io.Copy(io.Discard, reader); err != nil {
		t.Fatalf("retired stream stayed open or failed to close: %v", err)
	}
}
