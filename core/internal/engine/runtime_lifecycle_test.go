package engine

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel"
)

func TestRuntimeBeginsWarmWithoutConnectionTimer(t *testing.T) {
	fixture(t)
	eng.mu.Lock()
	setHostTun(false)
	waitDiagnostics := beginRuntime()
	publishRuntime()
	status := *eng.Status()
	eng.mu.Unlock()
	waitDiagnostics()
	if !status.Running || status.Intent != "stopped" || status.Forward != "stopped" || status.TunAttached || status.VpnCreated || status.ListenersOpen || status.StartedAt != 0 {
		t.Fatalf("warm status=%+v", status)
	}
	if status.BootID == "" || status.ConfigRevision != 1 {
		t.Fatalf("warm identity=%+v", status)
	}
	body, err := json.Marshal(status)
	if err != nil || !strings.Contains(string(body), `"vpnCreated":false`) {
		t.Fatalf("warm JSON=%s err=%v", body, err)
	}
}

func TestRuntimeVpnStatesRequireObservedResources(t *testing.T) {
	for _, test := range []struct {
		name       string
		core       bool
		tun        bool
		vpn        bool
		intent     string
		forward    string
		wantFailed bool
	}{
		{name: "warm", core: true, intent: "stopped", forward: "stopped"},
		{name: "preparing", core: true, intent: "started", forward: "preparing"},
		{name: "connected", core: true, tun: true, vpn: true, intent: "started", forward: "running"},
		{name: "missing-tun", core: true, vpn: true, intent: "started", forward: "running", wantFailed: true},
		{name: "missing-vpn", core: true, tun: true, intent: "started", forward: "running", wantFailed: true},
		{name: "missing-core", tun: true, vpn: true, intent: "started", forward: "running", wantFailed: true},
		{name: "stopped-intent", core: true, tun: true, vpn: true, intent: "stopped", forward: "running", wantFailed: true},
		{name: "tun-residue", core: true, tun: true, intent: "stopped", forward: "stopped", wantFailed: true},
		{name: "vpn-residue", core: true, vpn: true, intent: "stopped", forward: "stopped", wantFailed: true},
		{name: "stopped-core-vpn-residue", vpn: true, intent: "stopped", forward: "stopped", wantFailed: true},
		{name: "fully-stopped", intent: "stopped", forward: "stopped"},
		{name: "reported-failure", core: true, vpn: true, intent: "stopped", forward: "failed"},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture(t)
			eng.mu.Lock()
			defer eng.mu.Unlock()
			eng.running = test.core
			setHostTun(test.tun)
			err := updateVpnState(test.intent, test.forward, test.vpn)
			status := eng.Status()
			if (err != nil) != test.wantFailed || status.Running != test.core || status.TunAttached != test.tun || status.VpnCreated != test.vpn || status.Intent != test.intent {
				t.Fatalf("status=%+v err=%v", status, err)
			}
			wantForward := test.forward
			if test.wantFailed {
				wantForward = "failed"
			}
			if status.Forward != wantForward || (status.StartedAt > 0) != (wantForward == "running") {
				t.Fatalf("status=%+v want forward=%s", status, wantForward)
			}
		})
	}
}

func TestRuntimeTimerAndIdentityFollowConnectionNotHost(t *testing.T) {
	fixture(t)
	eng.mu.Lock()
	defer eng.mu.Unlock()
	boot, configRevision := eng.bootID, eng.configRevision
	node := currentProxyGraph().Actual["Manual"]
	eng.startedAt = 1
	if err := updateVpnState("started", "running", true); err != nil {
		t.Fatal(err)
	}
	if eng.Status().StartedAt != 1 {
		t.Fatal("idempotent connection report restarted timer")
	}
	setHostTun(false)
	if err := updateVpnState("stopped", "stopped", false); err != nil {
		t.Fatal(err)
	}
	stopped := *eng.Status()
	if stopped.StartedAt != 0 {
		t.Fatalf("disconnect retained timer: %+v", stopped)
	}
	if err := updateVpnState("started", "preparing", true); err != nil {
		t.Fatal(err)
	}
	if eng.Status().StartedAt != 0 {
		t.Fatal("preparing started connection timer")
	}
	setHostTun(true)
	before := time.Now().UnixMilli()
	if err := updateVpnState("started", "running", true); err != nil {
		t.Fatal(err)
	}
	connected := eng.Status()
	if connected.StartedAt < before || connected.StartedAt > time.Now().UnixMilli() || connected.Revision <= stopped.Revision {
		t.Fatalf("reconnect status=%+v", connected)
	}
	if connected.BootID != boot || connected.ConfigRevision != configRevision || currentProxyGraph().Actual["Manual"] != node {
		t.Fatal("VPN state changed core or node identity")
	}
	setHostTun(false)
	publishRuntime()
	if status := eng.Status(); status.Forward != "failed" || status.StartedAt != 0 || !status.VpnCreated {
		t.Fatalf("lost TUN concealed resources: %+v", status)
	}
}

