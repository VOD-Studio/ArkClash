package main

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"weak"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/resource"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	mdns "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/quic-go"
	"github.com/metacubex/tls"
	D "github.com/miekg/dns"
)

func installProbeConfig(t *testing.T, text string) *config.Config {
	t.Helper()
	raw, err := config.UnmarshalRawConfig([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	stopRuntimeRoutes()
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	tunnel.UpdateRules(cfg.Rules, cfg.SubRules, cfg.RuleProviders)
	tunnel.SetMode(cfg.General.Mode)
	runtimeConfigRevision++
	watchRuntimeRoutes(cfg)
	publishRuntime()
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		stopRuntimeRoutes()
		mu.Unlock()
		for _, provider := range cfg.Providers {
			if closer, ok := provider.(interface{ Close() error }); ok {
				if err := closer.Close(); err != nil {
					t.Error(err)
				}
			}
		}
	})
	return cfg
}

func probeProxyConfig(t *testing.T, name, address string) string {
	t.Helper()
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("  - {name: %s, type: http, server: %s, port: %s}\n", name, host, port)
}

func receiveProbeSignal(t *testing.T, signal <-chan struct{}, label string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(2 * time.Second):
		t.Fatal(label)
	}
}

func blockingProbeProxy(t *testing.T) (string, <-chan struct{}, <-chan struct{}, *atomic.Int32) {
	t.Helper()
	entered := make(chan struct{}, 16)
	closed := make(chan struct{}, 16)
	var active atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, reader, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		active.Add(1)
		entered <- struct{}{}
		defer func() { _ = conn.Close(); active.Add(-1); closed <- struct{}{} }()
		_, _ = io.Copy(io.Discard, reader)
	}))
	t.Cleanup(server.Close)
	address, _ := url.Parse(server.URL)
	return address.Host, entered, closed, &active
}

func TestRuleProbeCancellationStopsActualDialBeforeReusingCapacity(t *testing.T) {
	fixture(t)
	address, entered, closed, active := blockingProbeProxy(t)
	installProbeConfig(t, "mode: rule\nlog-level: silent\nproxies:\n"+probeProxyConfig(t, "Slow", address)+"rules: ['MATCH,Slow']\n")
	for range 2 {
		var requests sync.WaitGroup
		cancels := make([]context.CancelFunc, 0, cap(probeSlots))
		for range cap(probeSlots) {
			ctx, cancel := context.WithCancel(context.Background())
			cancels = append(cancels, cancel)
			defer cancel()
			requests.Add(1)
			go func() {
				defer requests.Done()
				getProbe(httptest.NewRecorder(), probeRequest(ctx, "http://127.0.0.1:1/", http.MethodGet))
			}()
			receiveProbeSignal(t, entered, "actual proxy dial never entered CONNECT handshake")
		}
		rejected := httptest.NewRecorder()
		getProbe(rejected, probeRequest(context.Background(), "http://127.0.0.1:1/", http.MethodGet))
		if rejected.Code != http.StatusTooManyRequests || active.Load() != 4 {
			t.Fatalf("capacity=%d actual live handshakes=%d", rejected.Code, active.Load())
		}
		for _, cancel := range cancels {
			cancel()
		}
		done := make(chan struct{})
		go func() { requests.Wait(); close(done) }()
		receiveProbeSignal(t, done, "canceled probes retained slots")
		for range cap(probeSlots) {
			receiveProbeSignal(t, closed, "canceled actual outbound remained open")
		}
		if len(probeSlots) != 0 || active.Load() != 0 {
			t.Fatalf("slots=%d live handshakes=%d", len(probeSlots), active.Load())
		}
	}
}

