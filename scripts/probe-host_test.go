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
	"regexp"
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
	mu.Lock()
	stopRuntimeRoutes()
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		mu.Unlock()
		t.Fatal(err)
	}
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
				postProbe(httptest.NewRecorder(), probeRequest(ctx, "http://127.0.0.1:1/", http.MethodGet))
			}()
			receiveProbeSignal(t, entered, "actual proxy dial never entered CONNECT handshake")
		}
		rejected := httptest.NewRecorder()
		postProbe(rejected, probeRequest(context.Background(), "http://127.0.0.1:1/", http.MethodGet))
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

func TestSubscriptionFetchUsesForwardingState(t *testing.T) {
	fixture(t)
	installProbeConfig(t, "mode: rule\nlog-level: silent\nrules: ['MATCH,REJECT']\n")
	setForward := func(forward string) {
		t.Helper()
		mu.Lock()
		defer mu.Unlock()
		intent := "started"
		tunListener = nil
		if forward == "stopped" {
			intent = "stopped"
		} else if forward == "running" {
			fd := 1
			tunListener = &fd
		}
		if err := updateVpnState(intent, forward, tunListener != nil); err != nil {
			t.Fatal(err)
		}
	}

	const content = "proxies: []\n"
	entered, release := make(chan struct{}), make(chan struct{})
	unblock := sync.OnceFunc(func() { close(release) })
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/pending" {
			close(entered)
			<-release
		} else {
			mu.Lock()
			publishRuntime()
			mu.Unlock()
		}
		_, _ = io.WriteString(w, content)
	}))
	defer server.Close()
	defer unblock()
	key := ""
	for _, tc := range []struct {
		name    string
		forward string
		key     *string
		success bool
	}{
		{"standby", "stopped", &key, true},
		{"paused", "paused", &key, true},
		{"forwarding", "running", &key, false},
		{"preparing", "preparing", &key, false},
		{"raw resource in standby", "stopped", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			setForward(tc.forward)
			target := filepath.Join(current.HomeDir, "profiles", tc.name+".yaml")
			got := fetch(fetchRequest{URL: server.URL, Path: target, AgeSecretKey: tc.key, TimeoutMs: 1000})
			data, err := os.ReadFile(target)
			if tc.success {
				if got.Error != "" || got.Status != http.StatusOK || err != nil || string(data) != content {
					t.Fatalf("direct download: status=%d error=%q file=%v", got.Status, got.Error, err)
				}
			} else if got.Error == "" || !os.IsNotExist(err) {
				t.Fatalf("unexpected download: %+v file=%v", got, err)
			}
			if tunnel.Mode().String() != "rule" {
				t.Fatal("subscription changed the global mode")
			}
		})
	}

	setForward("stopped")
	target := filepath.Join(current.HomeDir, "profiles", "pending.yaml")
	done := make(chan fetchResult, 1)
	go func() {
		done <- fetch(fetchRequest{URL: server.URL + "/pending", Path: target, AgeSecretKey: &key})
	}()
	receiveProbeSignal(t, entered, "pending direct request never reached the origin")
	setForward("running")
	setForward("stopped")
	unblock()
	if got := <-done; got.Error != "canceled" {
		t.Fatalf("stale direct download: %+v", got)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("stale candidate remained: %v", err)
	}
}

