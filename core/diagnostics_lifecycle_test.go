package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/diagnostics"
	"github.com/gobwas/ws"
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	D "github.com/miekg/dns"
)

type diagnosticStreamExecution struct {
	cancel context.CancelFunc
	done   chan struct{}
}

type diagnosticStreamServer struct {
	server  *httptest.Server
	entered chan *diagnosticStreamExecution
}

type diagnosticStreamHijacker struct {
	http.ResponseWriter
	wrap func(net.Conn, *bufio.ReadWriter) (net.Conn, *bufio.ReadWriter)
}

func (w diagnosticStreamHijacker) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	conn, rw, err := w.ResponseWriter.(http.Hijacker).Hijack()
	if err != nil {
		return nil, nil, err
	}
	conn, rw = w.wrap(conn, rw)
	return conn, rw, nil
}

func newDiagnosticStreamServer(t *testing.T, wrap func(net.Conn, *bufio.ReadWriter) (net.Conn, *bufio.ReadWriter)) *diagnosticStreamServer {
	t.Helper()
	s := &diagnosticStreamServer{entered: make(chan *diagnosticStreamExecution, 16)}
	s.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithCancel(r.Context())
		execution := &diagnosticStreamExecution{cancel: cancel, done: make(chan struct{})}
		s.entered <- execution
		defer close(execution.done)
		defer cancel()
		if wrap != nil {
			w = diagnosticStreamHijacker{ResponseWriter: w, wrap: wrap}
		}
		switch r.URL.Path {
		case "/capture":
			eng.diag.GetCapture(w, r.WithContext(ctx))
		case "/stats":
			eng.diag.GetStats(w, r.WithContext(ctx))
		case "/dns":
			eng.diag.GetDNS(w, r.WithContext(ctx))
		case "/logs":
			eng.diag.GetLogs(w, r.WithContext(ctx))
		case "/logs/clear":
			eng.diag.PostLogsClear(w, r.WithContext(ctx))
		default:
			eng.diag.GetConnections(w, r.WithContext(ctx))
		}
	}))
	t.Cleanup(s.server.Close)
	return s
}

func diagnosticStreamTarget(feed string) string {
	query := url.Values{"expectedBootId": {eng.bootID}}
	if feed != "capture" && feed != "logs" {
		query.Set("expectedConfigRevision", strconv.FormatUint(eng.configRevision, 10))
	}
	return "/" + feed + "?" + query.Encode()
}

func dialDiagnosticStream(t *testing.T, s *diagnosticStreamServer, feed string, smallReadBuffer bool) (net.Conn, *bufio.Reader, *diagnosticStreamExecution) {
	t.Helper()
	conn, err := net.DialTimeout("tcp", s.server.Listener.Addr().String(), 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	if smallReadBuffer {
		if err := conn.(*net.TCPConn).SetReadBuffer(1024); err != nil {
			t.Fatal(err)
		}
	}
	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	_, err = fmt.Fprintf(conn, "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", diagnosticStreamTarget(feed))
	if err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols || response.Header.Get("Sec-WebSocket-Accept") != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
		t.Fatalf("upgrade status=%d headers=%v", response.StatusCode, response.Header)
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	}
	select {
	case execution := <-s.entered:
		return conn, reader, execution
	case <-time.After(3 * time.Second):
		t.Fatal("handler did not start")
		return nil, nil, nil
	}
}

func waitDiagnosticStream(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("diagnostic worker did not exit")
	}
}

func readDiagnosticWSFrame(t *testing.T, conn net.Conn, reader *bufio.Reader) ws.Frame {
	t.Helper()
	if err := conn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	frame, err := ws.ReadFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := ws.CheckHeader(frame.Header, ws.StateClientSide); err != nil {
		t.Fatal(err)
	}
	return frame
}

