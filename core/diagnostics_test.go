package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel/statistic"
	D "github.com/miekg/dns"
)

func diagnosticTestSubscribe(t *testing.T, feed string) (*diagnosticSession, func()) {
	t.Helper()
	s, status, err := subscribeDiagnostics(feed, eng.bootID, eng.configRevision)
	if err != nil || status != 0 {
		t.Fatalf("subscribe: %d %v", status, err)
	}
	var once sync.Once
	release := func() { once.Do(func() { s.close(); close(s.workerDone) }) }
	t.Cleanup(release)
	return s, release
}

func diagnosticTestReceive[T any](t *testing.T, channel <-chan T) T {
	t.Helper()
	select {
	case value := <-channel:
		return value
	case <-time.After(5 * time.Second):
		t.Fatal("diagnostics fixture deadlocked")
		var zero T
		return zero
	}
}

func diagnosticTestFrame(t *testing.T, s *diagnosticSession, now time.Time) diagnosticConnectionsFrame {
	t.Helper()
	frame, ok := s.nextFrameAt(now).(diagnosticConnectionsFrame)
	if !ok {
		t.Fatal("expected connection frame")
	}
	return frame
}

func diagnosticTestDNSFrame(t *testing.T, s *diagnosticSession, now time.Time) diagnosticDNSFrame {
	t.Helper()
	frame, ok := s.nextFrameAt(now).(diagnosticDNSFrame)
	if !ok {
		t.Fatal("expected DNS frame")
	}
	return frame
}

func TestDiagnosticsShortConnectionBaselineAndSettling(t *testing.T) {
	cfg := fixture(t)
	left, peer := net.Pipe()
	defer peer.Close()
	baseline := statistic.NewTCPTracker(outbound.NewConn(left, cfg.Proxies["DIRECT"].Adapter()), statistic.DefaultManager,
		&C.Metadata{NetWork: C.TCP, Host: "baseline.diag.test"}, nil, 0, 0, false)
	defer baseline.Close()
	s, _ := diagnosticTestSubscribe(t, "connections")
	now := time.Now()
	first := diagnosticTestFrame(t, s, now)
	if first.Kind != "snapshot" || first.Seq != 1 || len(first.Live) != 1 || len(first.Recent) != 0 {
		t.Fatalf("baseline %+v", first)
	}
	left, peer = net.Pipe()
	defer peer.Close()
	metadata := &C.Metadata{NetWork: C.TCP, Host: "short.diag.test", SrcIP: netip.MustParseAddr("::1"), DstPort: 80,
		SrcGeoIP: []string{"ZZ"}, Process: "not exported", InUser: "not exported"}
	tracker := statistic.NewTCPTracker(outbound.NewConn(left, cfg.Proxies["DIRECT"].Adapter()), statistic.DefaultManager, metadata, nil, 0, 0, false)
	written := make(chan error, 1)
	go func() { _, err := io.CopyN(io.Discard, peer, 7); written <- err }()
	if _, err := tracker.Write([]byte("payload")); err != nil {
		t.Fatal(err)
	}
	if err := diagnosticTestReceive(t, written); err != nil {
		t.Fatal(err)
	}
	metadata.SrcGeoIP[0] = "changed"
	if err := tracker.Close(); err != nil {
		t.Fatal(err)
	}
	if err := tracker.Close(); err != nil {
		t.Fatal(err)
	}
	if s.nextFrameAt(now.Add(500*time.Millisecond)) != nil {
		t.Fatal("flushed before one second")
	}
	frame := diagnosticTestFrame(t, s, now.Add(time.Second))
	if len(frame.Opened) != 1 || len(frame.Closed) != 1 || len(frame.Traffic) != 1 || frame.Traffic[0].Upload != 7 || frame.Opened[0].Metadata.SourceGeoIP[0] != "ZZ" {
		t.Fatalf("short connection lost or duplicated: %+v", frame)
	}
	body, err := json.Marshal(frame)
	if err != nil || bytes.Contains(body, []byte("not exported")) || bytes.Contains(body, []byte(":null")) {
		t.Fatalf("invalid or sensitive DTO: %s %v", body, err)
	}
	c := s.collector
	c.mu.Lock()
	entry := c.connections[tracker.ID()]
	if entry.live || !entry.recent {
		c.mu.Unlock()
		t.Fatal("closed request lost recent provenance")
	}
	c.sampleConnectionsLocked(now.Add(2 * time.Second))
	if entry.stable != 1 || entry.info == nil {
		c.mu.Unlock()
		t.Fatal("released before two stable samples")
	}
	tracker.Info().UploadTotal.Add(3)
	c.sampleConnectionsLocked(now.Add(3 * time.Second))
	if entry.stable != 0 || entry.dto.Upload != 10 {
		c.mu.Unlock()
		t.Fatal("late accounting did not restart settling")
	}
	c.sampleConnectionsLocked(now.Add(4 * time.Second))
	c.sampleConnectionsLocked(now.Add(5 * time.Second))
	if entry.info != nil || entry.dto.Upload != 10 {
		c.mu.Unlock()
		t.Fatal("settled tracker reference retained")
	}
	c.mu.Unlock()
	frame = diagnosticTestFrame(t, s, now.Add(5*time.Second))
	if len(frame.Traffic) != 1 || frame.Traffic[0].Upload != 10 {
		t.Fatalf("late totals lost: %+v", frame)
	}
}