func TestSubscriptionSlowTLSUsesRequestDeadline(t *testing.T) {
	fixture(t)
	installProbeConfig(t, "mode: rule\nlog-level: silent\nrules: ['MATCH,DIRECT']\n")
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "proxies: []\n")
	}))
	server.TLS = &tls.Config{GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) {
		time.Sleep(5200 * time.Millisecond)
		return nil, nil
	}}
	server.StartTLS()
	defer server.Close()
	if err := ca.AddCertificate(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}))); err != nil {
		t.Fatal(err)
	}
	defer ca.ResetCertificate()
	key := ""
	target := filepath.Join(current.HomeDir, "profiles", "slow-tls.yaml")
	got := fetch(fetchRequest{URL: server.URL, Path: target, AgeSecretKey: &key, TimeoutMs: 9000})
	if got.Status != http.StatusOK || got.Error != "" {
		t.Fatalf("subscription handshake within the request deadline: %+v", got)
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
		postProbe(httptest.NewRecorder(), probeRequest(ctx, "http://cancel-query.invalid/", http.MethodGet))
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
				postProbe(result, probeRequest(context.Background(), "http://probe.invalid/held", http.MethodGet))
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
				postProbe(cached, probeRequest(context.Background(), "http://probe.invalid/result", http.MethodGet))
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
			postProbe(fresh, request)
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

func decodeProbeReply(t *testing.T, recorder *httptest.ResponseRecorder) probeResponse {
	t.Helper()
	if recorder.Code != http.StatusOK {
		t.Fatalf("probe failed: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var result probeResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestRuleProbeSendsServiceMethodHeadersAndBody(t *testing.T) {
	fixture(t)
	for _, test := range []struct {
		method string
		mode   string
		body   string
	}{
		{http.MethodGet, "small", ""},
		{http.MethodPost, "json", "client_id=public-client&grant_type=client_credentials"},
		{http.MethodHead, "none", ""},
	} {
		t.Run(test.method, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, err := io.ReadAll(r.Body)
				if err != nil || r.Method != test.method || string(body) != test.body ||
					r.Header.Get("User-Agent") != "Mozilla/5.0 ProbeHost" || r.Header.Get("Accept") != "application/json" ||
					r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" || r.Header.Get("Authorization") != "Bearer public-client" ||
					r.Header.Get("Cookie") != "" || r.Header.Get("Proxy-Authorization") != "" {
					t.Error("service request method, body or credential isolation changed")
					w.WriteHeader(http.StatusMethodNotAllowed)
					return
				}
				_, _ = io.WriteString(w, `{"region":"JP"}`)
			}))
			defer server.Close()
			request := probeRequestWithOptions(context.Background(), probeRequestBody{
				URL: server.URL + "/service", Method: test.method, BodyMode: test.mode, Body: test.body, Timeout: 10000,
				Headers: map[string]string{"user-agent": "Mozilla/5.0 ProbeHost", "aCcEpT": "application/json",
					"content-type": "application/x-www-form-urlencoded", "authorization": "Bearer public-client"},
			})
			request.Header.Set("Authorization", "Bearer controller-secret")
			request.Header.Set("Cookie", "controller-cookie")
			request.Header.Set("Proxy-Authorization", "controller-proxy-secret")
			recorder := httptest.NewRecorder()
			postProbe(recorder, request)
			result := decodeProbeReply(t, recorder)
			wantBody := `{"region":"JP"}`
			if test.method == http.MethodHead {
				wantBody = ""
			}
			if result.Status != http.StatusOK || result.Body != wantBody || result.URL != server.URL+"/service" || result.Delay < 0 {
				t.Fatalf("service response=%+v", result)
			}
		})
	}
}