func TestRuntimeRejectsInvalidVpnEnumsWithoutChangingFacts(t *testing.T) {
	fixture(t)
	eng.mu.Lock()
	defer eng.mu.Unlock()
	before := *eng.Status()
	for _, state := range [][2]string{{"invalid", "running"}, {"stopped", "invalid"}} {
		if err := updateVpnState(state[0], state[1], false); err == nil {
			t.Fatal("invalid VPN state accepted")
		}
		if after := *eng.Status(); after != before {
			t.Fatalf("invalid input changed resource facts: %+v", after)
		}
	}
}

func TestRuntimeStoppedCannotHideLiveBusinessListener(t *testing.T) {
	fixture(t)
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := reserved.Addr().(*net.TCPAddr).Port
	if err := reserved.Close(); err != nil {
		t.Fatal(err)
	}
	eng.mu.Lock()
	defer eng.mu.Unlock()
	listener.ReCreateHTTP(port, tunnel.Tunnel)
	defer listener.ReCreateHTTP(0, tunnel.Tunnel)
	if listener.GetPorts().Port != port {
		t.Fatal("HTTP listener did not open")
	}
	setHostTun(false)
	if err := updateVpnState("stopped", "stopped", false); err == nil {
		t.Fatal("live business listener concealed by stopped state")
	}
	if status := eng.Status(); !status.ListenersOpen || status.Forward != "failed" {
		t.Fatalf("listener facts=%+v", status)
	}
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	if err := updateVpnState("stopped", "stopped", false); err != nil {
		t.Fatal(err)
	}
}

func TestWarmCoreAllowsSelectionAndRealUrlTest(t *testing.T) {
	fixture(t)
	eng.mu.Lock()
	setHostTun(false)
	err := updateVpnState("stopped", "stopped", false)
	eng.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := captureProxySnapshot(); err != nil {
		t.Fatal(err)
	}
	request := selectionRequest{Profile: "fixture", Group: "Manual", Name: "REJECT", NodeID: snapshotNodeID(t, "Manual", "REJECT"), OperationID: "warm-select",
		ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision}
	if result, err := commitSelection(request); err != nil || result.Selected != "REJECT" {
		t.Fatalf("warm selection=%+v err=%v", result, err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead {
			t.Errorf("URLTest method=%s", r.Method)
		}
		time.Sleep(5 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	if response := requestDelay(t, "DIRECT", "Manual", server.URL, 0); response.Code != http.StatusOK {
		t.Fatalf("warm URLTest=%d %s", response.Code, response.Body.String())
	}
	eng.mu.Lock()
	defer eng.mu.Unlock()
	if group := tunnel.Proxies()["Manual"].Adapter().(outboundgroup.ProxyGroup); group.Now() != "REJECT" {
		t.Fatal("URLTest changed selected exit")
	}
	if status := eng.Status(); status.TunAttached || status.VpnCreated || status.Forward != "stopped" {
		t.Fatalf("warm URLTest connected VPN: %+v", status)
	}
}

func TestRuntimeDisconnectDoesNotCancelIndependentUrlTest(t *testing.T) {
	fixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-release
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	request := delayRequest(context.Background(), "DIRECT", "Manual", server.URL, 0)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		getDelay(response, request)
		close(done)
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("URLTest did not reach target")
	}
	if err := detachTun(); err != nil {
		t.Fatal(err)
	}
	eng.mu.Lock()
	err := updateVpnState("stopped", "stopped", false)
	eng.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)
	close(release)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("URLTest did not complete after disconnect")
	}
	if response.Code != http.StatusOK {
		t.Fatalf("disconnect cancelled URLTest=%d %s", response.Code, response.Body.String())
	}
	eng.mu.Lock()
	defer eng.mu.Unlock()
	if len(eng.delays.active) != 0 || len(eng.delaySlots) != 0 {
		t.Fatal("URLTest retained execution capacity")
	}
}

func TestEmptyProfileRejectsNodeOperationsAndSkipsSelectionFile(t *testing.T) {
	cfg := fixture(t)
	eng.mu.Lock()
	eng.current.Profile = ""
	setHostTun(false)
	err := updateVpnState("stopped", "stopped", false)
	opts := eng.current
	eng.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(opts.HomeDir, "profiles", ".selected.json"), []byte("invalid JSON"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := restoreSelections(cfg, opts); err != nil {
		t.Fatalf("empty profile read invented selection file: %v", err)
	}
	if _, err := captureProxySnapshot(); err == nil {
		t.Fatal("empty profile exposed proxy graph")
	}
	if _, err := commitSelection(selectionRequest{Profile: "", Group: "Manual", Name: "REJECT", OperationID: "empty"}); err == nil {
		t.Fatal("empty profile accepted selection")
	}
	response := httptest.NewRecorder()
	getSelections(response, httptest.NewRequest(http.MethodGet, "/arkclash/selections", nil))
	if response.Code != http.StatusConflict {
		t.Fatalf("empty selections=%d %s", response.Code, response.Body.String())
	}
	response = requestDelay(t, "DIRECT", "Manual", "http://127.0.0.1/", 0)
	if response.Code != http.StatusConflict {
		t.Fatalf("empty profile URLTest=%d %s", response.Code, response.Body.String())
	}
}