func TestDiagnosticsJoinBeforeStoreAndRangeCloseInterleaving(t *testing.T) {
	cfg := fixture(t)
	s, _ := diagnosticTestSubscribe(t, "connections")
	c := s.collector
	now := time.Now()
	diagnosticTestFrame(t, s, now)
	entered := make(chan statistic.Tracker, 1)
	release := make(chan struct{})
	joined := make(chan statistic.Tracker, 1)
	statistic.SetTrackerObserver(&statistic.TrackerObserver{Open: func(tracker statistic.Tracker) { c.openConnection(tracker); entered <- tracker; <-release }, Close: c.closeConnection})
	left, peer := net.Pipe()
	defer peer.Close()
	go func() {
		joined <- statistic.NewTCPTracker(outbound.NewConn(left, cfg.Proxies["DIRECT"].Adapter()), statistic.DefaultManager, &C.Metadata{Host: "before-store.diag.test"}, nil, 0, 0, false)
	}()
	tracker := diagnosticTestReceive(t, entered)
	if statistic.DefaultManager.Get(tracker.ID()) != nil {
		t.Fatal("Open did not precede Store")
	}
	statistic.DefaultManager.Range(func(current statistic.Tracker) bool { c.baselineConnection(current); return true })
	c.mu.Lock()
	entry := c.connections[tracker.ID()]
	if entry == nil || !entry.live || !entry.recent {
		c.mu.Unlock()
		t.Fatal("absent Store was inferred as closed")
	}
	c.mu.Unlock()
	close(release)
	tracker = diagnosticTestReceive(t, joined)
	statistic.SetTrackerObserver(&statistic.TrackerObserver{Open: c.openConnection, Close: c.closeConnection})
	statistic.DefaultManager.Range(func(current statistic.Tracker) bool { c.baselineConnection(current); return true })
	frame := diagnosticTestFrame(t, s, now.Add(time.Second))
	if len(frame.Opened) != 1 || len(frame.Closed) != 0 {
		t.Fatalf("Range duplicated or closed Open: %+v", frame)
	}
	c.mu.Lock()
	c.initializing = true
	c.mu.Unlock()
	captured := make(chan statistic.Tracker, 1)
	resume, ranged := make(chan struct{}), make(chan struct{})
	go func() {
		statistic.DefaultManager.Range(func(current statistic.Tracker) bool {
			if current.ID() == tracker.ID() {
				captured <- current
				<-resume
			}
			c.baselineConnection(current)
			return true
		})
		close(ranged)
	}()
	diagnosticTestReceive(t, captured)
	if err := tracker.Close(); err != nil {
		t.Fatal(err)
	}
	close(resume)
	diagnosticTestReceive(t, ranged)
	c.mu.Lock()
	c.initializing = false
	if c.connections[tracker.ID()].live {
		c.mu.Unlock()
		t.Fatal("stale Range resurrected closed tracker")
	}
	c.mu.Unlock()
	frame = diagnosticTestFrame(t, s, now.Add(2*time.Second))
	if len(frame.Closed) != 1 {
		t.Fatalf("close missing: %+v", frame)
	}
}

