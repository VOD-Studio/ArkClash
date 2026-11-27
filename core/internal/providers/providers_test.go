package providers

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
)

var (
	_ P.ProxyProvider = (*stubProxyProvider)(nil)
	_ P.RuleProvider  = (*stubRuleProvider)(nil)
)

type stubProxyProvider struct {
	name      string
	vehicle   P.VehicleType
	count     atomic.Int32
	updatedAt atomic.Int64
	onUpdate  func() (bool, error)
	onReplace func([]byte) (bool, error)
}

func (s *stubProxyProvider) Name() string               { return s.name }
func (s *stubProxyProvider) VehicleType() P.VehicleType { return s.vehicle }
func (s *stubProxyProvider) Type() P.ProviderType       { return P.Proxy }
func (s *stubProxyProvider) Initial() error             { return nil }
func (s *stubProxyProvider) Update() error              { return nil }
func (s *stubProxyProvider) Proxies() []C.Proxy         { return nil }
func (s *stubProxyProvider) Touch()                     {}
func (s *stubProxyProvider) HealthCheck()               {}
func (s *stubProxyProvider) Version() uint32            { return 0 }
func (s *stubProxyProvider) HealthCheckURL() string     { return "" }
func (s *stubProxyProvider) RegisterHealthCheckTask(string, utils.IntRanges[uint16], string, uint) {
}
func (s *stubProxyProvider) Count() int         { return int(s.count.Load()) }
func (s *stubProxyProvider) Vehicle() P.Vehicle { return nil }
func (s *stubProxyProvider) ArkClashUpdatedAt() time.Time {
	if ms := s.updatedAt.Load(); ms > 0 {
		return time.UnixMilli(ms)
	}
	return time.Time{}
}
func (s *stubProxyProvider) ArkClashUpdate() (bool, error) {
	if s.onUpdate != nil {
		return s.onUpdate()
	}
	return false, nil
}
func (s *stubProxyProvider) ArkClashReplace(data []byte) (bool, error) {
	if s.onReplace != nil {
		return s.onReplace(data)
	}
	return false, nil
}

type stubRuleProvider struct {
	name      string
	vehicle   P.VehicleType
	behavior  P.RuleBehavior
	format    P.RuleFormat
	count     atomic.Int32
	updatedAt atomic.Int64
	onUpdate  func() (bool, error)
	onReplace func([]byte) (bool, error)
}

func (s *stubRuleProvider) Name() string                              { return s.name }
func (s *stubRuleProvider) VehicleType() P.VehicleType                { return s.vehicle }
func (s *stubRuleProvider) Type() P.ProviderType                      { return P.Rule }
func (s *stubRuleProvider) Initial() error                            { return nil }
func (s *stubRuleProvider) Update() error                             { return nil }
func (s *stubRuleProvider) Behavior() P.RuleBehavior                  { return s.behavior }
func (s *stubRuleProvider) Match(*C.Metadata, C.RuleMatchHelper) bool { return false }
func (s *stubRuleProvider) ShouldResolveIP() bool                     { return false }
func (s *stubRuleProvider) ShouldFindProcess() bool                   { return false }
func (s *stubRuleProvider) Strategy() any                             { return nil }
func (s *stubRuleProvider) Count() int                                { return int(s.count.Load()) }
func (s *stubRuleProvider) ArkClashFormat() P.RuleFormat              { return s.format }
func (s *stubRuleProvider) ArkClashUpdatedAt() time.Time {
	if ms := s.updatedAt.Load(); ms > 0 {
		return time.UnixMilli(ms)
	}
	return time.Time{}
}
func (s *stubRuleProvider) ArkClashUpdate() (bool, error) {
	if s.onUpdate != nil {
		return s.onUpdate()
	}
	return false, nil
}
func (s *stubRuleProvider) ArkClashReplace(data []byte) (bool, error) {
	if s.onReplace != nil {
		return s.onReplace(data)
	}
	return false, nil
}

