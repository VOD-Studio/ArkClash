package main

import (
	"encoding/json"
	"net"
	"sync"
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

// diagnosticStatsMu 始终作为叶子锁，禁止在持锁期间获取 mu 或 collector 锁。
var (
	diagnosticStatsMu       sync.Mutex
	diagnosticStatsSessions = map[*diagnosticStatsSession]struct{}{}
)

func hasDiagnosticStats() bool {
	diagnosticStatsMu.Lock()
	active := len(diagnosticStatsSessions) != 0
	diagnosticStatsMu.Unlock()
	return active
}

func notifyDiagnosticStats() {
	diagnosticStatsMu.Lock()
	for s := range diagnosticStatsSessions {
		select {
		case s.dirty <- struct{}{}:
		default:
		}
	}
	diagnosticStatsMu.Unlock()
}

func subscribeDiagnosticStats(expectedBootID string, expectedConfigRevision uint64) (*diagnosticStatsSession, int, error) {
	mu.Lock()
	defer mu.Unlock()
	if status, err := diagnosticRuntimeError(expectedBootID, expectedConfigRevision); err != nil {
		return nil, status, err
	}
	// 仅挂观察器而不向 collector.sessions 注册，避免仪表盘触发连接页的 1Hz 流量采样。
	connections := ensureDiagnosticCollectorLocked(&diagnosticConnections, "connections")
	queries := ensureDiagnosticCollectorLocked(&diagnosticDNS, "dns")
	s := &diagnosticStatsSession{
		bootID:      expectedBootID,
		revision:    expectedConfigRevision,
		connections: connections,
		dns:         queries,
		dirty:       make(chan struct{}, 1),
		done:        make(chan struct{}),
		workerDone:  make(chan struct{}),
	}
	diagnosticStatsMu.Lock()
	diagnosticStatsSessions[s] = struct{}{}
	diagnosticStatsMu.Unlock()
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
	diagnosticStatsMu.Lock()
	if s.closed {
		diagnosticStatsMu.Unlock()
		_ = conn.Close()
		return false
	}
	s.conn = conn
	diagnosticStatsMu.Unlock()
	return true
}

func (s *diagnosticStatsSession) close() {
	mu.Lock()
	diagnosticStatsMu.Lock()
	if s.closed {
		diagnosticStatsMu.Unlock()
		mu.Unlock()
		return
	}
	s.closed = true
	close(s.done)
	conn := s.conn
	s.conn = nil
	delete(diagnosticStatsSessions, s)
	last := len(diagnosticStatsSessions) == 0
	diagnosticStatsMu.Unlock()
	var workers []<-chan struct{}
	if last && diagnosticCapture == nil {
		workers = retireDiagnosticCollectorsLocked(true)
	}
	mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
	waitDiagnosticWorkers(workers)
}

func retireDiagnosticStatsLocked() []<-chan struct{} {
	diagnosticStatsMu.Lock()
	workers := make([]<-chan struct{}, 0, len(diagnosticStatsSessions))
	conns := make([]net.Conn, 0, len(diagnosticStatsSessions))
	for s := range diagnosticStatsSessions {
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
	clear(diagnosticStatsSessions)
	diagnosticStatsMu.Unlock()
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
