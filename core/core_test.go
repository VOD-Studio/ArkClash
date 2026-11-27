// 宿主只替换平台 TUN 构造器；生命周期、事件推送、选择事务、规则拨号和取消路径均执行真实产品源码。
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	"github.com/VOD-Studio/ArkClash/core/internal/probe"
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/profile"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/inner"
	"github.com/metacubex/mihomo/tunnel"
)

type stubTunHandle struct {
	fd int
}

func (h *stubTunHandle) Close() error {
	return hostTunStopError
}

var hostTunStartError error
var hostTunStopError error

func hostNewTunListener(options LC.Tun) (tunHandle, error) {
	if hostTunStartError != nil {
		return nil, hostTunStartError
	}
	return &stubTunHandle{fd: options.FileDescriptor}, nil
}

// 绕过 startTun/stopTun 直接设置宿主 TUN 状态时，必须同步复位一次性关闭标记。
func setHostTun(attached bool) {
	eng.tunCloseAttempted = false
	eng.tunCloseErr = nil
	if attached {
		eng.tun = &stubTunHandle{fd: 1}
		return
	}
	eng.tun = nil
}

func assertEngineViewInvariant(e *coreEngine) {
	v := e.view.Load()
	if v == nil {
		if e.running {
			panic("engine invariant: running=true with nil runtimeView")
		}
		return
	}
	if v.Status.Running != e.running ||
		v.Status.Profile != e.current.Profile ||
		v.Status.BootID != e.bootID ||
		v.Status.ConfigRevision != e.configRevision ||
		v.Status.Revision != e.revision ||
		v.Status.Intent != e.intent ||
		v.Status.Forward != e.forward ||
		v.Status.TunAttached != (e.tun != nil) ||
		v.Status.VpnCreated != e.vpnCreated ||
		v.Status.PanelOpen != (e.panel != nil) ||
		v.Status.ProfileExtension != e.current.Script.identity ||
		v.Status.StandardRulesRevision != e.current.ProfileRules.Revision ||
		v.HomeDir != e.current.HomeDir ||
		v.StoreGeneration != e.current.StoreGeneration ||
		v.CaptureLogs != e.current.General.CaptureLogs ||
		v.DelayTimeout != e.current.General.DelayTimeout {
		panic(fmt.Sprintf("engine invariant violated: view=%+v running=%v profile=%q boot=%q rev=%d cfgRev=%d home=%q logs=%v delay=%d",
			v, e.running, e.current.Profile, e.bootID, e.revision, e.configRevision, e.current.HomeDir, e.current.General.CaptureLogs, e.current.General.DelayTimeout))
	}
}

func (e *coreEngine) resetForTestLocked() {
	stopRuntimeRoutes()
	cancelDelayTests()
	e.running = false
	e.current = startOptions{}
	setHostTun(false)
	e.vpnCreated = false
	e.intent = "stopped"
	e.forward = "stopped"
	e.startedAt = 0
	e.desiredInbound = inboundSettings{}
	e.cleanupFailure = nil
	e.view.Store(nil)
	resetProxyIdentities()
}

func TestMain(m *testing.M) {
	eng.tunFactory = hostNewTunListener
	engineUnlockCheck = assertEngineViewInvariant
	os.Exit(m.Run())
}
func fixture(t *testing.T) *config.Config {
	t.Helper()
	inbound.EnableArkClashListenerOwnership()
	if err := tunnel.ArkClashSuspendForwarding(); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	if err := os.Mkdir(filepath.Join(home, "profiles"), 0700); err != nil {
		t.Fatal(err)
	}
	C.SetHomeDir(home)
	raw, err := config.UnmarshalRawConfig([]byte(`mode: direct
log-level: silent
proxy-groups:
  - name: Manual
    type: select
    proxies: [DIRECT, REJECT]
  - name: Auto
    type: url-test
    url: http://127.0.0.1/
    interval: 0
    proxies: [DIRECT, REJECT]
rules: ['MATCH,DIRECT']
`))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	eng.mu.Lock()
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	tunnel.SetMode(tunnel.ModeMapping["direct"])
	inner.New(tunnel.Tunnel)
	tunnel.OnRunning()
	eng.current = startOptions{HomeDir: home, Profile: "fixture", Geo: geo.DefaultSettings()}
	eng.running = true
	setHostTun(true)
	waitDiagnostics := beginRuntime()
	if err := updateVpnState("started", "running", true); err != nil {
		eng.mu.Unlock()
		t.Fatal(err)
	}
	watchRuntimeRoutes(cfg)
	resetProxyIdentities()
	publishRuntime()
	tunnel.ArkClashResumeForwarding()
	eng.mu.Unlock()
	waitDiagnostics()
	t.Cleanup(func() {
		if err := tunnel.ArkClashSuspendForwarding(); err != nil {
			t.Error(err)
		}
		eng.mu.Lock()
		waitDiagnostics := eng.diag.Stop()
		defer func() {
			eng.mu.Unlock()
			waitDiagnostics()
		}()
		hostTunStartError = nil
		hostTunStopError = nil
		eng.resetForTestLocked()
		tunnel.OnSuspend()
		tunnel.UpdateProxies(nil, nil)
	})
	return cfg
}