func doRequest(h http.HandlerFunc, method, path string, payload any) *httptest.ResponseRecorder {
	var body *bytes.Reader
	if payload != nil {
		raw, _ := json.Marshal(payload)
		body = bytes.NewReader(raw)
	} else {
		body = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h(rec, req)
	return rec
}

func TestProviderHubUnitSnapshotMutexAndStaleReset(t *testing.T) {
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "profile-work"), 0o700); err != nil {
		t.Fatal(err)
	}
	hub := NewHub()
	defer func() { hub.Close()() }()

	// 未初始化前返回 503。
	if rec := doRequest(hub.HandleList, http.MethodGet, "/providers", nil); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("empty hub list=%d, want 503", rec.Code)
	}

	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	proxyStub := &stubProxyProvider{
		name: "shared", vehicle: P.HTTP,
		onUpdate: func() (bool, error) {
			entered <- struct{}{}
			<-release
			return true, nil
		},
	}
	proxyStub.count.Store(2)
	ruleStub := &stubRuleProvider{
		name: "shared", vehicle: P.HTTP, behavior: P.Domain, format: P.YamlRule,
		onUpdate: func() (bool, error) { return false, context.DeadlineExceeded },
	}
	ruleStub.count.Store(3)
	managedStub := &stubRuleProvider{
		name: ruleset.ManagedName("internal"), vehicle: P.File, behavior: P.Domain, format: P.TextRule,
	}

	id := Identity{BootID: "boot-1", ConfigRevision: 1, Profile: "unit", HomeDir: home}
	hub.Reset(id, &config.Config{
		Providers:     map[string]P.ProxyProvider{"shared": proxyStub},
		RuleProviders: map[string]P.RuleProvider{"shared": ruleStub, managedStub.name: managedStub},
	})

	// 快照区分同名 (proxy, shared) 与 (rule, shared)，并过滤托管规则集。
	rec := doRequest(hub.HandleList, http.MethodGet, "/providers", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list=%d %s", rec.Code, rec.Body.String())
	}
	var snap Snapshot
	if err := json.Unmarshal(rec.Body.Bytes(), &snap); err != nil {
		t.Fatal(err)
	}
	if len(snap.Items) != 2 || snap.Items[0].Kind != "proxy" || snap.Items[1].Kind != "rule" {
		t.Fatalf("unexpected items: %+v", snap.Items)
	}

	// 并发更新同一 proxy 互斥，但同名 rule 独立且超时映射为 504。
	var wg sync.WaitGroup
	var firstRec *httptest.ResponseRecorder
	wg.Add(1)
	go func() {
		defer wg.Done()
		firstRec = doRequest(hub.HandleUpdate, http.MethodPost, "/providers/update", UpdateRequest{
			BootID: id.BootID, ConfigRevision: id.ConfigRevision, Kind: "proxy", Name: "shared",
		})
	}()
	<-entered

	if busy := doRequest(hub.HandleUpdate, http.MethodPost, "/providers/update", UpdateRequest{
		BootID: id.BootID, ConfigRevision: id.ConfigRevision, Kind: "proxy", Name: "shared",
	}); busy.Code != http.StatusConflict || !strings.Contains(busy.Body.String(), "provider_busy") {
		t.Fatalf("expected provider_busy, got %d %s", busy.Code, busy.Body.String())
	}
	if timed := doRequest(hub.HandleUpdate, http.MethodPost, "/providers/update", UpdateRequest{
		BootID: id.BootID, ConfigRevision: id.ConfigRevision, Kind: "rule", Name: "shared",
	}); timed.Code != http.StatusGatewayTimeout || !strings.Contains(timed.Body.String(), "provider_timeout") {
		t.Fatalf("expected 504 provider_timeout, got %d %s", timed.Code, timed.Body.String())
	}

	// 热切换使进行中的更新返回 409 provider_stale_config。
	hub.Reset(Identity{BootID: "boot-1", ConfigRevision: 2, Profile: "unit-2", HomeDir: home}, &config.Config{})
	close(release)
	wg.Wait()
	if firstRec.Code != http.StatusConflict || !strings.Contains(firstRec.Body.String(), "provider_stale_config") {
		t.Fatalf("expected stale rejection, got %d %s", firstRec.Code, firstRec.Body.String())
	}
}