func TestRuleProbeRedirectControlsPreserveFinalURLAndIsolateAuthorization(t *testing.T) {
	fixture(t)
	var source *httptest.Server
	var finalCalls atomic.Int32
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			t.Error("target Authorization crossed an origin boundary")
		}
		if r.URL.Path == "/relay" {
			w.Header().Set("Location", "/return")
		} else {
			w.Header().Set("Location", source.URL+"/returned")
		}
		w.WriteHeader(http.StatusFound)
	}))
	defer destination.Close()
	source = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/same":
			w.Header().Set("Location", "/final")
			w.WriteHeader(http.StatusFound)
			_, _ = io.WriteString(w, "redirect body")
		case "/cross":
			w.Header().Set("Location", destination.URL+"/relay")
			w.WriteHeader(http.StatusFound)
		case "/returned":
			if r.Header.Get("Authorization") != "" {
				t.Error("redirect restored Authorization after crossing an origin")
			}
			_, _ = io.WriteString(w, "returned")
		case "/final":
			finalCalls.Add(1)
			if r.Header.Get("Authorization") != "Bearer public-client" {
				t.Error("same-origin redirect dropped target Authorization")
			}
			_, _ = io.WriteString(w, "final")
		}
	}))
	defer source.Close()
	for _, test := range []struct {
		name       string
		path       string
		noRedirect bool
		status     int
		body       string
		finalPath  string
		location   string
	}{
		{"controlled", "/same", true, http.StatusFound, "redirect body", "/same", "/final"},
		{"same origin", "/same", false, http.StatusOK, "final", "/final", ""},
		{"different port and return", "/cross", false, http.StatusOK, "returned", "/returned", ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			postProbe(recorder, probeRequestWithOptions(context.Background(), probeRequestBody{
				URL: source.URL + test.path, Method: http.MethodGet, BodyMode: "small", Timeout: 5000,
				NoRedirect: test.noRedirect, Headers: map[string]string{"Authorization": "Bearer public-client"},
			}))
			result := decodeProbeReply(t, recorder)
			if result.Status != test.status || result.Body != test.body || result.URL != source.URL+test.finalPath || result.Location != test.location {
				t.Fatalf("redirect response=%+v", result)
			}
			if test.noRedirect && finalCalls.Load() != 0 {
				t.Fatal("controlled redirect reached its destination")
			}
		})
	}
	var redirects atomic.Int32
	loop := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirects.Add(1)
		hop, _ := strconv.Atoi(r.URL.Query().Get("hop"))
		w.Header().Set("Location", "?hop="+strconv.Itoa(hop+1))
		w.WriteHeader(http.StatusFound)
	}))
	defer loop.Close()
	recorder := httptest.NewRecorder()
	postProbe(recorder, probeRequest(context.Background(), loop.URL, http.MethodGet))
	if recorder.Code != http.StatusServiceUnavailable || redirects.Load() != 10 {
		t.Fatalf("redirect loop status=%d requests=%d", recorder.Code, redirects.Load())
	}
}

func TestRuleProbeLargeServicePagesReturnBoundedPrefixes(t *testing.T) {
	fixture(t)
	page := "<html><body>" + strings.Repeat("x", 70<<10) + `<script>{"region":"JP"}</script>` + strings.Repeat("y", 600<<10) + "</body></html>"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, page) }))
	defer server.Close()
	for _, test := range []struct {
		mode  string
		limit int
	}{{"small", 16 << 10}, {"html", 512 << 10}} {
		t.Run(test.mode, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			postProbe(recorder, probeRequestWithOptions(context.Background(), probeRequestBody{
				URL: server.URL, Method: http.MethodGet, BodyMode: test.mode, Timeout: 5000,
			}))
			result := decodeProbeReply(t, recorder)
			if result.Status != http.StatusOK || result.Body != page[:test.limit] {
				t.Fatalf("%s prefix status=%d bytes=%d", test.mode, result.Status, len(result.Body))
			}
			if test.mode == "html" && !strings.Contains(result.Body, `"region":"JP"`) {
				t.Fatal("HTML service evidence beyond 64 KiB was lost")
			}
		})
	}
}