func snapshotNodeID(t *testing.T, group, name string) string {
	t.Helper()
	graph, err := captureProxySnapshot()
	if err != nil {
		t.Fatal(err)
	}
	for _, member := range graph.Members[group] {
		if member.Name == name {
			return member.ID
		}
	}
	t.Fatalf("group %s has no node %s", group, name)
	return ""
}

func TestSelectionPersistsAndReplaysOnce(t *testing.T) {
	cfg := fixture(t)
	request := selectionRequest{Profile: "fixture", Group: "Manual", Name: "REJECT", NodeID: snapshotNodeID(t, "Manual", "REJECT"), OperationID: "one",
		ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision}
	first, err := commitSelection(request)
	if err != nil || !first.Changed || first.Selected != "REJECT" {
		t.Fatalf("first=%+v err=%v", first, err)
	}
	revision := eng.revision
	replay, err := commitSelection(request)
	if err != nil || replay != first || eng.revision != revision {
		t.Fatalf("replay=%+v err=%v revision=%d", replay, err, eng.revision)
	}
	selected, err := readSelections(eng.current.HomeDir, "fixture")
	if err != nil || selected["Manual"] != "REJECT" {
		t.Fatalf("selected=%v err=%v", selected, err)
	}
	cfg.Proxies["Manual"].Adapter().(outboundgroup.SelectAble).ForceSet("DIRECT")
	if err := restoreSelections(cfg, eng.current); err != nil {
		t.Fatal(err)
	}
	if got := cfg.Proxies["Manual"].Adapter().(outboundgroup.ProxyGroup).Now(); got != "REJECT" {
		t.Fatalf("restored=%s", got)
	}
	request.Name = "DIRECT"
	request.NodeID = snapshotNodeID(t, "Manual", "DIRECT")
	if _, err := commitSelection(request); err == nil {
		t.Fatal("conflicting operation accepted")
	}
}

type movedSelector struct {
	*outboundgroup.Selector
	move func() error
}

func (selector *movedSelector) Set(name string) error {
	if err := selector.Selector.Set(name); err != nil {
		return err
	}
	return selector.move()
}

func TestSelectionPersistenceFailureRestoresForwarding(t *testing.T) {
	cfg := fixture(t)
	dir := filepath.Join(eng.current.HomeDir, "profiles")
	moved := dir + ".held"
	original := cfg.Proxies["Manual"].Adapter().(*outboundgroup.Selector)
	cfg.Proxies["Manual"] = adapter.NewProxy(&movedSelector{Selector: original, move: func() error { return os.Rename(dir, moved) }})
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	_, err := commitSelection(selectionRequest{Profile: "fixture", Group: "Manual", Name: "REJECT", NodeID: snapshotNodeID(t, "Manual", "REJECT"), OperationID: "rollback",
		ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision})
	if restore := os.Rename(moved, dir); restore != nil {
		t.Fatal(restore)
	}
	if err == nil || err.Error() != "selection_persist_failed" {
		t.Fatalf("err=%v", err)
	}
	if got := original.Now(); got != "DIRECT" {
		t.Fatalf("forwarding remained %s after persistence failure", got)
	}
	selected, err := readSelections(eng.current.HomeDir, "fixture")
	if err != nil || selected["Manual"] != "" {
		t.Fatalf("selected=%v err=%v", selected, err)
	}
}

