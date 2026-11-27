package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gobwas/ws"
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
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
			getDiagnosticCapture(w, r.WithContext(ctx))
		case "/stats":
			getDiagnosticStats(w, r.WithContext(ctx))
		case "/dns":
			getDiagnosticDns(w, r.WithContext(ctx))
		case "/logs":
			getDiagnosticLogs(w, r.WithContext(ctx))
		case "/logs/clear":
			postDiagnosticLogsClear(w, r.WithContext(ctx))
		default:
			getDiagnosticConnections(w, r.WithContext(ctx))
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

func diagnosticStreamRequest(target string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, target, nil)
	r.Header.Set("Connection", "keep-alive, Upgrade")
	r.Header.Set("Upgrade", "websocket")
	r.Header.Set("Sec-WebSocket-Version", "13")
	r.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	return r
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

func activeDiagnosticStream(t *testing.T, feed string) (*diagnosticCollector, *diagnosticSession) {
	t.Helper()
	eng.diag.mu.Lock()
	defer eng.diag.mu.Unlock()
	c := eng.diag.connections
	if feed == "dns" {
		c = eng.diag.dns
	}
	if c == nil {
		t.Fatal("subscription missing")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.sessions) != 1 {
		t.Fatalf("subscriptions=%d", len(c.sessions))
	}
	for session := range c.sessions {
		return c, session
	}
	panic("unreachable")
}