func TestRuleProbeScanJoinsChunksAndStopsAtFirstServiceEvidence(t *testing.T) {
	fixture(t)
	for _, test := range []struct {
		name     string
		pattern  string
		fragment string
	}{
		{"Gemini", `,2,1,200,"[A-Z]{3}`, `,2,1,200,"USA`},
		{"Prime", `isServiceRestricted|"currentTerritory":"[^"]+"`, `"currentTerritory":"JP"`},
		{"TikTok", `"webapp\.app-context"\s*:\s*\{[^{}]*?"region"\s*:\s*"[^"]*"`, `"webapp.app-context": {"lang":"en","region":"GB"`},
	} {
		t.Run(test.name, func(t *testing.T) {
			prefixSent := make(chan struct{})
			release := make(chan struct{})
			closed := make(chan struct{})
			var releaseOnce sync.Once
			defer releaseOnce.Do(func() { close(release) })
			split := len(test.fragment) / 2
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer close(closed)
				_, _ = io.WriteString(w, strings.Repeat("x", (32<<10)-split)+test.fragment[:split])
				w.(http.Flusher).Flush()
				close(prefixSent)
				select {
				case <-release:
				case <-r.Context().Done():
					return
				}
				_, _ = io.WriteString(w, test.fragment[split:]+strings.Repeat("z", 32<<10)+test.fragment)
				w.(http.Flusher).Flush()
				<-r.Context().Done()
			}))
			defer server.Close()
			recorder := httptest.NewRecorder()
			done := make(chan struct{})
			go func() {
				postProbe(recorder, probeRequestWithOptions(context.Background(), probeRequestBody{
					URL: server.URL, Method: http.MethodGet, BodyMode: "scan", ScanPattern: test.pattern, Timeout: 2000,
				}))
				close(done)
			}()
			receiveProbeSignal(t, prefixSent, "scan target did not stream its first chunk")
			releaseOnce.Do(func() { close(release) })
			receiveProbeSignal(t, done, "scan waited for the unfinished page after finding service evidence")
			result := decodeProbeReply(t, recorder)
			if !strings.HasPrefix(result.Body, test.fragment) || len(result.Body) > probeScanChunk+probeScanOverlap {
				t.Fatalf("scan returned invalid evidence window of %d bytes", len(result.Body))
			}
			receiveProbeSignal(t, closed, "scan left the rest of the target page downloading")
		})
	}
}

func TestProbeScanPreservesRestrictionAfterRegionInSameWindow(t *testing.T) {
	for _, sample := range []struct {
		body, pattern, restriction string
	}{
		{`{"currentTerritory":"US","isServiceRestricted":true}`,
			`isServiceRestricted|"currentTerritory":"[^"]+"`, "isServiceRestricted"},
		{`{"webapp.app-context":{"region":"US"}} Access Denied`,
			`"webapp\.app-context"\s*:\s*\{[^{}]*?"region"\s*:\s*"[^"]*"|Access Denied`, "Access Denied"},
	} {
		body, err := scanProbeBody(strings.NewReader(sample.body), regexp.MustCompile(sample.pattern))
		if err != nil || !strings.Contains(body, sample.restriction) {
			t.Fatalf("restriction was discarded after region evidence: %q, %v", body, err)
		}
	}
}

func TestRuleProbeDoesNotReplayPostBodyAcrossOrigins(t *testing.T) {
	fixture(t)
	var destinationCalls atomic.Int32
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		destinationCalls.Add(1)
	}))
	defer destination.Close()
	for _, code := range []int{http.StatusTemporaryRedirect, http.StatusPermanentRedirect} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			var sameOriginCalls atomic.Int32
			source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/start" {
					w.Header().Set("Location", "/relay")
				} else {
					body, _ := io.ReadAll(r.Body)
					if r.Method != http.MethodPost || string(body) != "refresh_token=private-fixture" {
						t.Error("same-origin redirect lost the POST body")
					}
					sameOriginCalls.Add(1)
					w.Header().Set("Location", destination.URL)
				}
				w.WriteHeader(code)
			}))
			defer source.Close()
			recorder := httptest.NewRecorder()
			postProbe(recorder, probeRequestWithOptions(context.Background(), probeRequestBody{
				URL: source.URL + "/start", Method: http.MethodPost, BodyMode: "small",
				Body: "refresh_token=private-fixture", Timeout: 5000,
			}))
			result := decodeProbeReply(t, recorder)
			if result.Status != code || result.URL != source.URL+"/relay" ||
				sameOriginCalls.Load() != 1 || destinationCalls.Load() != 0 {
				t.Fatalf("unsafe POST replay: status=%d same=%d cross=%d",
					result.Status, sameOriginCalls.Load(), destinationCalls.Load())
			}
		})
	}
}

