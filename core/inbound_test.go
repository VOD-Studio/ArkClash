package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/tunnel/statistic"
	D "github.com/miekg/dns"
)

func inboundPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := l.Addr().(*net.TCPAddr).Port
	l.Close()
	return p
}

func inboundReachable(t *testing.T, port int, open bool) {
	t.Helper()
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
	if c != nil {
		c.Close()
	}
	if (err == nil) != open {
		t.Fatalf("port %d open=%v want=%v: %v", port, err == nil, open, err)
	}
}

func TestInboundDetachedAttachDetachAndReload(t *testing.T) {
	opts := lifecycleOptions(t)
	ports := []int{inboundPort(t), inboundPort(t), inboundPort(t), inboundPort(t), inboundPort(t)}
	profile := fmt.Sprintf(`%s
port: %d
mixed-port: %d
dns:
  enable: true
  enhanced-mode: fake-ip
  listen: 127.0.0.1:%d
  nameserver: [1.1.1.1]
listeners:
  - name: CustomHTTP
    type: http
    listen: 127.0.0.1
    port: %d
tunnels:
  - network: [tcp, udp]
    address: 127.0.0.1:%d
    target: 127.0.0.1:9
    proxy: DIRECT
`, lifecycleProfile, ports[0], ports[1], ports[2], ports[3], ports[4])
	opts.Profile = "inbound"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile, profile)
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hostTunStopError = nil; stop() })
	for _, p := range ports {
		inboundReachable(t, p, false)
	}
	if runtimeSnapshot.Load().ListenersOpen {
		t.Fatal("detached start exposed listeners")
	}
	mode, allow := "direct", true
	if err := setRuntimeOptions(&mode, &allow); err != nil {
		t.Fatal(err)
	}
	if !desiredInbound.inbound.AllowLan {
		t.Fatal("detached LAN setting lost")
	}
	if err := reload(opts.ConfigPath, opts.Profile, new(opts.Profile)); err != nil {
		t.Fatal(err)
	}
	for _, p := range ports {
		inboundReachable(t, p, false)
	}
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	for _, p := range ports {
		inboundReachable(t, p, true)
	}
	if !runtimeSnapshot.Load().ListenersOpen {
		t.Fatal("actual listeners not reported")
	}
	originalTun := tunListener
	query := new(D.Msg)
	query.SetQuestion("inbound-test.example.", D.TypeA)
	dnsClient := &D.Client{Net: "udp", Timeout: time.Second}
	if reply, _, err := dnsClient.Exchange(query, fmt.Sprintf("127.0.0.1:%d", ports[2])); err != nil || reply == nil || len(reply.Answer) == 0 {
		t.Fatalf("attached DNS query failed: %v", err)
	}
	if err := reload(opts.ConfigPath, opts.Profile, new(opts.Profile)); err != nil {
		t.Fatal(err)
	}
	if tunListener != originalTun {
		t.Fatal("connected reload replaced platform TUN")
	}
	for _, p := range ports {
		inboundReachable(t, p, true)
	}

	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := target.Accept()
		if err == nil {
			accepted <- c
		}
	}()
	c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", ports[1]))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target.Addr(), target.Addr())
	if err := c.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(c)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodConnect})
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("CONNECT failed: %v %v", response, err)
	}
	var upstream net.Conn
	select {
	case upstream = <-accepted:
	case <-time.After(2 * time.Second):
		t.Fatal("proxy did not dial local target")
	}
	defer upstream.Close()
	if err := upstream.SetWriteDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(upstream, "ready"); err != nil {
		t.Fatal(err)
	}
	var marker [5]byte
	if _, err := io.ReadFull(reader, marker[:]); err != nil || string(marker[:]) != "ready" {
		t.Fatalf("CONNECT did not forward target data: %q, %v", marker, err)
	}
	var trackerID string
	targetPort := uint16(target.Addr().(*net.TCPAddr).Port)
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		if tracker.Info().Metadata.DstPort != targetPort {
			return true
		}
		trackerID = tracker.ID()
		return false
	})
	if trackerID == "" {
		t.Fatal("live forwarded connection was not tracked")
	}
	mapper, service := resolver.DefaultHostMapper, resolver.DefaultService
	before := *runtimeSnapshot.Load()
	if err := detachTun(); err != nil {
		t.Fatal(err)
	}
	if statistic.DefaultManager.Get(trackerID) != nil {
		t.Fatal("forwarding tracker survived detach")
	}
	upstream.SetReadDeadline(time.Now().Add(time.Second))
	var b [1]byte
	if _, err := upstream.Read(b[:]); err == nil {
		t.Fatal("accepted forwarding connection survived detach")
	} else if e, ok := err.(net.Error); ok && e.Timeout() {
		t.Fatal("accepted connection was not closed")
	}
	for _, p := range ports {
		inboundReachable(t, p, false)
	}
	if resolver.DefaultHostMapper != mapper || resolver.DefaultService != service {
		t.Fatal("detach rebuilt resolver")
	}
	after := runtimeSnapshot.Load()
	if after.ListenersOpen || before.BootID != after.BootID || before.ConfigRevision != after.ConfigRevision {
		t.Fatal("detach changed core identity or leaked listeners")
	}
}

func TestInboundPartialAttachRollsBack(t *testing.T) {
	opts := lifecycleOptions(t)
	busy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	free := inboundPort(t)
	opts.Profile = "partial"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile, fmt.Sprintf("%s\nport: %d\nmixed-port: %d\n", lifecycleProfile, free, busy.Addr().(*net.TCPAddr).Port))
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stop() })
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err == nil {
		t.Fatal("partial bind failure accepted")
	}
	if tunListener != nil || businessListenersOpen() {
		t.Fatal("partial attach left resources open")
	}
	inboundReachable(t, free, false)
	if err := busy.Close(); err != nil {
		t.Fatal(err)
	}
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	if err := detachTun(); err != nil {
		t.Fatal(err)
	}
}
