package main

import (
	"encoding/json"
	"net"
	"time"

	"github.com/metacubex/http"
)

// 仪表盘统计流默认最多每秒推送一次，无变化时不发帧；测试可调小间隔加速验证。
var diagnosticStatsInterval = time.Second

type diagnosticStatsFrame struct {
	Type           string `json:"type"`
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	Live           int    `json:"live"`
	Recent         int    `json:"recent"`
	DNS            int    `json:"dns"`
}

type diagnosticStatsSession struct {
	hub         *diagnosticsHub
	bootID      string
	revision    uint64
	connections *diagnosticCollector
	dns         *diagnosticCollector
	dirty       chan struct{}
	done        chan struct{}
	workerDone  chan struct{}
	conn        net.Conn
	closed      bool
}

func (h *diagnosticsHub) hasStats() bool {
	h.statsMu.Lock()
	active := len(h.stats) != 0
	h.statsMu.Unlock()
	return active
}

func notifyDiagnosticStats() {
	eng.diag.notifyStats()
}

func (h *diagnosticsHub) notifyStats() {
	h.statsMu.Lock()
	for s := range h.stats {
		select {
		case s.dirty <- struct{}{}:
		default:
		}
	}
	h.statsMu.Unlock()
}

func subscribeDiagnosticStats(expectedBootID string, expectedConfigRevision uint64) (*diagnosticStatsSession, int, error) {
	return eng.diag.subscribeStats(expectedBootID, expectedConfigRevision)
}

func (h *diagnosticsHub) subscribeStats(expectedBootID string, expectedConfigRevision uint64) (*diagnosticStatsSession, int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if status, err := h.runtimeErrorLocked(expectedBootID, expectedConfigRevision); err != nil {
		return nil, status, err
	}
	// 仅挂观察器而不向 collector.sessions 注册，避免仪表盘触发连接页的 1Hz 流量采样。
	connections := h.ensureCollectorLocked(&h.connections, "connections")
	queries := h.ensureCollectorLocked(&h.dns, "dns")
	s := &diagnosticStatsSession{
		hub:         h,
		bootID:      expectedBootID,
		revision:    expectedConfigRevision,
		connections: connections,
		dns:         queries,
		dirty:       make(chan struct{}, 1),
		done:        make(chan struct{}),
		workerDone:  make(chan struct{}),
	}
	h.statsMu.Lock()
	h.stats[s] = struct{}{}
	h.statsMu.Unlock()
	return s, 0, nil
}

func (s *diagnosticStatsSession) snapshot() diagnosticStatsFrame {
	return diagnosticStatsFrame{
		Type:           "stats",
		BootID:         s.bootID,
		ConfigRevision: s.revision,
		Live:           int(s.connections.liveAtomic.Load()),
		Recent:         int(s.connections.recentAtomic.Load()),
		DNS:            int(s.dns.dnsAtomic.Load()),
	}
}

func (s *diagnosticStatsSession) attach(conn net.Conn) bool {
	h := s.hub
	h.statsMu.Lock()
	if s.closed {
		h.statsMu.Unlock()
		_ = conn.Close()
		return false
	}
	s.conn = conn
	h.statsMu.Unlock()
	return true
}

func (s *diagnosticStatsSession) close() {
	h := s.hub
	h.mu.Lock()
	h.statsMu.Lock()
	if s.closed {
		h.statsMu.Unlock()
		h.mu.Unlock()
		return
	}
	s.closed = true
	close(s.done)
	conn := s.conn
	s.conn = nil
	delete(h.stats, s)
	last := len(h.stats) == 0
	h.statsMu.Unlock()
	var workers []<-chan struct{}
	if last && h.capture == nil {
		workers = h.retireCollectorsLocked(true)
	}
	h.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
	waitDiagnosticWorkers(workers)
}

func (h *diagnosticsHub) retireStatsLocked() []<-chan struct{} {
	h.statsMu.Lock()
	workers := make([]<-chan struct{}, 0, len(h.stats))
	conns := make([]net.Conn, 0, len(h.stats))
	for s := range h.stats {
		if !s.closed {
			s.closed = true
			close(s.done)
		}
		if s.conn != nil {
			conns = append(conns, s.conn)
			s.conn = nil
		}
		workers = append(workers, s.workerDone)
	}
	clear(h.stats)
	h.statsMu.Unlock()
	for _, conn := range conns {
		_ = conn.Close()
	}
	return workers
}

func writeDiagnosticStatsFrame(writer *diagnosticSocketWriter, frame diagnosticStatsFrame) error {
	data, err := json.Marshal(frame)
	if err != nil {
		return err
	}
	return writer.text(data)
}

func getDiagnosticStats(w http.ResponseWriter, r *http.Request) {
	bootID, revision, err := diagnosticStreamRuntime(r, true)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	session, status, err := subscribeDiagnosticStats(bootID, revision)
	if err != nil {
		writeError(w, r, status, err)
		return
	}
	defer close(session.workerDone)
	defer session.close()
	conn, rw, err := upgradeWebSocket(w, r)
	if err != nil {
		return
	}
	defer conn.Close()
	if !session.attach(conn) {
		return
	}
	writer, readerDone, stop := startDiagnosticSocket(r, conn, rw.Reader)
	defer stop()

	last := session.snapshot()
	if writeDiagnosticStatsFrame(writer, last) != nil {
		return
	}
	lastSent := time.Now()
	var timer *time.Timer
	var timerCh <-chan time.Time
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	pending := false
	for {
		select {
		case <-r.Context().Done():
			return
		case <-session.done:
			return
		case <-readerDone:
			return
		case <-session.dirty:
			now := time.Now()
			wait := lastSent.Add(diagnosticStatsInterval).Sub(now)
			if wait <= 0 {
				if pending && timer != nil {
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
					timerCh = nil
				}
				pending = false
				current := session.snapshot()
				if current != last {
					if writeDiagnosticStatsFrame(writer, current) != nil {
						return
					}
					last = current
					lastSent = now
				}
			} else if !pending {
				pending = true
				if timer == nil {
					timer = time.NewTimer(wait)
				} else {
					timer.Reset(wait)
				}
				timerCh = timer.C
			}
		case <-timerCh:
			timerCh = nil
			pending = false
			current := session.snapshot()
			if current != last {
				if writeDiagnosticStatsFrame(writer, current) != nil {
					return
				}
				last = current
				lastSent = time.Now()
			}
		}
	}
}
