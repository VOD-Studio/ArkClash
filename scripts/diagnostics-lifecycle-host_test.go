package main

import (
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"

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
	mu.Lock()
	lease, previousConnections, previousDNS := diagnosticCapture, diagnosticConnections, diagnosticDNS
	mu.Unlock()
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
	oldBoot := runtimeBootID
	oldRevision := runtimeConfigRevision
	path := filepath.Join(current.HomeDir, "profiles", "next.yaml")
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
	mu.Lock()
	untouched := diagnosticCapture == lease && diagnosticConnections == previousConnections && diagnosticDNS == previousDNS
	mu.Unlock()
	if !untouched {
		t.Fatal("failed parse cleared diagnostic state")
	}
	pingDiagnosticCapture(t, capture, captureReader)
	if runtimeConfigRevision != oldRevision || current.Profile != "fixture" {
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
	mu.Lock()
	fresh := diagnosticCapture == lease && diagnosticConnections != nil && diagnosticConnections != previousConnections &&
		diagnosticDNS != nil && diagnosticDNS != previousDNS
	mu.Unlock()
	if !fresh || runtimeBootID != oldBoot || runtimeConfigRevision != oldRevision+1 || current.Profile != "next" {
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
		records[0].ID == oldRecords[0].ID || runtimeBootID != oldBoot || runtimeConfigRevision != oldRevision+1 {
		t.Fatal("reload leaked old history or detach cleared the new generation")
	}
	closeDiagnosticClient(t, connectionPage, connectionReader)
	closeDiagnosticClient(t, dnsPage, dnsReader)
	waitDiagnosticStream(t, connectionExecution.done)
	waitDiagnosticStream(t, dnsExecution.done)
	closeDiagnosticClient(t, capture, captureReader)
	waitDiagnosticStream(t, captureExecution.done)
}

type diagnosticUncertainInbound struct {
	net.Conn
	err error
}

func (conn *diagnosticUncertainInbound) Close() error {
	_ = conn.Conn.Close()
	return conn.err
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
	mu.Lock()
	dns := diagnosticDNS
	oldRevision := runtimeConfigRevision
	mu.Unlock()
	dns.observeDNS(diagnosticTestRecord(1))

	sentinel := errors.New("fixture forwarding close uncertainty")
	inbound, peer := net.Pipe()
	defer peer.Close()
	// 无效 Metadata 不拨号；已准入连接的 Close 错误仍由转发代次保留。
	tunnel.Tunnel.HandleTCPConn(&diagnosticUncertainInbound{Conn: inbound, err: sentinel}, &C.Metadata{})
	path := filepath.Join(current.HomeDir, "profiles", "next.yaml")
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
	mu.Lock()
	intact := diagnosticConnections == session.collector && diagnosticDNS == dns && runtimeConfigRevision == oldRevision
	mu.Unlock()
	if !intact {
		t.Fatal("failed suspension replaced canonical diagnostic state")
	}
	late, releaseLate := diagnosticTestSubscribe(t, "connections")
	recent := diagnosticTestFrame(t, late, time.Now()).Recent
	if len(recent) != 1 || recent[0].ID != old.ID() {
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
	session, status, err := subscribeDiagnostics("connections", runtimeBootID, runtimeConfigRevision)
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