func TestRuleProbeScanStopsAtNetworkBudgetWithoutReadingPastIt(t *testing.T) {
	fixture(t)
	closed := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(closed)
		chunk := strings.Repeat("x", 32<<10)
		for range (8 << 20) / len(chunk) {
			if _, err := io.WriteString(w, chunk); err != nil {
				return
			}
		}
		_, _ = io.WriteString(w, `,2,1,200,"USA`)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	recorder := httptest.NewRecorder()
	postProbe(recorder, probeRequestWithOptions(context.Background(), probeRequestBody{
		URL: server.URL, Method: http.MethodGet, BodyMode: "scan", ScanPattern: `,2,1,200,"[A-Z]{3}`, Timeout: 5000,
	}))
	result := decodeProbeReply(t, recorder)
	if result.Body != "" {
		t.Fatal("scan consumed service evidence after its 8 MiB network budget")
	}
	receiveProbeSignal(t, closed, "scan kept its target alive after exhausting the network budget")
}

func TestRuleProbeNoneDoesNotReadBodyAndDelayEndsAtResponseHeaders(t *testing.T) {
	fixture(t)
	closed := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(closed)
		w.WriteHeader(http.StatusForbidden)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	recorder := httptest.NewRecorder()
	postProbe(recorder, probeRequestWithOptions(context.Background(), probeRequestBody{
		URL: server.URL, Method: http.MethodGet, BodyMode: "none", Timeout: 1000,
	}))
	result := decodeProbeReply(t, recorder)
	if result.Status != http.StatusForbidden || result.Body != "" {
		t.Fatalf("target 403 became a controller failure or body read: %+v", result)
	}
	receiveProbeSignal(t, closed, "none body mode retained the target connection")
	headersSent := make(chan struct{})
	release := make(chan struct{})
	var releaseOnce sync.Once
	defer releaseOnce.Do(func() { close(release) })
	slowBody := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		close(headersSent)
		select {
		case <-release:
			_, _ = io.WriteString(w, "ready")
		case <-r.Context().Done():
		}
	}))
	defer slowBody.Close()
	recorder = httptest.NewRecorder()
	done := make(chan struct{})
	started := time.Now()
	go func() {
		postProbe(recorder, probeRequest(context.Background(), slowBody.URL, http.MethodGet))
		close(done)
	}()
	receiveProbeSignal(t, headersSent, "RTT target did not send headers")
	<-time.After(200 * time.Millisecond)
	held := time.Since(started).Milliseconds()
	releaseOnce.Do(func() { close(release) })
	receiveProbeSignal(t, done, "RTT request did not finish after releasing the body")
	result = decodeProbeReply(t, recorder)
	if result.Body != "ready" || result.Delay < 0 || result.Delay >= held-50 {
		t.Fatalf("response body wait was included in header RTT: delay=%d held=%d", result.Delay, held)
	}
}

