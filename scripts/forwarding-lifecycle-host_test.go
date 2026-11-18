package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
)

func forwardingBlockedSocks(t *testing.T) (int, <-chan struct{}, <-chan struct{}) {
	t.Helper()
	server, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	entered, closed := make(chan struct{}, 8), make(chan struct{}, 8)
	accepted := make(chan struct{})
	var mu sync.Mutex
	clients := make(map[net.Conn]struct{})
	var workers sync.WaitGroup
	go func() {
		defer close(accepted)
		for {
			client, err := server.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			clients[client] = struct{}{}
			mu.Unlock()
			workers.Add(1)
			go func() {
				defer workers.Done()
				defer func() {
					_ = client.Close()
					mu.Lock()
					delete(clients, client)
					mu.Unlock()
				}()
				_ = client.SetDeadline(time.Now().Add(5 * time.Second))
				var greeting [2]byte
				if _, err := io.ReadFull(client, greeting[:]); err != nil || greeting[0] != 5 {
					return
				}
				if _, err := io.CopyN(io.Discard, client, int64(greeting[1])); err != nil {
					return
				}
				// 故意不回复认证协商：实际拨号尚未成为 statistic tracker。
				entered <- struct{}{}
				_, _ = io.Copy(io.Discard, client)
				closed <- struct{}{}
			}()
		}
	}()
	t.Cleanup(func() {
		_ = server.Close()
		<-accepted
		mu.Lock()
		for client := range clients {
			_ = client.Close()
		}
		mu.Unlock()
		workers.Wait()
	})
	return server.Addr().(*net.TCPAddr).Port, entered, closed
}

func forwardingCoreFixture(t *testing.T, socksPort int) (startOptions, []int) {
	t.Helper()
	options := lifecycleOptions(t)
	ports := []int{inboundPort(t), inboundPort(t), inboundPort(t), inboundPort(t), inboundPort(t)}
	profile := fmt.Sprintf(`mode: rule
log-level: silent
port: %d
mixed-port: %d
proxies:
  - name: Blocked
    type: socks5
    server: 127.0.0.1
    port: %d
    udp: true
listeners:
  - name: CustomHTTP
    type: http
    listen: 127.0.0.1
    port: %d
tunnels:
  - network: [tcp]
    address: 127.0.0.1:%d
    target: 127.0.0.1:9
    proxy: Blocked
  - network: [udp]
    address: 127.0.0.1:%d
    target: 127.0.0.1:9
    proxy: Blocked
rules: ['MATCH,Blocked']
`, ports[0], ports[1], socksPort, ports[2], ports[3], ports[4])
	options.Profile = "forwarding"
	options.ConfigPath = lifecycleWriteProfile(t, options, options.Profile, profile)
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = detachTun()
		mu.Lock()
		_ = updateVpnState("stopped", "stopped", false)
		mu.Unlock()
		_ = stop()
	})
	lifecycleVpnState(t, "started", "preparing", true)
	if err := attachTun(11, "gvisor", hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	lifecycleVpnState(t, "started", "running", true)
	return options, ports
}

func forwardingAwait(t *testing.T, signal <-chan struct{}, message string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(2 * time.Second):
		t.Fatal(message)
	}
}

func TestForwardingDetachCancelsAndJoinsPreTrackerDial(t *testing.T) {
	for _, protocol := range []string{"http", "tcp", "udp"} {
		t.Run(protocol, func(t *testing.T) {
			socksPort, entered, closed := forwardingBlockedSocks(t)
			_, ports := forwardingCoreFixture(t, socksPort)
			port := ports[0]
			network := "tcp"
			if protocol == "tcp" {
				port = ports[3]
			} else if protocol == "udp" {
				port, network = ports[4], "udp"
			}
			client, err := net.DialTimeout(network, fmt.Sprintf("127.0.0.1:%d", port), time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if protocol == "http" {
				_, err = io.WriteString(client, "CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n")
			} else {
				_, err = client.Write([]byte("forwarding-fixture"))
			}
			if err != nil {
				t.Fatal(err)
			}
			forwardingAwait(t, entered, "actual forwarding dial never reached SOCKS fixture")
			done := make(chan error, 1)
			go func() { done <- detachTun() }()
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("detach retained pre-tracker forwarding work")
			}
			forwardingAwait(t, closed, "detach returned before upstream handshake closed")
		})
	}
}

func TestForwardingDetachClosesAcceptedHandshakeSockets(t *testing.T) {
	socksPort, _, _ := forwardingBlockedSocks(t)
	_, ports := forwardingCoreFixture(t, socksPort)
	var clients []net.Conn
	for index, port := range ports[:3] {
		client, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		if index == 1 {
			_ = client.SetDeadline(time.Now().Add(time.Second))
			if _, err := client.Write([]byte{5, 1, 0}); err != nil {
				t.Fatal(err)
			}
			var response [2]byte
			if _, err := io.ReadFull(client, response[:]); err != nil || response != [2]byte{5, 0} {
				t.Fatalf("mixed listener did not enter accepted SOCKS handshake: %v", err)
			}
		}
		clients = append(clients, client)
	}
	if err := detachTun(); err != nil {
		t.Fatal(err)
	}
	for _, client := range clients {
		_ = client.SetReadDeadline(time.Now().Add(time.Second))
		if _, err := io.Copy(io.Discard, client); err != nil {
			if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
				t.Fatal("accepted handshake socket survived detach")
			}
		}
	}
}

func TestForwardingReloadJoinsOldDialBeforeReplacingConfig(t *testing.T) {
	socksPort, entered, closed := forwardingBlockedSocks(t)
	options, ports := forwardingCoreFixture(t, socksPort)
	client, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", ports[3]), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	forwardingAwait(t, entered, "old forwarding dial never reached SOCKS fixture")
	before := *runtimeSnapshot.Load()
	done := make(chan error, 1)
	go func() { done <- reload(options.ConfigPath, options.Profile, new(options.Profile)) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("reload retained an old forwarding dial")
	}
	forwardingAwait(t, closed, "reload returned with old upstream handshake still open")
	after := runtimeSnapshot.Load()
	if after.BootID != before.BootID || after.ConfigRevision != before.ConfigRevision+1 || !after.TunAttached {
		t.Fatal("forwarding quiescence rebuilt TUN or lost configuration identity")
	}
}

func TestLifecycleReloadCancelsOldConfigurationURLTest(t *testing.T) {
	options := lifecycleOptions(t)
	options.Profile = "delay-reload"
	options.ConfigPath = lifecycleWriteProfile(t, options, options.Profile, lifecycleProfile)
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	defer stop()
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	request := delayRequest(ctx, "DIRECT", "Manual", server.URL, 3000)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		getDelay(response, request)
		close(done)
	}()
	forwardingAwait(t, entered, "old configuration URLTest never reached target")
	if err := reload(options.ConfigPath, options.Profile, new(options.Profile)); err != nil {
		t.Fatal(err)
	}
	forwardingAwait(t, done, "reload did not cancel old configuration URLTest")
	if response.Code != http.StatusConflict {
		t.Fatalf("old configuration URLTest returned a usable result: %d", response.Code)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(activeDelayTests) != 0 || len(delaySlots) != 0 {
		t.Fatal("reloaded URLTest retained execution capacity")
	}
}