func TestRuleFetchDeadlineClosesActualProxyHandshake(t *testing.T) {
	fixture(t)
	address, entered, closed, active := blockingProbeProxy(t)
	installProbeConfig(t, "mode: rule\nlog-level: silent\nproxies:\n"+probeProxyConfig(t, "Slow", address)+"rules: ['MATCH,Slow']\n")
	done := make(chan fetchResult, 1)
	go func() {
		done <- fetch(fetchRequest{URL: "http://127.0.0.1:1/subscription", Path: filepath.Join(current.HomeDir, "profiles", "download.yaml"), TimeoutMs: 100})
	}()
	receiveProbeSignal(t, entered, "fetch did not use the real rule-selected proxy")
	select {
	case result := <-done:
		if result.Error == "" {
			t.Fatalf("fetch deadline became success: %+v", result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fetch deadline failed to terminate its actual dial")
	}
	receiveProbeSignal(t, closed, "fetch left its outbound handshake alive")
	if active.Load() != 0 {
		t.Fatal("fetch retained outbound resources")
	}
}

func TestRuleDNSCancellationClosesQueryWithoutBackgroundRetry(t *testing.T) {
	fixture(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	entered, closed := make(chan struct{}, 8), make(chan struct{}, 8)
	var count atomic.Int32
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			count.Add(1)
			go func() {
				defer conn.Close()
				_, err := (&D.Conn{Conn: conn}).ReadMsg()
				if err != nil {
					return
				}
				entered <- struct{}{}
				_, _ = io.Copy(io.Discard, conn)
				closed <- struct{}{}
			}()
		}
	}()
	installProbeConfig(t, "mode: rule\nlog-level: silent\nrules: ['IP-CIDR,203.0.113.0/24,DIRECT', 'MATCH,REJECT']\n")
	previous := resolver.DefaultResolver
	previousIPv6 := resolver.DisableIPv6
	resolver.DisableIPv6 = true
	rs := mdns.NewResolver(mdns.Config{Main: []mdns.NameServer{{Net: "tcp", Addr: listener.Addr().String()}}})
	resolver.DefaultResolver = rs.Resolver
	defer func() {
		resolver.DefaultResolver = previous
		resolver.DisableIPv6 = previousIPv6
		rs.Resolver.ResetConnection()
	}()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		getProbe(httptest.NewRecorder(), probeRequest(ctx, "http://cancel-query.invalid/", http.MethodGet))
		close(done)
	}()
	receiveProbeSignal(t, entered, "IP rule did not resolve through the kernel DNS client")
	cancel()
	receiveProbeSignal(t, done, "canceled rule DNS kept the probe occupied")
	receiveProbeSignal(t, closed, "canceled rule DNS kept its TCP query alive")
	select {
	case <-entered:
		t.Fatal("canceling rule DNS started another background query")
	case <-time.After(100 * time.Millisecond):
	}
	if count.Load() != 1 || len(probeSlots) != 0 {
		t.Fatalf("DNS connections=%d probe slots=%d", count.Load(), len(probeSlots))
	}
}

type automaticProbePeer struct {
	unhealthy atomic.Bool
	entered   chan struct{}
	release   chan struct{}
	holdPath  string
	headers   chan http.Header
}

func automaticProbeProxy(t *testing.T, name string, peer *automaticProbePeer) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, reader, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		_, _ = reader.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		_ = reader.Flush()
		request, err := http.ReadRequest(reader.Reader)
		if err != nil {
			return
		}
		if request.URL.Path == "/health" {
			status := 204
			if peer.unhealthy.Load() {
				status = 503
			}
			if name == "B" {
				<-time.After(20 * time.Millisecond)
			}
			fmt.Fprintf(conn, "HTTP/1.1 %d fixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status)
			return
		}
		peer.headers <- request.Header
		peer.entered <- struct{}{}
		if peer.release != nil && (peer.holdPath == "" || request.URL.Path == peer.holdPath) {
			<-peer.release
		}
		fmt.Fprintf(conn, "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(name), name)
	}))
	t.Cleanup(server.Close)
	address, _ := url.Parse(server.URL)
	return probeProxyConfig(t, name, address.Host)
}