type diagnosticStreamWireFrame struct {
	Type           string          `json:"type"`
	Kind           string          `json:"kind"`
	BootID         string          `json:"bootId"`
	ConfigRevision uint64          `json:"configRevision"`
	SessionID      string          `json:"sessionId"`
	Seq            uint64          `json:"seq"`
	Live           json.RawMessage `json:"live"`
	Recent         json.RawMessage `json:"recent"`
	Opened         json.RawMessage `json:"opened"`
	Closed         []string        `json:"closed"`
	Records        json.RawMessage `json:"records"`
}

func readDiagnosticCanonicalSnapshot(t *testing.T, conn net.Conn, reader *bufio.Reader, feed string) diagnosticStreamWireFrame {
	t.Helper()
	frame := readDiagnosticWSFrame(t, conn, reader)
	var snapshot diagnosticStreamWireFrame
	if frame.Header.OpCode != ws.OpText {
		t.Fatalf("initial opcode=%d", frame.Header.OpCode)
	}
	if err := json.Unmarshal(frame.Payload, &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Type != feed || snapshot.Kind != "snapshot" || snapshot.Seq != 1 || snapshot.SessionID == "" || snapshot.BootID != eng.bootID || snapshot.ConfigRevision != eng.configRevision {
		t.Fatalf("initial frame=%+v", snapshot)
	}
	return snapshot
}

func writeDiagnosticClientFrames(t *testing.T, conn net.Conn, frames ...ws.Frame) {
	t.Helper()
	var payload bytes.Buffer
	for _, frame := range frames {
		if err := ws.WriteFrame(&payload, ws.MaskFrame(frame)); err != nil {
			t.Fatal(err)
		}
	}
	if err := conn.SetWriteDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write(payload.Bytes()); err != nil {
		t.Fatal(err)
	}
}

func closeDiagnosticClient(t *testing.T, conn net.Conn, reader *bufio.Reader) {
	t.Helper()
	writeDiagnosticClientFrames(t, conn, ws.NewCloseFrame(ws.NewCloseFrameBody(ws.StatusNormalClosure, "done")))
	frame := readDiagnosticWSFrame(t, conn, reader)
	code, _ := ws.ParseCloseFrameData(frame.Payload)
	if frame.Header.OpCode != ws.OpClose || code != ws.StatusNormalClosure {
		t.Fatalf("close reply opcode=%d code=%d", frame.Header.OpCode, code)
	}
}

func readDiagnosticCaptureReady(t *testing.T, conn net.Conn, reader *bufio.Reader) {
	t.Helper()
	if frame := readDiagnosticWSFrame(t, conn, reader); frame.Header.OpCode != ws.OpText || string(frame.Payload) != "ready" {
		t.Fatalf("capture acknowledgement opcode=%d payload=%q", frame.Header.OpCode, frame.Payload)
	}
}

func pingDiagnosticCapture(t *testing.T, conn net.Conn, reader *bufio.Reader) {
	t.Helper()
	writeDiagnosticClientFrames(t, conn, ws.NewPingFrame([]byte("capture")))
	if frame := readDiagnosticWSFrame(t, conn, reader); frame.Header.OpCode != ws.OpPong || string(frame.Payload) != "capture" {
		t.Fatalf("capture sent data instead of pong: opcode=%d payload=%q", frame.Header.OpCode, frame.Payload)
	}
}

func diagnosticSnapshotRows[T any](t *testing.T, raw json.RawMessage) []T {
	t.Helper()
	var rows []T
	if err := json.Unmarshal(raw, &rows); err != nil || rows == nil {
		t.Fatalf("invalid snapshot rows: %s %v", raw, err)
	}
	return rows
}

func newDiagnosticStreamTracker(t *testing.T, host string) statistic.Tracker {
	t.Helper()
	conn, peer := net.Pipe()
	tracker := statistic.NewTCPTracker(outbound.NewConn(conn, outbound.NewDirect()), statistic.DefaultManager,
		&C.Metadata{NetWork: C.TCP, Type: C.HTTP, Host: host, DstPort: 80}, nil, 0, 0, false)
	t.Cleanup(func() { _ = tracker.Close(); _ = peer.Close() })
	return tracker
}

func newDiagnosticTestResolver(t *testing.T) dns.Resolvers {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	server := &D.Server{Listener: listener, NotifyStartedFunc: func() { close(started) }, Handler: D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		reply := new(D.Msg).SetReply(q)
		if strings.HasPrefix(q.Question[0].Name, "missing.") {
			reply.Rcode = D.RcodeNameError
		} else {
			reply.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.IPv4(192, 0, 2, 7)}}
		}
		_ = w.WriteMsg(reply)
	})}
	served := make(chan error, 1)
	go func() { served <- server.ActivateAndServe() }()
	waitDiagnosticStream(t, started)
	t.Cleanup(func() {
		_ = server.Shutdown()
		select {
		case <-served:
		case <-time.After(5 * time.Second):
			t.Fatal("DNS server shutdown deadlocked")
		}
	})
	rs := dns.NewResolver(dns.Config{Main: []dns.NameServer{{Net: "tcp", Addr: listener.Addr().String()}}, IPv6: true})
	t.Cleanup(rs.ResetConnection)
	return rs
}

