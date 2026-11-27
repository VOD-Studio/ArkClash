package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const diagnosticQueueLimit = 256
const diagnosticRecentLimit = 2000
const diagnosticDNSLimit = 3000

type diagnosticHeader struct {
	Type           string `json:"type"`
	Kind           string `json:"kind"`
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	SessionID      string `json:"sessionId"`
	Seq            uint64 `json:"seq"`
	SampledAt      int64  `json:"sampledAt"`
	Dropped        uint64 `json:"dropped"`
	Evicted        uint64 `json:"evicted"`
}

type diagnosticEvent struct {
	kind       string
	connection DiagnosticConnection
	traffic    diagnosticTraffic
	id         string
	dns        DiagnosticDnsRecord
	log        diagnosticLogRecord
}

type diagnosticSession struct {
	wake       chan struct{}
	done       chan struct{}
	workerDone chan struct{}
	collector  *diagnosticCollector
	conn       net.Conn
	closed     bool
	id         string
	seq        uint64
	dropped    uint64
	initial    any
	queue      []diagnosticEvent
	traffic    map[string]int
	needsReset bool
	heartbeat  bool
	lastFrame  time.Time
}

type diagnosticCollector struct {
	hub          *diagnosticsHub
	mu           sync.Mutex
	feed         string
	bootID       string
	revision     uint64
	closed       bool
	sessions     map[*diagnosticSession]struct{}
	stop         chan struct{}
	workerDone   chan struct{}
	kick         chan struct{}
	evicted      uint64
	connections  map[string]*diagnosticConnectionEntry
	liveCount    int
	liveAtomic   atomic.Int64
	recent       []*diagnosticConnectionEntry
	recentHead   int
	recentAtomic atomic.Int64
	dnsRecords   []DiagnosticDnsRecord
	dnsHead      int
	dnsAtomic    atomic.Int64
	logs         []diagnosticLogRecord
	logHead      int
	logDropped   atomic.Uint64
	logDone      chan struct{}
	sampleDue    time.Time
	timer        *time.Timer
	initializing bool
}

type diagnosticCaptureLease struct {
	hub        *diagnosticsHub
	conn       net.Conn
	workerDone chan struct{}
}

// diagIdentity 由 coreEngine 按值单向下推，diagnosticsHub 的全部 HTTP/WS 与关闭路径不再获取核心锁。
type diagIdentity struct {
	Running        bool
	BootID         string
	ConfigRevision uint64
	CaptureLogs    bool
}

type diagnosticsHub struct {
	// 严格单向锁序：eng.mu -> h.mu -> collector.mu -> h.statsMu。
	mu          sync.Mutex
	identity    diagIdentity
	reloading   bool
	connections *diagnosticCollector
	dns         *diagnosticCollector
	logs        *diagnosticCollector
	capture     *diagnosticCaptureLease
	// statsMu 始终作为叶子锁，禁止在持锁期间获取 h.mu 或 collector.mu。
	statsMu sync.Mutex
	stats   map[*diagnosticStatsSession]struct{}
}

func newDiagnosticsHub() *diagnosticsHub {
	return &diagnosticsHub{stats: make(map[*diagnosticStatsSession]struct{})}
}

var diagnosticIDs atomic.Uint64

func diagnosticID() string { return strconv.FormatUint(diagnosticIDs.Add(1), 16) }

func (h *diagnosticsHub) runtimeErrorLocked(boot string, revision uint64) (int, error) {
	if boot == "" || revision == 0 {
		return http.StatusBadRequest, errors.New("diagnostics_invalid_request")
	}
	if status, err := h.bootErrorLocked(boot); err != nil {
		return status, err
	}
	if h.reloading || revision != h.identity.ConfigRevision {
		return http.StatusConflict, errors.New("diagnostics_stale_runtime")
	}
	return 0, nil
}

func (h *diagnosticsHub) bootErrorLocked(boot string) (int, error) {
	if !h.identity.Running {
		return http.StatusServiceUnavailable, errors.New("diagnostics_not_ready")
	}
	if boot != h.identity.BootID {
		return http.StatusConflict, errors.New("diagnostics_stale_runtime")
	}
	return 0, nil
}

func (h *diagnosticsHub) checkBoot(boot string) (int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.bootErrorLocked(boot)
}