func TestAutomaticGroupClearsPinAndRejectsStaleProfile(t *testing.T) {
	fixture(t)
	request := selectionRequest{Profile: "fixture", Group: "Auto", Name: "REJECT", NodeID: snapshotNodeID(t, "Auto", "REJECT"), OperationID: "pin",
		ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision}
	result, err := commitSelection(request)
	if err != nil || result.Pinned != "REJECT" {
		t.Fatalf("pin=%+v err=%v", result, err)
	}
	request.ClearPin = true
	request.Name = ""
	request.OperationID = "unpin"
	result, err = commitSelection(request)
	if err != nil || result.Pinned != "" {
		t.Fatalf("unpin=%+v err=%v", result, err)
	}
	selected, err := readSelections(eng.current.HomeDir, "fixture")
	if err != nil {
		t.Fatal(err)
	}
	if _, found := selected["Auto"]; found {
		t.Fatal("pin remained on disk")
	}
	request.Profile = "obsolete"
	if _, err := commitSelection(request); err == nil {
		t.Fatal("stale profile accepted")
	}
}

func TestSelectionRejectsOldConfigurationWithSameProfileAndMembers(t *testing.T) {
	cfg := fixture(t)
	request := selectionRequest{Profile: "fixture", Group: "Manual", Name: "REJECT", NodeID: snapshotNodeID(t, "Manual", "REJECT"), OperationID: "stale-config",
		ExpectedBootID: eng.bootID, ExpectedRevision: eng.configRevision}
	eng.configRevision++
	publishRuntime()
	if _, err := commitSelection(request); err == nil || err.Error() != "selection_revision_changed" {
		t.Fatalf("old configuration request=%v", err)
	}
	if cfg.Proxies["Manual"].Adapter().(outboundgroup.ProxyGroup).Now() != "DIRECT" {
		t.Fatal("old request changed the new configuration")
	}
}

type (
	probeRequestBody = probe.RequestBody
	probeResponse    = probe.Response
)

func postProbe(w http.ResponseWriter, r *http.Request) {
	eng.probe.ServeHTTP(w, r)
}

func probeRequest(ctx context.Context, target, method string) *http.Request {
	return probeRequestWithOptions(ctx, probeRequestBody{URL: target, Method: method, BodyMode: "json", Timeout: 5000})
}

func probeRequestWithOptions(ctx context.Context, options probeRequestBody) *http.Request {
	body, _ := json.Marshal(options)
	request := httptest.NewRequestWithContext(ctx, http.MethodPost, "/arkclash/probe", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	return request
}

func TestRuleProbePreservesTargetStatusWithoutLocalProxyPort(t *testing.T) {
	fixture(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(403); io.WriteString(w, "fixture body") }))
	defer server.Close()
	recorder := httptest.NewRecorder()
	postProbe(recorder, probeRequest(context.Background(), server.URL, http.MethodGet))
	var result struct {
		Status   int
		Body     string
		BootID   string
		Revision uint64
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if recorder.Code != 200 || result.Status != 403 || result.Body != "fixture body" || result.BootID != eng.bootID {
		t.Fatalf("response=%d %+v", recorder.Code, result)
	}
}

func TestRuleProbeCancellationReleasesSlotAndConnection(t *testing.T) {
	fixture(t)
	entered := make(chan struct{})
	closed := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
		close(closed)
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { postProbe(httptest.NewRecorder(), probeRequest(ctx, server.URL, http.MethodGet)); close(done) }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("target never received request")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("probe retained execution slot")
	}
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatal("target connection remained open")
	}
	if len(eng.probe.Slots()) != 0 {
		t.Fatal("probe capacity leaked")
	}
}

func TestRuleProbeDiscardsReplyFromPreviousRevision(t *testing.T) {
	fixture(t)
	entered := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(entered); <-release; io.WriteString(w, "obsolete") }))
	defer server.Close()
	recorder := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		postProbe(recorder, probeRequest(context.Background(), server.URL, http.MethodGet))
		close(done)
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		close(release)
		t.Fatal("target never received request")
	}
	eng.mu.Lock()
	publishRuntime()
	eng.mu.Unlock()
	close(release)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("probe did not finish")
	}
	if recorder.Code != http.StatusConflict || strings.Contains(recorder.Body.String(), "obsolete") {
		t.Fatalf("stale response=%d %s", recorder.Code, recorder.Body.String())
	}
}