func TestDiagnosticsAllLiveUnboundedHistoryAndOverflowReset(t *testing.T) {
	cfg := fixture(t)
	s, _ := diagnosticTestSubscribe(t, "connections")
	now := time.Now()
	diagnosticTestFrame(t, s, now)
	trackers := make([]statistic.Tracker, 0, 2105)
	peers := make([]net.Conn, 0, 2105)
	defer func() {
		for _, tracker := range trackers {
			tracker.Close()
		}
		for _, peer := range peers {
			peer.Close()
		}
	}()
	for range 2105 {
		left, peer := net.Pipe()
		peers = append(peers, peer)
		trackers = append(trackers, statistic.NewTCPTracker(outbound.NewConn(left, cfg.Proxies["DIRECT"].Adapter()), statistic.DefaultManager, &C.Metadata{}, nil, 0, 0, false))
	}
	frame := diagnosticTestFrame(t, s, now.Add(time.Second))
	if frame.Kind != "reset" || len(frame.Live) != 2105 || len(frame.Recent) != 2000 || frame.Evicted != 105 || frame.Dropped == 0 {
		t.Fatalf("live truncated or ring/queue counters conflated: kind=%s live=%d recent=%d dropped=%d evicted=%d", frame.Kind, len(frame.Live), len(frame.Recent), frame.Dropped, frame.Evicted)
	}
	late, _ := diagnosticTestSubscribe(t, "connections")
	lateFirst := diagnosticTestFrame(t, late, now)
	if len(lateFirst.Live) != 2105 || len(lateFirst.Recent) != 2000 || lateFirst.Evicted != 105 || lateFirst.Dropped != 0 ||
		lateFirst.Recent[0].ID != trackers[105].ID() || lateFirst.Recent[1999].ID != trackers[2104].ID() {
		t.Fatal("late subscriber did not receive the canonical ring oldest-first")
	}
	for _, tracker := range trackers {
		tracker.Close()
	}
	frame = diagnosticTestFrame(t, s, now.Add(2*time.Second))
	lateFrame := diagnosticTestFrame(t, late, now.Add(time.Second))
	if frame.Kind != "reset" || len(frame.Live) != 0 || len(frame.Recent) != 2000 || lateFrame.Kind != "reset" ||
		len(lateFrame.Live) != 0 || len(lateFrame.Recent) != 2000 || lateFrame.Evicted != 105 ||
		lateFrame.Recent[0].ID != frame.Recent[0].ID || lateFrame.Recent[1999].ID != frame.Recent[1999].ID {
		t.Fatalf("overflow reset lost canonical history or final state: first live=%d recent=%d late live=%d recent=%d evicted=%d", len(frame.Live), len(frame.Recent), len(lateFrame.Live), len(lateFrame.Recent), lateFrame.Evicted)
	}
	if frame.Evicted != 105 || frame.Dropped <= frame.Evicted {
		t.Fatal("dropped and evicted are not independent")
	}
}