func subscribeDiagnostics(feed, expectedBootID string, expectedConfigRevision uint64) (*diagnosticSession, int, error) {
	return eng.diag.subscribe(feed, expectedBootID, expectedConfigRevision)
}

func (h *diagnosticsHub) subscribe(feed, expectedBootID string, expectedConfigRevision uint64) (*diagnosticSession, int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if feed != "connections" && feed != "dns" && feed != "logs" {
		return nil, http.StatusBadRequest, errors.New("diagnostics_invalid_request")
	}
	if feed == "logs" {
		if status, err := h.bootErrorLocked(expectedBootID); err != nil {
			return nil, status, err
		}
		if !h.identity.CaptureLogs {
			return nil, http.StatusForbidden, errDiagnosticLogsDisabled
		}
	} else if status, err := h.runtimeErrorLocked(expectedBootID, expectedConfigRevision); err != nil {
		return nil, status, err
	}
	owner := &h.connections
	switch feed {
	case "dns":
		owner = &h.dns
	case "logs":
		owner = &h.logs
	}
	c := h.ensureCollectorLocked(owner, feed)
	c.mu.Lock()
	if c.sessions == nil {
		c.sessions = make(map[*diagnosticSession]struct{})
	}
	now := time.Now()
	s := &diagnosticSession{wake: make(chan struct{}, 1), done: make(chan struct{}), workerDone: make(chan struct{}),
		collector: c, id: diagnosticID(), lastFrame: now}
	c.sessions[s] = struct{}{}
	s.initial = c.snapshotLocked(s, "snapshot", now)
	s.signalLocked()
	c.scheduleSampleLocked(now)
	c.mu.Unlock()
	return s, 0, nil
}

func (h *diagnosticsHub) ensureCollectorLocked(owner **diagnosticCollector, feed string) *diagnosticCollector {
	if c := *owner; c != nil {
		return c
	}
	revision := h.identity.ConfigRevision
	if feed == "logs" {
		// 日志采集按内核 boot 生命周期存活，跨配置热切换保留历史。
		revision = 0
	}
	c := &diagnosticCollector{hub: h, feed: feed, bootID: h.identity.BootID, revision: revision,
		stop: make(chan struct{}), workerDone: make(chan struct{}), kick: make(chan struct{}, 1)}
	if feed == "connections" {
		c.connections = make(map[string]*diagnosticConnectionEntry)
		c.initializing = true
		statistic.SetTrackerObserver(&statistic.TrackerObserver{Open: c.openConnection, Close: c.closeConnection})
		// Join 的通知早于 Store；Range 只能补基线，不能覆盖通知的建立/关闭事实。
		statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool { c.baselineConnection(tracker); return true })
		c.mu.Lock()
		c.initializing = false
		c.releaseUnreferencedLocked()
		c.mu.Unlock()
	} else if feed == "dns" {
		dns.SetQueryObserver(c.observeDNS)
	} else {
		c.collectLogs()
	}
	*owner = c
	go c.run()
	return c
}

func (h *diagnosticsHub) ensureCaptureCollectorsLocked() {
	if h.capture != nil && h.identity.Running {
		h.ensureCollectorLocked(&h.connections, "connections")
		h.ensureCollectorLocked(&h.dns, "dns")
	}
}

func acquireDiagnosticCapture(ctx context.Context, bootID string, conn net.Conn, readerDone <-chan struct{}) (*diagnosticCaptureLease, *diagnosticCaptureLease) {
	return eng.diag.acquireCapture(ctx, bootID, conn, readerDone)
}

func (h *diagnosticsHub) acquireCapture(ctx context.Context, bootID string, conn net.Conn, readerDone <-chan struct{}) (*diagnosticCaptureLease, *diagnosticCaptureLease) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, err := h.bootErrorLocked(bootID); err != nil || ctx.Err() != nil {
		return nil, nil
	}
	select {
	case <-readerDone:
		return nil, nil
	default:
	}
	lease := &diagnosticCaptureLease{hub: h, conn: conn, workerDone: make(chan struct{})}
	previous := h.capture
	h.capture = lease
	if previous != nil {
		_ = previous.conn.Close()
	}
	h.ensureCaptureCollectorsLocked()
	return lease, previous
}

func (lease *diagnosticCaptureLease) release() {
	h := lease.hub
	h.mu.Lock()
	if h.capture != lease {
		// 换手后旧连接退出不能注销新持有者。
		h.mu.Unlock()
		return
	}
	h.capture = nil
	workers := h.retireCollectorsLocked(true)
	h.mu.Unlock()
	waitDiagnosticWorkers(workers)
}

