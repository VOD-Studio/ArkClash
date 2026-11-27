package main

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"reflect"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func delayProviderFixture(t *testing.T, target string) *config.Config {
	t.Helper()
	fixture(t)
	raw, err := config.UnmarshalRawConfig([]byte(fmt.Sprintf(`mode: direct
log-level: silent
proxy-providers:
  Remote:
    type: inline
    payload:
      - {name: RemoteA, type: direct}
      - {name: RemoteB, type: direct}
      - {name: Shared, type: direct}
  Other:
    type: inline
    payload:
      - {name: Shared, type: reject}
proxy-groups:
  - {name: Provider, type: select, use: [Remote]}
  - {name: OtherGroup, type: select, use: [Other]}
  - {name: Both, type: select, use: [Other, Remote]}
  - {name: Filtered, type: select, use: [Remote], filter: '^RemoteB$'}
  - name: Auto
    type: url-test
    use: [Remote]
    filter: '^Remote[AB]$'
    url: %s
    interval: 0
  - name: Fallback
    type: fallback
    use: [Remote]
    filter: '^Remote[AB]$'
    url: %s
    interval: 0
  - {name: AutoShared, type: url-test, use: [Other, Remote], filter: '^Shared$', url: %s, interval: 0}
  - {name: FallbackShared, type: fallback, use: [Other, Remote], filter: '^Shared$', url: %s, interval: 0}
rules: ['MATCH,DIRECT']
`, strconv.Quote(target), strconv.Quote(target), strconv.Quote(target), strconv.Quote(target))))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	eng.mu.Lock()
	cancelDelayTests()
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	eng.configRevision++
	resetProxyIdentities()
	publishRuntime()
	eng.mu.Unlock()
	t.Cleanup(func() {
		eng.mu.Lock()
		cancelDelayTests()
		eng.mu.Unlock()
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

func delayRequest(ctx context.Context, name, group, target string, timeout int) *http.Request {
	eng.mu.Lock()
	graph := currentProxyGraph()
	id := ""
	if group != "" {
		for _, member := range graph.Members[group] {
			if member.Name == name {
				if id != "" {
					id = ""
					break
				}
				id = member.ID
			}
		}
	} else if global, exists := graph.Proxies[name]; exists {
		id = global.ID
	} else {
		for candidateID, node := range graph.Nodes {
			if node.Name() == name {
				if id != "" {
					id = ""
					break
				}
				id = candidateID
			}
		}
	}
	eng.mu.Unlock()
	return delayIDRequest(ctx, id, group, target, timeout)
}

func delayIDRequest(ctx context.Context, id, group, target string, timeout int) *http.Request {
	eng.mu.Lock()
	query := url.Values{"profile": {eng.current.Profile}, "id": {id}, "url": {target},
		"expectedBootId": {eng.bootID}, "expectedRevision": {strconv.FormatUint(eng.configRevision, 10)}}
	eng.mu.Unlock()
	if group != "" {
		query.Set("group", group)
	}
	if timeout != 0 {
		query.Set("timeout", strconv.Itoa(timeout))
	}
	return httptest.NewRequestWithContext(ctx, http.MethodGet, "/arkclash/delay?"+query.Encode(), nil)
}

func requestDelay(t *testing.T, name, group, target string, timeout int) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	getDelay(recorder, delayRequest(context.Background(), name, group, target, timeout))
	return recorder
}

func providerDelayNode(t *testing.T, cfg *config.Config, providerName, name string) C.Proxy {
	t.Helper()
	for _, proxy := range cfg.Providers[providerName].Proxies() {
		if proxy.Name() == name {
			return proxy
		}
	}
	t.Fatalf("provider %s has no node %s", providerName, name)
	return nil
}

func TestDelayFindsProviderNodesAndUsesActualGroupMembership(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	cfg := delayProviderFixture(t, server.URL)
	if tunnel.Proxies()["RemoteA"] != nil {
		t.Fatal("provider node unexpectedly appears in the global registry")
	}
	for _, test := range []struct {
		name   string
		group  string
		status int
	}{
		{name: "RemoteA", status: http.StatusOK},
		{name: "Shared", status: http.StatusConflict},
		{name: "Shared", group: "Provider", status: http.StatusOK},
		{name: "Shared", group: "OtherGroup", status: http.StatusServiceUnavailable},
		{name: "Shared", group: "Both", status: http.StatusConflict},
		{name: "RemoteA", group: "Filtered", status: http.StatusConflict},
		{name: "RemoteB", group: "Filtered", status: http.StatusOK},
		{name: "RemoteA", group: "missing", status: http.StatusConflict},
	} {
		t.Run(test.name+"/"+test.group, func(t *testing.T) {
			recorder := requestDelay(t, test.name, test.group, server.URL, 0)
			if recorder.Code != test.status {
				t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
			}
		})
	}
	node := providerDelayNode(t, cfg, "Remote", "RemoteA")
	if history := node.ExtraDelayHistories()[server.URL].History; len(history) != 1 || history[0].Delay == 0 {
		t.Fatalf("real provider node was not tested: %+v", history)
	}
	eng.mu.Lock()
	cfg.Proxies["Shared"] = adapter.NewProxy(outbound.NewRejectWithOption(outbound.RejectOption{Name: "Shared"}))
	eng.mu.Unlock()
	if recorder := requestDelay(t, "Shared", "", server.URL, 0); recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("global collision status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if recorder := requestDelay(t, "Shared", "Provider", server.URL, 0); recorder.Code != http.StatusOK {
		t.Fatalf("group collision status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestDelayCancellationPreservesHealthHistoryAndAutomaticConsumers(t *testing.T) {
	for _, groupName := range []string{"Auto", "Fallback"} {
		for _, cancellation := range []string{"request", "configuration"} {
			t.Run(groupName+"/"+cancellation, func(t *testing.T) {
				var blocking atomic.Bool
				entered := make(chan struct{}, 1)
				disconnected := make(chan struct{}, 1)
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if blocking.Load() {
						entered <- struct{}{}
						<-r.Context().Done()
						disconnected <- struct{}{}
						return
					}
					w.WriteHeader(http.StatusNoContent)
				}))
				defer server.Close()
				cfg := delayProviderFixture(t, server.URL)
				for _, name := range []string{"RemoteA", "RemoteB"} {
					if recorder := requestDelay(t, name, "Provider", server.URL, 0); recorder.Code != http.StatusOK {
						t.Fatalf("seed %s: status=%d body=%s", name, recorder.Code, recorder.Body.String())
					}
				}
				group := cfg.Proxies[groupName].Adapter().(outboundgroup.ProxyGroup)
				// 先按完整预热历史重算，取消前后使用相同的选路缓存状态。
				if automatic, ok := group.(*outboundgroup.URLTest); ok {
					automatic.ForceSet("")
				}
				selected := group.Now()
				node := providerDelayNode(t, cfg, "Remote", selected)
				beforeHistory := node.DelayHistory()
				beforeExtra := node.ExtraDelayHistories()
				beforeGlobalAlive := node.AliveForTestUrl(server.URL + "/untested")
				blocking.Store(true)
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				recorder := httptest.NewRecorder()
				done := make(chan struct{})
				go func() {
					getDelay(recorder, delayRequest(ctx, selected, groupName, server.URL, 0))
					close(done)
				}()
				select {
				case <-entered:
				case <-time.After(3 * time.Second):
					cancel()
					t.Fatal("real URLTest never reached the target")
				}
				if cancellation == "request" {
					cancel()
				} else {
					eng.mu.Lock()
					cancelDelayTests()
					eng.configRevision++
					publishRuntime()
					eng.mu.Unlock()
				}
				select {
				case <-done:
				case <-time.After(3 * time.Second):
					cancel()
					t.Fatal("canceled URLTest retained its execution slot")
				}
				select {
				case <-disconnected:
				case <-time.After(3 * time.Second):
					t.Fatal("canceled URLTest retained the target connection")
				}
				if cancellation == "configuration" && recorder.Code != http.StatusConflict {
					t.Fatalf("old configuration status=%d body=%s", recorder.Code, recorder.Body.String())
				}
				if cancellation == "request" && recorder.Body.Len() != 0 {
					t.Fatalf("request cancellation published a conclusion: %s", recorder.Body.String())
				}
				if !reflect.DeepEqual(beforeHistory, node.DelayHistory()) || !reflect.DeepEqual(beforeExtra, node.ExtraDelayHistories()) || beforeGlobalAlive != node.AliveForTestUrl(server.URL+"/untested") {
					t.Fatal("cancellation changed shared health or history")
				}
				if automatic, ok := group.(*outboundgroup.URLTest); ok {
					automatic.ForceSet("")
				}
				if after := group.Now(); after != selected {
					t.Fatalf("cancellation moved automatic route from %s to %s", selected, after)
				}
				if forwarding := group.Unwrap(nil, false).Name(); forwarding != selected {
					t.Fatalf("cancellation moved forwarding to %s", forwarding)
				}
				eng.mu.Lock()
				active := len(eng.delays.active)
				eng.mu.Unlock()
				if active != 0 || len(delaySlots) != 0 {
					t.Fatalf("cancellation leaked active=%d slots=%d", active, len(delaySlots))
				}
			})
		}
	}
}

func TestDelayRealFailureAndDeadlineStillUpdateHealthAndRoutes(t *testing.T) {
	for _, failure := range []string{"transport", "deadline"} {
		t.Run(failure, func(t *testing.T) {
			var failing atomic.Bool
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if !failing.Load() {
					w.WriteHeader(http.StatusNoContent)
					return
				}
				if failure == "deadline" {
					<-r.Context().Done()
					return
				}
				connection, _, err := w.(http.Hijacker).Hijack()
				if err != nil {
					t.Error(err)
					return
				}
				_ = connection.Close()
			}))
			defer server.Close()
			cfg := delayProviderFixture(t, server.URL)
			for _, name := range []string{"RemoteA", "RemoteB"} {
				if recorder := requestDelay(t, name, "Provider", server.URL, 0); recorder.Code != http.StatusOK {
					t.Fatalf("seed %s: status=%d body=%s", name, recorder.Code, recorder.Body.String())
				}
			}
			failing.Store(true)
			recorder := requestDelay(t, "RemoteA", "Provider", server.URL, 100)
			want := http.StatusServiceUnavailable
			if failure == "deadline" {
				want = http.StatusGatewayTimeout
			}
			if recorder.Code != want {
				t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
			}
			node := providerDelayNode(t, cfg, "Remote", "RemoteA")
			history := node.ExtraDelayHistories()[server.URL].History
			if node.AliveForTestUrl(server.URL) || node.AliveForTestUrl(server.URL+"/untested") || len(history) != 2 || history[1].Delay != 0 {
				t.Fatalf("real failure did not update health/history: %+v", history)
			}
			for _, name := range []string{"Auto", "Fallback"} {
				group := cfg.Proxies[name].Adapter().(outboundgroup.ProxyGroup)
				if automatic, ok := group.(*outboundgroup.URLTest); ok {
					automatic.ForceSet("")
				}
				if selected := group.Now(); selected != "RemoteB" {
					t.Fatalf("%s kept failed route %s", name, selected)
				}
				if forwarding := group.Unwrap(nil, false).Name(); forwarding != "RemoteB" {
					t.Fatalf("%s still forwards through failed route %s", name, forwarding)
				}
			}
		})
	}
}

func TestURLTestPreCanceledContextPreservesFreshNodeState(t *testing.T) {
	fixture(t)
	node := tunnel.Proxies()["DIRECT"]
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	expected, _ := utils.NewUnsignedRanges[uint16]("")
	_, err := node.URLTest(ctx, "http://127.0.0.1:1/", expected)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("pre-canceled URLTest error=%v", err)
	}
	if !node.AliveForTestUrl("http://127.0.0.1:1/") || len(node.DelayHistory()) != 0 || len(node.ExtraDelayHistories()) != 0 {
		t.Fatal("pre-canceled test created a failure or history entry")
	}
}