func diagnosticTestQuery(t *testing.T, rs dns.Resolvers, name string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(resolver.WithInitiator(context.Background(), "rule"), 5*time.Second)
	defer cancel()
	if _, err := rs.ExchangeContext(ctx, new(D.Msg).SetQuestion(name, D.TypeA)); err != nil {
		t.Fatal(err)
	}
}

func diagnosticTestRecord(index int) dns.QueryRecord {
	question := D.Question{Name: fmt.Sprintf("request-%d.diag.test.", index), Qtype: D.TypeA, Qclass: D.ClassINET}
	return dns.QueryRecord{Question: question, Start: time.Unix(1700000000, 0), Initiator: "direct", Msg: &D.Msg{MsgHdr: D.MsgHdr{Rcode: D.RcodeSuccess}, Answer: []D.RR{&D.A{Hdr: D.RR_Header{Name: question.Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.IPv4(192, 0, 2, 7)}}}}
}

func diagnosticTestSubscribe(t *testing.T, feed string) (*diagnostics.Session, func()) {
	t.Helper()
	s, status, err := eng.diag.Subscribe(feed, eng.bootID, eng.configRevision)
	if err != nil || status != 0 {
		t.Fatalf("subscribe: %d %v", status, err)
	}
	var once sync.Once
	release := func() { once.Do(func() { s.Close(); s.CloseWorkerDone() }) }
	t.Cleanup(release)
	return s, release
}

func diagnosticTestFrame(t *testing.T, s *diagnostics.Session, now time.Time) diagnostics.ConnectionsFrame {
	t.Helper()
	frame, ok := s.NextFrameAt(now).(diagnostics.ConnectionsFrame)
	if !ok {
		t.Fatal("expected connection frame")
	}
	return frame
}

func diagnosticTestDNSFrame(t *testing.T, s *diagnostics.Session, now time.Time) diagnostics.DNSFrame {
	t.Helper()
	frame, ok := s.NextFrameAt(now).(diagnostics.DNSFrame)
	if !ok {
		t.Fatal("expected DNS frame")
	}
	return frame
}

func TestDiagnosticsReloadKeepsBootLeaseAndReplacesConfigurationRings(t *testing.T) {
	fixture(t)
	server := newDiagnosticStreamServer(t, nil)
	rs := newDiagnosticTestResolver(t)
	capture, captureReader, captureExecution := dialDiagnosticStream(t, server, "capture", false)
	readDiagnosticCaptureReady(t, capture, captureReader)
	lease, previousConnections, previousDNS, _ := eng.diag.StateTokens()
	previousConnDone, previousDNSDone := eng.diag.CollectorWorkerDones()
	old := newDiagnosticStreamTracker(t, "old.diag.test")
	if err := old.Close(); err != nil {
		t.Fatal(err)
	}
	diagnosticTestQuery(t, rs, "old.diag.test.")
	connectionPage, connectionReader, connectionExecution := dialDiagnosticStream(t, server, "connections", false)
	connectionSnapshot := readDiagnosticCanonicalSnapshot(t, connectionPage, connectionReader, "connections")
	dnsPage, dnsReader, dnsExecution := dialDiagnosticStream(t, server, "dns", false)
	dnsSnapshot := readDiagnosticCanonicalSnapshot(t, dnsPage, dnsReader, "dns")
	oldRecent := diagnosticSnapshotRows[diagnostics.Connection](t, connectionSnapshot.Recent)
	oldRecords := diagnosticSnapshotRows[diagnostics.DNSRecord](t, dnsSnapshot.Records)
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
	curCapture, curConns, curDNS, _ := eng.diag.StateTokens()
	if curCapture != lease || curConns != previousConnections || curDNS != previousDNS {
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
	waitDiagnosticStream(t, previousConnDone)
	waitDiagnosticStream(t, previousDNSDone)
	pingDiagnosticCapture(t, capture, captureReader)
	curCapture, curConns, curDNS, _ = eng.diag.StateTokens()
	fresh := curCapture == lease && curConns != nil && curConns != previousConnections &&
		curDNS != nil && curDNS != previousDNS
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
	recent := diagnosticSnapshotRows[diagnostics.Connection](t, connectionSnapshot.Recent)
	records := diagnosticSnapshotRows[diagnostics.DNSRecord](t, dnsSnapshot.Records)
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
	_, _, dnsToken, _ := eng.diag.StateTokens()
	eng.diag.ObserveDNS(diagnosticTestRecord(1))

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
	case <-session.Done():
		t.Fatal("failed suspension canceled the existing stream")
	default:
	}
	pingDiagnosticCapture(t, capture, reader)
	eng.mu.Lock()
	rev := eng.configRevision
	eng.mu.Unlock()
	_, curConns, curDNS, _ := eng.diag.StateTokens()
	if curConns != session.CollectorToken() || curDNS != dnsToken || rev != oldRevision {
		t.Fatal("failed suspension replaced canonical diagnostic state")
	}
	late, releaseLate := diagnosticTestSubscribe(t, "connections")
	recent := diagnosticTestFrame(t, late, time.Now()).Recent
	if !slices.ContainsFunc(recent, func(c diagnostics.Connection) bool { return c.ID == old.ID() }) {
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
	session, status, err := eng.diag.Subscribe("connections", eng.bootID, eng.configRevision)
	if err != nil {
		t.Fatalf("subscribe status=%d err=%v", status, err)
	}
	go func() { <-session.Done(); session.CloseWorkerDone() }()
	defer session.Close()
	metadata.SrcGeoIP[0] = "mutated-after-ingress"
	conn.chain[0] = "mutated-after-ingress"
	data, err := json.Marshal(session.NextFrame())
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
		raw, err := json.Marshal(corecfg.GeneralSettings{
			Revision: rev, DelayTimeout: 8000, LogLevel: "error", CaptureLogs: capture,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(corecfg.GeneralSettingsPath(options.HomeDir), raw, 0o600); err != nil {
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

	_, _, _, initialLogs := eng.diag.StateTokens()
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
	_, _, _, afterOff := eng.diag.StateTokens()
	identityOff := eng.diag.Identity()
	if afterOff != nil || identityOff.CaptureLogs {
		t.Fatalf("backup restore off leaked log collector: logs=%v identity=%+v", afterOff, identityOff)
	}
	if _, status, _ := eng.diag.Subscribe("logs", eng.Status().BootID, 0); status != http.StatusForbidden {
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
	_, _, _, afterOn := eng.diag.StateTokens()
	identityOn := eng.diag.Identity()
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
			if s, _, err := eng.diag.Subscribe("connections", st.BootID, st.ConfigRevision); err == nil {
				s.Close()
				s.CloseWorkerDone()
			}
			if stSession, _, err := eng.diag.SubscribeStats(st.BootID, st.ConfigRevision); err == nil {
				stSession.Close()
				stSession.CloseWorkerDone()
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
			eng.diag.PostDNSClearCache(httptest.NewRecorder(), req)
		}
	}()
	wg.Wait()
}