func (s *diagnosticSession) signalLocked() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}
func (c *diagnosticCollector) kickLocked() {
	select {
	case c.kick <- struct{}{}:
	default:
	}
}

func (s *diagnosticSession) enqueueLocked(event diagnosticEvent) {
	if s.closed {
		return
	}
	if s.needsReset {
		s.dropped++
		return
	}
	if event.kind == "traffic" {
		if index, ok := s.traffic[event.id]; ok {
			s.queue[index] = event
			return
		}
	}
	if len(s.queue) == diagnosticQueueLimit {
		s.dropped += uint64(len(s.queue) + 1)
		s.needsReset = true
		clear(s.queue)
		s.queue = s.queue[:0]
		clear(s.traffic)
		return
	}
	if s.queue == nil {
		s.queue = make([]diagnosticEvent, 0, diagnosticQueueLimit)
	}
	if event.kind == "traffic" {
		if s.traffic == nil {
			s.traffic = make(map[string]int)
		}
		s.traffic[event.id] = len(s.queue)
	}
	s.queue = append(s.queue, event)
}

func (c *diagnosticCollector) broadcastLocked(event diagnosticEvent) {
	wake := false
	for s := range c.sessions {
		if !s.pendingLocked() {
			wake = true
		}
		s.enqueueLocked(event)
	}
	if wake {
		c.kickLocked()
	}
}

func (s *diagnosticSession) pendingLocked() bool {
	return s.needsReset || len(s.queue) != 0 || s.heartbeat
}

func (s *diagnosticSession) nextFrame() any { return s.nextFrameAt(time.Now()) }
func (s *diagnosticSession) nextFrameAt(now time.Time) any {
	c := s.collector
	c.mu.Lock()
	defer c.mu.Unlock()
	if s.closed {
		return nil
	}
	if s.initial != nil {
		frame := s.initial
		s.initial = nil
		s.seq = 1
		s.lastFrame = now
		c.kickLocked()
		return frame
	}
	if !s.pendingLocked() || now.Before(s.lastFrame.Add(time.Second)) {
		return nil
	}
	var frame any
	if s.needsReset {
		frame = c.snapshotLocked(s, "reset", now)
	} else {
		frame = c.deltaLocked(s, now)
	}
	s.seq++
	s.lastFrame = now
	clear(s.queue)
	s.queue = s.queue[:0]
	clear(s.traffic)
	s.needsReset = false
	s.heartbeat = false
	c.kickLocked()
	return frame
}

func (c *diagnosticCollector) headerLocked(s *diagnosticSession, kind string, now time.Time) diagnosticHeader {
	return diagnosticHeader{Type: c.feed, Kind: kind, BootID: c.bootID, ConfigRevision: c.revision, SessionID: s.id,
		Seq: s.seq + 1, SampledAt: now.UnixMilli(), Dropped: s.dropped + c.logDropped.Load(), Evicted: c.evicted}
}

func (c *diagnosticCollector) run() {
	defer close(c.workerDone)
	for {
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			return
		}
		now := time.Now()
		if !c.sampleDue.IsZero() && !now.Before(c.sampleDue) {
			c.sampleConnectionsLocked(now)
		}
		due := c.sampleDue
		for s := range c.sessions {
			if s.initial != nil {
				s.signalLocked()
			}
			if !s.pendingLocked() {
				continue
			}
			next := s.lastFrame.Add(time.Second)
			if !now.Before(next) {
				s.signalLocked()
				continue
			}
			if due.IsZero() || next.Before(due) {
				due = next
			}
		}
		var tick <-chan time.Time
		if !due.IsZero() {
			delay := time.Until(due)
			if delay < 0 {
				delay = 0
			}
			if c.timer == nil {
				c.timer = time.NewTimer(delay)
			} else {
				c.timer.Reset(delay)
			}
			tick = c.timer.C
		}
		c.mu.Unlock()
		select {
		case <-c.stop:
			return
		case <-c.kick:
		case <-tick:
		}
		c.mu.Lock()
		if c.timer != nil && !c.timer.Stop() {
			select {
			case <-c.timer.C:
			default:
			}
		}
		c.mu.Unlock()
	}
}

