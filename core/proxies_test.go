package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

type loginTestAdapter struct {
	C.ProxyAdapter
	login func(context.Context) (string, string, error)
}

func (a *loginTestAdapter) Type() C.AdapterType { return C.Tailscale }
func (a *loginTestAdapter) ArkClashTailscaleLogin(ctx context.Context) (string, string, error) {
	return a.login(ctx)
}

func loginProxyFixture(t *testing.T, login func(context.Context) (string, string, error)) proxyDefinitionRequest {
	t.Helper()
	cfg := fixture(t)
	proxy := adapter.NewProxy(&loginTestAdapter{cfg.Proxies["DIRECT"].Adapter(), login})
	eng.mu.Lock()
	defer eng.mu.Unlock()
	proxies := maps.Clone(cfg.Proxies)
	proxies["login"] = proxy
	tunnel.UpdateProxies(proxies, cfg.Providers)
	graph := currentProxyGraph()
	return proxyDefinitionRequest{BootID: eng.bootID, ConfigRevision: eng.configRevision, ID: graph.Proxies["login"].ID}
}

func TestTailscaleLoginStatesAndPrivateErrors(t *testing.T) {
	const address = "https://example.invalid/auth/private"
	var state, authURL string
	var failure error
	req := loginProxyFixture(t, func(ctx context.Context) (string, string, error) {
		if _, ok := ctx.Deadline(); !ok {
			t.Error("backend call lacks a deadline")
		}
		return state, authURL, failure
	})
	for _, sample := range []struct {
		state, url string
		err        error
		code       int
	}{
		{"authorize", address, nil, 200},
		{"running", address, nil, 200},
		{"key-configured", address, nil, 200},
		{"needs-approval", address, nil, 200},
		{"pending", address, nil, 200},
		{"authorize", "https://user@example.invalid/auth/private", nil, 503},
		{"authorize", "file:///auth/private", nil, 503},
		{"authorize", "", nil, 503},
		{"unknown", address, nil, 503},
		{"", "", errors.New(address), 503},
	} {
		state, authURL, failure = sample.state, sample.url, sample.err
		data, _ := json.Marshal(req)
		rec := httptest.NewRecorder()
		postTailscaleLogin(rec, httptest.NewRequest(http.MethodPost, "/arkclash/proxies/tailscale-login", bytes.NewReader(data)))
		if rec.Code != sample.code || rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("state %q status=%d", state, rec.Code)
		}
		if sample.code != 200 {
			if !strings.Contains(rec.Body.String(), "tailscale_login_failed") || strings.Contains(rec.Body.String(), "/auth/") {
				t.Fatal("backend failure exposed details")
			}
			continue
		}
		var result tailscaleLoginResponse
		if json.Unmarshal(rec.Body.Bytes(), &result) != nil || result.State != state || result.ID != req.ID ||
			result.BootID != req.BootID || result.ConfigRevision != req.ConfigRevision {
			t.Fatalf("state %q lost request identity", state)
		}
		if (state == "authorize" && result.AuthURL != address) || (state != "authorize" && strings.Contains(rec.Body.String(), "authUrl")) {
			t.Fatalf("state %q returned incorrect URL", state)
		}
	}
	wrongGroup := req
	wrongGroup.Group = "Manual"
	if _, status, _ := requestTailscaleLogin(context.Background(), wrongGroup); status != http.StatusNotFound {
		t.Fatalf("unrelated member returned %d", status)
	}
	direct := req
	direct.ID = snapshotNodeID(t, "Manual", "DIRECT")
	if _, status, _ := requestTailscaleLogin(context.Background(), direct); status != http.StatusBadRequest {
		t.Fatalf("non-Tailscale proxy returned %d", status)
	}
}

func TestTailscaleLoginDiscardsResponseAfterConfigChange(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	req := loginProxyFixture(t, func(ctx context.Context) (string, string, error) {
		close(started)
		select {
		case <-release:
			return "authorize", "https://example.invalid/auth/private", nil
		case <-ctx.Done():
			return "", "", ctx.Err()
		}
	})
	done := make(chan struct{})
	var response tailscaleLoginResponse
	var code int
	go func() {
		response, code, _ = requestTailscaleLogin(context.Background(), req)
		close(done)
	}()
	<-started
	eng.mu.Lock()
	eng.configRevision++
	publishRuntime()
	eng.mu.Unlock()
	close(release)
	<-done
	if code != http.StatusConflict || response.AuthURL != "" {
		t.Errorf("retired instance returned HTTP %d", code)
	}
}