func TestValidateRuleCandidateMatrix(t *testing.T) {
	if err := validateRuleCandidate([]byte("payload:\n  - 'a.example.test'\n"), P.Domain, P.YamlRule); err != nil {
		t.Fatalf("valid yaml domain rejected: %v", err)
	}
	if err := validateRuleCandidate([]byte("192.0.2.0/24\n"), P.IPCIDR, P.TextRule); err != nil {
		t.Fatalf("valid text ipcidr rejected: %v", err)
	}
	if err := validateRuleCandidate([]byte("DOMAIN,example.test\n"), P.Classical, P.TextRule); err != nil {
		t.Fatalf("valid classical text rejected: %v", err)
	}
	if err := validateRuleCandidate([]byte("RULE-SET,nested\n"), P.Classical, P.TextRule); !errors.Is(err, errInvalidContent) {
		t.Fatalf("nested RULE-SET accepted: %v", err)
	}
	if err := validateRuleCandidate([]byte("bad/domain.test\n"), P.Domain, P.TextRule); !errors.Is(err, errInvalidContent) {
		t.Fatalf("slash domain accepted: %v", err)
	}
	var mrs bytes.Buffer
	if err := RP.ConvertToMrs([]byte("ok.example.test\n"), P.Domain, P.TextRule, &mrs); err != nil {
		t.Fatal(err)
	}
	if err := validateRuleCandidate(mrs.Bytes(), P.Domain, P.MrsRule); err != nil {
		t.Fatalf("valid mrs rejected: %v", err)
	}
	if err := validateRuleCandidate(mrs.Bytes(), P.IPCIDR, P.MrsRule); !errors.Is(err, errInvalidContent) {
		t.Fatalf("mismatched mrs behavior accepted: %v", err)
	}
}

type stubHijackWriter struct {
	*httptest.ResponseRecorder
	conn net.Conn
	rw   *bufio.ReadWriter
}

func (w *stubHijackWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return w.conn, w.rw, nil
}

func TestProviderHubEventsStreamInitialAndClose(t *testing.T) {
	hub := NewHub()
	hub.Reset(Identity{BootID: "boot-ws", ConfigRevision: 1, Profile: "ws", HomeDir: t.TempDir()}, &config.Config{})

	client, server := net.Pipe()
	defer client.Close()
	req := httptest.NewRequest(http.MethodGet, "/providers/events", nil)
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	rw := bufio.NewReadWriter(bufio.NewReader(server), bufio.NewWriter(server))

	done := make(chan struct{})
	go func() {
		hub.HandleEvents(&stubHijackWriter{ResponseRecorder: httptest.NewRecorder(), conn: server, rw: rw}, req)
		close(done)
	}()

	_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
	clientReader := bufio.NewReader(client)
	var statusLine string
	for {
		line, err := clientReader.ReadString('\n')
		if err != nil {
			t.Fatalf("read ws handshake: %v", err)
		}
		if statusLine == "" {
			statusLine = line
		}
		if line == "\r\n" {
			break
		}
	}
	if !strings.Contains(statusLine, "101 Switching Protocols") {
		t.Fatalf("unexpected ws handshake status: %q", statusLine)
	}
	// net.Pipe 下帧头与帧体会分次到达，按 WebSocket 帧长度读全首帧快照。
	hdr := make([]byte, 2)
	if _, err := io.ReadFull(clientReader, hdr); err != nil {
		t.Fatalf("read ws frame header: %v", err)
	}
	if hdr[0] != 0x81 {
		t.Fatalf("unexpected ws frame opcode: 0x%x", hdr[0])
	}
	payloadLen := int(hdr[1] & 0x7f)
	if payloadLen == 126 {
		ext := make([]byte, 2)
		if _, err := io.ReadFull(clientReader, ext); err != nil {
			t.Fatalf("read ws extended length: %v", err)
		}
		payloadLen = int(binary.BigEndian.Uint16(ext))
	}
	payload := make([]byte, payloadLen)
	if _, err := io.ReadFull(clientReader, payload); err != nil {
		t.Fatalf("read ws frame payload: %v", err)
	}
	if !strings.Contains(string(payload), `"type":"providers"`) || !strings.Contains(string(payload), `"bootId":"boot-ws"`) {
		t.Fatalf("missing initial provider snapshot: %q", string(payload))
	}

	wait := hub.Close()
	wait()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("events stream handler did not exit after Hub.Close")
	}
}