func TestProbeAndDelayCapacityAreNotNodeFailures(t *testing.T) {
	fixture(t)
	for range cap(eng.probe.Slots()) {
		eng.probe.Slots() <- struct{}{}
	}
	recorder := httptest.NewRecorder()
	postProbe(recorder, probeRequest(context.Background(), "http://127.0.0.1/", http.MethodHead))
	for range cap(eng.probe.Slots()) {
		<-eng.probe.Slots()
	}
	if recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("probe capacity=%d", recorder.Code)
	}
	for range cap(delaySlots) {
		delaySlots <- struct{}{}
	}
	recorder = httptest.NewRecorder()
	getDelay(recorder, delayRequest(context.Background(), "DIRECT", "", "http://127.0.0.1/", 0))
	for range cap(delaySlots) {
		<-delaySlots
	}
	if recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("delay capacity=%d", recorder.Code)
	}
}

func TestDelayCancellationReleasesExecutionSlot(t *testing.T) {
	fixture(t)
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(entered); <-r.Context().Done() }))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	request := delayRequest(ctx, "DIRECT", "", server.URL, 0)
	done := make(chan struct{})
	go func() { getDelay(httptest.NewRecorder(), request); close(done) }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("delay target never received request")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("delay retained slot")
	}
	if len(delaySlots) != 0 {
		t.Fatal("delay capacity leaked")
	}
}

func TestProfileSelectionsSurviveLegacyGlobalCacheDuringApply(t *testing.T) {
	fixture(t)
	raw, err := config.UnmarshalRawConfig([]byte(`mode: direct
dns:
  enable: true
  enhanced-mode: redir-host
  nameserver: [127.0.0.1]
  default-nameserver: [127.0.0.1]
  fake-ip-filter: []
proxy-groups:
  - name: Manual
    type: select
    proxies: [DIRECT, REJECT]
rules: ['MATCH,DIRECT']
`))
	if err != nil {
		t.Fatal(err)
	}
	raw.Profile.StoreSelected = true
	applyOverrides(raw, eng.current)
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveSelections(eng.current.HomeDir, eng.current.Profile, map[string]string{"Manual": "REJECT"}); err != nil {
		t.Fatal(err)
	}
	if err := restoreSelections(cfg, eng.current); err != nil {
		t.Fatal(err)
	}
	legacy := cachefile.Cache()
	t.Cleanup(func() {
		executor.Shutdown()
		profile.StoreSelected.Store(false)
		if legacy.DB != nil {
			_ = legacy.Close()
		}
	})
	profile.StoreSelected.Store(true)
	legacy.SetSelected("Manual", "DIRECT")
	if legacy.SelectedMap()["Manual"] != "DIRECT" {
		t.Fatal("legacy cache fixture was not saved")
	}
	executor.ApplyConfig(cfg, true)
	if got := cfg.Proxies["Manual"].Adapter().(outboundgroup.ProxyGroup).Now(); got != "REJECT" {
		t.Fatalf("global cache replaced the profile selection with %s", got)
	}
}

func TestStartTunValidatesOptionsAndClearsStateOnFailure(t *testing.T) {
	t.Cleanup(func() {
		hostTunStartError = nil
		hostTunStopError = nil
		setHostTun(false)
	})
	if err := startTun(11, tunNetworkOptions{Stack: "invalid", MTU: 1500}); err == nil || eng.tun != nil {
		t.Fatalf("invalid stack accepted: err=%v tun=%v", err, eng.tun)
	}
	if err := startTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 575}); err == nil || eng.tun != nil {
		t.Fatalf("too small IPv4 MTU accepted: err=%v tun=%v", err, eng.tun)
	}
	if err := startTun(11, tunNetworkOptions{Stack: "gvisor", IPv6: true, MTU: 1279}); err == nil || eng.tun != nil {
		t.Fatalf("too small IPv6 MTU accepted: err=%v tun=%v", err, eng.tun)
	}
	wantErr := errors.New("constructor failure")
	hostTunStartError = wantErr
	if err := startTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500}); !errors.Is(err, wantErr) || eng.tun != nil {
		t.Fatalf("constructor failure left non-nil tunListener: err=%v tun=%v", err, eng.tun)
	}
	hostTunStartError = nil
	if err := startTun(11, tunNetworkOptions{Stack: "gvisor", IPv6: true, MTU: 1500}); err != nil || eng.tun == nil {
		t.Fatalf("valid startTun failed: err=%v tun=%v", err, eng.tun)
	}
	if err := stopTun(); err != nil || eng.tun != nil {
		t.Fatalf("stopTun failed: err=%v tun=%v", err, eng.tun)
	}
}
