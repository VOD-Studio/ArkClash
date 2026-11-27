package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestDiagnosticsReloadKeepsBootLeaseAndReplacesConfigurationRings(t *testing.T) {
	fixture(t)
	server := newDiagnosticStreamServer(t, nil)
	rs := newDiagnosticTestResolver(t)
	capture, captureReader, captureExecution := dialDiagnosticStream(t, server, "capture", false)
	readDiagnosticCaptureReady(t, capture, captureReader)
	eng.diag.mu.Lock()
	lease, previousConnections, previousDNS := eng.diag.capture, eng.diag.connections, eng.diag.dns
	eng.diag.mu.Unlock()
	old := newDiagnosticStreamTracker(t, "old.diag.test")
	if err := old.Close(); err != nil {
		t.Fatal(err)
	}
	diagnosticTestQuery(t, rs, "old.diag.test.")
	connectionPage, connectionReader, connectionExecution := dialDiagnosticStream(t, server, "connections", false)
	connectionSnapshot := readDiagnosticCanonicalSnapshot(t, connectionPage, connectionReader, "connections")
	dnsPage, dnsReader, dnsExecution := dialDiagnosticStream(t, server, "dns", false)
	dnsSnapshot := readDiagnosticCanonicalSnapshot(t, dnsPage, dnsReader, "dns")
	oldRecent := diagnosticSnapshotRows[DiagnosticConnection](t, connectionSnapshot.Recent)
	oldRecords := diagnosticSnapshotRows[DiagnosticDnsRecord](t, dnsSnapshot.Records)
	if len(oldRecent) != 1 || oldRecent[0].ID != old.ID() || len(oldRecords) != 1 || oldRecords[0].Domain != "old.diag.test" {
		t.Fatal("old boot lease did not populate both rings")
	}
	oldBoot := eng.bootID
	oldRevision := eng.configRevision
	path := filepath.Join(eng.current.HomeDir, "profiles", "next.yaml")
	if err := os.WriteFile(path, []byte("rules: [\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := reload(path, "next", new("fixture")); err == nil {
		t.Fatal("invalid config accepted")
	}
	for _, execution := range []*diagnosticStreamExecution{connectionExecution, dnsExecution, captureExecution} {
		select {
		case <-execution.done:
			t.Fatal("failed parse stopped a diagnostic socket")
		default:
		}
	}
	eng.diag.mu.Lock()
	untouched := eng.diag.capture == lease && eng.diag.connections == previousConnections && eng.diag.dns == previousDNS
	eng.diag.mu.Unlock()
	if !untouched {
		t.Fatal("failed parse cleared diagnostic state")
	}
	pingDiagnosticCapture(t, capture, captureReader)
	if eng.configRevision != oldRevision || eng.current.Profile != "fixture" {
		t.Fatal("failed parse changed runtime identity")
	}
	if err := os.WriteFile(path, []byte("mode: direct\nlog-level: silent\nrules: ['MATCH,DIRECT']\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := reload(path, "next", new("fixture")); err != nil {
		t.Fatal(err)
	}
	waitDiagnosticStream(t, connectionExecution.done)
	waitDiagnosticStream(t, dnsExecution.done)
	waitDiagnosticStream(t, previousConnections.workerDone)
	waitDiagnosticStream(t, previousDNS.workerDone)
	pingDiagnosticCapture(t, capture, captureReader)
	eng.diag.mu.Lock()
	fresh := eng.diag.capture == lease && eng.diag.connections != nil && eng.diag.connections != previousConnections &&
		eng.diag.dns != nil && eng.diag.dns != previousDNS
	eng.diag.mu.Unlock()
	if !fresh || eng.bootID != oldBoot || eng.configRevision != oldRevision+1 || eng.current.Profile != "next" {
		t.Fatal("successful reload did not advance configuration identity")
	}
	next := newDiagnosticStreamTracker(t, "next.diag.test")
	if err := next.Close(); err != nil {
		t.Fatal(err)
	}
	diagnosticTestQuery(t, rs, "next.diag.test.")
	if err := detachTun(); err != nil {
		t.Fatal(err)
	}
	pingDiagnosticCapture(t, capture, captureReader)
	connectionPage, connectionReader, connectionExecution = dialDiagnosticStream(t, server, "connections", false)
	connectionSnapshot = readDiagnosticCanonicalSnapshot(t, connectionPage, connectionReader, "connections")
	dnsPage, dnsReader, dnsExecution = dialDiagnosticStream(t, server, "dns", false)
	dnsSnapshot = readDiagnosticCanonicalSnapshot(t, dnsPage, dnsReader, "dns")
	recent := diagnosticSnapshotRows[DiagnosticConnection](t, connectionSnapshot.Recent)
	records := diagnosticSnapshotRows[DiagnosticDnsRecord](t, dnsSnapshot.Records)
	if len(recent) != 1 || recent[0].ID != next.ID() || len(records) != 1 || records[0].Domain != "next.diag.test" ||
		records[0].ID == oldRecords[0].ID || eng.bootID != oldBoot || eng.configRevision != oldRevision+1 {
		t.Fatal("reload leaked old history or detach cleared the new generation")
	}
	closeDiagnosticClient(t, connectionPage, connectionReader)
	closeDiagnosticClient(t, dnsPage, dnsReader)
	waitDiagnosticStream(t, connectionExecution.done)
	waitDiagnosticStream(t, dnsExecution.done)
	closeDiagnosticClient(t, capture, captureReader)
	waitDiagnosticStream(t, captureExecution.done)
}

func TestDiagnosticsReloadKeepsCollectorsOnForwardingSuspensionFailure(t *testing.T) {
	fixture(t)
	t.Cleanup(tunnel.ArkClashResumeForwarding)
	server := newDiagnosticStreamServer(t, nil)
	capture, reader, execution := dialDiagnosticStream(t, server, "capture", false)
	readDiagnosticCaptureReady(t, capture, reader)
	session, _ := diagnosticTestSubscribe(t, "connections")
	old := newDiagnosticStreamTracker(t, "preserve.diag.test")
	if err := old.Close(); err != nil {
		t.Fatal(err)
	}
	eng.mu.Lock()
	oldRevision := eng.configRevision
	eng.mu.Unlock()
	eng.diag.mu.Lock()
	dns := eng.diag.dns
	eng.diag.mu.Unlock()
	dns.observeDNS(diagnosticTestRecord(1))

	sentinel := errors.New("fixture forwarding close uncertainty")
	socksPort, entered, _ := forwardingBlockedSocks(t)
	inbound, peer := net.Pipe()
	defer peer.Close()
	go tunnel.Tunnel.HandleTCPConn(&forwardingCloseErrorConn{Conn: inbound, err: sentinel}, &C.Metadata{
		NetWork: C.TCP, DstIP: netip.MustParseAddr("127.0.0.1"), DstPort: uint16(socksPort),
	})
	if err := peer.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := peer.Write([]byte{5, 1, 0}); err != nil {
		t.Fatal(err)
	}
	forwardingAwait(t, entered, "connection was not forwarding before suspension")
	path := filepath.Join(eng.current.HomeDir, "profiles", "next.yaml")
	if err := os.WriteFile(path, []byte("mode: direct\nrules: ['MATCH,DIRECT']\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := reload(path, "next", new("fixture")); !errors.Is(err, sentinel) {
		t.Fatalf("reload did not fail at forwarding suspension: %v", err)
	}
	select {
	case <-session.done:
		t.Fatal("failed suspension canceled the existing stream")
	default:
	}
	pingDiagnosticCapture(t, capture, reader)
	eng.mu.Lock()
	rev := eng.configRevision
	eng.mu.Unlock()
	eng.diag.mu.Lock()
	intact := eng.diag.connections == session.collector && eng.diag.dns == dns && rev == oldRevision
	eng.diag.mu.Unlock()
	if !intact {
		t.Fatal("failed suspension replaced canonical diagnostic state")
	}
	late, releaseLate := diagnosticTestSubscribe(t, "connections")
	recent := diagnosticTestFrame(t, late, time.Now()).Recent
	if !slices.ContainsFunc(recent, func(c DiagnosticConnection) bool { return c.ID == old.ID() }) {
		t.Fatal("connection ring was cleared by failed suspension")
	}
	releaseLate()
	dnsSession, releaseDNS := diagnosticTestSubscribe(t, "dns")
	records := diagnosticTestDNSFrame(t, dnsSession, time.Now()).Records
	if len(records) != 1 || records[0].Domain != "request-1.diag.test" {
		t.Fatal("DNS ring was cleared by failed suspension")
	}
	releaseDNS()
	closeDiagnosticClient(t, capture, reader)
	waitDiagnosticStream(t, execution.done)
}

type lifecycleDiagnosticConn struct {
	C.Conn
	chain C.Chain
}

func (c *lifecycleDiagnosticConn) Close() error              { return nil }
func (c *lifecycleDiagnosticConn) RemoteDestination() string { return "fixture.diag.test:443" }
func (c *lifecycleDiagnosticConn) Chains() C.Chain           { return c.chain }
func (c *lifecycleDiagnosticConn) ProviderChains() C.Chain   { return nil }

func TestDiagnosticsMetadataSnapshotExcludesPrivateTrackerFields(t *testing.T) {
	fixture(t)
	metadata := &C.Metadata{
		NetWork: C.TCP, Host: "fixture.diag.test", DstIP: netip.MustParseAddr("2001:db8::1"),
		SrcPort: 54321, DstPort: 443, SrcGeoIP: []string{"initial"},
		InUser: "must-not-export", Process: "must-not-export", Uid: 1234,
	}
	conn := &lifecycleDiagnosticConn{chain: C.Chain{"DIRECT"}}
	tracker := statistic.NewTCPTracker(conn, statistic.DefaultManager, metadata, nil, 12, 34, false)
	defer tracker.Close()
	session, status, err := subscribeDiagnostics("connections", eng.bootID, eng.configRevision)
	if err != nil {
		t.Fatalf("subscribe status=%d err=%v", status, err)
	}
	go func() { <-session.done; close(session.workerDone) }()
	defer session.close()
	metadata.SrcGeoIP[0] = "mutated-after-ingress"
	conn.chain[0] = "mutated-after-ingress"
	data, err := json.Marshal(session.nextFrame())
	if err != nil {
		t.Fatal(err)
	}
	var frame struct {
		Live []struct {
			ID             string         `json:"id"`
			Metadata       map[string]any `json:"metadata"`
			Chains         []string       `json:"chains"`
			ProviderChains []string       `json:"providerChains"`
			Upload         int64          `json:"upload"`
			Download       int64          `json:"download"`
		} `json:"live"`
		Recent []any `json:"recent"`
	}
	if err := json.Unmarshal(data, &frame); err != nil {
		t.Fatal(err)
	}
	if len(frame.Live) == 0 || frame.Recent == nil || len(frame.Recent) != 0 {
		t.Fatalf("invalid baseline frame: %s", data)
	}
	record := frame.Live[0]
	found := false
	for _, candidate := range frame.Live {
		if candidate.ID == tracker.ID() {
			record = candidate
			found = true
			break
		}
	}
	if !found {
		t.Fatal("baseline omitted existing tracker")
	}
	for _, field := range []string{"uid", "process", "processPath", "inboundUser", "rawSrcAddr", "rawDstAddr"} {
		if _, leaked := record.Metadata[field]; leaked {
			t.Fatalf("exported private field %s", field)
		}
	}
	if record.Metadata["sourceIP"] != "" || record.Metadata["destinationIP"] != "2001:db8::1" ||
		record.Metadata["sourcePort"] != "54321" || record.Metadata["destinationPort"] != "443" {
		t.Fatalf("wrong address/port encoding: %+v", record.Metadata)
	}
	geo, ok := record.Metadata["sourceGeoIP"].([]any)
	if !ok || len(geo) != 1 || geo[0] != "initial" || len(record.Chains) != 1 || record.Chains[0] != "DIRECT" {
		t.Fatal("metadata snapshot retained mutable tracker slices")
	}
	destinationGeo, ok := record.Metadata["destinationGeoIP"].([]any)
	if !ok || destinationGeo == nil || record.ProviderChains == nil {
		t.Fatal("missing arrays encoded as null")
	}
	if record.Upload != 12 || record.Download != 34 {
		t.Fatal("lost initial cumulative traffic")
	}
}

func TestBackupRestoreSynchronizesDiagnosticLogsCollector(t *testing.T) {
	options := lifecycleOptions(t)
	profilePath := lifecycleWriteProfile(t, options, "p1", lifecycleProfile)
	options.Profile = "p1"
	options.ConfigPath = profilePath
	writeGeneral := func(rev string, capture bool) {
		t.Helper()
		raw, err := json.Marshal(generalSettings{
			Revision: rev, DelayTimeout: 8000, LogLevel: "error", CaptureLogs: capture,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(generalSettingsPath(options.HomeDir), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeList := func(rev string) {
		t.Helper()
		body := fmt.Sprintf(`{"current":"p1","revision":%q}`, rev)
		if err := os.WriteFile(filepath.Join(options.HomeDir, "profiles", "list.json"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeGeneral("init-on", true)
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })

	eng.diag.mu.Lock()
	initialLogs := eng.diag.logs
	eng.diag.mu.Unlock()
	if initialLogs == nil {
		t.Fatal("start with CaptureLogs=true did not start log collector")
	}

	// 备份恢复将 CaptureLogs 从开改为关：无页面订阅时也必须立即退休日志观察器并同步身份。
	writeGeneral("restored-off", false)
	writeList("rev-off")
	if err := applyBackup(backupApplyRequest{
		BootID: eng.Status().BootID, Profile: "p1", Revision: "rev-off", Mode: "direct",
	}); err != nil {
		t.Fatal(err)
	}
	eng.diag.mu.Lock()
	afterOff, identityOff := eng.diag.logs, eng.diag.identity
	eng.diag.mu.Unlock()
	if afterOff != nil || identityOff.CaptureLogs {
		t.Fatalf("backup restore off leaked log collector: logs=%v identity=%+v", afterOff, identityOff)
	}
	if _, status, _ := subscribeDiagnostics("logs", eng.Status().BootID, 0); status != http.StatusForbidden {
		t.Fatalf("expected 403 after backup disabled logs, got %d", status)
	}

	// 再由备份恢复将 CaptureLogs 从关改为开：立即拉起日志采集器并允许订阅。
	writeGeneral("restored-on", true)
	writeList("rev-on")
	if err := applyBackup(backupApplyRequest{
		BootID: eng.Status().BootID, Profile: "p1", Revision: "rev-on", Mode: "direct",
	}); err != nil {
		t.Fatal(err)
	}
	eng.diag.mu.Lock()
	afterOn, identityOn := eng.diag.logs, eng.diag.identity
	eng.diag.mu.Unlock()
	if afterOn == nil || !identityOn.CaptureLogs {
		t.Fatalf("backup restore on did not start log collector: logs=%v identity=%+v", afterOn, identityOn)
	}
}

func TestDiagnosticsConcurrentSubscribeAndActionsWithReload(t *testing.T) {
	options := lifecycleOptions(t)
	firstPath := lifecycleWriteProfile(t, options, "a", lifecycleProfile)
	secondPath := lifecycleWriteProfile(t, options, "b", lifecycleProfile)
	options.Profile = "a"
	options.ConfigPath = firstPath
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })

	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		for i := range 8 {
			p, name := secondPath, "b"
			if i%2 == 1 {
				p, name = firstPath, "a"
			}
			if err := reload(p, name, nil); err != nil {
				t.Errorf("reload %d: %v", i, err)
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		for range 20 {
			st := eng.Status()
			if st == nil {
				continue
			}
			if s, _, err := subscribeDiagnostics("connections", st.BootID, st.ConfigRevision); err == nil {
				s.close()
				close(s.workerDone)
			}
			if stSession, _, err := subscribeDiagnosticStats(st.BootID, st.ConfigRevision); err == nil {
				stSession.close()
				close(stSession.workerDone)
			}
		}
	}()
	go func() {
		defer wg.Done()
		for range 20 {
			st := eng.Status()
			if st == nil {
				continue
			}
			body := fmt.Sprintf(`{"expectedBootId":%q,"expectedConfigRevision":%d}`, st.BootID, st.ConfigRevision)
			req := httptest.NewRequest(http.MethodPost, "/arkclash/diagnostics/dns/clear-cache", strings.NewReader(body))
			postDiagnosticDnsClearCache(httptest.NewRecorder(), req)
		}
	}()
	wg.Wait()
}