func assertDiagnosticStreamRetired(t *testing.T, c *diagnosticCollector, session *diagnosticSession) {
	t.Helper()
	waitDiagnosticStream(t, session.workerDone)
	waitDiagnosticStream(t, c.workerDone)
	eng.diag.mu.Lock()
	defer eng.diag.mu.Unlock()
	if c.feed == "dns" && eng.diag.dns == c || c.feed == "connections" && eng.diag.connections == c {
		t.Fatal("last subscription retained its collector")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.closed || len(c.sessions) != 0 || len(c.connections) != 0 || len(c.recent) != 0 || len(c.dnsRecords) != 0 {
		t.Fatal("retired collector retained observation state")
	}
	select {
	case <-session.done:
	default:
		t.Fatal("retired session is still open")
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

func readDiagnosticSnapshot(t *testing.T, conn net.Conn, reader *bufio.Reader, feed string) diagnosticStreamWireFrame {
	t.Helper()
	snapshot := readDiagnosticCanonicalSnapshot(t, conn, reader, feed)
	if feed == "dns" {
		if string(snapshot.Records) != "[]" {
			t.Fatalf("initial DNS records=%s", snapshot.Records)
		}
	} else if string(snapshot.Recent) != "[]" || string(snapshot.Live) != "[]" {
		t.Fatalf("initial connections live=%s recent=%s", snapshot.Live, snapshot.Recent)
	}
	return snapshot
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

func TestDiagnosticsCaptureCollectsAndTransfersWithoutPageStreams(t *testing.T) {
	fixture(t)
	rs := newDiagnosticTestResolver(t)
	server := newDiagnosticStreamServer(t, nil)
	oldCapture, oldReader, oldExecution := dialDiagnosticStream(t, server, "capture", false)
	readDiagnosticCaptureReady(t, oldCapture, oldReader)
	eng.diag.mu.Lock()
	connections, queries := eng.diag.connections, eng.diag.dns
	eng.diag.mu.Unlock()
	if connections == nil || queries == nil {
		t.Fatal("capture did not enable both observers")
	}
	first := newDiagnosticStreamTracker(t, "first.diag.test")
	first.Info().UploadTotal.Add(17)
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	active := newDiagnosticStreamTracker(t, "active.diag.test")
	active.Info().UploadTotal.Add(23)
	diagnosticTestQuery(t, rs, "first.diag.test.")
	connections.mu.Lock()
	idle := len(connections.sessions) == 0 && connections.sampleDue.IsZero() && connections.timer == nil &&
		connections.connections[first.ID()].info == nil && connections.connections[active.ID()].dto.Upload == 0
	connections.mu.Unlock()
	if !idle {
		t.Fatal("capture-only observer sampled counters or kept closed tracker references")
	}
	pingDiagnosticCapture(t, oldCapture, oldReader)

	failed := diagnosticFailedHijacker{ResponseRecorder: httptest.NewRecorder(), hijack: func() (net.Conn, *bufio.ReadWriter, error) {
		return nil, nil, errors.New("fixture failure")
	}}
	getDiagnosticCapture(failed, diagnosticStreamRequest(diagnosticStreamTarget("capture")))
	pingDiagnosticCapture(t, oldCapture, oldReader)

	capture, captureReader, captureExecution := dialDiagnosticStream(t, server, "capture", false)
	readDiagnosticCaptureReady(t, capture, captureReader)
	waitDiagnosticStream(t, oldExecution.done)
	eng.diag.mu.Lock()
	preserved := eng.diag.connections == connections && eng.diag.dns == queries
	eng.diag.mu.Unlock()
	if !preserved {
		t.Fatal("lease transfer retired an active collector")
	}
	requests, requestsReader, requestsExecution := dialDiagnosticStream(t, server, "connections", false)
	snapshot := readDiagnosticCanonicalSnapshot(t, requests, requestsReader, "connections")
	live := diagnosticSnapshotRows[DiagnosticConnection](t, snapshot.Live)
	recent := diagnosticSnapshotRows[DiagnosticConnection](t, snapshot.Recent)
	if len(live) != 1 || live[0].ID != active.ID() || live[0].Upload != 23 ||
		len(recent) != 2 || recent[0].ID != first.ID() || recent[0].Upload != 17 || recent[1].ID != active.ID() || recent[1].Upload != 23 {
		t.Fatalf("hidden connection records missing or stale: live=%+v recent=%+v", live, recent)
	}
	dnsPage, dnsReader, dnsExecution := dialDiagnosticStream(t, server, "dns", false)
	dnsSnapshot := readDiagnosticCanonicalSnapshot(t, dnsPage, dnsReader, "dns")
	records := diagnosticSnapshotRows[DiagnosticDnsRecord](t, dnsSnapshot.Records)
	if len(records) != 1 || records[0].Domain != "first.diag.test" {
		t.Fatalf("hidden DNS records missing: %+v", records)
	}
	firstDNSID := records[0].ID
	if err := active.Close(); err != nil {
		t.Fatal(err)
	}
	active.Info().DownloadTotal.Add(19)
	_ = requests.Close()
	closeDiagnosticClient(t, dnsPage, dnsReader)
	waitDiagnosticStream(t, requestsExecution.done)
	waitDiagnosticStream(t, dnsExecution.done)
	connections.mu.Lock()
	closedReleased := connections.sampleDue.IsZero() && connections.connections[active.ID()].info == nil
	connections.mu.Unlock()
	if !closedReleased {
		t.Fatal("last visible stream left closed-counter polling enabled")
	}

	second := newDiagnosticStreamTracker(t, "second.diag.test")
	if err := second.Close(); err != nil {
		t.Fatal(err)
	}
	diagnosticTestQuery(t, rs, "second.diag.test.")
	requests, requestsReader, requestsExecution = dialDiagnosticStream(t, server, "connections", false)
	snapshot = readDiagnosticCanonicalSnapshot(t, requests, requestsReader, "connections")
	recent = diagnosticSnapshotRows[DiagnosticConnection](t, snapshot.Recent)
	if string(snapshot.Live) != "[]" || len(recent) != 3 || recent[0].ID != first.ID() ||
		recent[1].ID != active.ID() || recent[1].Download != 19 || recent[2].ID != second.ID() {
		t.Fatalf("reopened connections lost background history: %+v", recent)
	}
	dnsPage, dnsReader, dnsExecution = dialDiagnosticStream(t, server, "dns", false)
	dnsSnapshot = readDiagnosticCanonicalSnapshot(t, dnsPage, dnsReader, "dns")
	records = diagnosticSnapshotRows[DiagnosticDnsRecord](t, dnsSnapshot.Records)
	if len(records) != 2 || records[0].ID != firstDNSID || records[1].Domain != "second.diag.test" {
		t.Fatalf("reopened DNS lost background history: %+v", records)
	}
	closeDiagnosticClient(t, requests, requestsReader)
	closeDiagnosticClient(t, dnsPage, dnsReader)
	waitDiagnosticStream(t, requestsExecution.done)
	waitDiagnosticStream(t, dnsExecution.done)
	pingDiagnosticCapture(t, capture, captureReader)
	closeDiagnosticClient(t, capture, captureReader)
	waitDiagnosticStream(t, captureExecution.done)
	waitDiagnosticStream(t, connections.workerDone)
	waitDiagnosticStream(t, queries.workerDone)
	eng.diag.mu.Lock()
	released := eng.diag.capture == nil && eng.diag.connections == nil && eng.diag.dns == nil
	eng.diag.mu.Unlock()
	if !released {
		t.Fatal("last owner left an active lease or observer")
	}

	gap := newDiagnosticStreamTracker(t, "gap.diag.test")
	if err := gap.Close(); err != nil {
		t.Fatal(err)
	}
	diagnosticTestQuery(t, rs, "gap.diag.test.")
	capture, captureReader, captureExecution = dialDiagnosticStream(t, server, "capture", false)
	readDiagnosticCaptureReady(t, capture, captureReader)
	diagnosticTestQuery(t, rs, "restart.diag.test.")
	requests, requestsReader, requestsExecution = dialDiagnosticStream(t, server, "connections", false)
	readDiagnosticSnapshot(t, requests, requestsReader, "connections")
	dnsPage, dnsReader, dnsExecution = dialDiagnosticStream(t, server, "dns", false)
	dnsSnapshot = readDiagnosticCanonicalSnapshot(t, dnsPage, dnsReader, "dns")
	records = diagnosticSnapshotRows[DiagnosticDnsRecord](t, dnsSnapshot.Records)
	if len(records) != 1 || records[0].ID == firstDNSID || records[0].Domain != "restart.diag.test" {
		t.Fatalf("collector restart replayed gap or reused DNS ID: %+v", records)
	}
	closeDiagnosticClient(t, requests, requestsReader)
	closeDiagnosticClient(t, dnsPage, dnsReader)
	waitDiagnosticStream(t, requestsExecution.done)
	waitDiagnosticStream(t, dnsExecution.done)
	closeDiagnosticClient(t, capture, captureReader)
	waitDiagnosticStream(t, captureExecution.done)
}

func TestDiagnosticsCaptureCancellationPreservesOnlyVisibleFeed(t *testing.T) {
	for _, cause := range []string{"tcp-eof", "request", "boot-stop"} {
		t.Run(cause, func(t *testing.T) {
			fixture(t)
			server := newDiagnosticStreamServer(t, nil)
			capture, captureReader, captureExecution := dialDiagnosticStream(t, server, "capture", false)
			readDiagnosticCaptureReady(t, capture, captureReader)
			requests, requestsReader, requestsExecution := dialDiagnosticStream(t, server, "connections", false)
			readDiagnosticSnapshot(t, requests, requestsReader, "connections")
			connections, session := activeDiagnosticStream(t, "connections")
			eng.diag.mu.Lock()
			dns := eng.diag.dns
			eng.diag.mu.Unlock()
			switch cause {
			case "tcp-eof":
				_ = capture.Close()
			case "request":
				captureExecution.cancel()
			case "boot-stop":
				eng.mu.Lock()
				wait := eng.diag.Stop()
				eng.mu.Unlock()
				wait()
			}
			waitDiagnosticStream(t, captureExecution.done)
			waitDiagnosticStream(t, dns.workerDone)
			if cause != "boot-stop" {
				eng.diag.mu.Lock()
				ownedOnlyByPage := eng.diag.capture == nil && eng.diag.dns == nil && eng.diag.connections == connections
				eng.diag.mu.Unlock()
				if !ownedOnlyByPage {
					t.Fatal("only visible feed should survive capture cancellation")
				}
				closeDiagnosticClient(t, requests, requestsReader)
			}
			waitDiagnosticStream(t, requestsExecution.done)
			assertDiagnosticStreamRetired(t, connections, session)
		})
	}
}

func TestDiagnosticsCaptureRejectsInvalidRuntime(t *testing.T) {
	fixture(t)
	for _, tc := range []struct {
		name, target string
		status       int
	}{
		{"missing-boot", "/capture", http.StatusBadRequest},
		{"duplicate-boot", diagnosticStreamTarget("capture") + "&expectedBootId=x", http.StatusBadRequest},
		{"malformed-query", "/capture?expectedBootId=%zz", http.StatusBadRequest},
		{"stale-boot", "/capture?expectedBootId=old", http.StatusConflict},
		{"stopped", diagnosticStreamTarget("capture"), http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.name == "stopped" {
				eng.diag.mu.Lock()
				eng.diag.identity.Running = false
				eng.diag.mu.Unlock()
				defer func() {
					eng.diag.mu.Lock()
					eng.diag.identity.Running = true
					eng.diag.mu.Unlock()
				}()
			}
			response := httptest.NewRecorder()
			getDiagnosticCapture(response, diagnosticStreamRequest(tc.target))
			eng.diag.mu.Lock()
			untouched := eng.diag.connections == nil && eng.diag.dns == nil && eng.diag.capture == nil
			eng.diag.mu.Unlock()
			if response.Code != tc.status || !untouched {
				t.Fatalf("status=%d body=%s registry untouched=%v", response.Code, response.Body, untouched)
			}
		})
	}
}

func TestDiagnosticsStreamRejectsInvalidRequests(t *testing.T) {
	fixture(t)
	validQuery := url.Values{"expectedBootId": {eng.bootID}, "expectedConfigRevision": {strconv.FormatUint(eng.configRevision, 10)}}.Encode()
	tests := []struct {
		name   string
		query  string
		mutate func(*http.Request)
	}{
		{name: "missing-runtime", query: ""},
		{name: "missing-boot", query: "expectedConfigRevision=1"},
		{name: "empty-boot", query: "expectedBootId=&expectedConfigRevision=1"},
		{name: "blank-boot", query: "expectedBootId=%20%09&expectedConfigRevision=1"},
		{name: "duplicate-boot", query: validQuery + "&expectedBootId=other"},
		{name: "missing-revision", query: "expectedBootId=x"},
		{name: "empty-revision", query: "expectedBootId=x&expectedConfigRevision="},
		{name: "zero-revision", query: "expectedBootId=x&expectedConfigRevision=0"},
		{name: "negative-revision", query: "expectedBootId=x&expectedConfigRevision=-1"},
		{name: "signed-revision", query: "expectedBootId=x&expectedConfigRevision=%2b1"},
		{name: "fraction-revision", query: "expectedBootId=x&expectedConfigRevision=1.5"},
		{name: "overflow-revision", query: "expectedBootId=x&expectedConfigRevision=18446744073709551616"},
		{name: "duplicate-revision", query: validQuery + "&expectedConfigRevision=1"},
		{name: "bad-escape", query: validQuery + "&bad=%zz"},
		{name: "bad-query-separator", query: validQuery + ";bad=1"},
		{name: "method", query: validQuery, mutate: func(r *http.Request) { r.Method = http.MethodPost }},
		{name: "http-version", query: validQuery, mutate: func(r *http.Request) { r.ProtoMajor, r.ProtoMinor = 1, 0 }},
		{name: "missing-upgrade", query: validQuery, mutate: func(r *http.Request) { r.Header.Del("Upgrade") }},
		{name: "wrong-upgrade", query: validQuery, mutate: func(r *http.Request) { r.Header.Set("Upgrade", "h2c") }},
		{name: "missing-connection", query: validQuery, mutate: func(r *http.Request) { r.Header.Del("Connection") }},
		{name: "connection-substring", query: validQuery, mutate: func(r *http.Request) { r.Header.Set("Connection", "not-upgrade") }},
		{name: "missing-key", query: validQuery, mutate: func(r *http.Request) { r.Header.Del("Sec-WebSocket-Key") }},
		{name: "invalid-key", query: validQuery, mutate: func(r *http.Request) { r.Header.Set("Sec-WebSocket-Key", "bad!") }},
		{name: "short-key", query: validQuery, mutate: func(r *http.Request) { r.Header.Set("Sec-WebSocket-Key", "c2hvcnQ=") }},
		{name: "version", query: validQuery, mutate: func(r *http.Request) { r.Header.Set("Sec-WebSocket-Version", "12") }},
	}
	for _, feed := range []string{"connections", "dns"} {
		for _, test := range tests {
			t.Run(feed+"/"+test.name, func(t *testing.T) {
				r := diagnosticStreamRequest("/" + feed + "?" + test.query)
				if test.mutate != nil {
					test.mutate(r)
				}
				w := httptest.NewRecorder()
				getDiagnosticStream(w, r, feed)
				if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "diagnostics_invalid_request") {
					t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
				}
				eng.diag.mu.Lock()
				defer eng.diag.mu.Unlock()
				if eng.diag.connections != nil || eng.diag.dns != nil {
					t.Fatal("invalid handshake installed observation hooks")
				}
			})
		}
	}
}

func TestDiagnosticsStreamRejectsStaleAndStoppedRuntime(t *testing.T) {
	fixture(t)
	for _, feed := range []string{"connections", "dns"} {
		for _, stale := range []string{"boot", "configuration", "stopped"} {
			t.Run(feed+"/"+stale, func(t *testing.T) {
				r := diagnosticStreamRequest(diagnosticStreamTarget(feed))
				query := r.URL.Query()
				status, message := http.StatusConflict, "diagnostics_stale_runtime"
				if stale == "boot" {
					query.Set("expectedBootId", "old-boot")
				} else if stale == "configuration" {
					query.Set("expectedConfigRevision", strconv.FormatUint(eng.configRevision+1, 10))
				} else {
					eng.diag.mu.Lock()
					eng.diag.identity.Running = false
					eng.diag.mu.Unlock()
					defer func() {
						eng.diag.mu.Lock()
						eng.diag.identity.Running = true
						eng.diag.mu.Unlock()
					}()
					status, message = http.StatusServiceUnavailable, "diagnostics_not_ready"
				}
				r.URL.RawQuery = query.Encode()
				w := httptest.NewRecorder()
				getDiagnosticStream(w, r, feed)
				if w.Code != status || !strings.Contains(w.Body.String(), message) {
					t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
				}
			})
		}
	}
}

type diagnosticFailedHijacker struct {
	*httptest.ResponseRecorder
	hijack func() (net.Conn, *bufio.ReadWriter, error)
}

func (w diagnosticFailedHijacker) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return w.hijack()
}

func TestDiagnosticsStreamFailedHandshakeCompletesWorker(t *testing.T) {
	for _, feed := range []string{"connections", "dns"} {
		for _, failure := range []string{"hijack", "flush", "unsupported"} {
			t.Run(feed+"/"+failure, func(t *testing.T) {
				fixture(t)
				var c *diagnosticCollector
				var session *diagnosticSession
				var w http.ResponseWriter = httptest.NewRecorder()
				if failure != "unsupported" {
					w = diagnosticFailedHijacker{ResponseRecorder: httptest.NewRecorder(), hijack: func() (net.Conn, *bufio.ReadWriter, error) {
						c, session = activeDiagnosticStream(t, feed)
						if failure == "hijack" {
							return nil, nil, errors.New("fixture hijack failure")
						}
						conn, peer := net.Pipe()
						_ = peer.Close()
						t.Cleanup(func() { _ = conn.Close() })
						return conn, bufio.NewReadWriter(bufio.NewReader(conn), bufio.NewWriter(conn)), nil
					}}
				}
				getDiagnosticStream(w, diagnosticStreamRequest(diagnosticStreamTarget(feed)), feed)
				if session != nil {
					assertDiagnosticStreamRetired(t, c, session)
				} else {
					eng.diag.mu.Lock()
					defer eng.diag.mu.Unlock()
					if eng.diag.connections != nil || eng.diag.dns != nil {
						t.Fatal("unsupported hijacker retained collector")
					}
				}
			})
		}
	}
}

func TestDiagnosticsStreamPingPongAndCloseWithoutFIN(t *testing.T) {
	for _, feed := range []string{"connections", "dns"} {
		t.Run(feed, func(t *testing.T) {
			fixture(t)
			server := newDiagnosticStreamServer(t, nil)
			conn, reader, execution := dialDiagnosticStream(t, server, feed, false)
			readDiagnosticSnapshot(t, conn, reader, feed)
			c, session := activeDiagnosticStream(t, feed)
			// 连续帧能暴露控制处理器越过本帧长度吞掉后续数据的问题。
			writeDiagnosticClientFrames(t, conn, ws.NewPongFrame([]byte("unsolicited")), ws.NewPingFrame([]byte("ping payload")), ws.NewPingFrame(nil))
			for _, expected := range []string{"ping payload", ""} {
				frame := readDiagnosticWSFrame(t, conn, reader)
				if frame.Header.OpCode != ws.OpPong || string(frame.Payload) != expected {
					t.Fatalf("pong opcode=%d payload=%q", frame.Header.OpCode, frame.Payload)
				}
			}
			closeDiagnosticClient(t, conn, reader)
			// 客户端保持 TCP 打开，仅 Close 控制帧就必须撤销采集。
			waitDiagnosticStream(t, execution.done)
			assertDiagnosticStreamRetired(t, c, session)
		})
	}
}

func TestDiagnosticsStreamLastSubscriberOwnsCollector(t *testing.T) {
	for _, feed := range []string{"connections", "dns"} {
		t.Run(feed, func(t *testing.T) {
			fixture(t)
			server := newDiagnosticStreamServer(t, nil)
			first, firstReader, firstExecution := dialDiagnosticStream(t, server, feed, false)
			firstSnapshot := readDiagnosticSnapshot(t, first, firstReader, feed)
			c, firstSession := activeDiagnosticStream(t, feed)
			second, secondReader, secondExecution := dialDiagnosticStream(t, server, feed, false)
			secondSnapshot := readDiagnosticSnapshot(t, second, secondReader, feed)
			if firstSnapshot.SessionID == secondSnapshot.SessionID {
				t.Fatal("two subscriptions reused a session identity")
			}
			var secondSession *diagnosticSession
			c.mu.Lock()
			for session := range c.sessions {
				if session != firstSession {
					secondSession = session
				}
			}
			count := len(c.sessions)
			c.mu.Unlock()
			if count != 2 || secondSession == nil {
				t.Fatalf("shared subscriptions=%d", count)
			}
			closeDiagnosticClient(t, first, firstReader)
			waitDiagnosticStream(t, firstExecution.done)
			waitDiagnosticStream(t, firstSession.workerDone)
			c.mu.Lock()
			closed, count := c.closed, len(c.sessions)
			c.mu.Unlock()
			if closed || count != 1 {
				t.Fatalf("first departure closed=%v remaining=%d", closed, count)
			}
			select {
			case <-c.workerDone:
				t.Fatal("collector stopped with another subscriber present")
			default:
			}
			writeDiagnosticClientFrames(t, second, ws.NewPingFrame([]byte("still collecting")))
			if frame := readDiagnosticWSFrame(t, second, secondReader); frame.Header.OpCode != ws.OpPong || string(frame.Payload) != "still collecting" {
				t.Fatal("remaining subscription did not respond")
			}
			closeDiagnosticClient(t, second, secondReader)
			waitDiagnosticStream(t, secondExecution.done)
			assertDiagnosticStreamRetired(t, c, secondSession)
		})
	}
}

func TestDiagnosticsStreamRejectsDataAndInvalidControlFrames(t *testing.T) {
	tests := []struct {
		name  string
		frame ws.Frame
		raw   []byte
	}{
		{name: "text", frame: ws.MaskFrame(ws.NewTextFrame([]byte("not accepted")))},
		{name: "binary", frame: ws.MaskFrame(ws.NewBinaryFrame([]byte{1, 2}))},
		{name: "continuation", frame: ws.MaskFrame(ws.NewFrame(ws.OpContinuation, true, nil))},
		{name: "unmasked", frame: ws.NewPingFrame([]byte("no mask"))},
		{name: "fragmented-ping", frame: ws.MaskFrame(ws.NewFrame(ws.OpPing, false, nil))},
		{name: "oversized-ping", frame: ws.MaskFrame(ws.NewFrame(ws.OpPing, true, bytes.Repeat([]byte{'x'}, 126)))},
		{name: "reserved-bit", frame: ws.MaskFrame(ws.Frame{Header: ws.Header{Fin: true, Rsv: 1, OpCode: ws.OpPing}})},
		{name: "invalid-close", frame: ws.MaskFrame(ws.NewCloseFrame([]byte{1}))},
		{name: "invalid-length", raw: []byte{0x89, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture(t)
			server := newDiagnosticStreamServer(t, nil)
			conn, reader, execution := dialDiagnosticStream(t, server, "connections", false)
			readDiagnosticSnapshot(t, conn, reader, "connections")
			c, session := activeDiagnosticStream(t, "connections")
			if test.raw != nil {
				if _, err := conn.Write(test.raw); err != nil {
					t.Fatal(err)
				}
			} else if err := ws.WriteFrame(conn, test.frame); err != nil {
				t.Fatal(err)
			}
			reply := readDiagnosticWSFrame(t, conn, reader)
			code, _ := ws.ParseCloseFrameData(reply.Payload)
			if reply.Header.OpCode != ws.OpClose || code != ws.StatusProtocolError {
				t.Fatalf("rejection opcode=%d code=%d", reply.Header.OpCode, code)
			}
			waitDiagnosticStream(t, execution.done)
			assertDiagnosticStreamRetired(t, c, session)
		})
	}
}

func TestDiagnosticsStreamCancellationJoinsReader(t *testing.T) {
	for _, feed := range []string{"connections", "dns"} {
		for _, cancellation := range []string{"request", "tcp-eof", "runtime-stop", "partial-control"} {
			t.Run(feed+"/"+cancellation, func(t *testing.T) {
				fixture(t)
				server := newDiagnosticStreamServer(t, nil)
				conn, reader, execution := dialDiagnosticStream(t, server, feed, false)
				readDiagnosticSnapshot(t, conn, reader, feed)
				c, session := activeDiagnosticStream(t, feed)
				var stopped chan struct{}
				switch cancellation {
				case "request":
					execution.cancel()
				case "tcp-eof":
					_ = conn.Close()
				case "runtime-stop":
					eng.mu.Lock()
					wait := eng.diag.Stop()
					eng.mu.Unlock()
					stopped = make(chan struct{})
					go func() { wait(); close(stopped) }()
				case "partial-control":
					// 控制帧声明了正文却不发送，取消仍须唤醒持写锁的 reader。
					if err := ws.WriteHeader(conn, ws.Header{Fin: true, OpCode: ws.OpPing, Masked: true, Mask: [4]byte{1, 2, 3, 4}, Length: 1}); err != nil {
						t.Fatal(err)
					}
					execution.cancel()
				}
				waitDiagnosticStream(t, execution.done)
				if stopped != nil {
					waitDiagnosticStream(t, stopped)
				}
				assertDiagnosticStreamRetired(t, c, session)
			})
		}
	}
}

func newDiagnosticStreamTracker(t *testing.T, host string) statistic.Tracker {
	t.Helper()
	conn, peer := net.Pipe()
	tracker := statistic.NewTCPTracker(outbound.NewConn(conn, outbound.NewDirect()), statistic.DefaultManager,
		&C.Metadata{NetWork: C.TCP, Type: C.HTTP, Host: host, DstPort: 80}, nil, 0, 0, false)
	t.Cleanup(func() { _ = tracker.Close(); _ = peer.Close() })
	return tracker
}

type diagnosticGatedConn struct {
	net.Conn
	armed        atomic.Bool
	writeOnce    sync.Once
	readOnce     sync.Once
	releaseOnce  sync.Once
	writeStarted chan struct{}
	controlRead  chan struct{}
	release      chan struct{}
}

func (conn *diagnosticGatedConn) Write(data []byte) (int, error) {
	n, err := conn.Conn.Write(data)
	if conn.armed.Load() {
		conn.writeOnce.Do(func() {
			close(conn.writeStarted)
			<-conn.release
		})
	}
	return n, err
}

func (conn *diagnosticGatedConn) Close() error {
	conn.releaseOnce.Do(func() { close(conn.release) })
	return conn.Conn.Close()
}

type diagnosticReadProbe struct {
	io.Reader
	conn *diagnosticGatedConn
}

func (probe diagnosticReadProbe) Read(data []byte) (int, error) {
	n, err := probe.Reader.Read(data)
	if n > 0 && probe.conn.armed.Load() {
		probe.conn.readOnce.Do(func() { close(probe.conn.controlRead) })
	}
	return n, err
}

func TestDiagnosticsStreamTextAndControlFramesRemainWhole(t *testing.T) {
	fixture(t)
	wrapped := make(chan *diagnosticGatedConn, 1)
	server := newDiagnosticStreamServer(t, func(conn net.Conn, rw *bufio.ReadWriter) (net.Conn, *bufio.ReadWriter) {
		gate := &diagnosticGatedConn{Conn: conn, writeStarted: make(chan struct{}), controlRead: make(chan struct{}), release: make(chan struct{})}
		wrapped <- gate
		return gate, bufio.NewReadWriter(bufio.NewReader(diagnosticReadProbe{Reader: rw.Reader, conn: gate}), bufio.NewWriter(gate))
	})
	conn, reader, execution := dialDiagnosticStream(t, server, "connections", false)
	snapshot := readDiagnosticSnapshot(t, conn, reader, "connections")
	c, session := activeDiagnosticStream(t, "connections")
	gate := <-wrapped
	gate.armed.Store(true)
	tracker := newDiagnosticStreamTracker(t, "whole-frame.diag.test")
	c.mu.Lock()
	session.lastFrame = time.Now().Add(-2 * time.Second)
	session.signalLocked()
	c.kickLocked()
	c.mu.Unlock()
	waitDiagnosticStream(t, gate.writeStarted)
	writeDiagnosticClientFrames(t, conn, ws.NewPingFrame([]byte("during-text")))
	waitDiagnosticStream(t, gate.controlRead)
	gate.releaseOnce.Do(func() { close(gate.release) })
	frame := readDiagnosticWSFrame(t, conn, reader)
	var delta diagnosticStreamWireFrame
	if frame.Header.OpCode != ws.OpText || json.Unmarshal(frame.Payload, &delta) != nil {
		t.Fatalf("text frame was interleaved with control reply: opcode=%d payload=%q", frame.Header.OpCode, frame.Payload)
	}
	var opened []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(delta.Opened, &opened); err != nil {
		t.Fatal(err)
	}
	if delta.Kind != "delta" || delta.Seq != 2 || delta.SessionID != snapshot.SessionID || len(opened) != 1 || opened[0].ID != tracker.ID() {
		t.Fatalf("delta=%+v opened=%v", delta, opened)
	}
	pong := readDiagnosticWSFrame(t, conn, reader)
	if pong.Header.OpCode != ws.OpPong || string(pong.Payload) != "during-text" {
		t.Fatalf("pong opcode=%d payload=%q", pong.Header.OpCode, pong.Payload)
	}
	closeDiagnosticClient(t, conn, reader)
	waitDiagnosticStream(t, execution.done)
	assertDiagnosticStreamRetired(t, c, session)
}

type diagnosticSlowWriteResult struct {
	err     error
	elapsed time.Duration
}

type diagnosticSlowConn struct {
	net.Conn
	started  chan time.Time
	result   chan diagnosticSlowWriteResult
	deadline chan time.Time
	once     sync.Once
}

func (conn *diagnosticSlowConn) SetWriteDeadline(deadline time.Time) error {
	select {
	case conn.deadline <- deadline:
	default:
	}
	return conn.Conn.SetWriteDeadline(deadline)
}

func (conn *diagnosticSlowConn) Write(data []byte) (int, error) {
	large := len(data) > 64*1024
	start := time.Now()
	if large {
		conn.once.Do(func() { conn.started <- start })
	}
	n, err := conn.Conn.Write(data)
	if large {
		conn.result <- diagnosticSlowWriteResult{err: err, elapsed: time.Since(start)}
	}
	return n, err
}

func TestDiagnosticsStreamSlowReaderUsesFiveSecondDeadline(t *testing.T) {
	fixture(t)
	newDiagnosticStreamTracker(t, strings.Repeat("x", 4*1024*1024))
	wrapped := make(chan *diagnosticSlowConn, 1)
	server := newDiagnosticStreamServer(t, func(conn net.Conn, rw *bufio.ReadWriter) (net.Conn, *bufio.ReadWriter) {
		if err := conn.(*net.TCPConn).SetWriteBuffer(1024); err != nil {
			panic(err)
		}
		slow := &diagnosticSlowConn{Conn: conn, started: make(chan time.Time, 1), result: make(chan diagnosticSlowWriteResult, 1), deadline: make(chan time.Time, 4)}
		wrapped <- slow
		return slow, bufio.NewReadWriter(rw.Reader, bufio.NewWriter(slow))
	})
	// 只读取握手；真实 TCP 小缓冲会令大首帧阻塞，而非伪造超时错误。
	_, _, execution := dialDiagnosticStream(t, server, "connections", true)
	slow := <-wrapped
	var started time.Time
	select {
	case started = <-slow.started:
	case <-time.After(3 * time.Second):
		t.Fatal("large frame did not reach socket")
	}
	c, session := activeDiagnosticStream(t, "connections")
	deadline := <-slow.deadline
	if remaining := deadline.Sub(started); remaining < diagnosticWriteTimeout-500*time.Millisecond || remaining > diagnosticWriteTimeout {
		t.Fatalf("production write deadline remaining=%v", remaining)
	}
	select {
	case result := <-slow.result:
		var timeout net.Error
		if !errors.As(result.err, &timeout) || !timeout.Timeout() || result.elapsed < diagnosticWriteTimeout-500*time.Millisecond {
			t.Fatalf("slow write err=%v elapsed=%v", result.err, result.elapsed)
		}
	case <-time.After(diagnosticWriteTimeout + 3*time.Second):
		t.Fatal("slow writer ignored deadline")
	}
	waitDiagnosticStream(t, execution.done)
	assertDiagnosticStreamRetired(t, c, session)
}

func readDiagnosticStatsFrame(t *testing.T, conn net.Conn, reader *bufio.Reader) diagnosticStatsFrame {
	t.Helper()
	frame := readDiagnosticWSFrame(t, conn, reader)
	if frame.Header.OpCode != ws.OpText {
		t.Fatalf("stats opcode=%d", frame.Header.OpCode)
	}
	var payload diagnosticStatsFrame
	if err := json.Unmarshal(frame.Payload, &payload); err != nil {
		t.Fatalf("invalid stats json %q: %v", frame.Payload, err)
	}
	if payload.Type != "stats" || payload.BootID != eng.bootID || payload.ConfigRevision != eng.configRevision {
		t.Fatalf("unexpected stats frame: %+v", payload)
	}
	return payload
}

func TestDiagnosticsStatsPushesCoalescedCountsWithoutTrafficSampling(t *testing.T) {
	fixture(t)
	previousInterval := diagnosticStatsInterval
	diagnosticStatsInterval = 50 * time.Millisecond
	t.Cleanup(func() { diagnosticStatsInterval = previousInterval })

	rs := newDiagnosticTestResolver(t)
	server := newDiagnosticStreamServer(t, nil)
	baseline := newDiagnosticStreamTracker(t, "baseline.stats.test")

	conn, reader, execution := dialDiagnosticStream(t, server, "stats", false)
	initial := readDiagnosticStatsFrame(t, conn, reader)
	if initial.Live != 1 || initial.Recent != 0 || initial.DNS != 0 {
		t.Fatalf("initial stats=%+v want live=1 recent=0 dns=0", initial)
	}
	eng.diag.mu.Lock()
	connections, queries := eng.diag.connections, eng.diag.dns
	eng.diag.mu.Unlock()
	if connections == nil || queries == nil {
		t.Fatal("stats stream did not install both observers")
	}

	first := newDiagnosticStreamTracker(t, "first.stats.test")
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	second := newDiagnosticStreamTracker(t, "second.stats.test")
	diagnosticTestQuery(t, rs, "one.stats.test.")
	diagnosticTestQuery(t, rs, "two.stats.test.")

	connections.mu.Lock()
	noSampling := len(connections.sessions) == 0 && connections.sampleDue.IsZero() && connections.timer == nil &&
		connections.connections[first.ID()].info == nil
	connections.mu.Unlock()
	if !noSampling {
		t.Fatal("stats stream triggered connection traffic sampling or retained closed tracker info")
	}

	var updated diagnosticStatsFrame
	for attempt := 0; attempt < 3; attempt++ {
		updated = readDiagnosticStatsFrame(t, conn, reader)
		if updated.Live == 2 && updated.Recent == 2 && updated.DNS == 2 {
			break
		}
	}
	if updated.Live != 2 || updated.Recent != 2 || updated.DNS != 2 {
		t.Fatalf("coalesced stats=%+v want live=2 recent=2 dns=2", updated)
	}

	// 无变化期间不推送冗余帧，ping 应直接收到 pong。
	time.Sleep(diagnosticStatsInterval + 20*time.Millisecond)
	writeDiagnosticClientFrames(t, conn, ws.NewPingFrame([]byte("idle-stats")))
	if pong := readDiagnosticWSFrame(t, conn, reader); pong.Header.OpCode != ws.OpPong || string(pong.Payload) != "idle-stats" {
		t.Fatalf("idle stats emitted unexpected frame: opcode=%d payload=%q", pong.Header.OpCode, pong.Payload)
	}

	if err := baseline.Close(); err != nil {
		t.Fatal(err)
	}
	if err := second.Close(); err != nil {
		t.Fatal(err)
	}
	var closedFrame diagnosticStatsFrame
	for attempt := 0; attempt < 2; attempt++ {
		closedFrame = readDiagnosticStatsFrame(t, conn, reader)
		if closedFrame.Live == 0 {
			break
		}
	}
	if closedFrame.Live != 0 || closedFrame.Recent != 2 || closedFrame.DNS != 2 {
		t.Fatalf("post-close stats=%+v want live=0 recent=2 dns=2", closedFrame)
	}

	closeDiagnosticClient(t, conn, reader)
	waitDiagnosticStream(t, execution.done)
	waitDiagnosticStream(t, connections.workerDone)
	waitDiagnosticStream(t, queries.workerDone)
	eng.diag.mu.Lock()
	retired := eng.diag.connections == nil && eng.diag.dns == nil && !eng.diag.hasStats()
	eng.diag.mu.Unlock()
	if !retired {
		t.Fatal("closing last stats subscriber left collectors active")
	}
}

func TestDiagnosticsStatsLifecycleCoexistenceAndValidation(t *testing.T) {
	fixture(t)
	// 校验非法与过期请求均拒绝且不安装观察器。
	for _, tc := range []struct {
		name   string
		target string
		status int
		stop   bool
	}{
		{"missing-revision", "/stats?expectedBootId=" + eng.bootID, http.StatusBadRequest, false},
		{"stale-revision", "/stats?expectedBootId=" + eng.bootID + "&expectedConfigRevision=999", http.StatusConflict, false},
		{"stopped", diagnosticStreamTarget("stats"), http.StatusServiceUnavailable, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.stop {
				eng.diag.mu.Lock()
				eng.diag.identity.Running = false
				eng.diag.mu.Unlock()
				defer func() {
					eng.diag.mu.Lock()
					eng.diag.identity.Running = true
					eng.diag.mu.Unlock()
				}()
			}
			w := httptest.NewRecorder()
			getDiagnosticStats(w, diagnosticStreamRequest(tc.target))
			eng.diag.mu.Lock()
			untouched := eng.diag.connections == nil && eng.diag.dns == nil && !eng.diag.hasStats()
			eng.diag.mu.Unlock()
			if w.Code != tc.status || !untouched {
				t.Fatalf("status=%d body=%s untouched=%v", w.Code, w.Body.String(), untouched)
			}
		})
	}

	// capture 释放时仍有 stats 订阅，须保留采集器；stats 关闭后统一退休。
	server := newDiagnosticStreamServer(t, nil)
	capture, captureReader, captureExecution := dialDiagnosticStream(t, server, "capture", false)
	readDiagnosticCaptureReady(t, capture, captureReader)
	stats, statsReader, statsExecution := dialDiagnosticStream(t, server, "stats", false)
	readDiagnosticStatsFrame(t, stats, statsReader)
	eng.diag.mu.Lock()
	connections, queries := eng.diag.connections, eng.diag.dns
	eng.diag.mu.Unlock()
	closeDiagnosticClient(t, capture, captureReader)
	waitDiagnosticStream(t, captureExecution.done)
	eng.diag.mu.Lock()
	preserved := eng.diag.capture == nil && eng.diag.connections == connections && eng.diag.dns == queries && eng.diag.hasStats()
	eng.diag.mu.Unlock()
	if !preserved {
		t.Fatal("releasing capture retired collectors still owned by stats")
	}
	// 配置热切换/停机时必须关闭活跃 stats 会话并回收全部采集器。
	eng.mu.Lock()
	wait := eng.diag.BeginReload()
	eng.mu.Unlock()
	wait()
	waitDiagnosticStream(t, statsExecution.done)
	waitDiagnosticStream(t, connections.workerDone)
	waitDiagnosticStream(t, queries.workerDone)
	eng.diag.mu.Lock()
	cleared := eng.diag.connections == nil && eng.diag.dns == nil && !eng.diag.hasStats()
	eng.diag.mu.Unlock()
	if !cleared {
		t.Fatal("reload did not retire stats stream and collectors")
	}
}