func TestDiagnosticsSharedSamplerHeartbeatAndLastUnsubscribe(t *testing.T) {
	cfg := fixture(t)
	first, releaseFirst := diagnosticTestSubscribe(t, "connections")
	second, releaseSecond := diagnosticTestSubscribe(t, "connections")
	if first.collector != second.collector || diagnosticDNS != nil {
		t.Fatal("collectors are not feed scoped and shared")
	}
	now := time.Now()
	diagnosticTestFrame(t, first, now)
	diagnosticTestFrame(t, second, now)
	left, peer := net.Pipe()
	defer peer.Close()
	tracker := statistic.NewTCPTracker(outbound.NewConn(left, cfg.Proxies["DIRECT"].Adapter()), statistic.DefaultManager, &C.Metadata{}, nil, 0, 0, false)
	defer tracker.Close()
	diagnosticTestFrame(t, first, now.Add(time.Second))
	diagnosticTestFrame(t, second, now.Add(time.Second))
	c := first.collector
	c.mu.Lock()
	c.sampleConnectionsLocked(now.Add(2 * time.Second))
	if c.sampleDue.IsZero() {
		c.mu.Unlock()
		t.Fatal("live sampler stopped")
	}
	c.mu.Unlock()
	frame := diagnosticTestFrame(t, first, now.Add(2*time.Second))
	if len(frame.Opened)+len(frame.Closed)+len(frame.Traffic) != 0 {
		t.Fatalf("heartbeat fabricated changes: %+v", frame)
	}
	releaseFirst()
	eng.mu.Lock()
	stillActive := diagnosticConnections == c
	eng.mu.Unlock()
	if !stillActive {
		t.Fatal("first unsubscribe detached shared observer")
	}
	tracker.Close()
	frame = diagnosticTestFrame(t, second, now.Add(3*time.Second))
	if len(frame.Closed) != 1 {
		t.Fatal("remaining subscriber lost Close")
	}
	releaseSecond()
	eng.mu.Lock()
	if diagnosticConnections != nil {
		eng.mu.Unlock()
		t.Fatal("last unsubscribe retained registry")
	}
	eng.mu.Unlock()
	c.mu.Lock()
	if !c.closed || len(c.connections) != 0 || !c.sampleDue.IsZero() {
		c.mu.Unlock()
		t.Fatal("collector retained trackers or sampling")
	}
	c.mu.Unlock()
	diagnosticTestReceive(t, c.workerDone)
	c.openConnection(tracker)
	c.closeConnection(tracker)
	c.mu.Lock()
	if len(c.connections) != 0 {
		t.Fatal("retired callback mutated collector")
	}
	c.mu.Unlock()
}