func awaitAutomaticProbeRoute(t *testing.T, group outboundgroup.ProxyGroup, name string, previous uint64) {
	t.Helper()
	timeout := time.NewTimer(12 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case text := <-runtimeEvents:
			var event struct {
				Type   string         `json:"type"`
				Status statusResponse `json:"status"`
			}
			watch := runtimeRoutes.Load()
			changes := watch.changes.Load()
			if json.Unmarshal([]byte(text), &event) == nil && event.Type == "runtime" && event.Status.Revision > previous && group.Now() == name && watch.changes.Load() == changes {
				return
			}
		case <-timeout.C:
			t.Fatal("real automatic route change did not push a newer runtime event")
		}
	}
}

func TestAutomaticHealthChangePushesRuntimeAndDiscardsOldProbe(t *testing.T) {
	for _, kind := range []string{"url-test", "fallback"} {
		t.Run(kind, func(t *testing.T) {
			fixture(t)
			a := &automaticProbePeer{entered: make(chan struct{}, 4), release: make(chan struct{}), holdPath: "/held", headers: make(chan http.Header, 4)}
			b := &automaticProbePeer{entered: make(chan struct{}, 4), headers: make(chan http.Header, 4)}
			var release sync.Once
			defer release.Do(func() { close(a.release) })
			text := "mode: rule\nlog-level: silent\nproxies:\n" + automaticProbeProxy(t, "A", a) + automaticProbeProxy(t, "B", b) + fmt.Sprintf("proxy-groups:\n  - name: Auto\n    type: %s\n    url: http://health.invalid/health\n    expected-status: '204'\n    interval: 0\n    proxies: [A, B]\nrules: ['MATCH,Auto']\n", kind)
			cacheStartedAt := time.Now()
			cfg := installProbeConfig(t, text)
			group := cfg.Proxies["Auto"].Adapter().(outboundgroup.ProxyGroup)
			for _, provider := range group.Providers() {
				provider.HealthCheck()
			}
			if group.Now() != "A" {
				t.Fatal("initial automatic route was not A")
			}
			if kind == "url-test" {
				// 使用上游真实十秒缓存，旧请求在到期前进入，保留五秒请求预算。
				<-time.After(7 * time.Second)
			}
			before := runtimeSnapshot.Load().Revision
			result := httptest.NewRecorder()
			done := make(chan struct{})
			go func() {
				getProbe(result, probeRequest(context.Background(), "http://probe.invalid/held", http.MethodGet))
				close(done)
			}()
			receiveProbeSignal(t, a.entered, "old probe did not use the initially selected actual route")
			a.unhealthy.Store(true)
			expected, err := utils.NewUnsignedRanges[uint16]("204")
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			_, _ = cfg.Proxies["A"].URLTest(ctx, "http://health.invalid/health", expected)
			cancel()
			if kind == "url-test" {
				<-time.After(100 * time.Millisecond)
				cached := httptest.NewRecorder()
				getProbe(cached, probeRequest(context.Background(), "http://probe.invalid/result", http.MethodGet))
				if group.Now() != "A" || cached.Code != http.StatusOK || !strings.Contains(cached.Body.String(), `"body":"A"`) || runtimeSnapshot.Load().Revision != before {
					t.Fatalf("health completion bypassed the real ten-second route cache: now=%s response=%d %s", group.Now(), cached.Code, cached.Body.String())
				}
			}
			awaitAutomaticProbeRoute(t, group, "B", before)
			if kind == "url-test" && time.Since(cacheStartedAt) < 10*time.Second {
				t.Fatal("automatic update committed before the real ten-second cache expired")
			}
			release.Do(func() { close(a.release) })
			receiveProbeSignal(t, done, "old automatic-route probe did not complete")
			if result.Code != http.StatusConflict || strings.Contains(result.Body.String(), `"body":"A"`) {
				t.Fatalf("obsolete route response=%d %s", result.Code, result.Body.String())
			}
			request := probeRequest(context.Background(), "http://probe.invalid/result", http.MethodGet)
			request.Header.Set("Authorization", "Bearer controller-secret")
			request.Header.Set("Cookie", "controller-session=private")
			fresh := httptest.NewRecorder()
			getProbe(fresh, request)
			headers := <-b.headers
			if fresh.Code != 200 || !strings.Contains(fresh.Body.String(), `"body":"B"`) || headers.Get("Authorization") != "" || headers.Get("Proxy-Authorization") != "" || headers.Get("Cookie") != "" {
				t.Fatalf("current route or credential isolation failed: response=%d %s", fresh.Code, fresh.Body.String())
			}
		})
	}
}