func (s *diagnosticSession) attach(conn net.Conn) bool {
	c := s.collector
	c.mu.Lock()
	defer c.mu.Unlock()
	if s.closed {
		conn.Close()
		return false
	}
	s.conn = conn
	return true
}

func (s *diagnosticSession) close() {
	c := s.collector
	h := c.hub
	h.mu.Lock()
	c.mu.Lock()
	if s.closed {
		c.mu.Unlock()
		h.mu.Unlock()
		return
	}
	s.cancelLocked()
	delete(c.sessions, s)
	last := len(c.sessions) == 0
	retire := last && ((c.feed == "logs" && (!h.identity.Running || !h.identity.CaptureLogs)) ||
		(c.feed != "logs" && h.capture == nil && !h.hasStats()))
	if retire {
		c.retireLocked()
	} else if last && c.feed == "connections" {
		c.stopSamplingLocked()
	}
	c.mu.Unlock()
	if retire {
		c.uninstallLocked()
	}
	h.mu.Unlock()
	if retire {
		<-c.workerDone
		if c.logDone != nil {
			<-c.logDone
		}
	}
}

func (s *diagnosticSession) cancelLocked() {
	s.closed = true
	close(s.done)
	if s.conn != nil {
		s.conn.Close()
		s.conn = nil
	}
	s.initial = nil
	clear(s.queue)
	s.queue = nil
	clear(s.traffic)
}

func (c *diagnosticCollector) retireLocked() {
	c.closed = true
	close(c.stop)
	c.sampleDue = time.Time{}
	if c.timer != nil {
		c.timer.Stop()
		c.timer = nil
	}
	c.connections = nil
	c.liveCount = 0
	c.liveAtomic.Store(0)
	c.recent = nil
	c.recentAtomic.Store(0)
	c.dnsRecords = nil
	c.dnsAtomic.Store(0)
	c.logs = nil
}

// DNS 撤钩会等待正在执行的回调，必须先释放回调需要的 collector 锁。
func (c *diagnosticCollector) uninstallLocked() {
	h := c.hub
	if c.feed == "connections" {
		statistic.SetTrackerObserver(nil)
		if h.connections == c {
			h.connections = nil
		}
	} else if c.feed == "dns" {
		dns.SetQueryObserver(nil)
		if h.dns == c {
			h.dns = nil
		}
	} else if h.logs == c {
		log.SetArkClashLogObserver(nil)
		h.logs = nil
	}
}

func (h *diagnosticsHub) retireCollectorLocked(c *diagnosticCollector, onlyUnused bool) []<-chan struct{} {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	if onlyUnused && (len(c.sessions) != 0 || (c.feed != "logs" && h.hasStats())) {
		c.mu.Unlock()
		return nil
	}
	workers := make([]<-chan struct{}, 0, len(c.sessions)+1)
	for s := range c.sessions {
		if !s.closed {
			s.cancelLocked()
		}
		workers = append(workers, s.workerDone)
	}
	clear(c.sessions)
	c.retireLocked()
	c.mu.Unlock()
	c.uninstallLocked()
	if c.logDone != nil {
		workers = append(workers, c.logDone)
	}
	return append(workers, c.workerDone)
}

func (h *diagnosticsHub) retireCollectorsLocked(onlyUnused bool) []<-chan struct{} {
	var workers []<-chan struct{}
	for _, c := range [...]*diagnosticCollector{h.connections, h.dns} {
		workers = append(workers, h.retireCollectorLocked(c, onlyUnused)...)
	}
	return workers
}

func waitDiagnosticWorkers(workers []<-chan struct{}) {
	for _, done := range workers {
		<-done
	}
}

func (h *diagnosticsHub) stopLocked() []<-chan struct{} {
	workers := h.retireStatsLocked()
	workers = append(workers, h.retireCollectorsLocked(false)...)
	workers = append(workers, h.retireCollectorLocked(h.logs, false)...)
	if lease := h.capture; lease != nil {
		h.capture = nil
		_ = lease.conn.Close()
		workers = append(workers, lease.workerDone)
	}
	return workers
}

func (h *diagnosticsHub) Start(id diagIdentity) func() {
	h.mu.Lock()
	workers := h.stopLocked()
	h.identity = id
	h.reloading = false
	if id.Running && id.CaptureLogs {
		h.ensureCollectorLocked(&h.logs, "logs")
	}
	h.mu.Unlock()
	return func() { waitDiagnosticWorkers(workers) }
}