func diagnosticTestRecord(index int) dns.QueryRecord {
	question := D.Question{Name: fmt.Sprintf("request-%d.diag.test.", index), Qtype: D.TypeA, Qclass: D.ClassINET}
	return dns.QueryRecord{Question: question, Start: time.Unix(1700000000, 0), Initiator: "direct", Msg: &D.Msg{MsgHdr: D.MsgHdr{Rcode: D.RcodeSuccess}, Answer: []D.RR{&D.A{Hdr: D.RR_Header{Name: question.Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.IPv4(192, 0, 2, 7)}}}}
}

func TestDiagnosticsDNSOverflowBoundaryConversionAndRetirement(t *testing.T) {
	fixture(t)
	s, release := diagnosticTestSubscribe(t, "dns")
	now := time.Now()
	first := diagnosticTestDNSFrame(t, s, now)
	if first.Kind != "snapshot" || len(first.Records) != 0 || first.Seq != 1 || diagnosticConnections != nil {
		t.Fatal("DNS baseline or feed isolation incorrect")
	}
	c := s.collector
	for index := range 3005 {
		c.observeDNS(diagnosticTestRecord(index))
	}
	frame := diagnosticTestDNSFrame(t, s, now.Add(time.Second))
	if frame.Kind != "reset" || len(frame.Records) != 3000 || frame.Evicted != 5 || frame.Dropped == 0 || frame.Records[0].Domain != "request-5.diag.test" || frame.Records[2999].Domain != "request-3004.diag.test" {
		t.Fatalf("DNS reset incorrect: kind=%s count=%d dropped=%d evicted=%d", frame.Kind, len(frame.Records), frame.Dropped, frame.Evicted)
	}
	late, releaseLate := diagnosticTestSubscribe(t, "dns")
	lateFirst := diagnosticTestDNSFrame(t, late, now)
	if len(lateFirst.Records) != 3000 || lateFirst.Evicted != 5 || lateFirst.Dropped != 0 ||
		lateFirst.Records[0].ID != frame.Records[0].ID || lateFirst.Records[2999].ID != frame.Records[2999].ID {
		t.Fatal("late DNS subscriber did not receive the canonical ring oldest-first")
	}
	for index := range 257 {
		c.observeDNS(diagnosticTestRecord(index + 4000))
	}
	lateFrame := diagnosticTestDNSFrame(t, late, now.Add(time.Second))
	if lateFrame.Kind != "reset" || len(lateFrame.Records) != 3000 || lateFrame.Evicted != 262 ||
		lateFrame.Records[0].Domain != "request-262.diag.test" || lateFrame.Records[2999].Domain != "request-4256.diag.test" {
		t.Fatalf("late DNS reset lost canonical history: kind=%s count=%d evicted=%d", lateFrame.Kind, len(lateFrame.Records), lateFrame.Evicted)
	}
	record := diagnosticTestRecord(9000)
	record.Msg.Answer = append(record.Msg.Answer,
		&D.AAAA{Hdr: D.RR_Header{Rrtype: D.TypeAAAA}, AAAA: net.ParseIP("2001:db8::7")},
		&D.CNAME{Hdr: D.RR_Header{Rrtype: D.TypeCNAME}, Target: "target.diag.test."},
		&D.TXT{Hdr: D.RR_Header{Rrtype: D.TypeTXT}, Txt: []string{"diagnostics"}})
	record.Cached = true
	record.Upstream = "tcp://127.0.0.1:15353"
	c.observeDNS(record)
	record.Msg.Answer[0].(*D.A).A[0] = 1
	frame = diagnosticTestDNSFrame(t, late, now.Add(2*time.Second))
	if len(frame.Added) != 1 || frame.Added[0].Answers[0] != "192.0.2.7" || frame.Added[0].Answers[1] != "2001:db8::7" || frame.Added[0].Answers[2] != "target.diag.test" || frame.Added[0].Answers[3] != "\"diagnostics\"" {
		t.Fatalf("DNS conversion retained message or lost RR: %+v", frame)
	}
	failure := dns.QueryRecord{Question: D.Question{Name: "failure.", Qtype: D.TypeAAAA}, Initiator: "invalid", Start: now.Add(time.Hour), Err: errors.New("local failure")}
	converted := diagnosticDNSRecord(failure, "id", now)
	if converted.Delay != 0 || converted.Initiator != "other" || converted.Upstream != "" || converted.Error != "local failure" || converted.Answers == nil {
		t.Fatalf("failure conversion %+v", converted)
	}
	for _, initiator := range []string{"app", "rule", "direct", "proxy", "other"} {
		failure.Initiator = initiator
		if diagnosticDNSRecord(failure, "id", now).Initiator != initiator {
			t.Fatal("initiator changed")
		}
	}
	release()
	eng.mu.Lock()
	if diagnosticDNS != c {
		t.Fatal("early DNS unsubscribe detached shared hook")
	}
	eng.mu.Unlock()
	releaseLate()
	c.observeDNS(diagnosticTestRecord(9999))
	c.mu.Lock()
	if len(c.dnsRecords) != 0 {
		t.Fatal("retired DNS callback retained results")
	}
	c.mu.Unlock()
}

func diagnosticTestAction(t *testing.T, connections bool, body string) int {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
	response := httptest.NewRecorder()
	if connections {
		postDiagnosticConnectionsClose(response, request)
	} else {
		postDiagnosticDnsClearCache(response, request)
	}
	return response.Code
}

func TestDiagnosticsActionsRejectStaleMalformedAndCloseIdempotently(t *testing.T) {
	cfg := fixture(t)
	s, _ := diagnosticTestSubscribe(t, "connections")
	now := time.Now()
	diagnosticTestFrame(t, s, now)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() { connection, _ := listener.Accept(); accepted <- connection }()
	connection, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	peer := diagnosticTestReceive(t, accepted)
	defer peer.Close()
	tracker := statistic.NewTCPTracker(outbound.NewConn(connection, cfg.Proxies["DIRECT"].Adapter()), statistic.DefaultManager, &C.Metadata{}, nil, 0, 0, false)
	defer tracker.Close()
	identity := fmt.Sprintf(`"expectedBootId":%q,"expectedConfigRevision":%d`, eng.bootID, eng.configRevision)
	for _, body := range []string{`{` + identity + `,"scope":"one"}`, `{` + identity + `,"scope":"one","id":""}`, `{` + identity + `,"scope":"all","id":"x"}`, `{` + identity + `,"scope":"all","id":null}`, `{` + identity + `,"scope":"all","extra":true}`, `{` + identity + `,"scope":"one","id":17}`} {
		if status := diagnosticTestAction(t, true, body); status != 400 {
			t.Fatalf("invalid request status=%d body=%s", status, body)
		}
		if statistic.DefaultManager.Get(tracker.ID()) == nil {
			t.Fatal("invalid one request closed all")
		}
	}
	stale := fmt.Sprintf(`{"expectedBootId":%q,"expectedConfigRevision":%d,"scope":"all"}`, eng.bootID, eng.configRevision+1)
	if status := diagnosticTestAction(t, true, stale); status != 409 || statistic.DefaultManager.Get(tracker.ID()) == nil {
		t.Fatal("stale close-all changed current connections")
	}
	body := `{` + identity + `,"scope":"one","id":` + fmt.Sprintf("%q", tracker.ID()) + `}`
	if status := diagnosticTestAction(t, true, body); status != 204 {
		t.Fatalf("close status=%d", status)
	}
	peer.SetReadDeadline(time.Now().Add(5 * time.Second))
	var buffer [1]byte
	if _, err := peer.Read(buffer[:]); err != io.EOF {
		t.Fatalf("Close did not terminate real TCP: %v", err)
	}
	if status := diagnosticTestAction(t, true, body); status != 204 {
		t.Fatalf("idempotent close status=%d", status)
	}
	if status := diagnosticTestAction(t, false, `{`+identity+`,"scope":""}`); status != 400 {
		t.Fatal("DNS action accepted scope")
	}
	eng.mu.Lock()
	eng.running = false
	eng.mu.Unlock()
	if status := diagnosticTestAction(t, true, `{`+identity+`,"scope":"all"}`); status != 503 {
		t.Fatal("stopped action not rejected")
	}
	eng.mu.Lock()
	eng.running = true
	eng.mu.Unlock()
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
		w.WriteMsg(reply)
	})}
	served := make(chan error, 1)
	go func() { served <- server.ActivateAndServe() }()
	diagnosticTestReceive(t, started)
	t.Cleanup(func() { server.Shutdown(); diagnosticTestReceive(t, served) })
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