func TestOldConfigurationHealthCannotPublishIntoReplacement(t *testing.T) {
	old := fixture(t)
	installProbeConfig(t, "mode: direct\nlog-level: silent\nrules: ['MATCH,DIRECT']\n")
	before := runtimeSnapshot.Load()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, _ = old.Proxies["REJECT"].URLTest(ctx, "http://127.0.0.1:1/", nil)
	if after := runtimeSnapshot.Load(); after != before {
		t.Fatal("old configuration health callback changed the replacement runtime")
	}
}

func TestRuleProbeUsesKernelCertificateAuthority(t *testing.T) {
	fixture(t)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "trusted kernel CA") }))
	defer server.Close()
	certificate := server.TLS.Certificates[0].Certificate[0]
	if err := ca.AddCertificate(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate}))); err != nil {
		t.Fatal(err)
	}
	defer ca.ResetCertificate()
	result := httptest.NewRecorder()
	getProbe(result, probeRequest(context.Background(), server.URL, http.MethodGet))
	if result.Code != 200 || !strings.Contains(result.Body.String(), "trusted kernel CA") {
		t.Fatalf("kernel CA trust lost: %d %s", result.Code, result.Body.String())
	}
}

func TestRuleProbeDeadlineAndBodyLimitRemainConsumerErrors(t *testing.T) {
	fixture(t)
	address, entered, closed, _ := blockingProbeProxy(t)
	installProbeConfig(t, "mode: rule\nlog-level: silent\nproxies:\n"+probeProxyConfig(t, "Slow", address)+"rules: ['MATCH,Slow']\n")
	result := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		request := probeRequest(context.Background(), "http://127.0.0.1:1/", http.MethodHead)
		request.URL.RawQuery += "&timeout=" + strconv.Itoa(100)
		getProbe(result, request)
		close(done)
	}()
	receiveProbeSignal(t, entered, "deadline probe never entered its actual handshake")
	receiveProbeSignal(t, done, "deadline failed to end actual dialing")
	receiveProbeSignal(t, closed, "deadline failed to close actual dialing")
	if result.Code != http.StatusGatewayTimeout {
		t.Fatalf("timeout status=%d %s", result.Code, result.Body.String())
	}
	installProbeConfig(t, "mode: direct\nlog-level: silent\nrules: ['MATCH,DIRECT']\n")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, strings.Repeat("x", probeLimit+1))
	}))
	defer server.Close()
	result = httptest.NewRecorder()
	getProbe(result, probeRequest(context.Background(), server.URL, http.MethodGet))
	if result.Code != http.StatusServiceUnavailable {
		t.Fatalf("oversized response status=%d", result.Code)
	}
}