type proxyHTTPNode struct {
	Name    string `json:"name"`
	Type    string `json:"type"`
	History []struct {
		Delay uint16 `json:"delay"`
	} `json:"history"`
}

type proxyHTTPGraph struct {
	Proxies map[string]proxyReference   `json:"proxies"`
	Nodes   map[string]proxyHTTPNode    `json:"nodes"`
	Members map[string][]proxyReference `json:"members"`
	Actual  map[string]string           `json:"actual"`
	Retired map[string]bool             `json:"retired"`
}

func readProxyHTTPGraph(t *testing.T) proxyHTTPGraph {
	t.Helper()
	response := httptest.NewRecorder()
	getProxySnapshot(response, httptest.NewRequest(http.MethodGet, "/arkclash/proxies", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("snapshot status=%d", response.Code)
	}
	var graph proxyHTTPGraph
	if err := json.Unmarshal(response.Body.Bytes(), &graph); err != nil {
		t.Fatal(err)
	}
	return graph
}

func TestProxySnapshotPreservesProviderIdentityAndGroupFiltering(t *testing.T) {
	delayProviderFixture(t, "http://127.0.0.1/")
	graph := readProxyHTTPGraph(t)
	for _, test := range []struct{ group, provider, kind string }{
		{"Provider", "Remote", "Direct"}, {"OtherGroup", "Other", "Reject"},
	} {
		found := false
		for _, ref := range graph.Members[test.group] {
			if ref.Name != "Shared" {
				continue
			}
			node := graph.Nodes[ref.ID]
			if ref.ID == "" || ref.Provider != test.provider || node.Name != "Shared" || node.Type != test.kind {
				t.Fatalf("%s got reference=%+v node=%+v", test.group, ref, node)
			}
			found = true
		}
		if !found {
			t.Fatalf("%s missing Shared", test.group)
		}
	}
	var shared []proxyReference
	for _, member := range graph.Members["Both"] {
		if member.Name == "Shared" {
			shared = append(shared, member)
		}
	}
	if len(shared) != 2 || shared[0].ID == shared[1].ID || shared[0].Selectable || shared[1].Selectable {
		t.Fatalf("same-name members lost their real identities: %+v", shared)
	}
	filtered := graph.Members["Filtered"]
	if len(filtered) != 1 || filtered[0].Name != "RemoteB" || filtered[0].Provider != "Remote" {
		t.Fatalf("filtered group exposed excluded nodes: %+v", filtered)
	}
	again := readProxyHTTPGraph(t)
	for name, members := range graph.Members {
		for index, member := range members {
			if again.Members[name][index].ID != member.ID {
				t.Fatalf("unchanged %s member ID changed", name)
			}
		}
	}
}

func TestSameNameAutomaticSecondInstanceHasExactSnapshotAndDelay(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	cfg := delayProviderFixture(t, server.URL)
	expected, _ := utils.NewUnsignedRanges[uint16]("")
	first := providerDelayNode(t, cfg, "Other", "Shared")
	second := providerDelayNode(t, cfg, "Remote", "Shared")
	if _, err := first.URLTest(context.Background(), server.URL, expected); err == nil {
		t.Fatal("first real provider instance unexpectedly succeeded")
	}
	if _, err := second.URLTest(context.Background(), server.URL, expected); err != nil {
		t.Fatal(err)
	}
	graph := readProxyHTTPGraph(t)
	for _, groupName := range []string{"AutoShared", "FallbackShared"} {
		members := graph.Members[groupName]
		if len(members) != 2 || members[0].Name != "Shared" || members[1].Name != "Shared" || members[0].ID == members[1].ID {
			t.Fatalf("%s did not expose both real Shared instances: %+v", groupName, members)
		}
		group := cfg.Proxies[groupName].Adapter().(outboundgroup.ProxyGroup)
		if graph.Actual[groupName] != members[1].ID || group.Unwrap(nil, false) != second {
			t.Fatalf("%s actual=%s expected=%s", groupName, graph.Actual[groupName], members[1].ID)
		}
		for index, member := range members {
			beforeFirst := len(first.ExtraDelayHistories()[server.URL].History)
			beforeSecond := len(second.ExtraDelayHistories()[server.URL].History)
			recorder := httptest.NewRecorder()
			getDelay(recorder, delayIDRequest(context.Background(), member.ID, groupName, server.URL, 0))
			want := http.StatusServiceUnavailable
			if index == 1 {
				want = http.StatusOK
			}
			if recorder.Code != want {
				t.Fatalf("%s instance %d status=%d body=%s", groupName, index, recorder.Code, recorder.Body.String())
			}
			if after := len(first.ExtraDelayHistories()[server.URL].History); after != beforeFirst+1-index {
				t.Fatalf("first instance history=%d before=%d index=%d", after, beforeFirst, index)
			}
			if after := len(second.ExtraDelayHistories()[server.URL].History); after != beforeSecond+index {
				t.Fatalf("second instance history=%d before=%d index=%d", after, beforeSecond, index)
			}
			request := selectionRequest{Profile: eng.current.Profile, Group: groupName, Name: "Shared", NodeID: member.ID,
				OperationID: groupName + strconv.Itoa(index), ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision}
			if _, err := commitSelection(request); err == nil || err.Error() != "selection_node_not_addressable" {
				t.Fatalf("unaddressable instance selection=%v", err)
			}
		}
	}
	if graph.Members["AutoShared"][1].ID != graph.Members["FallbackShared"][1].ID {
		t.Fatal("one shared C.Proxy acquired different IDs across groups")
	}
	selected, err := readSelections(eng.current.HomeDir, eng.current.Profile)
	if err != nil || len(selected) != 0 {
		t.Fatalf("unaddressable buttons wrote selected state: %v %v", selected, err)
	}
	wrongGroup := httptest.NewRecorder()
	getDelay(wrongGroup, delayIDRequest(context.Background(), graph.Members["AutoShared"][1].ID, "OtherGroup", server.URL, 0))
	if wrongGroup.Code != http.StatusConflict {
		t.Fatal("same display name bypassed exact current group membership")
	}
	if err := saveSelections(eng.current.HomeDir, eng.current.Profile, map[string]string{"AutoShared": "Shared", "FallbackShared": "Shared"}); err != nil {
		t.Fatal(err)
	}
	for _, groupName := range []string{"AutoShared", "FallbackShared"} {
		result, err := commitSelection(selectionRequest{Profile: eng.current.Profile, Group: groupName, ClearPin: true,
			OperationID: groupName + ".clear", ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision})
		if err != nil || result.Pinned != "" || result.SelectedID != graph.Members[groupName][1].ID {
			t.Fatalf("explicit same-name group unpin=%+v err=%v", result, err)
		}
	}
	selected, err = readSelections(eng.current.HomeDir, eng.current.Profile)
	if err != nil || len(selected) != 0 {
		t.Fatalf("explicit group unpin left persisted state: %v %v", selected, err)
	}
}

func TestProxyIdentitiesRejectOldBootAndConfiguration(t *testing.T) {
	for _, change := range []string{"boot", "configuration"} {
		t.Run(change, func(t *testing.T) {
			fixture(t)
			id := snapshotNodeID(t, "Manual", "DIRECT")
			oldRequest := delayIDRequest(context.Background(), id, "Manual", "http://127.0.0.1/", 0)
			eng.mu.Lock()
			if change == "boot" {
				eng.bootID += ".next"
			} else {
				eng.configRevision++
			}
			resetProxyIdentities()
			publishRuntime()
			eng.mu.Unlock()
			fresh := snapshotNodeID(t, "Manual", "DIRECT")
			if fresh == id {
				t.Fatal("new lifecycle reused an old node ID")
			}
			for _, request := range []*http.Request{oldRequest, delayIDRequest(context.Background(), id, "Manual", "http://127.0.0.1/", 0)} {
				response := httptest.NewRecorder()
				getDelay(response, request)
				if response.Code != http.StatusConflict {
					t.Fatalf("old identity accepted: %d %s", response.Code, response.Body.String())
				}
			}
		})
	}
}

func TestRetiredFileProviderInstanceRejectsDelayAndSelection(t *testing.T) {
	fixture(t)
	providerPath := filepath.Join(eng.current.HomeDir, "nodes.yaml")
	if err := os.WriteFile(providerPath, []byte("proxies:\n  - {name: Shared, type: direct}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	raw, err := config.UnmarshalRawConfig([]byte(fmt.Sprintf(`mode: direct
proxy-providers:
  Remote: {type: file, path: %s}
proxy-groups:
  - {name: Provider, type: select, proxies: [DIRECT], use: [Remote]}
rules: ['MATCH,DIRECT']
`, strconv.Quote(providerPath))))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	remote := cfg.Providers["Remote"]
	if err := remote.Initial(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = remote.(interface{ Close() error }).Close() })
	eng.mu.Lock()
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	eng.configRevision++
	resetProxyIdentities()
	publishRuntime()
	eng.mu.Unlock()
	id := snapshotNodeID(t, "Provider", "Shared")
	entered := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-release
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	response := httptest.NewRecorder()
	request := delayIDRequest(context.Background(), id, "Provider", server.URL, 0)
	done := make(chan struct{})
	go func() { getDelay(response, request); close(done) }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		close(release)
		t.Fatal("real provider delay did not reach target")
	}
	if err := os.WriteFile(providerPath, []byte("proxies:\n  - {name: Shared, type: reject}\n"), 0600); err != nil {
		close(release)
		t.Fatal(err)
	}
	if err := remote.Update(); err != nil {
		close(release)
		t.Fatal(err)
	}
	close(release)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("retired delay did not finish")
	}
	if response.Code != http.StatusConflict {
		t.Fatalf("retired result escaped: %d %s", response.Code, response.Body.String())
	}
	fresh := snapshotNodeID(t, "Provider", "Shared")
	if fresh == id {
		t.Fatal("provider replacement reused retired identity")
	}
	response = httptest.NewRecorder()
	getDelay(response, delayIDRequest(context.Background(), id, "Provider", server.URL, 0))
	if response.Code != http.StatusConflict {
		t.Fatal("retired ID tested the new same-name node")
	}
	if _, err := commitSelection(selectionRequest{Profile: eng.current.Profile, Group: "Provider", Name: "Shared", NodeID: id,
		OperationID: "retired", ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision}); err == nil {
		t.Fatal("retired provider ID selected a new same-name instance")
	}
	original := cfg.Proxies["Provider"].Adapter().(*outboundgroup.Selector)
	cfg.Proxies["Provider"] = adapter.NewProxy(&movedSelector{Selector: original, move: func() error {
		if err := os.WriteFile(providerPath, []byte("proxies:\n  - {name: Shared, type: direct}\n"), 0600); err != nil {
			return err
		}
		return remote.Update()
	}})
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	requestSelection := selectionRequest{Profile: eng.current.Profile, Group: "Provider", Name: "Shared", NodeID: fresh,
		OperationID: "retired-during-set", ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision}
	if _, err := commitSelection(requestSelection); err == nil || err.Error() != "selection_node_unavailable" {
		t.Fatalf("provider retirement during Set accepted: %v", err)
	}
	if original.Now() != "DIRECT" {
		t.Fatal("retired request was not rolled back to the prior forwarding selection")
	}
	selected, err := readSelections(eng.current.HomeDir, eng.current.Profile)
	if err != nil || len(selected) != 0 {
		t.Fatalf("retired request wrote selected.json: %v %v", selected, err)
	}
}

func TestURLTestSnapshotPreservesRetiredActualDuringProviderCache(t *testing.T) {
	for _, kind := range []string{"http", "file"} {
		t.Run(kind, func(t *testing.T) {
			fixture(t)
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusNoContent)
			}))
			defer target.Close()
			providerPath := filepath.Join(eng.current.HomeDir, "cached-actual.yaml")
			const originalPayload = "proxies:\n  - {name: Shared, type: direct}\n"
			const replacementPayload = "proxies:\n  - {name: Shared, type: reject}\n"
			definition := fmt.Sprintf("{type: file, path: %s}", strconv.Quote(providerPath))
			var replacement atomic.Bool
			if kind == "http" {
				source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if replacement.Load() {
						_, _ = fmt.Fprint(w, replacementPayload)
					} else {
						_, _ = fmt.Fprint(w, originalPayload)
					}
				}))
				defer source.Close()
				definition = fmt.Sprintf("{type: http, path: %s, url: %s, interval: 0}", strconv.Quote(providerPath), strconv.Quote(source.URL))
			} else if err := os.WriteFile(providerPath, []byte(originalPayload), 0600); err != nil {
				t.Fatal(err)
			}
			raw, err := config.UnmarshalRawConfig([]byte(fmt.Sprintf(`mode: direct
log-level: silent
proxy-providers:
  Remote: %s
proxy-groups:
  - {name: Auto, type: url-test, use: [Remote], url: %s, interval: 0}
  - {name: Outer, type: select, proxies: [Auto]}
rules: ['MATCH,DIRECT']
`, definition, strconv.Quote(target.URL))))
			if err != nil {
				t.Fatal(err)
			}
			cfg, err := config.ParseRawConfig(raw)
			if err != nil {
				t.Fatal(err)
			}
			remote := cfg.Providers["Remote"]
			if err := remote.Initial(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = remote.(interface{ Close() error }).Close() })
			old := remote.Proxies()[0]
			expected, _ := utils.NewUnsignedRanges[uint16]("")
			if _, err := old.URLTest(context.Background(), target.URL, expected); err != nil {
				t.Fatal(err)
			}
			eng.mu.Lock()
			stopRuntimeRoutes()
			tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
			eng.configRevision++
			resetProxyIdentities()
			cacheStarted := time.Now()
			watchRuntimeRoutes(cfg)
			publishRuntime()
			eng.mu.Unlock()
			group := cfg.Proxies["Auto"].Adapter().(*outboundgroup.URLTest)
			if group.Unwrap(nil, false) != old {
				t.Fatal("real URLTest did not initially adopt the original provider instance")
			}
			before := readProxyHTTPGraph(t)
			oldID := before.Actual["Auto"]
			if oldID == "" || len(before.Members["Auto"]) != 1 || before.Members["Auto"][0].ID != oldID {
				t.Fatalf("original HTTP snapshot did not identify the actual instance: %+v", before)
			}
			replacement.Store(true)
			if kind == "file" {
				if err := os.WriteFile(providerPath, []byte(replacementPayload), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := remote.Update(); err != nil {
				t.Fatal(err)
			}
			members := group.Proxies()
			if len(members) != 1 || members[0] == old || members[0].Name() != "Shared" || members[0].Type() != C.Reject {
				t.Fatalf("real provider did not install the replacement instance: %+v", members)
			}
			if time.Since(cacheStarted) >= 10*time.Second || group.Unwrap(nil, false) != old {
				t.Fatal("fixture did not retain the original instance inside the real ten-second URLTest cache")
			}
			address, err := url.Parse(target.URL)
			if err != nil {
				t.Fatal(err)
			}
			port, err := strconv.ParseUint(address.Port(), 10, 16)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			connection, err := group.DialContext(ctx, &C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr(address.Hostname()), DstPort: uint16(port)})
			cancel()
			if err != nil {
				t.Fatalf("cached retired actual no longer forwarded through its real Direct adapter: %v", err)
			}
			_ = connection.Close()
			after := readProxyHTTPGraph(t)
			if after.Actual["Auto"] != oldID {
				t.Fatalf("HTTP snapshot erased a still-forwarding cached actual: got=%q want=%q", after.Actual["Auto"], oldID)
			}
			if !after.Retired[oldID] || after.Nodes[oldID].Name != "Shared" || after.Nodes[oldID].Type != "Direct" || len(after.Nodes[oldID].History) == 0 {
				t.Fatalf("retired actual lost its explicit state or real wire summary: %+v", after)
			}
			if len(after.Members["Auto"]) != 1 || after.Members["Auto"][0].ID == oldID || after.Retired[after.Members["Auto"][0].ID] {
				t.Fatalf("retired actual contaminated current selectable membership: %+v", after.Members["Auto"])
			}
			if repeat := readProxyHTTPGraph(t); repeat.Actual["Auto"] != oldID || !repeat.Retired[oldID] {
				t.Fatalf("cached retired actual identity was unstable across HTTP snapshots: %+v", repeat)
			}
			for _, owner := range []string{"Auto", ""} {
				response := httptest.NewRecorder()
				getDelay(response, delayIDRequest(context.Background(), oldID, owner, target.URL, 0))
				if response.Code != http.StatusConflict {
					t.Fatalf("retired actual accepted a new delay request: %d %s", response.Code, response.Body.String())
				}
			}
			if _, err := commitSelection(selectionRequest{Profile: eng.current.Profile, Group: "Auto", Name: "Shared", NodeID: oldID,
				OperationID: "retired-cached-actual", ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision}); err == nil {
				t.Fatal("cached retired actual became selectable again")
			}
			selected, err := readSelections(eng.current.HomeDir, eng.current.Profile)
			if err != nil || len(selected) != 0 {
				t.Fatalf("retired actual request wrote selected state: %v %v", selected, err)
			}
		})
	}
}