func TestDiagnosticsDNSRealMissHitClearAndStaleNoSideEffect(t *testing.T) {
	fixture(t)
	s, _ := diagnosticTestSubscribe(t, "dns")
	now := time.Now()
	diagnosticTestDNSFrame(t, s, now)
	rs := newDiagnosticTestResolver(t)
	previous := resolver.DefaultResolver
	resolver.DefaultResolver = rs
	defer func() { resolver.DefaultResolver = previous }()
	query := func(name string) { diagnosticTestQuery(t, rs, name) }
	query("ok.diag.test.")
	query("ok.diag.test.")
	identity := fmt.Sprintf(`"expectedBootId":%q,"expectedConfigRevision":%d`, eng.bootID, eng.configRevision)
	stale := fmt.Sprintf(`{"expectedBootId":%q,"expectedConfigRevision":%d}`, eng.bootID, eng.configRevision+1)
	if diagnosticTestAction(t, false, stale) != 409 {
		t.Fatal("stale clear not rejected")
	}
	query("ok.diag.test.")
	if diagnosticTestAction(t, false, `{`+identity+`}`) != 204 {
		t.Fatal("clear cache failed")
	}
	query("ok.diag.test.")
	query("missing.diag.test.")
	frame := diagnosticTestDNSFrame(t, s, now.Add(time.Second))
	if len(frame.Added) != 5 || frame.Added[0].Cached || !frame.Added[1].Cached || !frame.Added[2].Cached || frame.Added[3].Cached || frame.Added[4].Rcode != "NXDOMAIN" {
		t.Fatalf("miss/hit/clear lifecycle incorrect: %+v", frame)
	}
	if frame.Added[0].Initiator != "rule" || frame.Added[0].Upstream == "" || frame.Added[0].Answers[0] != "192.0.2.7" {
		t.Fatalf("real DNS observation incorrect: %+v", frame.Added[0])
	}
	c := s.collector
	c.mu.Lock()
	if len(c.dnsRecords) != 5 {
		t.Fatal("cache clear deleted diagnostic history")
	}
	c.mu.Unlock()
}