func awaitProbeCondition(t *testing.T, condition func() bool, label string) {
	t.Helper()
	deadline := time.NewTimer(4 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for !condition() {
		select {
		case <-deadline.C:
			t.Fatal(label)
		case <-tick.C:
		}
	}
}

func installRetiringProbeProvider(t *testing.T, vehicle P.Vehicle, parses *atomic.Int32) weak.Pointer[provider.ProxySetProvider] {
	t.Helper()
	parser := func(buf []byte) ([]C.Proxy, error) {
		var schema provider.ProxySchema
		if err := json.Unmarshal(buf, &schema); err != nil {
			return nil, err
		}
		proxies := make([]C.Proxy, 0, len(schema.Proxies))
		for _, mapping := range schema.Proxies {
			proxy, err := adapter.ParseProxy(mapping)
			if err != nil {
				return nil, err
			}
			proxies = append(proxies, proxy)
		}
		parses.Add(1)
		return proxies, nil
	}
	hc := provider.NewHealthCheck(nil, "", 1000, 0, true, nil)
	remote, err := provider.NewProxySetProvider("Retiring", 100*time.Millisecond, nil, parser, vehicle, hc)
	if err != nil {
		t.Fatal(err)
	}
	if err := remote.Initial(); err != nil {
		_ = remote.Close()
		t.Fatal(err)
	}
	raw, err := config.UnmarshalRawConfig([]byte("mode: rule\nlog-level: silent\nrules: ['MATCH,DIRECT']\n"))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	group, err := outboundgroup.NewFallback(outboundgroup.GroupCommonOption{Name: "Auto", URL: "http://health.invalid/health"}, outboundgroup.FallbackOption{}, cfg.Proxies["DIRECT"], []P.ProxyProvider{remote})
	if err != nil {
		t.Fatal(err)
	}
	cfg.Proxies["Auto"] = adapter.NewProxy(group)
	cfg.Providers["Retiring"] = remote
	mu.Lock()
	stopRuntimeRoutes()
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	tunnel.UpdateRules(cfg.Rules, cfg.SubRules, cfg.RuleProviders)
	tunnel.SetMode(cfg.General.Mode)
	runtimeConfigRevision++
	watchRuntimeRoutes(cfg)
	publishRuntime()
	mu.Unlock()
	return weak.Make(remote)
}

func TestHTTPAndFileProviderRetirementReleasesBackgroundResources(t *testing.T) {
	for _, kind := range []string{"http", "file"} {
		t.Run(kind, func(t *testing.T) {
			fixture(t)
			var requests, parses atomic.Int32
			var generation atomic.Int32
			generation.Store(1)
			payload := func() string {
				return fmt.Sprintf(`{"proxies":[{"name":"Remote%d","type":"direct"}]}`, generation.Load())
			}
			path := filepath.Join(current.HomeDir, "retiring.json")
			var vehicle P.Vehicle
			if kind == "http" {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					requests.Add(1)
					_, _ = io.WriteString(w, payload())
				}))
				defer server.Close()
				vehicle = resource.NewHTTPVehicle(server.URL, path, "DIRECT", nil, time.Second, 1<<20)
			} else {
				if err := os.WriteFile(path, []byte(payload()), 0600); err != nil {
					t.Fatal(err)
				}
				vehicle = resource.NewFileVehicle(path)
			}
			retired := installRetiringProbeProvider(t, vehicle, &parses)
			generation.Store(2)
			if kind == "file" {
				if err := os.WriteFile(path, []byte(payload()), 0600); err != nil {
					t.Fatal(err)
				}
			}
			awaitProbeCondition(t, func() bool { return parses.Load() >= 2 }, "live provider never consumed its real HTTP/File update")
			awaitProbeCondition(t, func() bool {
				return tunnel.Proxies()["Auto"].Adapter().(outboundgroup.ProxyGroup).Now() == "Remote2"
			}, "live provider update never reached the actual automatic group")
			installProbeConfig(t, "mode: direct\nlog-level: silent\nrules: ['MATCH,DIRECT']\n")
			awaitProbeCondition(t, func() bool { runtime.GC(); return retired.Value() == nil }, "retired provider wrapper remains strongly retained by its updater")
			// 等 finalizer 和已有回调退出后，真实拉取/文件监听都应保持静止。
			<-time.After(300 * time.Millisecond)
			beforeRequests, beforeParses := requests.Load(), parses.Load()
			beforeRuntime := runtimeSnapshot.Load()
			generation.Store(3)
			if kind == "file" {
				if err := os.WriteFile(path, []byte(payload()), 0600); err != nil {
					t.Fatal(err)
				}
			}
			<-time.After(500 * time.Millisecond)
			if requests.Load() != beforeRequests || parses.Load() != beforeParses || runtimeSnapshot.Load() != beforeRuntime {
				t.Fatalf("retired provider remained active: HTTP %d→%d parses %d→%d", beforeRequests, requests.Load(), beforeParses, parses.Load())
			}
		})
	}
}