func TestRuleProbeRejectsUnsafeOrUnboundedProtocolInputsBeforeDial(t *testing.T) {
	fixture(t)
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1) }))
	defer server.Close()
	for _, test := range []struct {
		name   string
		change func(*probeRequestBody)
	}{
		{"URL credentials", func(p *probeRequestBody) { p.URL = strings.Replace(server.URL, "://", "://user:password@", 1) }},
		{"long URL", func(p *probeRequestBody) { p.URL = server.URL + "/" + strings.Repeat("x", 2048) }},
		{"URL scheme", func(p *probeRequestBody) { p.URL = "file:///tmp/service" }},
		{"method", func(p *probeRequestBody) { p.Method = http.MethodPut }},
		{"timeout zero", func(p *probeRequestBody) { p.Timeout = 0 }},
		{"timeout over budget", func(p *probeRequestBody) { p.Timeout = 10001 }},
		{"target body", func(p *probeRequestBody) { p.Body = strings.Repeat("x", 8193) }},
		{"controller-sized headers", func(p *probeRequestBody) { p.Headers = map[string]string{"Accept": strings.Repeat("x", 16<<10)} }},
		{"cookie", func(p *probeRequestBody) { p.Headers = map[string]string{"Cookie": "session=fixture"} }},
		{"proxy authorization", func(p *probeRequestBody) { p.Headers = map[string]string{"Proxy-Authorization": "Bearer fixture"} }},
		{"host override", func(p *probeRequestBody) { p.Headers = map[string]string{"Host": "other.invalid"} }},
		{"header injection", func(p *probeRequestBody) { p.Headers = map[string]string{"Authorization": "Bearer fixture\r\nCookie: injected"} }},
		{"body mode", func(p *probeRequestBody) { p.BodyMode = "unlimited" }},
		{"pattern on HTML", func(p *probeRequestBody) { p.BodyMode = "html"; p.ScanPattern = "region" }},
		{"missing scan pattern", func(p *probeRequestBody) { p.BodyMode = "scan" }},
		{"invalid pattern", func(p *probeRequestBody) { p.BodyMode = "scan"; p.ScanPattern = "[" }},
		{"lookahead", func(p *probeRequestBody) { p.BodyMode = "scan"; p.ScanPattern = "region(?=US)" }},
		{"backreference", func(p *probeRequestBody) { p.BodyMode = "scan"; p.ScanPattern = `(US)\1` }},
		{"long pattern", func(p *probeRequestBody) { p.BodyMode = "scan"; p.ScanPattern = strings.Repeat("x", 513) }},
	} {
		t.Run(test.name, func(t *testing.T) {
			options := probeRequestBody{URL: server.URL, Method: http.MethodGet, BodyMode: "none", Timeout: 5000}
			test.change(&options)
			recorder := httptest.NewRecorder()
			postProbe(recorder, probeRequestWithOptions(context.Background(), options))
			if recorder.Code != http.StatusBadRequest {
				t.Fatalf("invalid protocol request became status=%d", recorder.Code)
			}
		})
	}
	valid, _ := json.Marshal(probeRequestBody{URL: server.URL, Method: http.MethodGet, BodyMode: "none", Timeout: 5000})
	for _, body := range []string{string(valid) + `{}`, strings.TrimSuffix(string(valid), "}") + `,"unexpected":true}`, strings.Repeat(" ", 16<<10) + string(valid)} {
		recorder := httptest.NewRecorder()
		postProbe(recorder, httptest.NewRequest(http.MethodPost, "/arkclash/probe", strings.NewReader(body)))
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("invalid JSON envelope became status=%d", recorder.Code)
		}
	}
	recorder := httptest.NewRecorder()
	postProbe(recorder, httptest.NewRequest(http.MethodGet, "/arkclash/probe?url="+url.QueryEscape(server.URL), nil))
	if recorder.Code != http.StatusMethodNotAllowed || calls.Load() != 0 || len(probeSlots) != 0 {
		t.Fatalf("legacy GET or invalid request dialed the target: status=%d calls=%d slots=%d", recorder.Code, calls.Load(), len(probeSlots))
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
	postProbe(result, probeRequest(context.Background(), server.URL, http.MethodGet))
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
		request := probeRequestWithOptions(context.Background(), probeRequestBody{
			URL: "http://127.0.0.1:1/", Method: http.MethodHead, BodyMode: "none", Timeout: 100,
		})
		postProbe(result, request)
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
		_, _ = io.WriteString(w, strings.Repeat("x", probeJSONLimit+1))
	}))
	defer server.Close()
	result = httptest.NewRecorder()
	postProbe(result, probeRequest(context.Background(), server.URL, http.MethodGet))
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
						postProbe(httptest.NewRecorder(), probeRequest(ctx, "http://cancel-query.invalid/", http.MethodGet))
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