func TestDiagnosticsStopCancelsSocketsAndWaitsOutsideCoreLock(t *testing.T) {
	fixture(t)
	connections, releaseConnections := diagnosticTestSubscribe(t, "connections")
	dnsSession, releaseDNS := diagnosticTestSubscribe(t, "dns")
	left, right := net.Pipe()
	defer right.Close()
	if !connections.attach(left) {
		t.Fatal("attach failed")
	}
	eng.mu.Lock()
	wait := stopDiagnosticsLocked()
	if diagnosticConnections != nil || diagnosticDNS != nil {
		t.Fatal("stop left observers registered")
	}
	select {
	case <-connections.done:
	default:
		t.Fatal("connection session not canceled synchronously")
	}
	select {
	case <-dnsSession.done:
	default:
		t.Fatal("DNS session not canceled synchronously")
	}
	eng.mu.Unlock()
	joined := make(chan struct{})
	go func() { wait(); close(joined) }()
	select {
	case <-joined:
		t.Fatal("stop did not wait for transport")
	default:
	}
	releaseConnections()
	releaseDNS()
	diagnosticTestReceive(t, joined)
	if connections.nextFrame() != nil || dnsSession.nextFrame() != nil {
		t.Fatal("canceled session emitted data")
	}
	late, peer := net.Pipe()
	defer peer.Close()
	if connections.attach(late) {
		t.Fatal("canceled session accepted socket")
	}
	if _, err := right.Write([]byte("x")); err == nil {
		t.Fatal("stop left attached socket open")
	}
}

func TestDiagnosticsInitializationReconcilesLifecycleAndSnapshot(t *testing.T) {
	cfg := fixture(t)
	manager := new(statistic.Manager)
	left, peer := net.Pipe()
	defer peer.Close()
	baseline := statistic.NewTCPTracker(outbound.NewConn(left, cfg.Proxies["DIRECT"].Adapter()), manager, &C.Metadata{Host: "baseline.diag.test"}, nil, 0, 0, false)
	defer baseline.Close()
	s, _ := diagnosticTestSubscribe(t, "connections")
	now := time.Now()
	diagnosticTestFrame(t, s, now)
	c := s.collector
	c.mu.Lock()
	c.initializing = true
	c.mu.Unlock()
	captured, resume, ranged := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		manager.Range(func(tracker statistic.Tracker) bool {
			close(captured)
			<-resume
			c.baselineConnection(tracker)
			return true
		})
		close(ranged)
	}()
	diagnosticTestReceive(t, captured)
	if err := baseline.Close(); err != nil {
		t.Fatal(err)
	}
	left, peer = net.Pipe()
	defer peer.Close()
	short := statistic.NewTCPTracker(outbound.NewConn(left, cfg.Proxies["DIRECT"].Adapter()), manager, &C.Metadata{Host: "short.diag.test"}, nil, 0, 0, false)
	short.Info().UploadTotal.Add(19)
	if err := short.Close(); err != nil {
		t.Fatal(err)
	}
	close(resume)
	diagnosticTestReceive(t, ranged)
	c.mu.Lock()
	c.initializing = false
	c.releaseUnreferencedLocked()
	missingBaseline := c.connections[baseline.ID()] == nil
	c.mu.Unlock()
	if !missingBaseline {
		t.Fatal("initial Range resurrected baseline closed before merge")
	}
	late, _ := diagnosticTestSubscribe(t, "connections")
	snapshot := diagnosticTestFrame(t, late, now)
	if len(snapshot.Live) != 0 || len(snapshot.Recent) != 1 || snapshot.Recent[0].ID != short.ID() || snapshot.Recent[0].Upload != 19 {
		t.Fatalf("snapshot lost short connection or its final counters: %+v", snapshot)
	}
	delta := diagnosticTestFrame(t, s, now.Add(time.Second))
	if len(delta.Opened) != 1 || delta.Opened[0].ID != short.ID() || len(delta.Closed) != 2 {
		t.Fatalf("initial lifecycle queue lost events: %+v", delta)
	}
	foundTraffic := false
	for _, traffic := range delta.Traffic {
		if traffic.ID == short.ID() && traffic.Upload == 19 {
			foundTraffic = true
		}
	}
	if !foundTraffic {
		t.Fatal("initial queue lost final observed counters")
	}
}
