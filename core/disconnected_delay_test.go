package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
)

func disconnectedSocksFixture(t *testing.T) *atomic.Int32 {
	t.Helper()
	server, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	var accepted atomic.Int32
	go func() {
		for {
			client, err := server.Accept()
			if err != nil {
				return
			}
			go func() {
				defer client.Close()
				_ = client.SetDeadline(time.Now().Add(5 * time.Second))
				var greeting [2]byte
				if _, err := io.ReadFull(client, greeting[:]); err != nil || greeting[0] != 5 {
					return
				}
				if _, err := io.CopyN(io.Discard, client, int64(greeting[1])); err != nil {
					return
				}
				if _, err := client.Write([]byte{5, 0}); err != nil {
					return
				}
				var command [4]byte
				if _, err := io.ReadFull(client, command[:]); err != nil || command[0] != 5 || command[1] != 1 {
					return
				}
				var host string
				switch command[3] {
				case 1:
					var address [4]byte
					if _, err := io.ReadFull(client, address[:]); err != nil {
						return
					}
					host = net.IP(address[:]).String()
				case 3:
					var length [1]byte
					if _, err := io.ReadFull(client, length[:]); err != nil {
						return
					}
					address := make([]byte, int(length[0]))
					if _, err := io.ReadFull(client, address); err != nil {
						return
					}
					host = string(address)
				default:
					return
				}
				var port [2]byte
				if _, err := io.ReadFull(client, port[:]); err != nil {
					return
				}
				target, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(int(port[0])<<8|int(port[1]))), time.Second)
				if err != nil {
					return
				}
				defer target.Close()
				accepted.Add(1)
				if _, err := client.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 0}); err != nil {
					return
				}
				copied := make(chan struct{})
				go func() { _, _ = io.Copy(target, client); _ = target.Close(); close(copied) }()
				_, _ = io.Copy(client, target)
				_ = client.Close()
				<-copied
			}()
		}
	}()
	_, port, _ := net.SplitHostPort(server.Addr().String())
	raw, err := config.UnmarshalRawConfig([]byte(fmt.Sprintf(`mode: rule
log-level: silent
proxies:
  - name: Unselected
    type: socks5
    server: 127.0.0.1
    port: %s
proxy-groups:
  - name: Manual
    type: select
    proxies: [DIRECT, Unselected]
rules: ['MATCH,DIRECT']
`, port)))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	eng.mu.Lock()
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	watchRuntimeRoutes(cfg)
	resetProxyIdentities()
	eng.mu.Unlock()
	return &accepted
}

func TestDetachedURLTestUsesUnselectedSocksWithoutChangingSelection(t *testing.T) {
	fixture(t)
	accepted := disconnectedSocksFixture(t)
	if err := detachTun(); err != nil {
		t.Fatal(err)
	}
	var heads atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			heads.Add(1)
		}
		time.Sleep(3 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	response := requestDelay(t, "Unselected", "Manual", target.URL, 1000)
	if response.Code != http.StatusOK || accepted.Load() != 1 || heads.Load() != 1 {
		t.Fatalf("real URLTest failed: status=%d socks=%d heads=%d", response.Code, accepted.Load(), heads.Load())
	}
	group := tunnel.Proxies()["Manual"].Adapter().(outboundgroup.ProxyGroup)
	if group.Now() != "DIRECT" {
		t.Fatal("URLTest switched current selection")
	}
	if len(delaySlots) != 0 {
		t.Fatal("URLTest retained execution capacity")
	}
}

func TestDetachDoesNotCancelIndependentURLTest(t *testing.T) {
	fixture(t)
	disconnectedSocksFixture(t)
	entered := make(chan struct{})
	release := make(chan struct{})
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		select {
		case <-release:
			w.WriteHeader(http.StatusNoContent)
		case <-r.Context().Done():
		}
	}))
	defer target.Close()
	request := delayRequest(context.Background(), "Unselected", "Manual", target.URL, 2000)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { getDelay(response, request); close(done) }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("URLTest never reached target")
	}
	if err := detachTun(); err != nil {
		close(release)
		t.Fatal(err)
	}
	close(release)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("URLTest did not finish")
	}
	if response.Code != http.StatusOK {
		t.Fatalf("detach canceled URLTest: %d", response.Code)
	}
	if len(delaySlots) != 0 {
		t.Fatal("URLTest retained execution capacity")
	}
}