type isolatedProbeDNSQuery struct {
	name       string
	connection string
	protocol   string
	done       <-chan struct{}
}

func probeDNSReply(query *D.Msg) *D.Msg {
	reply := new(D.Msg)
	reply.SetReply(query)
	reply.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: query.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.IPv4(203, 0, 113, 1)}}
	return reply
}

func isolatedProbeDNSServer(t *testing.T, kind string, queries chan<- isolatedProbeDNSQuery, release <-chan struct{}) mdns.NameServer {
	t.Helper()
	handle := func(ctx context.Context, connection, protocol string, query *D.Msg) *D.Msg {
		name := query.Question[0].Name
		queries <- isolatedProbeDNSQuery{name: name, connection: connection, protocol: protocol, done: ctx.Done()}
		switch name {
		case "cancel-query.invalid.":
			<-ctx.Done()
			return nil
		case "ordinary-query.invalid.":
			select {
			case <-ctx.Done():
				return nil
			case <-release:
			}
		}
		return probeDNSReply(query)
	}
	if kind == "doh" {
		server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			data, err := base64.RawURLEncoding.DecodeString(r.URL.Query().Get("dns"))
			if err != nil {
				return
			}
			query := new(D.Msg)
			if err := query.Unpack(data); err != nil {
				t.Error(err)
				return
			}
			if reply := handle(r.Context(), r.RemoteAddr, r.Proto, query); reply != nil {
				data, err := reply.Pack()
				if err != nil {
					t.Error(err)
					return
				}
				w.Header().Set("Content-Type", "application/dns-message")
				_, _ = w.Write(data)
			}
		}))
		server.EnableHTTP2 = true
		server.StartTLS()
		t.Cleanup(server.Close)
		return mdns.NameServer{Net: "https", Addr: server.URL + "/dns-query", Params: map[string]string{"skip-cert-verify": "true"}}
	}
	certificateServer := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	certificates := certificateServer.TLS.Certificates
	certificateServer.Close()
	listener, err := quic.ListenAddr("127.0.0.1:0", &tls.Config{Certificates: certificates, NextProtos: []string{mdns.NextProtoDQ}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	var connections sync.Map
	t.Cleanup(func() {
		cancel()
		_ = listener.Close()
		connections.Range(func(key, value any) bool {
			_ = key.(*quic.Conn).CloseWithError(0, "")
			return true
		})
	})
	go func() {
		for {
			conn, err := listener.Accept(ctx)
			if err != nil {
				return
			}
			connections.Store(conn, struct{}{})
			go func() {
				for {
					stream, err := conn.AcceptStream(ctx)
					if err != nil {
						return
					}
					go func() {
						var size uint16
						if binary.Read(stream, binary.BigEndian, &size) != nil {
							return
						}
						data := make([]byte, size)
						if _, err := io.ReadFull(stream, data); err != nil {
							return
						}
						query := new(D.Msg)
						if err := query.Unpack(data); err != nil {
							t.Error(err)
							return
						}
						if reply := handle(conn.Context(), conn.RemoteAddr().String(), "doq", query); reply != nil {
							data, err := reply.Pack()
							if err != nil {
								t.Error(err)
								return
							}
							_ = binary.Write(stream, binary.BigEndian, uint16(len(data)))
							_, _ = stream.Write(data)
							_ = stream.Close()
						}
					}()
				}
			}()
		}
	}()
	return mdns.NameServer{Net: "quic", Addr: listener.Addr().String(), Params: map[string]string{"skip-cert-verify": "true"}}
}

func TestProbeCancellationKeepsConcurrentOrdinaryDoHAndDoQAlive(t *testing.T) {
	for _, kind := range []string{"doh", "doq"} {
		for _, order := range []string{"probe-first", "ordinary-first"} {
			t.Run(kind+"/"+order, func(t *testing.T) {
				fixture(t)
				installProbeConfig(t, "mode: rule\nlog-level: silent\nrules: ['IP-CIDR,203.0.113.0/24,DIRECT', 'MATCH,REJECT']\n")
				queries := make(chan isolatedProbeDNSQuery, 16)
				release := make(chan struct{})
				var releaseOnce sync.Once
				defer releaseOnce.Do(func() { close(release) })
				nameserver := isolatedProbeDNSServer(t, kind, queries, release)
				rs := mdns.NewResolver(mdns.Config{Main: []mdns.NameServer{nameserver}})
				previous, previousIPv6 := resolver.DefaultResolver, resolver.DisableIPv6
				resolver.DefaultResolver, resolver.DisableIPv6 = rs.Resolver, true
				defer func() {
					resolver.DefaultResolver, resolver.DisableIPv6 = previous, previousIPv6
					rs.Resolver.ResetConnection()
				}()
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				probeDone := make(chan struct{})
				ordinaryDone := make(chan error, 1)
				startProbe := func() {
					go func() {
						getProbe(httptest.NewRecorder(), probeRequest(ctx, "http://cancel-query.invalid/", http.MethodGet))
						close(probeDone)
					}()
				}
				startOrdinary := func() {
					go func() {
						query := new(D.Msg)
						query.SetQuestion("ordinary-query.invalid.", D.TypeA)
						ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
						defer cancel()
						reply, err := rs.Resolver.ExchangeContext(ctx, query)
						if err == nil && (reply == nil || len(reply.Answer) != 1) {
							err = fmt.Errorf("ordinary DNS returned no real answer")
						}
						ordinaryDone <- err
					}()
				}
				receive := func() isolatedProbeDNSQuery {
					select {
					case query := <-queries:
						return query
					case <-time.After(2 * time.Second):
						t.Fatal("real DNS transport did not receive query")
						return isolatedProbeDNSQuery{}
					}
				}
				var probe, ordinary isolatedProbeDNSQuery
				if order == "probe-first" {
					startProbe()
					probe = receive()
					startOrdinary()
					ordinary = receive()
				} else {
					startOrdinary()
					ordinary = receive()
					startProbe()
					probe = receive()
				}
				if probe.name != "cancel-query.invalid." || ordinary.name != "ordinary-query.invalid." || probe.connection == ordinary.connection || (kind == "doh" && (probe.protocol != "HTTP/2.0" || ordinary.protocol != "HTTP/2.0")) {
					t.Fatalf("probe reused ordinary DNS pool: probe=%+v ordinary=%+v", probe, ordinary)
				}
				cancel()
				receiveProbeSignal(t, probeDone, "probe canceled but retained actual DNS work/capacity")
				if len(probeSlots) != 0 {
					t.Fatal("canceled DNS retained its probe slot")
				}
				select {
				case <-ordinary.done:
					t.Fatal("probe cancellation closed the ordinary DNS request/connection")
				case err := <-ordinaryDone:
					t.Fatalf("ordinary DNS ended before its server release: %v", err)
				default:
				}
				releaseOnce.Do(func() { close(release) })
				select {
				case err := <-ordinaryDone:
					if err != nil {
						t.Fatal(err)
					}
				case <-time.After(2 * time.Second):
					t.Fatal("ordinary DNS did not survive concurrent probe cancellation")
				}
				query := new(D.Msg)
				query.SetQuestion("ordinary-next.invalid.", D.TypeA)
				checkCtx, checkCancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer checkCancel()
				if reply, err := rs.Resolver.ExchangeContext(checkCtx, query); err != nil || reply == nil || len(reply.Answer) != 1 {
					t.Fatalf("ordinary DNS pool failed after probe finish: reply=%v err=%v", reply, err)
				}
				next := receive()
				if next.name != "ordinary-next.invalid." || next.connection != ordinary.connection {
					t.Fatalf("ordinary DNS transport was replaced after probe finish: old=%+v next=%+v", ordinary, next)
				}
				select {
				case extra := <-queries:
					t.Fatalf("canceling probe started background DNS work: %+v", extra)
				case <-time.After(100 * time.Millisecond):
				}
			})
		}
	}
}