func (h *diagnosticsHub) BeginReload() func() {
	h.mu.Lock()
	h.reloading = true
	workers := h.retireStatsLocked()
	workers = append(workers, h.retireCollectorsLocked(false)...)
	h.mu.Unlock()
	return func() { waitDiagnosticWorkers(workers) }
}

// EndReload 接收完整运行身份，在所有走 CommitReload 的路径（含备份恢复）自动同步日志采集器启停。
func (h *diagnosticsHub) EndReload(id diagIdentity) func() {
	h.mu.Lock()
	h.identity = id
	h.reloading = false
	h.ensureCaptureCollectorsLocked()
	var workers []<-chan struct{}
	if id.Running && id.CaptureLogs {
		h.ensureCollectorLocked(&h.logs, "logs")
	} else {
		workers = h.retireCollectorLocked(h.logs, false)
	}
	h.mu.Unlock()
	if len(workers) == 0 {
		return nil
	}
	return func() { waitDiagnosticWorkers(workers) }
}

func (h *diagnosticsHub) SetCaptureLogs(enabled bool) func() {
	h.mu.Lock()
	h.identity.CaptureLogs = enabled
	var workers []<-chan struct{}
	if h.identity.Running && enabled {
		h.ensureCollectorLocked(&h.logs, "logs")
	} else {
		workers = h.retireCollectorLocked(h.logs, false)
	}
	h.mu.Unlock()
	if len(workers) == 0 {
		return nil
	}
	return func() { waitDiagnosticWorkers(workers) }
}

func (h *diagnosticsHub) Stop() func() {
	h.mu.Lock()
	h.identity = diagIdentity{}
	h.reloading = false
	workers := h.stopLocked()
	h.mu.Unlock()
	return func() { waitDiagnosticWorkers(workers) }
}

type diagnosticActionRequest struct {
	ExpectedBootID         string  `json:"expectedBootId"`
	ExpectedConfigRevision uint64  `json:"expectedConfigRevision"`
	Scope                  string  `json:"scope"`
	ID                     *string `json:"id"`
}

func readDiagnosticAction(r *http.Request, connections bool) (diagnosticActionRequest, error) {
	var request diagnosticActionRequest
	body, err := io.ReadAll(io.LimitReader(r.Body, 4097))
	var fields map[string]json.RawMessage
	if err != nil || len(body) > 4096 || json.Unmarshal(body, &fields) != nil || json.Unmarshal(body, &request) != nil ||
		request.ExpectedBootID == "" || request.ExpectedConfigRevision == 0 {
		return request, errors.New("diagnostics_invalid_request")
	}
	for key := range fields {
		if key != "expectedBootId" && key != "expectedConfigRevision" && (!connections || key != "scope" && key != "id") {
			return request, errors.New("diagnostics_invalid_request")
		}
	}
	if connections {
		_, hasID := fields["id"]
		if request.Scope != "one" && request.Scope != "all" || request.Scope == "one" && (request.ID == nil || *request.ID == "") || request.Scope == "all" && hasID {
			return request, errors.New("diagnostics_invalid_request")
		}
	}
	return request, nil
}

func postDiagnosticConnectionsClose(w http.ResponseWriter, r *http.Request) {
	diagnosticAction(w, r, true)
}
func postDiagnosticDnsClearCache(w http.ResponseWriter, r *http.Request) {
	diagnosticAction(w, r, false)
}
func diagnosticAction(w http.ResponseWriter, r *http.Request, connections bool) {
	request, err := readDiagnosticAction(r, connections)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	h := eng.diag
	h.mu.Lock()
	status, err := h.runtimeErrorLocked(request.ExpectedBootID, request.ExpectedConfigRevision)
	if err == nil {
		if !connections {
			dns.ClearAll()
		} else if request.Scope == "all" {
			statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
				if tracker.Close() != nil {
					err = errors.New("diagnostics_operation_failed")
				}
				return true
			})
		} else if tracker := statistic.DefaultManager.Get(*request.ID); tracker != nil {
			if tracker.Close() != nil {
				err = errors.New("diagnostics_operation_failed")
			}
		}
	}
	h.mu.Unlock()
	if err != nil {
		if status == 0 {
			status = http.StatusInternalServerError
		}
		writeError(w, r, status, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
